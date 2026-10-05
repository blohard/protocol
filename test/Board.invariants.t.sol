// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {Board} from "../src/Board.sol";
import {AllowAllGate, DenyGate} from "./mocks/Gates.sol";

/// Drives the board with random posts, replies, gate swaps, tombstones, removals and deactivations,
/// keeping ghost state to check against.
contract Handler is Test {
    Board public board;
    address[] public actors;
    address public allow;
    address public deny;
    address internal immutable TOMBSTONE;
    address internal immutable REMOVED;

    uint64 public posted;
    /// Messages ended for good, by their author (tombstoned) or by their parent's author (removed).
    uint64[] public tombstoned;
    mapping(uint64 => bool) public isTombstoned;
    mapping(uint64 => bool) public isRemoved;

    constructor(Board board_, address allow_, address deny_) {
        board = board_;
        allow = allow_;
        deny = deny_;
        TOMBSTONE = board_.TOMBSTONE();
        REMOVED = board_.REMOVED();
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _gate(uint256 seed) internal view returns (address) {
        uint256 k = seed % 4;
        if (k == 0) return address(0);
        if (k == 1) return allow;
        if (k == 2) return deny;
        return TOMBSTONE;
    }

    function post(uint256 who, bytes32 hash, uint256 gateSeed) external {
        address actor = _actor(who);
        address gate = _gate(gateSeed);
        vm.prank(actor);
        uint64 id = board.post(hash, 0, gate, "");
        posted++;
        if (gate == TOMBSTONE) _markTombstoned(id);
    }

    function reply(uint256 who, uint256 parentSeed, bytes32 hash) external {
        if (posted == 0) return;
        uint64 parent = uint64(parentSeed % posted) + 1; // < posted, fits
        address actor = _actor(who);
        vm.prank(actor);
        try board.post(hash, parent, address(0), "") {
            posted++;
        } catch {}
    }

    function setReplyGate(uint256 idSeed, uint256 gateSeed) external {
        if (posted == 0) return;
        uint64 id = uint64(idSeed % posted) + 1; // < posted, fits
        (address author,,,) = board.getMessage(id);
        address gate = _gate(gateSeed);
        vm.prank(author);
        try board.setReplyGate(id, gate) {
            if (gate == TOMBSTONE) _markTombstoned(id);
        } catch {}
    }

    /// The parent's author removes a reply; on a top-level post, or a reply to their own post, this
    /// reverts.
    function remove(uint256 idSeed) external {
        if (posted == 0) return;
        uint64 id = uint64(idSeed % posted) + 1; // < posted, fits
        (, uint64 parent,,) = board.getMessage(id);
        address remover = parent == 0 ? _actor(idSeed) : board.authorOf(parent);
        vm.prank(remover);
        try board.setReplyGate(id, REMOVED) {
            isRemoved[id] = true;
            _markTombstoned(id);
        } catch {}
    }

    function setAuthorGate(uint256 who, uint256 gateSeed) external {
        address gate = _gate(gateSeed);
        address actor = _actor(who);
        vm.prank(actor);
        board.setAuthorGate(gate);
    }

    function _markTombstoned(uint64 id) internal {
        if (!isTombstoned[id]) {
            isTombstoned[id] = true;
            tombstoned.push(id);
        }
    }

    function tombstonedCount() external view returns (uint256) {
        return tombstoned.length;
    }
}

contract BoardInvariants is StdInvariant, Test {
    Board internal board;
    Handler internal handler;

    function setUp() public {
        board = new Board();
        handler = new Handler(board, address(new AllowAllGate()), address(new DenyGate()));
        targetContract(address(handler));
    }

    /// Ids are dense: every id below nextId exists, nothing at or above it does, and nextId moves
    /// exactly once per successful post.
    function invariant_idsAreDenseAndSequential() public view {
        uint64 next = board.nextId();
        assertEq(next, handler.posted() + 1);
        for (uint64 i = 1; i < next; i++) {
            assertTrue(board.exists(i));
            (address author,,,) = board.getMessage(i);
            assertTrue(author != address(0));
        }
        assertFalse(board.exists(next));
        assertFalse(board.exists(0));
    }

    /// A deleted or removed message stays that way. Its gate never changes again, so the value
    /// still says who acted, and every reply to it fails.
    function invariant_tombstonesArePermanent() public {
        uint256 n = handler.tombstonedCount();
        for (uint256 i = 0; i < n; i++) {
            uint64 id = handler.tombstoned(i);
            address sentinel = handler.isRemoved(id) ? address(2) : address(1);
            assertEq(board.replyGate(id), sentinel);
            assertEq(board.effectiveGate(id), sentinel);
            address outsider = makeAddr("outsider");
            vm.prank(outsider);
            vm.expectRevert();
            board.post(keccak256("x"), id, address(0), "");
        }
    }

    /// A parent link always points at an older, existing message.
    function invariant_parentsPrecedeChildren() public view {
        uint64 next = board.nextId();
        for (uint64 i = 1; i < next; i++) {
            (, uint64 parent,,) = board.getMessage(i);
            if (parent != 0) {
                assertLt(parent, i);
                assertTrue(board.exists(parent));
            }
        }
    }

    /// A reply by the author of its parent's parent can never be removed.
    function invariant_protectedResponsesAreNeverRemoved() public view {
        uint64 next = board.nextId();
        for (uint64 i = 1; i < next; i++) {
            if (board.replyGate(i) != address(2)) continue;
            (address author, uint64 parent,,) = board.getMessage(i);
            (, uint64 grandparent,,) = board.getMessage(parent);
            if (grandparent != 0) {
                assertTrue(board.authorOf(grandparent) != author, "protected response removed");
            }
        }
    }

    /// Deletion and removal win over the right of response too.
    function invariant_terminalTargetsRefuseTheEntitledResponder() public {
        uint256 n = handler.tombstonedCount();
        for (uint256 i = 0; i < n; i++) {
            uint64 id = handler.tombstoned(i);
            (, uint64 parent,,) = board.getMessage(id);
            if (parent == 0) continue;
            vm.prank(board.authorOf(parent));
            vm.expectRevert();
            board.post(keccak256("y"), id, address(0), "");
        }
    }

    /// The entitled responder of every live reply is admitted without a gate.
    function invariant_entitledResponderIsAdmittedWithoutAGate() public view {
        uint64 next = board.nextId();
        for (uint64 i = 1; i < next; i++) {
            address own = board.replyGate(i);
            if (own == address(1) || own == address(2)) continue;
            (, uint64 parent,,) = board.getMessage(i);
            if (parent == 0) continue;
            assertEq(board.checkReply(i, board.authorOf(parent), ""), address(0));
        }
    }
}
