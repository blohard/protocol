// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DeterministicDeploy} from "./DeterministicDeploy.sol";

import {ListRegistry} from "../src/ListRegistry.sol";

/// Deploys the shared `ListRegistry` (SPEC.md §5.3) through the deterministic deployer proxy
/// (CREATE2): same address on every chain for the same version. One per chain is enough: every
/// account keeps its own lists in it. Re-running reports an existing deployment instead of
/// repeating it.
///
///   forge script script/DeployLists.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
///
/// Gates that read a list are deployed by whoever wants one; the shared author gate has its own
/// script (DeployGates.s.sol).
contract DeployLists is DeterministicDeploy {
    bytes32 public constant SALT = keccak256("ListRegistry v1");

    function run() external returns (ListRegistry) {
        return ListRegistry(deploy("ListRegistry", SALT, type(ListRegistry).creationCode));
    }
}
