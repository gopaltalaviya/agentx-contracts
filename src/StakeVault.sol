// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IIdentityRegistry} from "./interfaces/IERC8004.sol";
import {IStakeVault} from "./interfaces/IStakeVault.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title StakeVault — bonds keyed by ERC-8004 agentId
/// @notice ERC-8004 has no custody, so being listed costs nothing and identity
///         is disposable. A published study of the live ecosystem found exactly
///         that: coordinated sybil registrations and dormant agents. This makes
///         being *hireable through AGENTX* cost a bond with a withdrawal delay,
///         while leaving identity itself free and open as the standard intends.
contract StakeVault is IStakeVault, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant CONFIGURER_ROLE = keccak256("CONFIGURER_ROLE");

    struct Bond {
        uint96 available; // counts toward isHireable
        uint96 pending; // requested for withdrawal, still slashable
        uint64 unlockAt;
    }

    IERC20 public token;
    IIdentityRegistry public identityRegistry;
    uint96 public minStake;
    uint64 public withdrawDelay;
    bool public configured;

    mapping(uint256 agentId => Bond) internal _bonds;

    event Configured(
        address token, address identityRegistry, uint96 minStake, uint64 withdrawDelay
    );

    error AlreadyConfigured();
    error NotConfigured();
    error ZeroAmount();

    /// @dev Constructor takes only `admin` so bytecode and constructor args are
    ///      network-independent, which is what lets CREATE2 produce the same
    ///      address on testnet and mainnet. Parameters arrive via configure().
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIGURER_ROLE, admin);
    }

    function configure(
        address token_,
        address identityRegistry_,
        uint96 minStake_,
        uint64 withdrawDelay_
    ) external onlyRole(CONFIGURER_ROLE) {
        if (configured) revert AlreadyConfigured();
        configured = true;
        token = IERC20(token_);
        identityRegistry = IIdentityRegistry(identityRegistry_);
        minStake = minStake_;
        withdrawDelay = withdrawDelay_;
        emit Configured(token_, identityRegistry_, minStake_, withdrawDelay_);
    }

    /// @notice Anyone may top up an agent's bond; only its owner may take it out.
    function deposit(uint256 agentId, uint96 amount) external nonReentrant {
        if (!configured) revert NotConfigured();
        if (amount == 0) revert ZeroAmount();

        _bonds[agentId].available += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(agentId, msg.sender, amount);
    }

    /// @notice Begin unbonding. The delay is the whole point: without it an
    ///         agent could take a large job and pull its bond in the same block.
    function requestWithdraw(uint256 agentId, uint96 amount) external {
        _onlyAgentOwner(agentId);
        Bond storage b = _bonds[agentId];
        if (amount == 0) revert ZeroAmount();
        if (b.available < amount) revert InsufficientBond();

        b.available -= amount;
        b.pending += amount;
        b.unlockAt = uint64(block.timestamp) + withdrawDelay;

        emit WithdrawRequested(agentId, amount, b.unlockAt);
    }

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

    /// @notice Burn part of a bond.
    /// @dev Takes from `available` first and then from `pending`, so requesting
    ///      a withdrawal is not an escape hatch from being slashed.
    ///      No role holder is granted SLASHER_ROLE in the MVP — the capability
    ///      exists, automatic slashing does not.
    function slash(uint256 agentId, uint96 amount, bytes32 reason) external onlyRole(SLASHER_ROLE) {
        Bond storage b = _bonds[agentId];
        if (amount == 0) revert ZeroAmount();
        if (uint256(b.available) + b.pending < amount) revert InsufficientBond();

        uint96 fromAvailable = amount <= b.available ? amount : b.available;
        b.available -= fromAvailable;
        b.pending -= (amount - fromAvailable);

        emit Slashed(agentId, amount, reason);
    }

    function bondOf(uint256 agentId) external view returns (uint96) {
        return _bonds[agentId].available;
    }

    function pendingOf(uint256 agentId) external view returns (uint96 amount, uint64 unlockAt) {
        Bond storage b = _bonds[agentId];
        return (b.pending, b.unlockAt);
    }

    /// @dev Pending funds deliberately do NOT count: an agent that has started
    ///      unbonding is on its way out and should stop receiving work.
    function isHireable(uint256 agentId) external view returns (bool) {
        return _bonds[agentId].available >= minStake;
    }

    function setMinStake(uint96 newMinStake) external onlyRole(CONFIGURER_ROLE) {
        minStake = newMinStake;
        emit Configured(address(token), address(identityRegistry), newMinStake, withdrawDelay);
    }

    function _onlyAgentOwner(uint256 agentId) internal view returns (address owner) {
        owner = identityRegistry.ownerOf(agentId);
        if (owner != msg.sender) revert NotAgentOwner();
    }
}
