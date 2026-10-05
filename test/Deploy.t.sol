// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Board} from "../src/Board.sol";
import {AuthorBlocklistGate} from "../src/ListGates.sol";
import {ListRegistry} from "../src/ListRegistry.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployGates} from "../script/DeployGates.s.sol";
import {DeployClosedGate} from "../script/DeployClosedGate.s.sol";
import {ClosedReplyGate} from "../src/ClosedReplyGate.sol";
import {DeployLists} from "../script/DeployLists.s.sol";

/// The deploy scripts land every contract at its predicted CREATE2 address and are idempotent: a
/// second run reports the existing deployment.
///
/// Keep environment-changing deployment checks in one test: `vm.setEnv` changes BOARD, REGISTRY and
/// LIST_NAME for all tests in the process.
contract DeployTest is Test {
    bytes32 constant GATE_SALT = keccak256("AuthorBlocklistGate v1");

    /// The salts as SPEC.md §9 documents them, spelled out here on purpose: a renamed salt in a
    /// script must fail this test, not move every address while keeping it green.
    function test_saltsAreTheDocumentedOnes() public {
        assertEq(new Deploy().SALT(), keccak256("Board v1"));
        assertEq(new DeployLists().SALT(), keccak256("ListRegistry v1"));
        assertEq(new DeployGates().SALT(), GATE_SALT);
        assertEq(new DeployClosedGate().SALT(), keccak256("ClosedReplyGate v1"));
    }

    function _gateAddress(Board board, ListRegistry registry, string memory listName)
        internal
        pure
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(AuthorBlocklistGate).creationCode,
                abi.encode(board, registry, keccak256(bytes(listName)))
            )
        );
        return vm.computeCreate2Address(GATE_SALT, initCodeHash);
    }

    function test_deterministicAddressesAndIdempotence() public {
        Board board = new Deploy().run();
        assertEq(
            address(board),
            vm.computeCreate2Address(keccak256("Board v1"), keccak256(type(Board).creationCode))
        );
        assertEq(
            address(new Deploy().run()), address(board), "second run finds the first deployment"
        );

        ListRegistry registry = new DeployLists().run();
        assertEq(
            address(registry),
            vm.computeCreate2Address(
                keccak256("ListRegistry v1"), keccak256(type(ListRegistry).creationCode)
            )
        );

        vm.setEnv("BOARD", vm.toString(address(board)));
        vm.setEnv("REGISTRY", vm.toString(address(registry)));
        AuthorBlocklistGate gate = new DeployGates().run();
        assertEq(address(gate), _gateAddress(board, registry, "blocked"));
        assertEq(address(gate.BOARD()), address(board));
        assertEq(address(gate.REGISTRY()), address(registry));
        assertEq(gate.LIST_ID(), keccak256("blocked"));
        assertEq(address(new DeployGates().run()), address(gate), "gate deploy is idempotent too");

        // LIST_NAME is a constructor argument, so another name is another gate at another address.
        vm.setEnv("LIST_NAME", "muted");
        AuthorBlocklistGate muted = new DeployGates().run();
        assertTrue(address(muted) != address(gate), "another list name, another gate");
        assertEq(address(muted), _gateAddress(board, registry, "muted"));
        assertEq(muted.LIST_ID(), keccak256("muted"));
        vm.setEnv("LIST_NAME", "blocked");

        // The gate script requires its board and registry to have code already.
        DeployGates deployer = new DeployGates();
        vm.setEnv("BOARD", vm.toString(address(0xBEEF)));
        vm.expectRevert(bytes("BOARD has no code on this chain"));
        deployer.run();
        vm.setEnv("BOARD", vm.toString(address(board)));
        vm.setEnv("REGISTRY", vm.toString(address(0xBEEF)));
        vm.expectRevert(bytes("REGISTRY has no code on this chain"));
        deployer.run();
        vm.setEnv("REGISTRY", vm.toString(address(registry)));

        ClosedReplyGate closed = new DeployClosedGate().run();
        assertEq(
            address(closed),
            vm.computeCreate2Address(
                keccak256("ClosedReplyGate v1"), keccak256(type(ClosedReplyGate).creationCode)
            )
        );
        assertEq(
            address(new DeployClosedGate().run()), address(closed), "closed gate is idempotent"
        );
        assertFalse(closed.canReply(1, address(this), ""));
    }
}
