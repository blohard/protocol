// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DeterministicDeploy} from "./DeterministicDeploy.sol";

import {ClosedReplyGate} from "../src/ClosedReplyGate.sol";

/// Deploys the shared `ClosedReplyGate` ("no new replies") through the deterministic deployer proxy
/// (CREATE2). It has no constructor arguments, so its address is the same on every chain. Authors
/// close a post, or their whole account, by setting it as the reply gate.
///
///   forge script script/DeployClosedGate.s.sol \
///       --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
///
/// Re-running is harmless: an existing deployment is reported, not repeated.
contract DeployClosedGate is DeterministicDeploy {
    bytes32 public constant SALT = keccak256("ClosedReplyGate v1");

    function run() external returns (ClosedReplyGate) {
        return ClosedReplyGate(deploy("ClosedReplyGate", SALT, type(ClosedReplyGate).creationCode));
    }
}
