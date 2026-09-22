// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStakeVault — bonds keyed by ERC-8004 agentId
/// @notice ERC-8004 has no custody, so listings would be free. A bond with a
///         withdrawal delay is what makes a listing cost something, which is
///         the direct answer to the sybil and dormant-registration findings in
///         the ERC-8004 empirical study (docs/09 §2).
interface IStakeVault {
    event Deposited(uint256 indexed agentId, address indexed from, uint96 amount);
    event WithdrawRequested(uint256 indexed agentId, uint96 amount, uint64 unlockAt);
    event Withdrawn(uint256 indexed agentId, address indexed to, uint96 amount);
    event Slashed(uint256 indexed agentId, uint96 amount, bytes32 reason);

    error NotAgentOwner();
    error InsufficientBond();
    error WithdrawNotReady();
    error NothingRequested();

    function deposit(uint256 agentId, uint96 amount) external;

    /// @dev Starts the cooldown. Without it an agent could take a large job and
    ///      pull its bond in the same block.
    function requestWithdraw(uint256 agentId, uint96 amount) external;

    function withdraw(uint256 agentId) external;

    function slash(uint256 agentId, uint96 amount, bytes32 reason) external;

    function bondOf(uint256 agentId) external view returns (uint96);

    /// @return true when bond >= minStake; AGENTX will not route work otherwise
    function isHireable(uint256 agentId) external view returns (bool);
}
