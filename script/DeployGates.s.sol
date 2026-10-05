// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {console} from "forge-std/Script.sol";

import {DeterministicDeploy} from "./DeterministicDeploy.sol";

import {IBoard} from "../src/IBoard.sol";
import {AuthorBlocklistGate} from "../src/ListGates.sol";
import {ListRegistry} from "../src/ListRegistry.sol";

/// Deploys the shared `AuthorBlocklistGate` for a board and a registry through the deterministic
/// deployer proxy (CREATE2). With the board and registry at their own deterministic addresses, the
/// gate's address is the same on every chain too. Every author who wants a block list points their
/// author gate at it and keeps their own list (named LIST_NAME, default "blocked").
///
///   BOARD=0x… REGISTRY=0x… forge script script/DeployGates.s.sol \
///       --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
///
/// BOARD and REGISTRY must already have code on the target chain; the script refuses to deploy a
/// gate whose dependencies are missing, since a gate bound to an empty address would refuse replies
/// until that dependency had code.
contract DeployGates is DeterministicDeploy {
    bytes32 public constant SALT = keccak256("AuthorBlocklistGate v1");

    function run() external returns (AuthorBlocklistGate) {
        IBoard board = IBoard(vm.envAddress("BOARD"));
        require(address(board).code.length > 0, "BOARD has no code on this chain");

        ListRegistry registry = ListRegistry(vm.envAddress("REGISTRY"));
        require(address(registry).code.length > 0, "REGISTRY has no code on this chain");

        string memory name = vm.envOr("LIST_NAME", string("blocked"));
        console.log("list name", name);
        bytes memory initCode = abi.encodePacked(
            type(AuthorBlocklistGate).creationCode,
            abi.encode(board, registry, keccak256(bytes(name)))
        );
        return AuthorBlocklistGate(deploy("AuthorBlocklistGate", SALT, initCode));
    }
}
