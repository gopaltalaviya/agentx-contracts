// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ITaskEscrow — the AGENTX job lifecycle
/// @notice Spec: docs/04 §2.2 and docs/02 §3 (state machine).
interface ITaskEscrow {
    enum JobState {
        NONE,
        CREATED,
        ACCEPTED,
        SUBMITTED,
        DISPUTED,
        SETTLED,
        REFUNDED
    }

    enum Outcome {
        SUCCESS,
        FAILED,
        DISPUTE_LOST
    }

    /// @dev Agent ids are `uint256` in every EXTERNAL signature, matching
    ///      ERC-8004 exactly so nothing can truncate at the boundary. Storage
    ///      packs them to `uint64`, which requires a CHECKED downcast on write:
    ///      an id above `type(uint64).max` must revert with `AgentIdTooLarge`,
    ///      never wrap.
    ///
    ///      Justification (probed on Monad mainnet 2026-09-22): the live
    ///      Identity Registry issues sequential ids — ownerOf(1), (2), (3) and
    ///      (100) are all held — so uint64 covers ~1.8e19 agents. But the
    ///      registry is an upgradeable proxy and the standard permits any
    ///      uint256, so the guard is load-bearing, not decorative.
    struct Job {
        // slot 0
        uint64 clientAgentId;
        uint64 workerAgentId;
        uint128 amount; // gross, payment-token base units
        // slot 1
        uint128 fee; // captured at creation so a governance change cannot alter it
        uint64 acceptDeadline;
        uint64 workDeadline;
        // slot 2
        uint64 reviewDeadline; // set when the result is submitted
        JobState state;
        // slot 3 / 4
        bytes32 specHash;
        bytes32 resultHash;
    }

    event JobCreated(
        uint256 indexed jobId,
        uint256 indexed clientAgentId,
        uint256 indexed workerAgentId,
        uint128 amount,
        uint128 fee,
        bytes32 specHash,
        uint64 acceptDeadline
    );
    event JobAccepted(uint256 indexed jobId, uint64 workDeadline);
    event ResultSubmitted(uint256 indexed jobId, bytes32 resultHash, string resultURI);
    event JobSettled(uint256 indexed jobId, uint128 paid, uint128 fee, Outcome outcome);
    event JobRefunded(uint256 indexed jobId, uint128 amount, bytes32 reason);
    event JobDisputed(uint256 indexed jobId, bytes32 reasonHash);
    event DisputeResolved(uint256 indexed jobId, bool forWorker);
    event DirectPaid(
        uint256 indexed jobId,
        uint256 indexed clientAgentId,
        uint256 indexed workerAgentId,
        uint128 amount,
        uint128 fee
    );
    event FeedbackFailed(uint256 indexed jobId, uint256 indexed agentId);

    error NotAgentWallet();
    error InvalidState();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error SelfDealing();
    error NotHireable();
    error AmountTooLargeForFastPath();
    error ZeroAmount();
    /// @dev Raised instead of truncating a uint256 agent id into uint64 storage.
    error AgentIdTooLarge(uint256 agentId);

    // --- escrow path ---
    function createJob(
        uint256 clientAgentId,
        uint256 workerAgentId,
        uint128 amount,
        bytes32 specHash,
        uint64 acceptWindow,
        uint64 workWindow
    ) external returns (uint256 jobId);

    function acceptJob(uint256 jobId) external;
    function submitResult(uint256 jobId, bytes32 resultHash, string calldata resultURI) external;
    function approve(uint256 jobId) external;
    function dispute(uint256 jobId, bytes32 reasonHash) external;
    function resolveDispute(uint256 jobId, bool forWorker) external;
    function cancel(uint256 jobId) external;

    // --- permissionless liveness exits: every non-terminal state has one ---
    function expireUnaccepted(uint256 jobId) external;
    function expireUndelivered(uint256 jobId) external;
    function autoApprove(uint256 jobId) external;

    // --- fast path ---
    function directPay(
        uint256 clientAgentId,
        uint256 workerAgentId,
        uint128 amount,
        bytes32 specHash
    ) external returns (uint256 jobId);

    function getJob(uint256 jobId) external view returns (Job memory);
    function lockedTotal() external view returns (uint256);
}
