// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIdentityRegistry, IReputationRegistry} from "./interfaces/IERC8004.sol";
import {IStakeVault} from "./interfaces/IStakeVault.sol";
import {ITaskEscrow} from "./interfaces/ITaskEscrow.sol";
import {
    AccessControlDefaultAdminRules
} from "openzeppelin-contracts/access/extensions/AccessControlDefaultAdminRules.sol";
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
///         that cannot exist without a real payment between two DIFFERENT
///         owners, of at least `minJobAmount`, that paid at least `minFee`.
///
///         That is a cost floor on manufactured reputation, not a proof of
///         honesty: an attacker with two identities and two bonds can still pay
///         themselves. What v2 guarantees is that each such review costs a real
///         fee, where v1 let one owner buy one for the price of gas.
///
/// @dev Payments never trap funds. Every payout goes through `_payAgent`, which
///      credits `owed` instead of reverting when the recipient cannot be paid —
///      a cleared wallet, a token-blacklisted address, or an identity registry
///      (someone else's upgradeable proxy) that reverts. Solvency:
///      `balance >= lockedTotal + owedTotal` (invariant I1).
contract TaskEscrow is ITaskEscrow, AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");
    bytes32 public constant CONFIGURER_ROLE = keccak256("CONFIGURER_ROLE");

    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant MAX_FEE_BPS = 1_000; // 10%
    /// @dev Upper bound on every window. Keeps `now + window` far from uint64
    ///      overflow and lets the per-job copies live in uint32.
    uint64 internal constant MAX_WINDOW = 365 days;
    /// @dev Gas given to the identity registry when resolving a payout wallet.
    ///      Bounded so a hostile registry cannot spend the gas the fallback
    ///      (crediting `owed`) needs.
    uint256 internal constant WALLET_LOOKUP_GAS = 100_000;

    /// @param fastPathMax largest `directPay`, base units; 0 disables the fast path
    /// @param minJobAmount smallest amount any job may carry
    /// @param minFee fee floor, charged when the percentage fee is lower
    /// @param protocolFeeBps fee in basis points, at most 10%
    /// @param reviewWindow seconds a client has to approve or dispute
    /// @param maxAcceptWindow longest accept window a client may choose
    /// @param maxWorkWindow longest work window a client may choose
    /// @param disputeTimeout seconds the arbiter has before anyone may expire a dispute
    struct Config {
        uint128 fastPathMax;
        uint128 minJobAmount;
        uint128 minFee;
        uint16 protocolFeeBps;
        uint64 reviewWindow;
        uint64 maxAcceptWindow;
        uint64 maxWorkWindow;
        uint64 disputeTimeout;
    }

    IERC20 public token;
    IIdentityRegistry public identityRegistry;
    IReputationRegistry public reputationRegistry;
    IStakeVault public stakeVault;
    address public feeRecipient;
    Config public config;
    bool public configured;

    uint256 public nextJobId = 1;

    /// @notice Sum of `amount` across all non-terminal jobs.
    uint256 public lockedTotal;
    /// @notice Deferred payments plus deferred fees, still held here.
    uint256 public owedTotal;
    /// @notice Deferred fees, deliverable with `claimFees`.
    uint256 public feesOwed;
    /// @notice Deferred payments per agent, claimable with `claimOwed`.
    mapping(uint256 agentId => uint256) public owed;

    mapping(uint256 jobId => Job) internal _jobs;

    /// @notice The contract's dependencies were set, once.
    event Configured(
        address indexed token,
        address indexed identityRegistry,
        address indexed reputationRegistry,
        address stakeVault
    );
    /// @notice The protocol parameters or fee recipient changed.
    event ParamsUpdated(Config config, address indexed feeRecipient);

    error AlreadyConfigured();
    error NotConfigured();
    error WindowTooLong();
    error InvalidWindow();
    error FeeTooHigh();
    error InvalidFeeFloor();
    /// @dev The token moved a different amount than it was asked to.
    error TokenDeliveredLess(uint256 asked, uint256 received);

    /// @param admin holds the default admin, configurer and arbiter roles
    /// @param adminDelay seconds a transfer of the default admin role must wait
    constructor(address admin, uint48 adminDelay)
        AccessControlDefaultAdminRules(adminDelay, admin)
    {
        _grantRole(CONFIGURER_ROLE, admin);
        _grantRole(ARBITER_ROLE, admin);
    }

    /// @notice Set the dependencies and the first parameters. Once only.
    /// @param token_ the payment token
    /// @param identityRegistry_ the ERC-8004 identity registry
    /// @param reputationRegistry_ the ERC-8004 reputation registry
    /// @param stakeVault_ the bond vault that decides hireability
    /// @param feeRecipient_ receives protocol fees
    /// @param config_ the protocol parameters
    function configure(
        address token_,
        address identityRegistry_,
        address reputationRegistry_,
        address stakeVault_,
        address feeRecipient_,
        Config calldata config_
    ) external onlyRole(CONFIGURER_ROLE) {
        if (configured) revert AlreadyConfigured();
        if (
            token_ == address(0) || identityRegistry_ == address(0)
                || reputationRegistry_ == address(0) || stakeVault_ == address(0)
        ) revert ZeroAddress();
        _checkParams(config_, feeRecipient_); // includes feeRecipient_ != 0
        configured = true;
        token = IERC20(token_);
        identityRegistry = IIdentityRegistry(identityRegistry_);
        reputationRegistry = IReputationRegistry(reputationRegistry_);
        stakeVault = IStakeVault(stakeVault_);
        // slither-disable-next-line missing-zero-check
        feeRecipient = feeRecipient_; // checked in _checkParams
        config = config_;
        emit Configured(token_, identityRegistry_, reputationRegistry_, stakeVault_);
        emit ParamsUpdated(config_, feeRecipient_);
    }

    /// @notice Change the parameters for FUTURE jobs. A job's fee and windows
    ///         are captured at creation, so nothing here alters one in flight.
    /// @param config_ the new parameters
    /// @param feeRecipient_ the new fee recipient
    function setParams(Config calldata config_, address feeRecipient_)
        external
        onlyRole(CONFIGURER_ROLE)
    {
        _checkParams(config_, feeRecipient_);
        config = config_;
        // slither-disable-next-line missing-zero-check
        feeRecipient = feeRecipient_; // checked in _checkParams
        emit ParamsUpdated(config_, feeRecipient_);
    }

    // ─────────────────────────── escrow path ───────────────────────────

    /// @inheritdoc ITaskEscrow
    // The balance is read around transferFrom ON PURPOSE (the fee-on-transfer
    // guard), and the function is nonReentrant.
    // slither-disable-next-line reentrancy-balance
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
            // Bounded by MAX_WINDOW in _checkParams, so these casts are exact.
            reviewWindow: uint32(config.reviewWindow),
            disputeTimeout: uint32(config.disputeTimeout),
            disputeDeadline: 0,
            specHash: specHash,
            resultHash: bytes32(0)
        });

        lockedTotal += amount;

        // Trust the balance, not the call. A fee-on-transfer or deflationary
        // token delivers less than it was asked for, which would leave the
        // escrow owing more than it holds — invariant I1, broken silently.
        uint256 received = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - received;
        if (received != amount) revert TokenDeliveredLess(amount, received);

        emit JobCreated(jobId, clientAgentId, workerAgentId, amount, fee, specHash, acceptDeadline);
    }

    /// @inheritdoc ITaskEscrow
    function acceptJob(uint256 jobId) external {
        Job storage job = _jobs[jobId];
        _onlyWorkerWallet(job);
        if (job.state != JobState.CREATED) revert InvalidState();
        if (block.timestamp > job.acceptDeadline) revert DeadlinePassed();

        job.state = JobState.ACCEPTED;
        emit JobAccepted(jobId, job.workDeadline);
    }

    /// @inheritdoc ITaskEscrow
    function submitResult(uint256 jobId, bytes32 resultHash, string calldata resultURI) external {
        Job storage job = _jobs[jobId];
        _onlyWorkerWallet(job);
        if (job.state != JobState.ACCEPTED) revert InvalidState();
        if (block.timestamp > job.workDeadline) revert DeadlinePassed();

        job.state = JobState.SUBMITTED;
        job.resultHash = resultHash;
        job.reviewDeadline = uint64(block.timestamp) + job.reviewWindow;

        emit ResultSubmitted(jobId, resultHash, resultURI);
    }

    /// @inheritdoc ITaskEscrow
    function approve(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        _onlyClientWallet(job);
        if (job.state != JobState.SUBMITTED) revert InvalidState();
        _settle(jobId, job, Outcome.SUCCESS, true);
    }

    /// @inheritdoc ITaskEscrow
    function dispute(uint256 jobId, bytes32 reasonHash) external {
        Job storage job = _jobs[jobId];
        _onlyClientWallet(job);
        if (job.state != JobState.SUBMITTED) revert InvalidState();
        if (block.timestamp > job.reviewDeadline) revert DeadlinePassed();

        job.state = JobState.DISPUTED;
        job.disputeDeadline = uint64(block.timestamp) + job.disputeTimeout;
        emit JobDisputed(jobId, reasonHash);
    }

    /// @inheritdoc ITaskEscrow
    function resolveDispute(uint256 jobId, bool forWorker)
        external
        onlyRole(ARBITER_ROLE)
        nonReentrant
    {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.DISPUTED) revert InvalidState();

        emit DisputeResolved(jobId, forWorker);
        if (forWorker) {
            _settle(jobId, job, Outcome.SUCCESS, true);
        } else {
            _refund(jobId, job, "dispute", Outcome.DISPUTE_LOST, true);
        }
    }

    /// @inheritdoc ITaskEscrow
    function cancel(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        _onlyClientWallet(job);
        if (job.state != JobState.CREATED) revert InvalidState();
        // No outcome recorded: nobody accepted, so nobody failed.
        _refund(jobId, job, "cancelled", Outcome.SUCCESS, false);
    }

    // ───────────── permissionless exits (liveness, invariant I5) ─────────────
    // Every non-terminal state has one. No job can hold funds forever because
    // a counterparty — or the arbiter — went offline.

    /// @inheritdoc ITaskEscrow
    function expireUnaccepted(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.CREATED) revert InvalidState();
        if (block.timestamp <= job.acceptDeadline) revert DeadlineNotPassed();
        _refund(jobId, job, "unaccepted", Outcome.SUCCESS, false);
    }

    /// @inheritdoc ITaskEscrow
    function expireUndelivered(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.ACCEPTED) revert InvalidState();
        if (block.timestamp <= job.workDeadline) revert DeadlineNotPassed();
        // The worker accepted and did not deliver. That is a failure, and it
        // is recorded as one.
        _refund(jobId, job, "undelivered", Outcome.FAILED, true);
    }

    /// @inheritdoc ITaskEscrow
    function autoApprove(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.SUBMITTED) revert InvalidState();
        if (block.timestamp <= job.reviewDeadline) revert DeadlineNotPassed();
        // Settles without the client, so a client cannot take a result and
        // withhold payment by going quiet.
        _settle(jobId, job, Outcome.SUCCESS, true);
    }

    /// @inheritdoc ITaskEscrow
    /// @dev Pays the WORKER. The result is delivered and revealed; refunding on
    ///      timeout would make "dispute, then wait out a slow arbiter" a way to
    ///      get work for free — the exploit `autoApprove` exists to prevent.
    ///      No feedback is written, so a disputed result never earns
    ///      reputation by default. The arbiter can still rule until this runs.
    function expireDispute(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != JobState.DISPUTED) revert InvalidState();
        if (block.timestamp <= job.disputeDeadline) revert DeadlineNotPassed();
        emit DisputeExpired(jobId);
        _settle(jobId, job, Outcome.UNRESOLVED, false);
    }

    // ─────────────────────────── fast path ───────────────────────────

    /// @inheritdoc ITaskEscrow
    /// @dev All-or-nothing: the funds never rest here, so a recipient that
    ///      cannot be paid simply reverts the payment — nothing is stranded.
    function directPay(
        uint256 clientAgentId,
        uint256 workerAgentId,
        uint128 amount,
        bytes32 specHash
    ) external whenNotPaused nonReentrant returns (uint256 jobId) {
        address workerWallet = _validateHire(clientAgentId, workerAgentId, amount);
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
            reviewWindow: 0,
            disputeTimeout: 0,
            disputeDeadline: 0,
            specHash: specHash,
            resultHash: bytes32(0)
        });

        token.safeTransferFrom(msg.sender, workerWallet, paid);
        token.safeTransferFrom(msg.sender, feeRecipient, fee);

        emit DirectPaid(jobId, clientAgentId, workerAgentId, amount, fee, specHash);
        emit JobSettled(jobId, paid, fee, Outcome.SUCCESS);

        _recordFeedback(jobId, workerAgentId, Outcome.SUCCESS, _jobs[jobId]);
    }

    // ─────────────────────────── deferred payments ───────────────────────────

    /// @inheritdoc ITaskEscrow
    /// @dev The agent's OWNER may claim, as may its current wallet. The owner
    ///      can already point the wallet anywhere, so letting it choose `to`
    ///      grants no new power — and a canonical registry clears the wallet
    ///      on transfer, which would otherwise leave nobody able to claim.
    function claimOwed(uint256 agentId, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = owed[agentId];
        if (amount == 0) revert NothingOwed();
        if (msg.sender != identityRegistry.ownerOf(agentId) && msg.sender != _walletOf(agentId)) {
            revert NotOwedClaimer();
        }

        owed[agentId] = 0;
        owedTotal -= amount;
        token.safeTransfer(to, amount);
        emit OwedClaimed(agentId, to, amount);
    }

    /// @inheritdoc ITaskEscrow
    function claimFees() external nonReentrant {
        uint256 amount = feesOwed;
        if (amount == 0) revert NothingOwed();
        feesOwed = 0;
        owedTotal -= amount;
        token.safeTransfer(feeRecipient, amount);
        emit FeesClaimed(feeRecipient, amount);
    }

    // ─────────────────────────── internals ───────────────────────────

    function _settle(uint256 jobId, Job storage job, Outcome outcome, bool recordFeedback)
        internal
    {
        uint128 amount = job.amount;
        uint128 fee = job.fee;
        uint128 paid = amount - fee;
        uint256 workerAgentId = job.workerAgentId;

        // Effects before interactions.
        job.state = JobState.SETTLED;
        lockedTotal -= amount;

        _payAgent(jobId, workerAgentId, paid);
        _payFee(jobId, fee);

        emit JobSettled(jobId, paid, fee, outcome);
        if (recordFeedback) _recordFeedback(jobId, workerAgentId, outcome, job);
    }

    function _refund(
        uint256 jobId,
        Job storage job,
        bytes32 reason,
        Outcome outcome,
        bool recordOutcome
    ) internal {
        uint128 amount = job.amount;

        job.state = JobState.REFUNDED;
        lockedTotal -= amount;

        _payAgent(jobId, job.clientAgentId, amount);

        emit JobRefunded(jobId, amount, reason);
        if (recordOutcome) _recordFeedback(jobId, job.workerAgentId, outcome, job);
    }

    /// @dev Pay an agent, or hold the money for it. Never reverts for a reason
    ///      the recipient controls — that is what used to trap funds.
    ///      `amount` is never zero: a refund returns the whole job (at least
    ///      `minJobAmount`) and a settlement pays `amount - fee`, where
    ///      `_checkParams` keeps the fee below the amount.
    function _payAgent(uint256 jobId, uint256 agentId, uint256 amount) internal {
        address to = _walletOf(agentId);
        if (to == address(0) || !_tryTransfer(to, amount)) {
            owed[agentId] += amount;
            owedTotal += amount;
            emit PaymentDeferred(jobId, agentId, amount);
        }
    }

    function _payFee(uint256 jobId, uint256 fee) internal {
        if (fee == 0) return;
        if (!_tryTransfer(feeRecipient, fee)) {
            feesOwed += fee;
            owedTotal += fee;
            emit FeeDeferred(jobId, fee);
        }
    }

    /// @dev The payout wallet, or zero if the registry cannot say. A low-level
    ///      staticcall with bounded gas that copies at most one word back: a
    ///      `try` would still revert on malformed return data, and an
    ///      unbounded copy could be used to exhaust the caller.
    function _walletOf(uint256 agentId) internal view returns (address wallet) {
        bytes memory data = abi.encodeCall(IIdentityRegistry.getAgentWallet, (agentId));
        address registry = address(identityRegistry);
        uint256 word;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(WALLET_LOOKUP_GAS, registry, add(data, 0x20), mload(data), 0, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) { word := mload(0) }
        }
        // Safe: the high 96 bits are checked to be zero first.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (ok && word >> 160 == 0) wallet = address(uint160(word));
    }

    /// @dev `transfer` that reports failure instead of reverting. Success means
    ///      the call succeeded AND returned `true` or nothing from a contract
    ///      (the SafeERC20 rule).
    function _tryTransfer(address to, uint256 amount) internal returns (bool success) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        address t = address(token);
        assembly ("memory-safe") {
            success := call(gas(), t, 0, add(data, 0x20), mload(data), 0, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(t), 0) }
                default { success := and(gt(returndatasize(), 0x1f), eq(mload(0), 1)) }
            }
        }
    }

    /// @dev Invariant I8. The Reputation Registry is an upgradeable proxy owned
    ///      by someone else; if it reverts, pauses, or is upgraded badly, a
    ///      direct call here would revert the settlement and TRAP the worker's
    ///      money. Reputation is best-effort. Payment is not.
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

    /// @return workerWallet the worker's payout wallet, known to be non-zero
    function _validateHire(uint256 clientAgentId, uint256 workerAgentId, uint128 amount)
        internal
        view
        returns (address workerWallet)
    {
        if (!configured) revert NotConfigured();
        if (amount == 0) revert ZeroAmount();
        if (amount < config.minJobAmount) revert AmountBelowMinimum(amount, config.minJobAmount);
        // Invariant I6.
        if (clientAgentId == workerAgentId) revert SelfDealing();
        if (identityRegistry.getAgentWallet(clientAgentId) != msg.sender) revert NotAgentWallet();
        workerWallet = identityRegistry.getAgentWallet(workerAgentId);
        // An agent with no payout wallet can be hired but never paid.
        if (workerWallet == address(0)) revert NotHireable();
        if (workerWallet == msg.sender) revert SelfDealing();
        // Two ids, one owner: the v1 hole. Distinct ids were never the point.
        if (identityRegistry.ownerOf(clientAgentId) == identityRegistry.ownerOf(workerAgentId)) {
            revert SameOwner();
        }
        if (!stakeVault.isHireable(workerAgentId)) revert NotHireable();
    }

    /// @dev The percentage fee, rounded down, but never below `minFee`.
    ///      `_checkParams` keeps `minFee < minJobAmount <= amount`, so the
    ///      worker is always paid something.
    function _feeOf(uint128 amount) internal view returns (uint128 fee) {
        fee = uint128((uint256(amount) * config.protocolFeeBps) / BPS_DENOMINATOR);
        if (fee < config.minFee) fee = config.minFee;
    }

    function _checkParams(Config calldata c, address feeRecipient_) internal pure {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (c.protocolFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (
            c.reviewWindow == 0 || c.reviewWindow > MAX_WINDOW || c.maxAcceptWindow == 0
                || c.maxAcceptWindow > MAX_WINDOW || c.maxWorkWindow == 0
                || c.maxWorkWindow > MAX_WINDOW || c.disputeTimeout == 0
                || c.disputeTimeout > MAX_WINDOW
        ) revert InvalidWindow();
        if (c.minJobAmount == 0 || c.minFee >= c.minJobAmount) revert InvalidFeeFloor();
        if (c.fastPathMax != 0 && c.fastPathMax < c.minJobAmount) revert InvalidFeeFloor();
    }

    /// @dev Checked downcast. ERC-8004 ids are uint256; storage packs uint64.
    ///      Reverts rather than wrapping — a wrapped id would silently address
    ///      a different agent.
    function _toU64(uint256 agentId) internal pure returns (uint64) {
        if (agentId > type(uint64).max) revert AgentIdTooLarge(agentId);
        // Safe: bounded on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
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

    /// @inheritdoc ITaskEscrow
    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    /// @notice Stop NEW jobs. Settlement, refund and every exit stay open, so
    ///         pausing can never trap funds already in escrow.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Allow new jobs again.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
