// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title Deploy — network-agnostic deployment driven entirely by config/
/// @notice One script for every network. The chain is selected by `--rpc-url`,
///         and everything else is read from:
///           config/networks.json        what this chain is
///           config/params.<chainId>.json what the protocol parameters are
///
///         There is no `if (mainnet)` anywhere. See docs/08.
///
/// @dev M0 scope: payment token only. M1 extends `run()` with StakeVault,
///      TaskEscrow and AgentAccountFactory, plus the ERC-8004 reference
///      registries on chains where they are absent (Monad testnet — verified
///      2026-09-22, see docs/09 §8).
contract Deploy is Script {
    struct Params {
        uint96 minStake;
        uint64 withdrawDelaySeconds;
        uint128 fastPathMax;
        uint16 fastPathMinScore;
        uint16 protocolFeeBps;
        uint64 acceptWindowSeconds;
        uint64 workWindowSeconds;
        uint64 reviewWindowSeconds;
        uint32 confidenceFloor;
    }

    string internal networksJson;
    string internal paramsJson;
    uint256 internal chainId;

    function setUp() public {
        chainId = block.chainid;
        networksJson = vm.readFile("config/networks.json");
        paramsJson = vm.readFile(string.concat("config/params.", vm.toString(chainId), ".json"));
    }

    function run() public {
        Params memory p = _readParams();
        bool isTestnet = _netBool("testnet");

        console2.log("=====================================");
        console2.log("AGENTX deploy");
        console2.log("  chain    :", _netString("name"));
        console2.log("  chainId  :", chainId);
        console2.log("  testnet  :", isTestnet);
        console2.log("=====================================");

        vm.startBroadcast();

        address paymentToken = _resolvePaymentToken(isTestnet);
        _reportErc8004(isTestnet);

        vm.stopBroadcast();

        // Written to deployments/<chainId>.json by scripts/write-deployment.mjs,
        // which reads the broadcast artifact. Never hand-edited.
        console2.log("");
        console2.log("DEPLOYED paymentToken:", paymentToken);
        console2.log("PARAM minStake       :", p.minStake);
        console2.log("PARAM fastPathMax    :", p.fastPathMax);
        console2.log("PARAM protocolFeeBps :", p.protocolFeeBps);
        console2.log("");
        console2.log("Next: node scripts/write-deployment.mjs <network-alias>");
    }

    /// @dev Deploy a mintable test token, or adopt the canonical one — decided
    ///      by config, never by a branch in application code.
    function _resolvePaymentToken(bool isTestnet) internal returns (address) {
        bool deployToken = _netBool("paymentToken.deployWithProtocol");

        if (!deployToken) {
            address configured = _netAddress("paymentToken.address");
            require(configured != address(0), "paymentToken.address unset (see D8)");
            require(configured.code.length > 0, "paymentToken.address has no code");
            console2.log("paymentToken: using canonical", configured);
            return configured;
        }

        // A mintable token must never reach a production network. The config
        // checker enforces this too; belt and braces, because this one is
        // irreversible.
        require(isTestnet, "refusing to deploy MockUSDC on a non-testnet");

        MockUSDC token = new MockUSDC();
        console2.log("paymentToken: deployed MockUSDC", address(token));
        return address(token);
    }

    /// @dev ERC-8004 is absent on Monad testnet (verified on-chain 2026-09-22).
    ///      M1-00c adds the reference-registry deployment here.
    function _reportErc8004(bool) internal view {
        if (_netBool("erc8004.deployWithProtocol")) {
            console2.log(
                "erc8004: NOT deployed on this chain - M1-00c will deploy the reference impl"
            );
        } else {
            console2.log("erc8004 identity  :", _netAddress("erc8004.identityRegistry"));
            console2.log("erc8004 reputation:", _netAddress("erc8004.reputationRegistry"));
        }
    }

    // ── config readers ───────────────────────────────────────────────────
    // Amounts are strings in JSON so they survive any tooling that would
    // otherwise round them through a float.

    function _readParams() internal view returns (Params memory p) {
        p.minStake = uint96(vm.parseUint(vm.parseJsonString(paramsJson, ".minStake")));
        p.withdrawDelaySeconds = uint64(vm.parseJsonUint(paramsJson, ".withdrawDelaySeconds"));
        p.fastPathMax = uint128(vm.parseUint(vm.parseJsonString(paramsJson, ".fastPathMax")));
        p.fastPathMinScore = uint16(vm.parseJsonUint(paramsJson, ".fastPathMinScore"));
        p.protocolFeeBps = uint16(vm.parseJsonUint(paramsJson, ".protocolFeeBps"));
        p.acceptWindowSeconds = uint64(vm.parseJsonUint(paramsJson, ".acceptWindowSeconds"));
        p.workWindowSeconds = uint64(vm.parseJsonUint(paramsJson, ".workWindowSeconds"));
        p.reviewWindowSeconds = uint64(vm.parseJsonUint(paramsJson, ".reviewWindowSeconds"));
        p.confidenceFloor = uint32(vm.parseJsonUint(paramsJson, ".confidenceFloor"));

        require(p.fastPathMax > 0, "fastPathMax must be > 0");
        require(p.protocolFeeBps <= 1000, "protocolFeeBps > 10%");
        require(p.reviewWindowSeconds > 0, "reviewWindow 0 would trap funds");
    }

    function _key(string memory path) internal view returns (string memory) {
        return string.concat(".", vm.toString(chainId), ".", path);
    }

    function _netBool(string memory path) internal view returns (bool) {
        return vm.parseJsonBool(networksJson, _key(path));
    }

    function _netString(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(networksJson, _key(path));
    }

    function _netAddress(string memory path) internal view returns (address) {
        return vm.parseJsonAddress(networksJson, _key(path));
    }
}
