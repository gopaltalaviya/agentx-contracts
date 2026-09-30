// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "openzeppelin-contracts/utils/math/SafeCast.sol";

/// @title AgentAccount — an agent's wallet, with spending limits enforced
///        ON-CHAIN rather than on someone's server
///
/// @notice Skyfire, Nevermined and Coinbase Agentic Wallets all offer spend
///         controls, but off-chain and custodially: you trust their server.
///         These caps are verifiable by anyone and survive a full compromise
///         of the AGENTX signer — even with the hot key, an attacker cannot
///         exceed the daily cap or call anything the owner never allowlisted.
///
///         The human never approves individual payments — that is the whole
///         point of an autonomous agent — but keeps the two powers that matter:
///         **revoke** and **sweep**.
///
/// @dev Spend is measured as the ACTUAL balance delta of `token` across the
///      call, not decoded from calldata. Calldata decoding has to know every
///      function signature it might meet and silently misreads anything new;
///      a balance delta cannot be fooled by an unfamiliar call.
///
///      Only `token` is measured. The allowlist is therefore per (target,
///      selector): allowing `transfer` on the payment token does not allow
///      `transfer` on any other contract, whose balance no cap would see. And
///      no selector that grants a standing allowance can ever be allowed —
///      allowances are granted by the owner via `setAllowance`, so every spend
///      shows up as a delta while the call is running.
///
///      The daily cap is a FIXED window: it resets 24h after the first spend
///      of a window, not continuously. Up to 2× `dailyCap` can therefore be
///      spent across a window boundary. The signer and the API model exactly
///      this, and report when the window resets.
contract AgentAccount is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @param perTaskCap most one call may spend
    /// @param dailyCap most one window may spend
    /// @param allowlistOnly when false, a selector allowed for `address(0)`
    ///        is allowed on every target
    struct Policy {
        uint128 perTaskCap;
        uint128 dailyCap;
        bool allowlistOnly;
    }

    /// @notice Longest life a session key may be granted, enforced on grant.
    uint64 public constant MAX_SESSION_KEY_TTL = 1 days;

    struct SessionKey {
        uint64 expiry;
        uint128 budget;
        uint128 spent;
    }

    address public owner;
    /// @notice The owner named by `transferOwnership`, until they accept.
    address public pendingOwner;
    IERC20 public token;
    Policy public policy;

    uint128 public spentToday;
    uint64 public dayStart;

    mapping(address => SessionKey) public sessionKeys;
    /// @notice Whether `selector` may be called on `target` through `execute`.
    mapping(address target => mapping(bytes4 selector => bool)) public allowedCall;
    /// @notice How many selectors are allowed on each target.
    mapping(address target => uint256) public allowedCallCount;

    event Initialized(address indexed owner, address token);
    event PolicySet(uint128 perTaskCap, uint128 dailyCap, bool allowlistOnly);
    event SessionKeyGranted(address indexed key, uint64 expiry, uint128 budget);
    event SessionKeyRevoked(address indexed key);
    event CallAllowed(address indexed target, bytes4 indexed selector, bool allowed);
    event Executed(address indexed target, bytes4 selector, uint128 spent);
    event Swept(address indexed to, uint256 amount);
    event NativeSwept(address indexed to, uint256 amount);
    event AllowanceSet(address indexed spender, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotAuthorized();
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(bytes4 selector);
    /// @dev A selector that would hand out a standing allowance or approval.
    error ForbiddenSelector(bytes4 selector);
    error PerTaskCapExceeded(uint128 spend, uint128 cap);
    error DailyCapExceeded(uint128 spend, uint128 remaining);
    error SessionKeyExpired();
    error SessionKeyTtlInvalid(uint64 expiry, uint64 latestAllowed);
    error SessionBudgetExceeded();
    error CallFailed(bytes returndata);
    error ZeroAddress();
    error NativeTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        // The implementation behind the clones must never be initialisable.
        _disableInitializers();
    }

    /// @notice Called once, by the factory, on a fresh clone.
    /// @param owner_ the human (or multisig) that controls the account
    /// @param token_ the token whose outflow the caps measure
    /// @param policy_ the caps
    function initialize(address owner_, address token_, Policy calldata policy_)
        external
        initializer
    {
        if (owner_ == address(0) || token_ == address(0)) revert ZeroAddress();
        owner = owner_;
        token = IERC20(token_);
        policy = policy_;
        dayStart = uint64(block.timestamp);
        emit Initialized(owner_, token_);
        emit PolicySet(policy_.perTaskCap, policy_.dailyCap, policy_.allowlistOnly);
    }

    // ───────────────────────── execution ─────────────────────────

    /// @notice Perform a call on the agent's behalf, within policy.
    /// @dev The checks run in this order, cheapest first:
    ///        1. caller is the owner, or an unexpired session key
    ///        2. (target, selector) is allowed, and never a forbidden selector
    ///        3. spend <= perTaskCap
    ///        4. spentToday + spend <= dailyCap   (fixed 24h window)
    ///      3 and 4 can only be checked AFTER the call, because the spend is a
    ///      measured balance delta. The call is reverted if it overspends, so
    ///      an over-cap call has no effect — it is checked, not merely detected.
    /// @param target the contract to call
    /// @param data the calldata
    /// @return result the call's return data
    // The spend can only be measured AFTER the call, so the cap state is
    // written after it — safe because execute is nonReentrant, and an
    // over-cap call reverts entirely.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function execute(address target, bytes calldata data)
        external
        nonReentrant
        returns (bytes memory result)
    {
        bool isOwner = msg.sender == owner;
        if (!isOwner) _requireValidSessionKey(msg.sender);

        // The account's own controls are owner-only functions, reached
        // directly. Through `execute` they would be callable by a session key.
        if (target == address(this)) revert TargetNotAllowed(target);

        // The first four bytes are the selector by definition.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data);
        if (_isForbidden(selector)) revert ForbiddenSelector(selector);
        if (!allowedCall[target][selector]) {
            if (policy.allowlistOnly || !allowedCall[address(0)][selector]) {
                if (allowedCallCount[target] == 0) revert TargetNotAllowed(target);
                revert SelectorNotAllowed(selector);
            }
        }

        uint256 balanceBefore = token.balanceOf(address(this));

        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallFailed(ret);

        uint256 balanceAfter = token.balanceOf(address(this));
        // Checked: a delta beyond uint128 used to wrap to a small number and
        // pass the caps.
        uint128 spent =
            balanceAfter >= balanceBefore ? 0 : SafeCast.toUint128(balanceBefore - balanceAfter);

        if (spent > 0) {
            _chargeSpend(spent, isOwner ? address(0) : msg.sender);
        }

        emit Executed(target, selector, spent);
        return ret;
    }

    function _chargeSpend(uint128 spent, address sessionKey) internal {
        if (spent > policy.perTaskCap) revert PerTaskCapExceeded(spent, policy.perTaskCap);

        // Roll the window before testing it, so a stale day never blocks work.
        if (block.timestamp >= dayStart + 1 days) {
            dayStart = uint64(block.timestamp);
            spentToday = 0;
        }

        uint128 remaining = policy.dailyCap > spentToday ? policy.dailyCap - spentToday : 0;
        if (spent > remaining) revert DailyCapExceeded(spent, remaining);
        spentToday += spent;

        if (sessionKey != address(0)) {
            SessionKey storage sk = sessionKeys[sessionKey];
            if (sk.spent + spent > sk.budget) revert SessionBudgetExceeded();
            sk.spent += spent;
        }
    }

    function _requireValidSessionKey(address key) internal view {
        SessionKey storage sk = sessionKeys[key];
        if (sk.expiry == 0) revert NotAuthorized();
        if (block.timestamp > sk.expiry) revert SessionKeyExpired();
    }

    /// @dev Selectors that grant a standing allowance or approval. Any of them
    ///      would let a spender move funds outside every cap, with no delta
    ///      visible while `execute` runs.
    function _isForbidden(bytes4 selector) internal pure returns (bool) {
        return selector == IERC20.approve.selector // approve(address,uint256)
            || selector == 0x39509351 // increaseAllowance(address,uint256)
            || selector == 0xa22cb465 // setApprovalForAll(address,bool)
            || 
            // permit(address,address,uint256,uint256,uint8,bytes32,bytes32)
            selector == 0xd505accf;
    }

    // ───────────────────────── owner controls ─────────────────────────

    /// @notice Replace the caps.
    /// @param policy_ the new caps
    function setPolicy(Policy calldata policy_) external onlyOwner {
        policy = policy_;
        emit PolicySet(policy_.perTaskCap, policy_.dailyCap, policy_.allowlistOnly);
    }

    /// @notice Grant a hot key a bounded, expiring right to act.
    /// @dev Rotation is a grant plus a revoke: no funds move, no downtime.
    ///      The lifetime ceiling is enforced HERE rather than left to whoever
    ///      calls this: a session key exists so that compromise of an online
    ///      signer is bounded in time (docs/04 §9.2 T7). A past expiry is
    ///      rejected too — it would log a grant for a key that never worked.
    /// @param key the hot key
    /// @param expiry unix time; within MAX_SESSION_KEY_TTL of now
    /// @param budget most the key may spend over its life
    function grantSessionKey(address key, uint64 expiry, uint128 budget) external onlyOwner {
        uint64 latest = uint64(block.timestamp) + MAX_SESSION_KEY_TTL;
        if (expiry <= block.timestamp || expiry > latest) {
            revert SessionKeyTtlInvalid(expiry, latest);
        }

        sessionKeys[key] = SessionKey({expiry: expiry, budget: budget, spent: 0});
        emit SessionKeyGranted(key, expiry, budget);
    }

    /// @notice Revocable by the owner OR by the key itself, so a signer that
    ///         detects its own compromise can disarm without waiting.
    /// @param key the key to revoke
    function revokeSessionKey(address key) external {
        if (msg.sender != owner && msg.sender != key) revert NotAuthorized();
        delete sessionKeys[key];
        emit SessionKeyRevoked(key);
    }

    /// @notice Allow or disallow one function on one contract.
    /// @param target the contract; `address(0)` is a wildcard used only when
    ///        `allowlistOnly` is false
    /// @param selector the function
    /// @param allowed whether it may be called through `execute`
    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyOwner {
        if (allowed && _isForbidden(selector)) revert ForbiddenSelector(selector);
        if (allowed && target == address(this)) revert TargetNotAllowed(target);
        bool was = allowedCall[target][selector];
        if (was == allowed) return;
        allowedCall[target][selector] = allowed;
        if (allowed) allowedCallCount[target] += 1;
        else allowedCallCount[target] -= 1;
        emit CallAllowed(target, selector, allowed);
    }

    /// @notice Grant a standing ERC-20 allowance. Owner only, deliberately
    ///         outside `execute` so it can never be done by a session key.
    /// @param spender who may pull `token`
    /// @param amount the allowance
    function setAllowance(address spender, uint256 amount) external onlyOwner {
        token.forceApprove(spender, amount);
        emit AllowanceSet(spender, amount);
    }

    /// @notice The kill switch. Autonomy with a way out.
    /// @param to where the tokens go
    /// @param amount base units
    function sweep(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Swept(to, amount);
    }

    /// @notice Recover the native coin. `execute` forwards none, so without
    ///         this anything sent here was locked for good.
    /// @param to where it goes
    /// @param amount wei
    function sweepNative(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativeSwept(to, amount);
    }

    /// @notice Begin handing the account to `newOwner`, who must accept.
    ///         Two steps, so a typo cannot hand an account to nobody.
    /// @param newOwner the proposed owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept a pending transfer. The pending owner only.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @return what may still be spent in the current window
    function dailyRemaining() external view returns (uint128) {
        if (block.timestamp >= dayStart + 1 days) return policy.dailyCap;
        return policy.dailyCap > spentToday ? policy.dailyCap - spentToday : 0;
    }

    receive() external payable {}
}
