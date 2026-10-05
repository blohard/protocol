// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DeterministicDeploy} from "./DeterministicDeploy.sol";

import {Board} from "../src/Board.sol";

/// Deploys the core contract (`Board`) through the deterministic deployer proxy (CREATE2), so the
/// same version lands at the same address on every chain regardless of who deploys it or in what
/// order (SPEC.md §9). The address depends only on the salt and the compiled bytecode, which the
/// build pins (compiler version, optimizer settings, no metadata hash). Re-running is harmless: an
/// existing deployment is reported, not repeated.
///
///   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
///
/// Without --broadcast nothing is sent: the script simulates the deployment and prints the Board's
/// address on that chain, whether it is already deployed there or not.
contract Deploy is DeterministicDeploy {
    bytes32 public constant SALT = keccak256("Board v1");

    function run() external returns (Board) {
        return Board(deploy("Board", SALT, type(Board).creationCode));
    }
}
