// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IIdentityRegistry, IReputationRegistry} from "./interfaces/IERC8004.sol";
import {IStakeVault} from "./interfaces/IStakeVault.sol";
import {ITaskEscrow} from "./interfaces/ITaskEscrow.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title TaskEscrow — the AGENTX job lifecycle and the sole writer of
///        settlement-backed ERC-8004 feedback
///
/// @notice ERC-8004's `giveFeedback()` is free for anyone to call, which is why
///         a published study found its reputation manipulable. This contract is
///         the answer: it writes feedback ONLY after a job has settled on-chain,
///         so a reader who filters `getSummary` to this address gets a score
///         that cannot exist without a real payment.
///
///         `getSummary` reverts on an empty client list, so ERC-8004 already
///         forces readers to name their sources. It just never supplied an
///         address worth naming.
contract TaskEscrow is ITaskEscrow, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");
    bytes32 public constant CONFIGURER_ROLE = keccak256("CONFIGURER_ROLE");

    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant MAX_FEE_BPS = 1_000; // 10%

    struct Config {
        uint128 fastPathMax;
        uint16 fastPathMinScore;
        uint16 protocolFeeBps;
        uint64 reviewWindow;
        uint64 maxAcceptWindow;
        uint64 maxWorkWindow;
    }

    IERC20 public token;
    IIdentityRegistry public identityRegistry;
    IReputationRegistry public reputationRegistry;
    IStakeVault public stakeVault;
    address public feeRecipient;
    Config public config;
    bool public configured;

    uint256 public nextJobId = 1;

    /// @dev Sum of `amount` across all non-terminal jobs. Makes invariant I1
    ///      checkable on-chain in one call.
    uint256 public lockedTotal;

    mapping(uint256 jobId => Job) internal _jobs;

    event Configured(
        address token, address identityRegistry, address reputationRegistry, address stakeVault
    );
    event ParamsUpdated(Config config, address feeRecipient);

    error AlreadyConfigured();
    error NotConfigured();
    error WindowTooLong();
    error FeeTooHigh();

    /// @dev Only `admin`, so bytecode + args are identical on every network and
    ///      CREATE2 yields the same address. Parameters arrive via configure().
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIGURER_ROLE, admin);
        _grantRole(ARBITER_ROLE, admin);
    }

    function configure(
        address token_,
        address identityRegistry_,
        address reputationRegistry_,
        address stakeVault_,
        address feeRecipient_,
        Config calldata config_
    ) external onlyRole(CONFIGURER_ROLE) {
        if (configured) revert AlreadyConfigured();
        if (config_.protocolFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        configured = true;
        token = IERC20(token_);
        identityRegistry = IIdentityRegistry(identityRegistry_);
        reputationRegistry = IReputationRegistry(reputationRegistry_);
        stakeVault = IStakeVault(stakeVault_);
        feeRecipient = feeRecipient_;
        config = config_;
        emit Configured(token_, identityRegistry_, reputationRegistry_, stakeVault_);
        emit ParamsUpdated(config_, feeRecipient_);
    }

    /// @dev A fee change can never alter an in-flight job: the fee is captured
    ///      into the Job at creation.
    function setParams(Config calldata config_, address feeRecipient_)
        external
        onlyRole(CONFIGURER_ROLE)
    {
        if (config_.protocolFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        config = config_;
        feeRecipient = feeRecipient_;
        emit ParamsUpdated(config_, feeRecipient_);
    }

    // ─────────────────────────── escrow path ───────────────────────────

    function createJob(
        uint256 clientAgentId,
        uint256 workerAgentId,
        uint128 amount,
        bytes32 specHash,
        uint64 acceptWindow,
        uint64 workWindow
    ) external whenNotPaused nonReentrant returns (uint256 jobId) {
        _validateHire(clientAgentId, workerAgentId, amount);
        if (acceptWindow == 0 || workWindow == 0) revert WindowTooLong();
        if (acceptWindow > config.maxAcceptWindow || workWindow > config.maxWorkWindow) {
            revert WindowTooLong();
        }

        uint128 fee = _feeOf(amount);
        uint64 acceptDeadline = uint64(block.timestamp) + acceptWindow;

        jobId = nextJobId++;
        _jobs[jobId] = Job({
            clientAgentId: _toU64(clientAgentId),
            workerAgentId: _toU64(workerAgentId),
            amount: amount,
            fee: fee,
            acceptDeadline: acceptDeadline,
            // Absolute from the start, so the worker knows its real deadline
            // before accepting rather than after.
            workDeadline: acceptDeadline + workWindow,
            reviewDeadline: 0,
            state: JobState.CREATED,
            specHash: specHash,
            resultHash: bytes32(0)
        });

        lockedTotal += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);

        emit JobCreated(jobId, clientAgentId, workerAgentId, amount, fee, specHash, acceptDeadline);
    }

    function acceptJob(uint256 jobId) external {
        Job storage job = _jobs[jobId];
        _onlyWorkerWallet(job);
        if (job.state != JobState.CREATED) revert InvalidState();
        if (block.timestamp > job.acceptDeadline) revert DeadlinePassed();

        job.state = JobState.ACCEPTED;
        emit JobAccepted(jobId, job.workDeadline);
    }

    function submitResult(uint256 jobId, bytes32 resultHash, string calldata resultURI) external {
        Job storage job = _jobs[jobId];
        _onlyWorkerWallet(job);
        if (job.state != JobState.ACCEPTED) revert InvalidState();
        if (block.timestamp > job.workDeadline) revert DeadlinePassed();

        job.state = JobState.SUBMITTED;
        job.resultHash = resultHash;
        job.reviewDeadline = uint64(block.timestamp) + config.reviewWindow;

        emit ResultSubmitted(jobId, resultHash, resultURI);
    }

    function approve(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        _onlyClientWallet(job);
        if (job.state != JobState.SUBMITTED) revert InvalidState();
        _settle(jobId, job, Outcome.SUCCESS);
    }

    function dispute(uint256 jobId, bytes32 reasonHash) external {
        Job storage job = _jobs[jobId];
        _onlyClientWallet(job);
        if (job.state != JobState.SUBMITTED) revert InvalidState();
        if (block.timestamp > job.reviewDeadline) revert DeadlinePassed();

        job.state = JobState.DISPUTED;
        emit JobDisputed(jobId, reasonHash);
    }

    function resolveDispute(uint256 jobId, bool forWorker)
        external
        onlyRole(ARBITER_ROLE)
        nonReentrant
    {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.DISPUTED) revert InvalidState();

        emit DisputeResolved(jobId, forWorker);
        if (forWorker) {
            _settle(jobId, job, Outcome.SUCCESS);
        } else {
            _refund(jobId, job, "dispute", Outcome.DISPUTE_LOST);
        }
    }

    function cancel(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        _onlyClientWallet(job);
        if (job.state != JobState.CREATED) revert InvalidState();
        // No outcome recorded: nobody accepted, so nobody failed.
        _refund(jobId, job, "cancelled", Outcome.SUCCESS, false);
    }

    // ───────────── permissionless exits (liveness, invariant I5) ─────────────
    // Every non-terminal state has one. No job can hold funds forever because
    // a counterparty went offline.

    function expireUnaccepted(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.CREATED) revert InvalidState();
        if (block.timestamp <= job.acceptDeadline) revert DeadlineNotPassed();
        _refund(jobId, job, "unaccepted", Outcome.SUCCESS, false);
    }

    function expireUndelivered(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.ACCEPTED) revert InvalidState();
        if (block.timestamp <= job.workDeadline) revert DeadlineNotPassed();
        // The worker accepted and did not deliver. That is a failure, and it
        // is recorded as one.
        _refund(jobId, job, "undelivered", Outcome.FAILED, true);
    }

    function autoApprove(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.SUBMITTED) revert InvalidState();
        if (block.timestamp <= job.reviewDeadline) revert DeadlineNotPassed();
        // Settles without the client, so a client cannot take a result and
        // withhold payment by going quiet.
        _settle(jobId, job, Outcome.SUCCESS);
    }

    // ─────────────────────────── fast path ───────────────────────────

    /// @notice Pay immediately, no escrow. Below the threshold, protecting a
    ///         payment costs more than the payment.
    function directPay(
        uint256 clientAgentId,
        uint256 workerAgentId,
        uint128 amount,
        bytes32 specHash
    ) external whenNotPaused nonReentrant returns (uint256 jobId) {
        _validateHire(clientAgentId, workerAgentId, amount);
        if (amount > config.fastPathMax) revert AmountTooLargeForFastPath();

        uint128 fee = _feeOf(amount);
        uint128 paid = amount - fee;

        jobId = nextJobId++;
        _jobs[jobId] = Job({
            clientAgentId: _toU64(clientAgentId),
            workerAgentId: _toU64(workerAgentId),
            amount: amount,
            fee: fee,
            acceptDeadline: uint64(block.timestamp),
            workDeadline: uint64(block.timestamp),
            reviewDeadline: uint64(block.timestamp),
            state: JobState.SETTLED,
            specHash: specHash,
            resultHash: bytes32(0)
        });

        // Straight from client to worker — funds never rest in this contract,
        // so lockedTotal is untouched and invariant I1 still holds.
        token.safeTransferFrom(msg.sender, identityRegistry.getAgentWallet(workerAgentId), paid);
        if (fee > 0) token.safeTransferFrom(msg.sender, feeRecipient, fee);

        emit DirectPaid(jobId, clientAgentId, workerAgentId, amount, fee);
        emit JobSettled(jobId, paid, fee, Outcome.SUCCESS);

        _recordFeedback(jobId, workerAgentId, Outcome.SUCCESS, _jobs[jobId]);
    }

    // ─────────────────────────── internals ───────────────────────────

    function _settle(uint256 jobId, Job storage job, Outcome outcome) internal {
        uint128 amount = job.amount;
        uint128 fee = job.fee;
        uint128 paid = amount - fee;
        uint256 workerAgentId = job.workerAgentId;

        // Effects before interactions.
        job.state = JobState.SETTLED;
        lockedTotal -= amount;

        token.safeTransfer(identityRegistry.getAgentWallet(workerAgentId), paid);
        if (fee > 0) token.safeTransfer(feeRecipient, fee);

        emit JobSettled(jobId, paid, fee, outcome);
        _recordFeedback(jobId, workerAgentId, outcome, job);
    }

    function _refund(uint256 jobId, Job storage job, bytes32 reason, Outcome outcome) internal {
        _refund(jobId, job, reason, outcome, true);
    }

    function _refund(
        uint256 jobId,
        Job storage job,
        bytes32 reason,
        Outcome outcome,
        bool recordOutcome
    ) internal {
        uint128 amount = job.amount;
        uint256 workerAgentId = job.workerAgentId;

        job.state = JobState.REFUNDED;
        lockedTotal -= amount;

        token.safeTransfer(identityRegistry.getAgentWallet(job.clientAgentId), amount);

        emit JobRefunded(jobId, amount, reason);
        if (recordOutcome) _recordFeedback(jobId, workerAgentId, outcome, job);
    }

    /// @dev Invariant I8. The Reputation Registry is an upgradeable proxy owned
    ///      by someone else; if it reverts, pauses, or is upgraded badly, a
    ///      direct call here would revert the settlement and TRAP the worker's
    ///      money. Reputation is best-effort. Payment is not.
    ///
    ///      A failure is recoverable — `FeedbackFailed` is replayable from the
    ///      event log. A stuck escrow is not.
    function _recordFeedback(uint256 jobId, uint256 agentId, Outcome outcome, Job storage job)
        internal
    {
        int128 value = outcome == Outcome.SUCCESS ? int128(100) : int128(0);

        // Binds the review to this exact job, spec, result and amount. Anyone
        // can recompute it from public chain state and confirm the feedback
        // corresponds to a real settled payment.
        bytes32 feedbackHash =
            keccak256(abi.encode(jobId, job.specHash, job.resultHash, job.amount));

        try reputationRegistry.giveFeedback(
            agentId, value, 0, "agentx", "settled", "", "", feedbackHash
        ) {
        // recorded
        }
        catch {
            emit FeedbackFailed(jobId, agentId);
        }
    }

    function _validateHire(uint256 clientAgentId, uint256 workerAgentId, uint128 amount)
        internal
        view
    {
        if (!configured) revert NotConfigured();
        if (amount == 0) revert ZeroAmount();
        // Invariant I6. Without it, one owner could hire their own agent and
        // manufacture reputation for the cost of gas plus a fee.
        if (clientAgentId == workerAgentId) revert SelfDealing();
        if (identityRegistry.getAgentWallet(clientAgentId) != msg.sender) revert NotAgentWallet();
        if (!stakeVault.isHireable(workerAgentId)) revert NotHireable();
    }

    function _feeOf(uint128 amount) internal view returns (uint128) {
        // Rounds DOWN, so the remainder goes to the worker. Rounding in the
        // protocol's own favour is the version of this that gets flagged.
        return uint128((uint256(amount) * config.protocolFeeBps) / BPS_DENOMINATOR);
    }

    /// @dev Checked downcast. ERC-8004 ids are uint256; storage packs uint64.
    ///      Reverts rather than wrapping — a wrapped id would silently address
    ///      a different agent.
    function _toU64(uint256 agentId) internal pure returns (uint64) {
        if (agentId > type(uint64).max) revert AgentIdTooLarge(agentId);
        return uint64(agentId);
    }

    function _onlyClientWallet(Job storage job) internal view {
        if (identityRegistry.getAgentWallet(job.clientAgentId) != msg.sender) {
            revert NotAgentWallet();
        }
    }

    function _onlyWorkerWallet(Job storage job) internal view {
        if (identityRegistry.getAgentWallet(job.workerAgentId) != msg.sender) {
            revert NotAgentWallet();
        }
    }

    // ─────────────────────────── views / admin ───────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    /// @dev Pausing blocks NEW jobs only. Settlement and refund stay open, so
    ///      pausing can never trap funds already in escrow.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
