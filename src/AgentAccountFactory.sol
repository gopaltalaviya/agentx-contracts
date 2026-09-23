// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentAccount} from "./AgentAccount.sol";
import {Clones} from "openzeppelin-contracts/proxy/Clones.sol";

/// @title AgentAccountFactory — deterministic minimal-proxy accounts
/// @dev ERC-1167 clones: an agent wallet costs ~45 bytes of deployed code
///      instead of a full contract. At the volume AGENTX is designed for —
///      thousands of agents — that difference is the difference between
///      onboarding being free and being a fundraise.
///
///      Addresses are CREATE2-deterministic from (owner, salt), so an agent's
///      wallet address can be computed and funded BEFORE it is deployed.
contract AgentAccountFactory {
    address public immutable implementation;
    address public immutable token;

    event AccountCreated(address indexed account, address indexed owner, bytes32 salt);

    constructor(address token_) {
        token = token_;
        implementation = address(new AgentAccount());
    }

    function createAccount(address owner, bytes32 salt, AgentAccount.Policy calldata policy)
        external
        returns (address account)
    {
        account = Clones.cloneDeterministic(implementation, _saltOf(owner, salt));
        AgentAccount(payable(account)).initialize(owner, token, policy);
        emit AccountCreated(account, owner, salt);
    }

    /// @notice Where an account WILL live, before it exists.
    function predictAddress(address owner, bytes32 salt) external view returns (address) {
        return
            Clones.predictDeterministicAddress(implementation, _saltOf(owner, salt), address(this));
    }

    /// @dev Binding the owner into the salt stops one owner from front-running
    ///      another's chosen salt to occupy their address.
    function _saltOf(address owner, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt));
    }
}
