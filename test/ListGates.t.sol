// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Board} from "../src/Board.sol";
import {IBoard} from "../src/IBoard.sol";
import {AuthorBlocklistGate, BlocklistGate, ZeroAddress} from "../src/ListGates.sol";
import {ListRegistry} from "../src/ListRegistry.sol";
import {AllowAllGate} from "./mocks/Gates.sol";

/// The list gates, exercised through the board like a real thread would.
contract ListGatesTest is Test {
    Board board;
    ListRegistry registry;
    BlocklistGate blocklist;
    AuthorBlocklistGate authorBlocklist;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    bytes32 constant FRIENDS = keccak256("friends");
    bytes32 constant BLOCKED = keccak256("blocked");
    address constant NO_GATE = address(0);
    bytes constant NO_DATA = "";

    function setUp() public {
        board = new Board();
        registry = new ListRegistry();
        blocklist = new BlocklistGate(registry, alice, FRIENDS);
        authorBlocklist = new AuthorBlocklistGate(board, registry, BLOCKED);
        address[] memory m = new address[](1);
        m[0] = bob;
        vm.prank(alice);
        registry.add(alice, FRIENDS, m);
    }

    function _post(address who, uint64 parent, address gate) internal returns (uint64) {
        vm.prank(who);
        return board.post(keccak256(abi.encode(who, parent, gate)), parent, gate, NO_DATA);
    }

    function _expectRejected(address who, uint64 parent, address gate) internal {
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, gate));
        board.post(keccak256(abi.encode(who, parent, "rejected")), parent, NO_GATE, NO_DATA);
    }

    function test_gatesRememberTheirList() public view {
        assertEq(address(blocklist.REGISTRY()), address(registry));
        assertEq(blocklist.LIST_OWNER(), alice);
        assertEq(blocklist.LIST_ID(), FRIENDS);
    }

    function test_blocklistRejectsMembersOnly() public {
        uint64 root = _post(alice, 0, address(blocklist));
        _post(carol, root, NO_GATE); // carol is not on the list
        _expectRejected(bob, root, address(blocklist));
    }

    /// A blocklist nobody has written to admits everyone.
    function test_emptyBlocklistAdmitsEveryone() public {
        BlocklistGate open = new BlocklistGate(registry, carol, FRIENDS);
        uint64 root = _post(alice, 0, address(open));
        _post(alice, root, NO_GATE);
        _post(bob, root, NO_GATE);
        _post(carol, root, NO_GATE);
    }

    function test_listChangesApplyForward() public {
        uint64 root = _post(alice, 0, address(blocklist));
        // Adding carol closes the door for her next reply; her earlier one stands.
        uint64 earlier = _post(carol, root, NO_GATE);
        address[] memory m = new address[](1);
        m[0] = carol;
        vm.prank(alice);
        registry.add(alice, FRIENDS, m);
        _expectRejected(carol, root, address(blocklist));
        assertTrue(board.exists(earlier));
    }

    /// The shared author gate: one deployment, each author's own list.
    function test_authorBlocklistGateServesEveryAuthor() public {
        // Alice installs the shared gate as her author gate and blocks bob.
        vm.prank(alice);
        board.setAuthorGate(address(authorBlocklist));
        address[] memory m = new address[](1);
        m[0] = bob;
        vm.prank(alice);
        registry.add(alice, BLOCKED, m);

        uint64 root = _post(alice, 0, NO_GATE);
        // Carol may reply; bob may not.
        uint64 carols = _post(carol, root, NO_GATE);
        _expectRejected(bob, root, address(authorBlocklist));
        // Bob may reply to carol's reply: carol has no author gate, and the gate resolves the list
        // owner from the parent's author.
        _post(bob, carols, NO_GATE);
        // A permissive per-message gate on alice's own message wins over her default.
        uint64 open = _post(alice, 0, address(new AllowAllGate()));
        _post(bob, open, NO_GATE);
        // Unblocking reopens the door.
        vm.prank(alice);
        registry.remove(alice, BLOCKED, m);
        _post(bob, root, NO_GATE);
    }

    /// Constructors reject a zero registry, owner or board.
    function test_gatesRejectZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new BlocklistGate(ListRegistry(address(0)), alice, FRIENDS);
        vm.expectRevert(ZeroAddress.selector);
        new BlocklistGate(registry, address(0), FRIENDS);

        vm.expectRevert(ZeroAddress.selector);
        new AuthorBlocklistGate(IBoard(address(0)), registry, BLOCKED);
        vm.expectRevert(ZeroAddress.selector);
        new AuthorBlocklistGate(board, ListRegistry(address(0)), BLOCKED);
    }
}
