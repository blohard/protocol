// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Board} from "../src/Board.sol";
import {ClosedReplyGate} from "../src/ClosedReplyGate.sol";
import {AuthorBlocklistGate} from "../src/ListGates.sol";
import {ListRegistry} from "../src/ListRegistry.sol";

/// Every address in deployments.json is the CREATE2 address of the code in this repository, so the
/// file cannot go stale: changing a contract without updating it, or the reverse, fails here.
contract DeploymentsTest is Test {
    string json;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/deployments.json"));
    }

    function _check(string memory chain) internal view {
        string memory root = string.concat(".", chain);
        address board = vm.parseJsonAddress(json, string.concat(root, ".Board.address"));
        assertEq(
            board,
            vm.computeCreate2Address(keccak256("Board v1"), keccak256(type(Board).creationCode)),
            string.concat(chain, " Board")
        );
        address registry = vm.parseJsonAddress(json, string.concat(root, ".ListRegistry.address"));
        assertEq(
            registry,
            vm.computeCreate2Address(
                keccak256("ListRegistry v1"), keccak256(type(ListRegistry).creationCode)
            ),
            string.concat(chain, " ListRegistry")
        );
        string memory list =
            vm.parseJsonString(json, string.concat(root, ".AuthorBlocklistGate.list"));
        assertEq(
            vm.parseJsonAddress(json, string.concat(root, ".AuthorBlocklistGate.address")),
            vm.computeCreate2Address(
                keccak256("AuthorBlocklistGate v1"),
                keccak256(
                    abi.encodePacked(
                        type(AuthorBlocklistGate).creationCode,
                        abi.encode(board, registry, keccak256(bytes(list)))
                    )
                )
            ),
            string.concat(chain, " AuthorBlocklistGate")
        );
        if (vm.keyExistsJson(json, string.concat(root, ".ClosedReplyGate"))) {
            assertEq(
                vm.parseJsonAddress(json, string.concat(root, ".ClosedReplyGate.address")),
                vm.computeCreate2Address(
                    keccak256("ClosedReplyGate v1"), keccak256(type(ClosedReplyGate).creationCode)
                ),
                string.concat(chain, " ClosedReplyGate")
            );
        }
    }

    function test_baseAddressesAreThisCode() public view {
        assertEq(vm.parseJsonUint(json, ".base.chainId"), 8453);
        _check("base");
    }

    function test_baseSepoliaAddressesAreThisCode() public view {
        assertEq(vm.parseJsonUint(json, ".baseSepolia.chainId"), 84532);
        _check("baseSepolia");
    }
}
