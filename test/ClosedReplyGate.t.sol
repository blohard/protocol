// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Board} from "../src/Board.sol";
import {IBoard} from "../src/IBoard.sol";
import {ClosedReplyGate} from "../src/ClosedReplyGate.sol";

contract ClosedReplyGateTest is Test {
    function test_closingIsReversibleAndLeavesExistingRepliesAlone() public {
        Board board = new Board();
        ClosedReplyGate gate = new ClosedReplyGate();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.prank(alice);
        uint64 root = board.post(keccak256("root"), 0, address(0), "");
        vm.prank(bob);
        uint64 reply = board.post(keccak256("reply"), root, address(0), "");
        vm.prank(alice);
        board.setReplyGate(root, address(gate));
        assertEq(board.authorOf(reply), bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        vm.prank(bob);
        board.post(keccak256("closed"), root, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        vm.prank(alice);
        board.post(keccak256("also closed"), root, address(0), "");
        // Closing the root affects its direct replies, not replies under an existing child.
        vm.prank(alice);
        board.post(keccak256("nested"), reply, address(0), "");
        vm.prank(alice);
        board.setReplyGate(root, address(0));
        vm.prank(bob);
        board.post(keccak256("reopened"), root, address(0), "");
    }

    function testFuzz_deniesEveryCaller(uint64 parent, address replier, bytes memory data) public {
        assertFalse(new ClosedReplyGate().canReply(parent, replier, data));
    }
}
