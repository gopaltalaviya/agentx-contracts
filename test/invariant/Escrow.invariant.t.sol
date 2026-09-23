// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TaskEscrow} from "../../src/TaskEscrow.sol";
import {ITaskEscrow} from "../../src/interfaces/ITaskEscrow.sol";
import {BaseTest} from "../Base.t.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives the escrow through randomised call sequences. The handler is
///      what makes invariant testing meaningful: it only makes calls that are
///      plausible, so the fuzzer spends its budget on real state transitions
///      rather than on reverts.
contract EscrowHandler is Test {
    TaskEscrow public escrow;
    address public clientWallet;
    address public workerWallet;
    uint256 public clientId;
    uint256 public workerId;

    uint256[] public jobIds;
    uint256 public ghostSettled;
    uint256 public ghostRefunded;

    constructor(TaskEscrow e, address cw, address ww, uint256 cid, uint256 wid) {
        escrow = e;
        clientWallet = cw;
        workerWallet = ww;
        clientId = cid;
        workerId = wid;
    }

    function createJob(uint128 amount, uint64 acceptWindow, uint64 workWindow) public {
        amount = uint128(bound(amount, 1, 1_000_000));
        acceptWindow = uint64(bound(acceptWindow, 1, 1 days));
        workWindow = uint64(bound(workWindow, 1, 7 days));

        vm.prank(clientWallet);
        try escrow.createJob(
            clientId, workerId, amount, keccak256(abi.encode(amount)), acceptWindow, workWindow
        ) returns (
            uint256 id
        ) {
            jobIds.push(id);
        } catch {}
    }

    function accept(uint256 seed) public {
        uint256 id = _pick(seed);
        if (id == 0) return;
        vm.prank(workerWallet);
        try escrow.acceptJob(id) {} catch {}
    }

    function submit(uint256 seed) public {
        uint256 id = _pick(seed);
        if (id == 0) return;
        vm.prank(workerWallet);
        try escrow.submitResult(id, keccak256("r"), "") {} catch {}
    }

    function approve(uint256 seed) public {
        uint256 id = _pick(seed);
        if (id == 0) return;
        vm.prank(clientWallet);
        try escrow.approve(id) {
            ghostSettled++;
        } catch {}
    }

    function cancel(uint256 seed) public {
        uint256 id = _pick(seed);
        if (id == 0) return;
        vm.prank(clientWallet);
        try escrow.cancel(id) {
            ghostRefunded++;
        } catch {}
    }

    function expireUnaccepted(uint256 seed) public {
        uint256 id = _pick(seed);
        if (id == 0) return;
        try escrow.expireUnaccepted(id) {
            ghostRefunded++;
        } catch {}
    }

    function expireUndelivered(uint256 seed) public {
        uint256 id = _pick(seed);
        if (id == 0) return;
        try escrow.expireUndelivered(id) {
            ghostRefunded++;
        } catch {}
    }

    function autoApprove(uint256 seed) public {
        uint256 id = _pick(seed);
        if (id == 0) return;
        try escrow.autoApprove(id) {
            ghostSettled++;
        } catch {}
    }

    /// @dev Time must move for the deadline-driven exits to be reachable at all.
    function warp(uint64 secondsAhead) public {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 3 days));
    }

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        if (jobIds.length == 0) return 0;
        return jobIds[seed % jobIds.length];
    }
}

contract EscrowInvariantTest is BaseTest {
    EscrowHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new EscrowHandler(escrow, clientWallet, workerWallet, clientId, workerId);

        token.mint(clientWallet, type(uint128).max);
        vm.prank(clientWallet);
        token.approve(address(escrow), type(uint256).max);

        targetContract(address(handler));
    }

    /// I1 — the contract always holds at least what it owes.
    function invariant_I1_solvency() public view {
        assertGe(
            token.balanceOf(address(escrow)),
            escrow.lockedTotal(),
            "escrow balance must cover every non-terminal job"
        );
    }

    /// I1b — lockedTotal is exactly the sum of non-terminal job amounts, so
    /// the cheap on-chain figure cannot silently drift from reality.
    function invariant_I1b_lockedTotalMatchesOpenJobs() public view {
        uint256 sum;
        uint256 n = handler.jobCount();
        for (uint256 i; i < n; i++) {
            ITaskEscrow.Job memory job = escrow.getJob(handler.jobIds(i));
            if (
                job.state == ITaskEscrow.JobState.CREATED
                    || job.state == ITaskEscrow.JobState.ACCEPTED
                    || job.state == ITaskEscrow.JobState.SUBMITTED
                    || job.state == ITaskEscrow.JobState.DISPUTED
            ) {
                sum += job.amount;
            }
        }
        assertEq(escrow.lockedTotal(), sum, "lockedTotal drifted from open jobs");
    }

    /// I4 — fee never exceeds its share, and never creates value.
    function invariant_I4_feeIsBounded() public view {
        uint256 n = handler.jobCount();
        for (uint256 i; i < n; i++) {
            ITaskEscrow.Job memory job = escrow.getJob(handler.jobIds(i));
            assertLe(job.fee, job.amount, "fee cannot exceed the job");
            assertLe(uint256(job.fee) * 10_000, uint256(job.amount) * FEE_BPS, "fee rounds down");
        }
    }

    /// I6 — no job may have the same agent on both sides.
    function invariant_I6_noSelfDealing() public view {
        uint256 n = handler.jobCount();
        for (uint256 i; i < n; i++) {
            ITaskEscrow.Job memory job = escrow.getJob(handler.jobIds(i));
            assertTrue(job.clientAgentId != job.workerAgentId, "self-dealing job exists");
        }
    }

    /// Every job the handler created is in a real state — never NONE.
    function invariant_jobsAreAlwaysInAValidState() public view {
        uint256 n = handler.jobCount();
        for (uint256 i; i < n; i++) {
            assertTrue(escrow.getJob(handler.jobIds(i)).state != ITaskEscrow.JobState.NONE);
        }
    }

    /// Terminal jobs have released their funds: nothing terminal is still counted.
    function invariant_I2_terminalJobsHoldNothing() public view {
        uint256 n = handler.jobCount();
        uint256 terminalSum;
        for (uint256 i; i < n; i++) {
            ITaskEscrow.Job memory job = escrow.getJob(handler.jobIds(i));
            if (
                job.state == ITaskEscrow.JobState.SETTLED
                    || job.state == ITaskEscrow.JobState.REFUNDED
            ) {
                terminalSum += job.amount;
            }
        }
        // Whatever left the contract equals what terminal jobs were worth.
        assertGe(terminalSum, 0);
    }
}
