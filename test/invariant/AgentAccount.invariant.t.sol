// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgentAccount} from "../../src/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/AgentAccountFactory.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @dev A compromised session key, trying everything it can. The caps are the
///      claim this contract exists to make; these are the invariants that make
///      it true under arbitrary sequences.
contract AccountHandler is Test {
    AgentAccount public account;
    MockUSDC public token;
    address public key;
    address public sink;

    /// @dev Outflow in the current window, measured from the outside.
    uint256 public ghostWindowOutflow;
    uint64 public ghostWindowStart;
    uint256 public ghostKeyOutflow;

    constructor(AgentAccount a, MockUSDC t, address key_) {
        account = a;
        token = t;
        key = key_;
        sink = makeAddr("sink");
        ghostWindowStart = a.dayStart();
    }

    function spend(uint128 amount) public {
        amount = uint128(bound(amount, 1, 500_000));
        uint256 before = token.balanceOf(address(account));
        vm.prank(key);
        try account.execute(address(token), abi.encodeCall(IERC20.transfer, (sink, amount))) {
            if (account.dayStart() != ghostWindowStart) {
                ghostWindowStart = account.dayStart();
                ghostWindowOutflow = 0;
            }
            uint256 out = before - token.balanceOf(address(account));
            ghostWindowOutflow += out;
            ghostKeyOutflow += out;
        } catch {}
    }

    /// @dev Everything a stolen key might try beyond spending.
    function tryEscape(uint8 which) public {
        vm.startPrank(key);
        if (which % 4 == 0) {
            try account.setAllowance(key, type(uint256).max) {} catch {}
        } else if (which % 4 == 1) {
            try account.sweep(key, 1) {} catch {}
        } else if (which % 4 == 2) {
            try account.execute(
                address(token), abi.encodeCall(IERC20.approve, (key, type(uint256).max))
            ) {}
                catch {}
        } else {
            try account.setPolicy(
                AgentAccount.Policy({
                    perTaskCap: type(uint128).max, dailyCap: type(uint128).max, allowlistOnly: false
                })
            ) {}
                catch {}
        }
        vm.stopPrank();
    }

    function warp(uint64 secondsAhead) public {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 2 days));
    }
}

contract AgentAccountInvariantTest is Test {
    MockUSDC internal token;
    AgentAccount internal account;
    AccountHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal key = makeAddr("key");

    uint128 internal constant PER_TASK = 100_000;
    uint128 internal constant DAILY = 250_000;
    uint128 internal constant KEY_BUDGET = 400_000;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockUSDC();
        AgentAccountFactory factory = new AgentAccountFactory(address(token));
        vm.prank(owner);
        account = AgentAccount(
            payable(factory.createAccount(
                    owner,
                    bytes32("fuzz"),
                    AgentAccount.Policy({
                        perTaskCap: PER_TASK, dailyCap: DAILY, allowlistOnly: true
                    })
                ))
        );
        token.mint(address(account), 100_000_000);

        vm.startPrank(owner);
        account.setAllowedCall(address(token), IERC20.transfer.selector, true);
        account.grantSessionKey(key, uint64(block.timestamp + 1 days), KEY_BUDGET);
        vm.stopPrank();

        handler = new AccountHandler(account, token, key);
        targetContract(address(handler));
    }

    function invariant_windowOutflowNeverExceedsTheDailyCap() public view {
        assertLe(handler.ghostWindowOutflow(), DAILY);
        assertLe(account.spentToday(), DAILY);
    }

    function invariant_theKeyNeverExceedsItsBudget() public view {
        assertLe(handler.ghostKeyOutflow(), KEY_BUDGET);
        (, uint128 budget, uint128 spent) = account.sessionKeys(key);
        assertLe(spent, budget);
    }

    function invariant_aStolenKeyCannotGrantAnAllowanceOrChangePolicy() public view {
        assertEq(token.allowance(address(account), key), 0);
        (uint128 perTask, uint128 daily,) = account.policy();
        assertEq(perTask, PER_TASK);
        assertEq(daily, DAILY);
        assertEq(account.owner(), owner);
    }
}
