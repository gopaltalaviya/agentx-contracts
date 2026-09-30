// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIdentityRegistry} from "./interfaces/IERC8004.sol";
import {IStakeVault} from "./interfaces/IStakeVault.sol";
import {
    AccessControlDefaultAdminRules
} from "openzeppelin-contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title StakeVault — bonds keyed by ERC-8004 agentId
/// @notice ERC-8004 has no custody, so being listed costs nothing and identity
///         is disposable. A published study of the live ecosystem found exactly
///         that: coordinated sybil registrations and dormant agents. This makes
///         being *hireable through AGENTX* cost a bond with a withdrawal delay,
///         while leaving identity itself free and open as the standard intends.
contract StakeVault is IStakeVault, AccessControlDefaultAdminRules, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant CONFIGURER_ROLE = keccak256("CONFIGURER_ROLE");

    /// @dev Longest cooldown governance may impose. Beyond this a bond is a lock-up.
    uint64 public constant MAX_WITHDRAW_DELAY = 90 days;

    struct Bond {
        uint96 available; // counts toward isHireable
        uint96 pending; // requested for withdrawal, still slashable
        uint64 unlockAt;
    }

    IERC20 public token;
    IIdentityRegistry public identityRegistry;
    uint96 public minStake;
    uint64 public withdrawDelay;
    /// @notice Where slashed bonds go. Slashed tokens never stay stranded here.
    address public slashRecipient;
    bool public configured;

    mapping(uint256 agentId => Bond) internal _bonds;

    /// @notice The dependencies and first parameters were set, once.
    event Configured(
        address indexed token,
        address indexed identityRegistry,
        uint96 minStake,
        uint64 withdrawDelay,
        address indexed slashRecipient
    );
    /// @notice The bond required to be hireable changed.
    event MinStakeUpdated(uint96 previous, uint96 current);
    /// @notice Slashed bonds now go to `recipient`.
    event SlashRecipientSet(address indexed recipient);

    error AlreadyConfigured();
    error NotConfigured();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidDelay();
    error TokenDeliveredLess(uint256 asked, uint256 received);

    /// @param admin holds the default admin and configurer roles
    /// @param adminDelay seconds a transfer of the default admin role must wait
    constructor(address admin, uint48 adminDelay)
        AccessControlDefaultAdminRules(adminDelay, admin)
    {
        _grantRole(CONFIGURER_ROLE, admin);
    }

    /// @notice Set the dependencies and first parameters. Once only.
    /// @param token_ the bond token
    /// @param identityRegistry_ the ERC-8004 identity registry
    /// @param minStake_ bond required to be hireable; non-zero
    /// @param withdrawDelay_ cooldown, 1 second to 90 days
    /// @param slashRecipient_ where slashed bonds go
    function configure(
        address token_,
        address identityRegistry_,
        uint96 minStake_,
        uint64 withdrawDelay_,
        address slashRecipient_
    ) external onlyRole(CONFIGURER_ROLE) {
        if (configured) revert AlreadyConfigured();
        if (
            token_ == address(0) || identityRegistry_ == address(0) || slashRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (minStake_ == 0) revert ZeroAmount();
        if (withdrawDelay_ == 0 || withdrawDelay_ > MAX_WITHDRAW_DELAY) revert InvalidDelay();

        configured = true;
        token = IERC20(token_);
        identityRegistry = IIdentityRegistry(identityRegistry_);
        minStake = minStake_;
        withdrawDelay = withdrawDelay_;
        slashRecipient = slashRecipient_;
        emit Configured(token_, identityRegistry_, minStake_, withdrawDelay_, slashRecipient_);
    }

    /// @inheritdoc IStakeVault
    // Balance read around transferFrom on purpose (fee-on-transfer guard); nonReentrant.
    // slither-disable-next-line reentrancy-balance,reentrancy-benign
    function deposit(uint256 agentId, uint96 amount) external nonReentrant {
        if (!configured) revert NotConfigured();
        if (amount == 0) revert ZeroAmount();

        // Credit only what arrived. Crediting the asked-for amount under a
        // fee-on-transfer token would let one agent's bond be withdrawn out
        // of another's deposit.
        uint256 received = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - received;
        if (received != amount) revert TokenDeliveredLess(amount, received);

        _bonds[agentId].available += amount;
        emit Deposited(agentId, msg.sender, amount);
    }

    /// @inheritdoc IStakeVault
    /// @dev One request at a time. A second used to reset the first one's
    ///      unlock time silently; now the owner cancels and re-requests, which
    ///      says what it does.
    function requestWithdraw(uint256 agentId, uint96 amount) external {
        _onlyAgentOwner(agentId);
        Bond storage b = _bonds[agentId];
        if (amount == 0) revert ZeroAmount();
        if (b.pending != 0) revert WithdrawAlreadyPending();
        if (b.available < amount) revert InsufficientBond();

        b.available -= amount;
        b.pending = amount;
        b.unlockAt = uint64(block.timestamp) + withdrawDelay;

        emit WithdrawRequested(agentId, amount, b.unlockAt);
    }

    /// @inheritdoc IStakeVault
    function cancelWithdraw(uint256 agentId) external {
        _onlyAgentOwner(agentId);
        Bond storage b = _bonds[agentId];
        uint96 amount = b.pending;
        if (amount == 0) revert NothingRequested();

        b.pending = 0;
        b.unlockAt = 0;
        b.available += amount;
        emit WithdrawCancelled(agentId, amount);
    }

    /// @inheritdoc IStakeVault
    function withdraw(uint256 agentId) external nonReentrant {
        address owner = _onlyAgentOwner(agentId);
        Bond storage b = _bonds[agentId];

        uint96 amount = b.pending;
        if (amount == 0) revert NothingRequested();
        if (block.timestamp < b.unlockAt) revert WithdrawNotReady();

        b.pending = 0;
        b.unlockAt = 0;

        token.safeTransfer(owner, amount);
        emit Withdrawn(agentId, owner, amount);
    }

    /// @inheritdoc IStakeVault
    /// @dev Takes from `available` first and then from `pending`, so requesting
    ///      a withdrawal is not an escape hatch from being slashed. The tokens
    ///      go to `slashRecipient`; v1 only decremented storage and left them
    ///      in the vault, owned by nobody.
    ///      No role holder is granted SLASHER_ROLE in the MVP — the capability
    ///      exists, automatic slashing does not.
    function slash(uint256 agentId, uint96 amount, bytes32 reason)
        external
        onlyRole(SLASHER_ROLE)
        nonReentrant
    {
        Bond storage b = _bonds[agentId];
        if (amount == 0) revert ZeroAmount();
        if (uint256(b.available) + b.pending < amount) revert InsufficientBond();

        uint96 fromAvailable = amount <= b.available ? amount : b.available;
        b.available -= fromAvailable;
        b.pending -= (amount - fromAvailable);
        if (b.pending == 0) b.unlockAt = 0;

        token.safeTransfer(slashRecipient, amount);
        emit Slashed(agentId, amount, reason);
    }

    /// @inheritdoc IStakeVault
    function bondOf(uint256 agentId) external view returns (uint96) {
        return _bonds[agentId].available;
    }

    /// @param agentId the agent
    /// @return amount pending withdrawal
    /// @return unlockAt when it becomes withdrawable
    function pendingOf(uint256 agentId) external view returns (uint96 amount, uint64 unlockAt) {
        Bond storage b = _bonds[agentId];
        return (b.pending, b.unlockAt);
    }

    /// @inheritdoc IStakeVault
    /// @dev Pending funds deliberately do NOT count: an agent that has started
    ///      unbonding is on its way out and should stop receiving work.
    function isHireable(uint256 agentId) external view returns (bool) {
        return _bonds[agentId].available >= minStake;
    }

    /// @notice Change the bond required to be hireable. Never zero.
    /// @param newMinStake base units
    function setMinStake(uint96 newMinStake) external onlyRole(CONFIGURER_ROLE) {
        if (newMinStake == 0) revert ZeroAmount();
        emit MinStakeUpdated(minStake, newMinStake);
        minStake = newMinStake;
    }

    /// @notice Change where slashed bonds go.
    /// @param recipient non-zero
    function setSlashRecipient(address recipient) external onlyRole(CONFIGURER_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        slashRecipient = recipient;
        emit SlashRecipientSet(recipient);
    }

    function _onlyAgentOwner(uint256 agentId) internal view returns (address owner) {
        owner = identityRegistry.ownerOf(agentId);
        if (owner != msg.sender) revert NotAgentOwner();
    }
}
