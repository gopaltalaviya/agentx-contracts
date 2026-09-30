// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IStakeVault — bonds keyed by ERC-8004 agentId
/// @notice ERC-8004 has no custody, so listings would be free. A bond with a
///         withdrawal delay is what makes a listing cost something, which is
///         the direct answer to the sybil and dormant-registration findings in
///         the ERC-8004 empirical study (docs/09 §2).
interface IStakeVault {
    /// @notice `from` added `amount` to `agentId`'s bond.
    event Deposited(uint256 indexed agentId, address indexed from, uint96 amount);
    /// @notice The owner began unbonding; withdrawable from `unlockAt`.
    event WithdrawRequested(uint256 indexed agentId, uint96 amount, uint64 unlockAt);
    /// @notice The owner stopped unbonding; the amount counts toward the bond again.
    event WithdrawCancelled(uint256 indexed agentId, uint96 amount);
    /// @notice Unbonded funds left the vault.
    event Withdrawn(uint256 indexed agentId, address indexed to, uint96 amount);
    /// @notice Part of a bond was taken and sent to the slash recipient.
    event Slashed(uint256 indexed agentId, uint96 amount, bytes32 reason);

    error NotAgentOwner();
    error InsufficientBond();
    error WithdrawNotReady();
    error NothingRequested();
    /// @dev One request at a time: a second would reset the first one's clock.
    error WithdrawAlreadyPending();

    /// @notice Add to an agent's bond. Anyone may; only the owner may withdraw.
    /// @param agentId the agent
    /// @param amount base units
    function deposit(uint256 agentId, uint96 amount) external;

    /// @notice Start the cooldown. Without it an agent could take a large job
    ///         and pull its bond in the same block.
    /// @param agentId the agent
    /// @param amount base units
    function requestWithdraw(uint256 agentId, uint96 amount) external;

    /// @notice Return a pending withdrawal to the bond.
    /// @param agentId the agent
    function cancelWithdraw(uint256 agentId) external;

    /// @notice Pay out a withdrawal whose cooldown has passed, to the owner.
    /// @param agentId the agent
    function withdraw(uint256 agentId) external;

    /// @notice Take part of a bond. Slasher only.
    /// @param agentId the agent
    /// @param amount base units
    /// @param reason commitment to why
    function slash(uint256 agentId, uint96 amount, bytes32 reason) external;

    /// @param agentId the agent
    /// @return the bond that counts toward hireability
    function bondOf(uint256 agentId) external view returns (uint96);

    /// @param agentId the agent
    /// @return true when bond >= minStake; AGENTX will not route work otherwise
    function isHireable(uint256 agentId) external view returns (bool);
}
