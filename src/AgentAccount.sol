// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title AgentAccount — an agent's wallet, with spending limits enforced
///        ON-CHAIN rather than on someone's server
///
/// @notice Skyfire, Nevermined and Coinbase Agentic Wallets all offer spend
///         controls, but off-chain and custodially: you trust their server.
///         These caps are verifiable by anyone and survive a full compromise
///         of the AGENTX signer — even with the hot key, an attacker cannot
///         exceed the daily cap or pay an address the owner never allowlisted.
///
///         The human never approves individual payments — that is the whole
///         point of an autonomous agent — but keeps the two powers that matter:
///         **revoke** and **sweep**.
///
/// @dev Spend is measured as the ACTUAL token balance delta across the call,
///      not decoded from calldata. Calldata decoding has to know every
///      function signature it might meet and silently misreads anything new;
///      a balance delta cannot be fooled by an unfamiliar call.
///
///      For that to be sound, the account must never hand out a standing
///      allowance through `execute` — `approve` is not an allowlisted selector.
///      Allowances are granted by the owner via `setAllowance`, so every spend
///      shows up as a delta while the call is running.
contract AgentAccount is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

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
    IERC20 public token;
    Policy public policy;

    uint128 public spentToday;
    uint64 public dayStart;

    mapping(address => SessionKey) public sessionKeys;
    mapping(address => bool) public allowedTarget;
    mapping(bytes4 => bool) public allowedSelector;

    event Initialized(address indexed owner, address token);
    event PolicySet(uint128 perTaskCap, uint128 dailyCap, bool allowlistOnly);
    event SessionKeyGranted(address indexed key, uint64 expiry, uint128 budget);
    event SessionKeyRevoked(address indexed key);
    event TargetAllowed(address indexed target, bool allowed);
    event SelectorAllowed(bytes4 indexed selector, bool allowed);
    event Executed(address indexed target, bytes4 selector, uint128 spent);
    event Swept(address indexed to, uint256 amount);
    event AllowanceSet(address indexed spender, uint256 amount);

    error NotOwner();
    error NotAuthorized();
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(bytes4 selector);
    error PerTaskCapExceeded(uint128 spend, uint128 cap);
    error DailyCapExceeded(uint128 spend, uint128 remaining);
    error SessionKeyExpired();
    error SessionKeyTtlInvalid(uint64 expiry, uint64 latestAllowed);
    error SessionBudgetExceeded();
    error CallFailed(bytes returndata);
    error ApproveNotAllowedHere();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        // The implementation behind the clones must never be initialisable.
        _disableInitializers();
    }

    function initialize(address owner_, address token_, Policy calldata policy_)
        external
        initializer
    {
        owner = owner_;
        token = IERC20(token_);
        policy = policy_;
        dayStart = uint64(block.timestamp);
        emit Initialized(owner_, token_);
        emit PolicySet(policy_.perTaskCap, policy_.dailyCap, policy_.allowlistOnly);
    }

    // ───────────────────────── execution ─────────────────────────

    /// @notice Perform a call on the agent's behalf, within policy.
    /// @dev The five checks run in this order, cheapest first:
    ///        1. caller is the owner, or an unexpired session key
    ///        2. target is allowlisted
    ///        3. selector is allowlisted
    ///        4. spend <= perTaskCap
    ///        5. spentToday + spend <= dailyCap   (rolling 24h window)
    ///      4 and 5 can only be checked AFTER the call, because the spend is a
    ///      measured balance delta. The call is reverted if it overspends, so
    ///      an over-cap call has no effect — it is checked, not merely detected.
    function execute(address target, bytes calldata data)
        external
        nonReentrant
        returns (bytes memory result)
    {
        bool isOwner = msg.sender == owner;
        if (!isOwner) _requireValidSessionKey(msg.sender);

        if (policy.allowlistOnly && !allowedTarget[target]) revert TargetNotAllowed(target);

        bytes4 selector = bytes4(data);
        if (!allowedSelector[selector]) revert SelectorNotAllowed(selector);
        // Unreachable today, because setAllowedSelector refuses to allowlist
        // `approve` in the first place — so this line is dead by construction
        // and shows as uncovered. It stays because a standing allowance would
        // let a spender move funds outside every cap, and the day someone
        // relaxes that setter, this is the check that still holds.
        if (selector == IERC20.approve.selector) revert ApproveNotAllowedHere();

        uint256 balanceBefore = token.balanceOf(address(this));

        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallFailed(ret);

        uint256 balanceAfter = token.balanceOf(address(this));
        uint128 spent = balanceAfter >= balanceBefore ? 0 : uint128(balanceBefore - balanceAfter);

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

    // ───────────────────────── owner controls ─────────────────────────

    function setPolicy(Policy calldata policy_) external onlyOwner {
        policy = policy_;
        emit PolicySet(policy_.perTaskCap, policy_.dailyCap, policy_.allowlistOnly);
    }

    /// @notice Grant a hot key a bounded, expiring right to spend.
    /// @dev Rotation is a grant plus a revoke: no funds move, no downtime.
    ///
    ///      The lifetime ceiling is enforced HERE rather than left to whoever
    ///      calls this. A session key exists so that compromise of an online
    ///      signer is bounded in time; one granted until the heat death of the
    ///      universe is a permanent key with extra steps, and a time bound that
    ///      depends on the caller getting it right is not a control. The threat
    ///      model (docs/04 §9.2 T7) claims this bound, so the contract makes it
    ///      true.
    ///
    ///      A past expiry is rejected too: it would emit a grant event for a
    ///      key that never worked, which reads as a working key in the log.
    function grantSessionKey(address key, uint64 expiry, uint128 budget) external onlyOwner {
        uint64 latest = uint64(block.timestamp) + MAX_SESSION_KEY_TTL;
        if (expiry <= block.timestamp || expiry > latest) revert SessionKeyTtlInvalid(expiry, latest);

        sessionKeys[key] = SessionKey({expiry: expiry, budget: budget, spent: 0});
        emit SessionKeyGranted(key, expiry, budget);
    }

    /// @notice Revocable by the owner OR by the key itself, so a signer that
    ///         detects its own compromise can disarm without waiting.
    function revokeSessionKey(address key) external {
        if (msg.sender != owner && msg.sender != key) revert NotAuthorized();
        delete sessionKeys[key];
        emit SessionKeyRevoked(key);
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTarget[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function setAllowedSelector(bytes4 selector, bool allowed) external onlyOwner {
        if (selector == IERC20.approve.selector && allowed) revert ApproveNotAllowedHere();
        allowedSelector[selector] = allowed;
        emit SelectorAllowed(selector, allowed);
    }

    /// @notice Grant a standing ERC-20 allowance. Owner only, deliberately
    ///         outside `execute` so it can never be done by a session key.
    function setAllowance(address spender, uint256 amount) external onlyOwner {
        token.forceApprove(spender, amount);
        emit AllowanceSet(spender, amount);
    }

    /// @notice The kill switch. Autonomy with a way out.
    function sweep(address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
        emit Swept(to, amount);
    }

    function dailyRemaining() external view returns (uint128) {
        if (block.timestamp >= dayStart + 1 days) return policy.dailyCap;
        return policy.dailyCap > spentToday ? policy.dailyCap - spentToday : 0;
    }

    receive() external payable {}
}
