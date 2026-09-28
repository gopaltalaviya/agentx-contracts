// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentAccount} from "../../src/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/AgentAccountFactory.sol";
import {TaskEscrow} from "../../src/TaskEscrow.sol";
import {BaseTest} from "../Base.t.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @dev The threat model these tests encode: the AGENTX signer is compromised
///      and the attacker holds a live session key. The caps must still hold.
contract AgentAccountTest is BaseTest {
    AgentAccountFactory internal factory;
    AgentAccount internal account;

    address internal agentOwner = makeAddr("agentOwner");
    address internal sessionKey = makeAddr("sessionKey");
    address internal attacker = makeAddr("attacker");

    uint128 internal constant PER_TASK_CAP = 100_000; // 0.10 USDC
    uint128 internal constant DAILY_CAP = 250_000; // 0.25 USDC

    uint256 internal accountAgentId;

    function setUp() public override {
        super.setUp();

        // These tests probe the ACCOUNT's caps, so the escrow's own fast-path
        // ceiling must be raised out of the way — otherwise directPay rejects
        // first and the account limits are never reached.
        vm.prank(admin);
        escrow.setParams(
            TaskEscrow.Config({
                fastPathMax: 1_000_000,
                fastPathMinScore: 70,
                protocolFeeBps: FEE_BPS,
                reviewWindow: REVIEW_WINDOW,
                maxAcceptWindow: 1 days,
                maxWorkWindow: 7 days
            }),
            feeRecipient
        );

        factory = new AgentAccountFactory(address(token));
        address predicted = factory.predictAddress(agentOwner, bytes32("agent-1"));

        account = AgentAccount(
            payable(factory.createAccount(
                    agentOwner,
                    bytes32("agent-1"),
                    AgentAccount.Policy({
                        perTaskCap: PER_TASK_CAP, dailyCap: DAILY_CAP, allowlistOnly: true
                    })
                ))
        );
        assertEq(address(account), predicted, "address must be predictable before deployment");

        // The account is this agent's registered wallet.
        vm.prank(agentOwner);
        accountAgentId = identity.register("ipfs://acct", address(account));
        _bond(accountAgentId, agentOwner, MIN_STAKE);

        token.mint(address(account), 10_000_000);

        vm.startPrank(agentOwner);
        account.setAllowedTarget(address(escrow), true);
        account.setAllowedSelector(TaskEscrow.directPay.selector, true);
        account.setAllowedSelector(TaskEscrow.createJob.selector, true);
        account.setAllowance(address(escrow), type(uint256).max);
        account.grantSessionKey(sessionKey, uint64(block.timestamp + 1 days), DAILY_CAP);
        vm.stopPrank();
    }

    // ─────────────────── access control ───────────────────

    /// @dev Nothing tested this. `onlyOwner` showed as an uncovered branch in
    ///      the coverage report, which means no test had ever called an
    ///      owner-only function as a stranger — so removing the modifier from
    ///      any of these six would not have failed a single test.
    ///
    ///      This is the contract that bounds a compromised agent. Its access
    ///      control is the reason the bound holds.
    function test_onlyOwner_strangerCannotSetPolicy() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.setPolicy(AgentAccount.Policy({perTaskCap: type(uint128).max, dailyCap: type(uint128).max, allowlistOnly: false}));
    }

    function test_onlyOwner_strangerCannotGrantThemselvesASessionKey() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.grantSessionKey(attacker, uint64(block.timestamp) + 1 hours, type(uint128).max);
    }

    function test_onlyOwner_strangerCannotAllowlistATarget() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.setAllowedTarget(attacker, true);
    }

    function test_onlyOwner_strangerCannotAllowlistASelector() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.setAllowedSelector(bytes4(0xdeadbeef), true);
    }

    function test_onlyOwner_strangerCannotGrantAnAllowance() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.setAllowance(attacker, type(uint256).max);
    }

    /// @dev The one that would drain it outright.
    function test_onlyOwner_strangerCannotSweepTheFunds() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.sweep(attacker, 1);
    }

    /// @dev A live session key may SPEND within its budget, but it is not the
    ///      owner: it must not be able to raise its own limits.
    function test_onlyOwner_aSessionKeyCannotRaiseItsOwnCaps() public {
        vm.prank(sessionKey);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.setPolicy(AgentAccount.Policy({perTaskCap: type(uint128).max, dailyCap: type(uint128).max, allowlistOnly: false}));
    }

    function test_onlyOwner_aSessionKeyCannotSweep() public {
        vm.prank(sessionKey);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.sweep(sessionKey, 1);
    }

    // ─────────────────── session key lifetime ───────────────────

    /// @dev A session key exists so that compromise of an online signer is
    ///      bounded IN TIME. One granted forever is a permanent key with extra
    ///      steps, and a bound that relies on the caller passing the right
    ///      number is not a control. T7 claims this; the contract enforces it.
    function test_grantSessionKey_rejectsLifetimeBeyondTheCeiling() public {
        uint64 tooLong = uint64(block.timestamp + 1 days + 1);
        vm.prank(agentOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentAccount.SessionKeyTtlInvalid.selector, tooLong, uint64(block.timestamp) + 1 days
            )
        );
        account.grantSessionKey(attacker, tooLong, 1);
    }

    function test_grantSessionKey_rejectsAnEternalKey() public {
        vm.prank(agentOwner);
        vm.expectRevert();
        account.grantSessionKey(attacker, type(uint64).max, 1);
    }

    /// @dev Exactly at the ceiling is allowed: an off-by-one here would make
    ///      the documented 24h grant itself impossible.
    function test_grantSessionKey_allowsExactlyTheCeiling() public {
        vm.prank(agentOwner);
        account.grantSessionKey(attacker, uint64(block.timestamp) + 1 days, 1);
        (uint64 expiry,,) = account.sessionKeys(attacker);
        assertEq(expiry, uint64(block.timestamp) + 1 days, "a 24h grant must be allowed");
    }

    /// @dev A grant that expired before it was made would emit a
    ///      SessionKeyGranted event for a key that never worked, which reads
    ///      in the log exactly like a working key.
    function test_grantSessionKey_rejectsAnExpiryInThePast() public {
        vm.warp(block.timestamp + 10 days);
        vm.prank(agentOwner);
        vm.expectRevert();
        account.grantSessionKey(attacker, uint64(block.timestamp - 1), 1);
    }

    function test_grantSessionKey_rejectsTheCurrentTimestamp() public {
        vm.prank(agentOwner);
        vm.expectRevert();
        account.grantSessionKey(attacker, uint64(block.timestamp), 1);
    }

    /// @dev Rotation must keep working: the ceiling constrains each grant, not
    ///      the total life of a key that is re-granted daily.
    function test_grantSessionKey_canBeRenewedAfterTheCeilingPasses() public {
        vm.warp(block.timestamp + 2 days);
        vm.prank(agentOwner);
        account.grantSessionKey(sessionKey, uint64(block.timestamp) + 1 days, DAILY_CAP);

        vm.prank(sessionKey);
        account.execute(address(escrow), _payCall(10_000));
    }

    function _payCall(uint128 amount) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                TaskEscrow.directPay, (accountAgentId, workerId, amount, keccak256("spec"))
            );
    }

    // ───────────────────── it actually works ─────────────────────

    function test_sessionKeyCanSpendWithinPolicy() public {
        uint256 before = token.balanceOf(workerWallet);

        vm.prank(sessionKey);
        account.execute(address(escrow), _payCall(MICRO));

        assertEq(token.balanceOf(workerWallet) - before, MICRO - _feeOf(MICRO), "worker paid");
        assertEq(account.spentToday(), MICRO, "spend measured from the real balance delta");
    }

    function test_ownerCanSpendDirectly() public {
        vm.prank(agentOwner);
        account.execute(address(escrow), _payCall(MICRO));
        assertEq(account.spentToday(), MICRO);
    }

    // ───────────────────── the caps hold ─────────────────────

    function test_perTaskCapBlocksASingleLargePayment() public {
        vm.prank(sessionKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentAccount.PerTaskCapExceeded.selector, PER_TASK_CAP + 1, PER_TASK_CAP
            )
        );
        account.execute(address(escrow), _payCall(PER_TASK_CAP + 1));
    }

    /// @dev The runaway-loop case: many individually-legal payments.
    function test_dailyCapStopsARunawayLoop() public {
        uint128 each = 100_000; // == perTaskCap, so each call alone is legal
        for (uint256 i; i < 2; i++) {
            vm.prank(sessionKey);
            account.execute(address(escrow), _payCall(each));
        }
        assertEq(account.spentToday(), 200_000);
        assertEq(account.dailyRemaining(), 50_000);

        // The third would exceed the daily cap and must revert outright.
        vm.prank(sessionKey);
        vm.expectRevert(
            abi.encodeWithSelector(AgentAccount.DailyCapExceeded.selector, each, uint128(50_000))
        );
        account.execute(address(escrow), _payCall(each));

        assertEq(account.spentToday(), 200_000, "a rejected call must leave no trace");
    }

    function test_dailyCapRollsAfterADay() public {
        vm.prank(sessionKey);
        account.execute(address(escrow), _payCall(100_000));
        assertEq(account.dailyRemaining(), 150_000);

        vm.warp(block.timestamp + 1 days);
        assertEq(account.dailyRemaining(), DAILY_CAP, "window rolled");

        vm.prank(sessionKey);
        account.execute(address(escrow), _payCall(100_000));
        assertEq(account.spentToday(), 100_000, "counter reset, not accumulated");
    }

    // ───────────────────── compromise containment ─────────────────────

    function test_strangerWithNoSessionKeyCannotSpend() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotAuthorized.selector);
        account.execute(address(escrow), _payCall(MICRO));
    }

    function test_expiredSessionKeyCannotSpend() public {
        vm.warp(block.timestamp + 2 days);
        vm.prank(sessionKey);
        vm.expectRevert(AgentAccount.SessionKeyExpired.selector);
        account.execute(address(escrow), _payCall(MICRO));
    }

    function test_nonAllowlistedTargetRejected() public {
        vm.prank(sessionKey);
        vm.expectRevert(
            abi.encodeWithSelector(AgentAccount.TargetNotAllowed.selector, address(token))
        );
        account.execute(address(token), abi.encodeCall(IERC20.transfer, (attacker, 1)));
    }

    function test_nonAllowlistedSelectorRejected() public {
        vm.prank(agentOwner);
        account.setAllowedTarget(address(token), true);

        vm.prank(sessionKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentAccount.SelectorNotAllowed.selector, IERC20.transfer.selector
            )
        );
        account.execute(address(token), abi.encodeCall(IERC20.transfer, (attacker, 1)));
    }

    /// @dev A standing allowance would let a spender move funds outside every
    ///      cap, so it must be unreachable from the session-key path.
    function test_approveCanNeverBeGrantedThroughExecute() public {
        vm.prank(agentOwner);
        vm.expectRevert(AgentAccount.ApproveNotAllowedHere.selector);
        account.setAllowedSelector(IERC20.approve.selector, true);
    }

    function test_sessionKeyBudgetIsIndependentOfTheDailyCap() public {
        vm.prank(agentOwner);
        account.grantSessionKey(sessionKey, uint64(block.timestamp + 1 days), 30_000);

        vm.prank(sessionKey);
        account.execute(address(escrow), _payCall(MICRO)); // 20_000, fits

        vm.prank(sessionKey);
        vm.expectRevert(AgentAccount.SessionBudgetExceeded.selector);
        account.execute(address(escrow), _payCall(MICRO)); // would total 40_000
    }

    // ───────────────────── owner keeps control ─────────────────────

    function test_ownerCanRevokeAndStopEverythingImmediately() public {
        vm.prank(agentOwner);
        account.revokeSessionKey(sessionKey);

        vm.prank(sessionKey);
        vm.expectRevert(AgentAccount.NotAuthorized.selector);
        account.execute(address(escrow), _payCall(MICRO));
    }

    /// @dev A signer that detects its own compromise should be able to disarm
    ///      without waiting for a human.
    function test_sessionKeyCanRevokeItself() public {
        vm.prank(sessionKey);
        account.revokeSessionKey(sessionKey);

        vm.prank(sessionKey);
        vm.expectRevert(AgentAccount.NotAuthorized.selector);
        account.execute(address(escrow), _payCall(MICRO));
    }

    function test_ownerCanSweep() public {
        uint256 bal = token.balanceOf(address(account));
        vm.prank(agentOwner);
        account.sweep(agentOwner, bal);
        assertEq(token.balanceOf(agentOwner), bal);
        assertEq(token.balanceOf(address(account)), 0);
    }

    function test_onlyOwnerMaySweepOrSetPolicy() public {
        vm.startPrank(attacker);
        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.sweep(attacker, 1);

        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.setPolicy(
            AgentAccount.Policy({
                perTaskCap: type(uint128).max, dailyCap: type(uint128).max, allowlistOnly: false
            })
        );

        vm.expectRevert(AgentAccount.NotOwner.selector);
        account.grantSessionKey(attacker, uint64(block.timestamp + 1 days), type(uint128).max);
        vm.stopPrank();
    }

    function test_implementationCannotBeInitialized() public {
        AgentAccount impl = AgentAccount(payable(factory.implementation()));
        vm.expectRevert();
        impl.initialize(
            attacker,
            address(token),
            AgentAccount.Policy({perTaskCap: 1, dailyCap: 1, allowlistOnly: false})
        );
    }

    function test_failedInnerCallBubblesUp() public {
        // Self-dealing: the escrow will reject it, and execute must not swallow it.
        vm.prank(sessionKey);
        vm.expectRevert();
        account.execute(
            address(escrow),
            abi.encodeCall(
                TaskEscrow.directPay, (accountAgentId, accountAgentId, MICRO, keccak256("s"))
            )
        );
    }

    function testFuzz_spendNeverExceedsTheDailyCap(uint128[5] calldata amounts) public {
        uint128 total;
        for (uint256 i; i < amounts.length; i++) {
            uint128 amount = uint128(bound(amounts[i], 1, PER_TASK_CAP));
            vm.prank(sessionKey);
            try account.execute(address(escrow), _payCall(amount)) {
                total += amount;
            } catch {}
        }
        assertEq(account.spentToday(), total);
        assertLe(account.spentToday(), DAILY_CAP, "the cap is absolute");
    }

    function test_ownerCanTightenPolicyOnALiveAccount() public {
        vm.prank(agentOwner);
        account.setPolicy(
            AgentAccount.Policy({perTaskCap: 1_000, dailyCap: 2_000, allowlistOnly: true})
        );

        (uint128 perTask, uint128 daily,) = account.policy();
        assertEq(perTask, 1_000);
        assertEq(daily, 2_000);

        // The new, tighter cap applies immediately to the existing session key.
        vm.prank(sessionKey);
        vm.expectRevert(
            abi.encodeWithSelector(AgentAccount.PerTaskCapExceeded.selector, MICRO, uint128(1_000))
        );
        account.execute(address(escrow), _payCall(MICRO));
    }

    function test_aThirdPartyCannotRevokeSomeoneElsesSessionKey() public {
        vm.prank(attacker);
        vm.expectRevert(AgentAccount.NotAuthorized.selector);
        account.revokeSessionKey(sessionKey);
    }
}
