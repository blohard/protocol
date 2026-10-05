// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";

import {ListRegistry} from "../src/ListRegistry.sol";

contract ListRegistryTest is Test {
    ListRegistry registry;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    bytes32 constant FRIENDS = keccak256("friends");
    bytes32 constant BLOCKED = keccak256("blocked");

    event Added(address indexed owner, bytes32 indexed listId, address indexed member);
    event Removed(address indexed owner, bytes32 indexed listId, address indexed member);

    function setUp() public {
        registry = new ListRegistry();
    }

    function _list(address a, address b) internal pure returns (address[] memory m) {
        m = new address[](2);
        m[0] = a;
        m[1] = b;
    }

    function _list(address a, address b, address c) internal pure returns (address[] memory m) {
        m = new address[](3);
        m[0] = a;
        m[1] = b;
        m[2] = c;
    }

    function _one(address a) internal pure returns (address[] memory m) {
        m = new address[](1);
        m[0] = a;
    }

    function test_addAndRemove() public {
        vm.prank(alice);
        vm.expectEmit();
        emit Added(alice, FRIENDS, bob);
        registry.add(alice, FRIENDS, _list(bob, carol));
        assertTrue(registry.contains(alice, FRIENDS, bob));
        assertTrue(registry.contains(alice, FRIENDS, carol));

        vm.prank(alice);
        vm.expectEmit();
        emit Removed(alice, FRIENDS, bob);
        registry.remove(alice, FRIENDS, _one(bob));
        assertFalse(registry.contains(alice, FRIENDS, bob));
        assertTrue(registry.contains(alice, FRIENDS, carol));
    }

    function test_idempotent() public {
        vm.startPrank(alice);
        registry.add(alice, FRIENDS, _list(bob, bob));
        assertTrue(registry.contains(alice, FRIENDS, bob));
        registry.add(alice, FRIENDS, _one(bob));
        assertTrue(registry.contains(alice, FRIENDS, bob));
        registry.remove(alice, FRIENDS, _one(carol));
        assertTrue(registry.contains(alice, FRIENDS, bob));
        assertFalse(registry.contains(alice, FRIENDS, carol));
        registry.remove(alice, FRIENDS, _list(bob, bob));
        assertFalse(registry.contains(alice, FRIENDS, bob));
        vm.stopPrank();
    }

    /// The zero address is an ordinary key: it can be listed and delisted.
    function test_zeroAddressIsAnOrdinaryMember() public {
        vm.startPrank(alice);
        registry.add(alice, FRIENDS, _one(address(0)));
        assertTrue(registry.contains(alice, FRIENDS, address(0)));
        registry.remove(alice, FRIENDS, _one(address(0)));
        assertFalse(registry.contains(alice, FRIENDS, address(0)));
        vm.stopPrank();
    }

    /// Exactly one event per actual change: duplicates within a batch, re-adds and removals of
    /// absent addresses emit nothing.
    function test_eventsFireOncePerChange() public {
        vm.startPrank(alice);
        vm.recordLogs();
        registry.add(alice, FRIENDS, _list(bob, bob, carol));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "two members joined");
        assertEq(logs[0].topics[0], Added.selector);
        assertEq(address(uint160(uint256(logs[0].topics[3]))), bob);
        assertEq(logs[1].topics[0], Added.selector);
        assertEq(address(uint160(uint256(logs[1].topics[3]))), carol);

        registry.add(alice, FRIENDS, _one(bob));
        assertEq(vm.getRecordedLogs().length, 0, "re-adding is silent");

        registry.remove(alice, FRIENDS, _list(bob, bob, dave));
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one member left; dave was never there");
        assertEq(logs[0].topics[0], Removed.selector);
        assertEq(address(uint160(uint256(logs[0].topics[3]))), bob);
        vm.stopPrank();
    }

    /// Membership stays correct across batches that overlap each other in both directions.
    function test_membershipTracksInterleavedOverlappingBatches() public {
        vm.startPrank(alice);
        registry.add(alice, FRIENDS, _list(bob, carol)); // {bob, carol}
        assertTrue(registry.contains(alice, FRIENDS, bob));
        assertTrue(registry.contains(alice, FRIENDS, carol));
        registry.add(alice, FRIENDS, _list(carol, dave)); // {bob, carol, dave}
        assertTrue(registry.contains(alice, FRIENDS, dave));
        registry.remove(alice, FRIENDS, _list(bob, dave)); // {carol}
        assertFalse(registry.contains(alice, FRIENDS, bob));
        assertFalse(registry.contains(alice, FRIENDS, dave));
        assertTrue(registry.contains(alice, FRIENDS, carol));
        registry.add(alice, FRIENDS, _list(dave, erin)); // {carol, dave, erin}
        assertTrue(registry.contains(alice, FRIENDS, dave));
        assertTrue(registry.contains(alice, FRIENDS, erin));
        registry.remove(alice, FRIENDS, _list(carol, erin, bob)); // {dave}
        vm.stopPrank();
        assertTrue(registry.contains(alice, FRIENDS, dave));
        assertFalse(registry.contains(alice, FRIENDS, bob));
        assertFalse(registry.contains(alice, FRIENDS, carol));
        assertFalse(registry.contains(alice, FRIENDS, erin));
    }

    function test_listsAreScopedByOwnerAndId() public {
        vm.prank(alice);
        registry.add(alice, FRIENDS, _one(bob));
        // Same id, different owner: a different list.
        assertFalse(registry.contains(carol, FRIENDS, bob));
        // Same owner, different id: a different list.
        assertFalse(registry.contains(alice, BLOCKED, bob));
        // Nobody else can write to alice's list; they only write their own.
        vm.prank(bob);
        registry.remove(bob, FRIENDS, _one(bob));
        assertTrue(registry.contains(alice, FRIENDS, bob));
        assertFalse(registry.contains(bob, FRIENDS, bob));
    }

    function test_onlyTheNamedOwnerWrites() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ListRegistry.NotOwner.selector, alice, bob));
        registry.add(alice, FRIENDS, _one(carol));
        vm.prank(alice);
        registry.add(alice, FRIENDS, _one(carol));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ListRegistry.NotOwner.selector, alice, bob));
        registry.remove(alice, FRIENDS, _one(carol));
        assertTrue(registry.contains(alice, FRIENDS, carol), "a stranger changed nothing");
        assertFalse(registry.contains(bob, FRIENDS, carol), "and got no list of their own");
    }

    function testFuzz_eventsMatchMembership(address[] calldata members) public {
        vm.assume(members.length <= 64);
        vm.recordLogs();
        vm.prank(alice);
        registry.add(alice, FRIENDS, members);
        uint256 distinct;
        for (uint256 i; i < members.length; ++i) {
            assertTrue(registry.contains(alice, FRIENDS, members[i]));
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (members[j] == members[i]) seen = true;
            }
            if (!seen) ++distinct;
        }
        assertEq(vm.getRecordedLogs().length, distinct, "one Added event per distinct member");
        vm.prank(alice);
        registry.remove(alice, FRIENDS, members);
        assertEq(vm.getRecordedLogs().length, distinct, "one Removed event per distinct member");
        for (uint256 i; i < members.length; ++i) {
            assertFalse(registry.contains(alice, FRIENDS, members[i]));
        }
    }
}
