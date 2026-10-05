// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Board} from "../src/Board.sol";
import {AuthorBlocklistGate, BlocklistGate} from "../src/ListGates.sol";
import {ListRegistry} from "../src/ListRegistry.sol";

/// Gas ceilings for what people pay for: a post, a reply, replies through both list gates, and the
/// signature paths a relayer pays for. Each figure is the call's own cost measured from the test,
/// printed with `forge test --match-contract BoardGasTest -vv`; the ceilings sit about fifteen
/// percent above the measurement, so a regression fails here rather than on a receipt. Raise a
/// ceiling only with the new measurement in the commit message.
contract BoardGasTest is Test {
    Board board;
    ListRegistry registry;
    BlocklistGate blocklist;
    AuthorBlocklistGate authorBlocklist;

    address alice;
    uint256 aliceKey;
    address bob;
    address relayer = makeAddr("relayer");

    bytes32 constant LIST = keccak256("blocked");
    address constant NO_GATE = address(0);
    bytes constant NO_DATA = "";

    uint256 constant POST_CEILING = 94_000;
    uint256 constant REPLY_CEILING = 104_000;
    uint256 constant BLOCKLIST_REPLY_CEILING = 112_000;
    uint256 constant AUTHOR_BLOCKLIST_REPLY_CEILING = 118_000;
    uint256 constant POST_BY_SIG_CEILING = 140_000;
    uint256 constant DELETE_CEILING = 64_000;
    uint256 constant DELETE_BY_SIG_CEILING = 100_000;

    // Parents are created in setUp so every measured reply reads a cold parent, as a real reply
    // does; a parent written in the same test would be warm.
    uint64 root;
    uint64 gatedRoot;
    uint64 authorGatedRoot;
    uint64 gatedReply;

    function setUp() public {
        board = new Board();
        registry = new ListRegistry();
        (alice, aliceKey) = makeAddrAndKey("alice");
        bob = makeAddr("bob");
        blocklist = new BlocklistGate(registry, alice, LIST);
        authorBlocklist = new AuthorBlocklistGate(board, registry, LIST);
        address[] memory blocked = new address[](1);
        blocked[0] = makeAddr("carol");
        vm.prank(alice);
        registry.add(alice, LIST, blocked);
        vm.warp(1_700_000_000);
        // The first post ever initialises the counter; steady-state posts are what people pay for,
        // so every measurement follows these.
        vm.prank(alice);
        root = board.post(keccak256("root"), 0, NO_GATE, NO_DATA);
        vm.prank(alice);
        gatedRoot = board.post(keccak256("gated"), 0, address(blocklist), NO_DATA);
        address dave = makeAddr("dave");
        vm.prank(dave);
        board.setAuthorGate(address(authorBlocklist));
        vm.prank(dave);
        authorGatedRoot = board.post(keccak256("author gated"), 0, NO_GATE, NO_DATA);
        vm.prank(bob);
        gatedReply = board.post(keccak256("gated reply"), root, address(authorBlocklist), NO_DATA);
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", board.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _report(string memory what, uint256 used, uint256 ceiling) internal {
        emit log_named_uint(what, used);
        assertLt(used, ceiling, what);
    }

    function test_gas_post() public {
        vm.prank(bob);
        uint256 before = gasleft();
        board.post(keccak256("post"), 0, NO_GATE, NO_DATA);
        _report("post", before - gasleft(), POST_CEILING);
    }

    function test_gas_reply() public {
        vm.prank(bob);
        uint256 before = gasleft();
        board.post(keccak256("reply"), root, NO_GATE, NO_DATA);
        _report("reply", before - gasleft(), REPLY_CEILING);
    }

    function test_gas_protectedResponse() public {
        vm.prank(alice);
        uint256 before = gasleft();
        board.post(keccak256("response"), gatedReply, NO_GATE, NO_DATA);
        _report("protected response", before - gasleft(), REPLY_CEILING);
    }

    function test_gas_ordinaryResponse() public {
        vm.prank(bob);
        uint256 before = gasleft();
        board.post(keccak256("ordinary response"), gatedReply, NO_GATE, NO_DATA);
        _report(
            "ordinary response through a gate", before - gasleft(), AUTHOR_BLOCKLIST_REPLY_CEILING
        );
    }

    function test_gas_replyThroughBlocklistGate() public {
        vm.prank(bob);
        uint256 before = gasleft();
        board.post(keccak256("reply"), gatedRoot, NO_GATE, NO_DATA);
        _report("reply through a blocklist gate", before - gasleft(), BLOCKLIST_REPLY_CEILING);
    }

    function test_gas_replyThroughAuthorBlocklistGate() public {
        vm.prank(bob);
        uint256 before = gasleft();
        board.post(keccak256("reply"), authorGatedRoot, NO_GATE, NO_DATA);
        _report(
            "reply through the author blocklist gate",
            before - gasleft(),
            AUTHOR_BLOCKLIST_REPLY_CEILING
        );
    }

    function test_gas_postBySig() public {
        bytes32 hash = keccak256("sponsored");
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _sign(
            keccak256(abi.encode(board.POST_TYPEHASH(), alice, hash, root, NO_GATE, 1, deadline))
        );
        vm.prank(relayer);
        uint256 before = gasleft();
        board.postBySig(alice, hash, root, NO_GATE, 1, deadline, sig, NO_DATA);
        _report("sponsored reply", before - gasleft(), POST_BY_SIG_CEILING);
    }

    function test_gas_delete() public {
        address tombstone = board.TOMBSTONE();
        vm.prank(alice);
        uint256 before = gasleft();
        board.setReplyGate(root, tombstone);
        _report("delete", before - gasleft(), DELETE_CEILING);
    }

    function test_gas_deleteBySig() public {
        address tombstone = board.TOMBSTONE();
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _sign(
            keccak256(
                abi.encode(board.SET_REPLY_GATE_TYPEHASH(), alice, root, tombstone, 1, deadline)
            )
        );
        vm.prank(relayer);
        uint256 before = gasleft();
        board.setReplyGateBySig(alice, root, tombstone, 1, deadline, sig);
        _report("sponsored delete", before - gasleft(), DELETE_BY_SIG_CEILING);
    }
}
