// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StakeVault} from "../../src/StakeVault.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {BaseTest} from "../Base.t.sol";
import {Test} from "forge-std/Test.sol";

contract VaultHandler is Test {
    StakeVault public vault;
    MockUSDC public token;
    address public admin;
    address public owner;
    uint256 public agentId;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostSlashed;

    constructor(StakeVault v, MockUSDC t, address admin_, address owner_, uint256 id) {
        vault = v;
        token = t;
        admin = admin_;
        owner = owner_;
        agentId = id;
    }

    function deposit(uint96 amount) public {
        amount = uint96(bound(amount, 1, 50_000_000));
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(agentId, amount);
        ghostDeposited += amount;
    }

    function requestWithdraw(uint96 amount) public {
        amount = uint96(bound(amount, 1, 50_000_000));
        vm.prank(owner);
        try vault.requestWithdraw(agentId, amount) {} catch {}
    }

    function cancelWithdraw() public {
        vm.prank(owner);
        try vault.cancelWithdraw(agentId) {} catch {}
    }

    function withdraw() public {
        (uint96 pending,) = vault.pendingOf(agentId);
        vm.prank(owner);
        try vault.withdraw(agentId) {
            ghostWithdrawn += pending;
        } catch {}
    }

    function slash(uint96 amount) public {
        amount = uint96(bound(amount, 1, 50_000_000));
        vm.prank(admin);
        try vault.slash(agentId, amount, "fuzz") {
            ghostSlashed += amount;
        } catch {}
    }

    function warp(uint64 secondsAhead) public {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 10 days));
    }
}

/// @dev The vault must always hold exactly the bonds it records, and slashed
///      tokens must leave it — v1 decremented storage and kept them.
contract StakeVaultInvariantTest is BaseTest {
    VaultHandler internal handler;
    uint256 internal startBalance;
    uint256 internal startBond;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, token, admin, workerOwner, workerId);

        bytes32 slasher = vault.SLASHER_ROLE();
        vm.prank(admin);
        vault.grantRole(slasher, admin);

        startBalance = token.balanceOf(address(vault));
        startBond = vault.bondOf(workerId);
        targetContract(address(handler));
    }

    function invariant_vaultHoldsExactlyWhatItRecords() public view {
        (uint96 pending,) = vault.pendingOf(workerId);
        uint256 others = startBalance - startBond; // the client's bond, untouched here
        assertEq(
            token.balanceOf(address(vault)),
            others + vault.bondOf(workerId) + pending,
            "vault balance must equal recorded bonds"
        );
    }

    function invariant_slashedTokensReachTheRecipient() public view {
        assertEq(token.balanceOf(slashRecipient), handler.ghostSlashed());
    }

    function invariant_conservation() public view {
        (uint96 pending,) = vault.pendingOf(workerId);
        assertEq(
            startBond + handler.ghostDeposited(),
            vault.bondOf(workerId) + pending + handler.ghostWithdrawn() + handler.ghostSlashed(),
            "every token deposited is bonded, pending, withdrawn or slashed"
        );
    }

    function invariant_pendingImpliesAnUnlockTime() public view {
        (uint96 pending, uint64 unlockAt) = vault.pendingOf(workerId);
        if (pending > 0) assertGt(unlockAt, 0);
        else assertEq(unlockAt, 0);
    }
}
