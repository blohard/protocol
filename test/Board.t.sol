// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";

import {Board} from "../src/Board.sol";
import {IBoard} from "../src/IBoard.sol";
import {
    GreedyWallet,
    RejectingWallet,
    RevertingWallet,
    SessionAccount,
    SessionWallet,
    ShortReturnWallet
} from "./mocks/Wallets.sol";
import {
    AllowAllGate,
    DenyGate,
    MalformedBoolGate,
    RecordingGate,
    ReturnBombGate,
    RevertingGate,
    ShortReturnGate,
    StateWritingGate
} from "./mocks/Gates.sol";

contract BoardTest is Test {
    Board internal board;

    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    address internal relayer;

    AllowAllGate internal allow;
    DenyGate internal deny;

    // Cached so they are never read via an external call inside a pranked or expectEmit'd statement
    // (that call would consume the prank/expectation).
    address internal TOMBSTONE;
    address internal REMOVED;

    bytes32 internal constant HASH_A = keccak256("post a");
    bytes32 internal constant HASH_B = keccak256("post b");
    address internal constant NO_GATE = address(0);
    bytes internal constant NO_DATA = "";

    function setUp() public {
        board = new Board();
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        relayer = makeAddr("relayer");
        allow = new AllowAllGate();
        deny = new DenyGate();
        TOMBSTONE = board.TOMBSTONE();
        REMOVED = board.REMOVED();
        vm.warp(1_700_000_000);
    }

    // ---- helpers --------------------------------------------------------------

    /// A test vector for the quote commitment (SPEC.md §7): getMessage's immutable fields,
    /// ABI-encoded in order.
    function test_quoteCommitment_encodingVector() public pure {
        bytes32 pin = keccak256(
            abi.encode(
                address(0x1111111111111111111111111111111111111111),
                uint64(7),
                uint32(0xabcdef01),
                bytes32(0x2222222222222222222222222222222222222222222222222222222222222222)
            )
        );
        assertEq(pin, 0x4db098ca2d19724366861cb45ccdc8f5ba82751be711c2d37aaa8bcb6daf56c7);
    }

    function _post(address who, bytes32 hash, uint64 parent, address gate)
        internal
        returns (uint64)
    {
        vm.prank(who);
        return board.post(hash, parent, gate, NO_DATA);
    }

    function _reply(address who, uint64 parent) internal returns (uint64) {
        return _post(who, HASH_B, parent, NO_GATE);
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", board.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _postStruct(
        address author,
        bytes32 hash,
        uint64 parent,
        address gate,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(board.POST_TYPEHASH(), author, hash, parent, gate, nonce, deadline)
        );
    }

    function _postBySig(
        uint256 key,
        address author,
        bytes32 hash,
        uint64 parent,
        address gate,
        uint256 nonce,
        uint256 deadline,
        bytes memory gateData
    ) internal returns (uint64) {
        bytes memory sig = _sign(key, _postStruct(author, hash, parent, gate, nonce, deadline));
        vm.prank(relayer);
        return board.postBySig(author, hash, parent, gate, nonce, deadline, sig, gateData);
    }

    // ---- posting (§3, §4.1) ---------------------------------------------------

    function test_post_topLevel_storesEverything() public {
        vm.expectEmit(address(board));
        emit IBoard.Posted(alice, 0, address(0), 1, HASH_A, NO_GATE);
        uint64 id = _post(alice, HASH_A, 0, NO_GATE);

        assertEq(id, 1);
        assertEq(board.nextId(), 2);
        assertTrue(board.exists(1));
        (address author, uint64 parent, uint32 ts, bytes32 hash) = board.getMessage(1);
        assertEq(board.authorOf(1), author);
        assertEq(author, alice);
        assertEq(parent, 0);
        assertEq(ts, uint32(block.timestamp));
        assertEq(hash, HASH_A);
        assertEq(board.replyGate(1), NO_GATE);
        assertEq(board.effectiveGate(1), NO_GATE);
    }

    function test_post_idsAreSequentialAcrossAuthors() public {
        assertEq(_post(alice, HASH_A, 0, NO_GATE), 1);
        assertEq(_post(bob, HASH_A, 0, NO_GATE), 2); // identical content, distinct id
        assertEq(_post(alice, HASH_A, 0, NO_GATE), 3);
        (address a2,,,) = board.getMessage(2);
        assertEq(a2, bob);
    }

    /// The log's shape is what clients filter by (SPEC.md §3): author, parent and the parent's
    /// author in the topics, the id in the data.
    function test_post_eventTopicsAreAuthorParentAndParentAuthor() public {
        vm.recordLogs();
        uint64 top = _post(alice, HASH_A, 0, NO_GATE);
        uint64 reply = _reply(bob, top);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        bytes32 sig = keccak256("Posted(address,uint64,address,uint64,bytes32,address)");
        for (uint256 i = 0; i < 2; i++) {
            assertEq(logs[i].topics.length, 4, "three indexed fields");
            assertEq(logs[i].topics[0], sig);
        }
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].topics[2], bytes32(0), "a top-level post has parent zero");
        assertEq(logs[0].topics[3], bytes32(0), "and no parent author");
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(bob))));
        assertEq(logs[1].topics[2], bytes32(uint256(top)));
        assertEq(
            logs[1].topics[3], bytes32(uint256(uint160(alice))), "the parent's author is a topic"
        );
        (uint64 id, bytes32 hash, address gate) =
            abi.decode(logs[1].data, (uint64, bytes32, address));
        assertEq(id, reply, "the id rides in the data");
        assertEq(hash, HASH_B);
        assertEq(gate, NO_GATE);
    }

    function test_post_reply_linksToParent() public {
        uint64 parent = _post(alice, HASH_A, 0, NO_GATE);
        vm.expectEmit(address(board));
        emit IBoard.Posted(bob, parent, alice, 2, HASH_B, NO_GATE);
        uint64 id = _reply(bob, parent);
        (, uint64 p,,) = board.getMessage(id);
        assertEq(p, parent);
    }

    function test_post_replyToUnknownParent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentNotFound.selector, uint64(7)));
        _reply(bob, 7);
        // Including the id that will be assigned next: a reply cannot cite itself.
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentNotFound.selector, uint64(1)));
        _reply(bob, 1);
    }

    function test_post_storesReplyGateOnlyWhenSet() public {
        uint64 a = _post(alice, HASH_A, 0, NO_GATE);
        uint64 b = _post(alice, HASH_A, 0, address(deny));
        assertEq(board.replyGate(a), NO_GATE);
        assertEq(board.replyGate(b), address(deny));
        assertEq(board.effectiveGate(b), address(deny));
    }

    function test_post_bornRetracted() public {
        uint64 id = _post(alice, HASH_A, 0, TOMBSTONE);
        assertEq(board.effectiveGate(id), TOMBSTONE);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRetracted.selector, id));
        _reply(bob, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageTombstoned.selector, id));
        board.setReplyGate(id, NO_GATE);
    }

    function test_sentinels_areTheDesignedAddresses() public view {
        assertEq(TOMBSTONE, address(1));
        assertEq(REMOVED, address(2));
    }

    function test_views_unknownId() public {
        assertFalse(board.exists(1));
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageNotFound.selector, uint64(1)));
        board.getMessage(1);
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageNotFound.selector, uint64(1)));
        board.authorOf(1);
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageNotFound.selector, uint64(1)));
        board.effectiveGate(1);
        assertEq(board.replyGate(1), NO_GATE); // plain mapping read, no revert
    }

    // ---- gate resolution: message → author → open (§4.1, §5.7) ----------------

    function test_checkReply_resolvesGateWithoutPosting() public {
        uint64 open = _post(alice, HASH_A, 0, NO_GATE);
        uint64 ownGate = _post(alice, HASH_A, 0, address(allow));
        assertEq(board.checkReply(0, bob, NO_DATA), NO_GATE);
        assertEq(board.checkReply(open, bob, NO_DATA), NO_GATE);
        assertEq(board.checkReply(ownGate, bob, NO_DATA), address(allow));

        vm.prank(alice);
        board.setAuthorGate(address(allow));
        assertEq(board.checkReply(open, bob, NO_DATA), address(allow));
        vm.prank(alice);
        board.setAuthorGate(address(deny));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        board.checkReply(open, bob, NO_DATA);
        // A per-message gate still overrides the author's default.
        assertEq(board.checkReply(ownGate, bob, NO_DATA), address(allow));
        assertEq(board.nextId(), 3, "a preview creates no message");
        assertEq(board.nonceBitmap(bob, 0), 0, "a preview consumes no nonce");
    }

    function test_checkReply_parentErrorsMatchPosting() public {
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentNotFound.selector, uint64(1)));
        board.checkReply(1, bob, NO_DATA);

        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 removed = _reply(bob, root);
        vm.prank(alice);
        board.setReplyGate(removed, REMOVED);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRemoved.selector, removed));
        board.checkReply(removed, alice, NO_DATA);

        uint64 retracted = _post(alice, HASH_A, 0, TOMBSTONE);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRetracted.selector, retracted));
        board.checkReply(retracted, bob, NO_DATA);
        vm.prank(alice);
        board.setAuthorGate(TOMBSTONE);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRetracted.selector, root));
        board.checkReply(root, bob, NO_DATA);
        assertEq(board.checkReply(0, alice, NO_DATA), NO_GATE, "top-level posts stay ungated");
    }

    /// Every malformed or hostile answer a gate can give is a rejection, in the preview and at
    /// posting alike: no code at the address, a revert, a short return, a word other than `true`,
    /// and a return bomb whose first word is not `true`. A return bomb whose first word is `true`
    /// admits, and only 32 bytes of it were copied (§5.1, §8).
    function test_gate_badAnswersRejectInPreviewAndAtPosting() public {
        address[5] memory gates = [
            makeAddr("no gate code"),
            address(new RevertingGate()),
            address(new ShortReturnGate()),
            address(new MalformedBoolGate()),
            address(new ReturnBombGate(7, 64 * 1024))
        ];
        for (uint256 i = 0; i < gates.length; i++) {
            uint64 id = _post(alice, HASH_A, 0, gates[i]);
            vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, gates[i]));
            board.checkReply(id, bob, NO_DATA);
            vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, gates[i]));
            _reply(bob, id);
        }
        address yes = address(new ReturnBombGate(1, 64 * 1024));
        uint64 open = _post(alice, HASH_A, 0, yes);
        assertEq(board.checkReply(open, bob, NO_DATA), yes);
        _reply(bob, open);
    }

    function test_checkReply_staticCallEvenWhenPreviewIsAnOrdinaryCall() public {
        StateWritingGate g = new StateWritingGate();
        uint64 id = _post(alice, HASH_A, 0, address(g));
        // An RPC eth_call starts an ordinary call. The Board itself must set the static flag when
        // it calls the gate, not rely on its caller to.
        (bool ok, bytes memory result) =
            address(board).call{gas: 500_000}(abi.encodeCall(board.checkReply, (id, bob, NO_DATA)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(IBoard.GateRejected.selector, address(g)));
        assertEq(g.calls(), 0, "the gate's write must fail");
        assertEq(board.nextId(), 2);
    }

    function test_gate_perMessage_allowsAndDenies() public {
        uint64 open = _post(alice, HASH_A, 0, address(allow));
        uint64 closed = _post(alice, HASH_A, 0, address(deny));
        _reply(bob, open);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(bob, closed);
    }

    function test_gate_authorDefault_coversOldAndNewMessages() public {
        uint64 before = _post(alice, HASH_A, 0, NO_GATE);
        vm.prank(alice);
        vm.expectEmit(address(board));
        emit IBoard.AuthorGateChanged(alice, NO_GATE, address(deny));
        board.setAuthorGate(address(deny));
        uint64 after_ = _post(alice, HASH_A, 0, NO_GATE);

        assertEq(board.authorGate(alice), address(deny));
        assertEq(board.effectiveGate(before), address(deny));
        assertEq(board.effectiveGate(after_), address(deny));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(bob, before);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(bob, after_);
    }

    function test_gate_permissiveGate_optsOutOfAuthorDefault() public {
        // The per-message pointer beats the author's default, and there is no reserved "open"
        // value: a message that should stay open despite the author's default points at a gate that
        // admits everyone.
        vm.prank(alice);
        board.setAuthorGate(address(deny));
        uint64 gated = _post(alice, HASH_A, 0, NO_GATE);
        uint64 open = _post(alice, HASH_A, 0, address(allow));
        assertEq(board.replyGate(open), address(allow));
        assertEq(board.effectiveGate(open), address(allow));
        _reply(bob, open);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(bob, gated);
    }

    function test_gate_authorDefault_doesNotAffectOtherAuthors() public {
        vm.prank(alice);
        board.setAuthorGate(address(deny));
        uint64 bobs = _post(bob, HASH_A, 0, NO_GATE);
        _reply(alice, bobs);
    }

    // ---- right of response ---------------------------------------------------

    function test_response_bypassesOwnAndDefaultGates() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        address reverting = address(new RevertingGate());
        address[3] memory defaults = [NO_GATE, address(deny), TOMBSTONE];
        address[3] memory own = [NO_GATE, address(deny), reverting];
        for (uint256 i = 0; i < defaults.length; i++) {
            vm.prank(bob);
            board.setAuthorGate(defaults[i]);
            for (uint256 j = 0; j < own.length; j++) {
                uint64 target = _post(bob, HASH_B, root, own[j]);
                address effective = own[j] == NO_GATE ? defaults[i] : own[j];
                assertEq(board.effectiveGate(target), effective);
                assertEq(board.checkReply(target, alice, NO_DATA), NO_GATE);
                uint64 next = board.nextId();
                vm.expectEmit(address(board));
                emit IBoard.Posted(alice, target, bob, next, HASH_B, NO_GATE);
                _reply(alice, target);
                assertEq(board.effectiveGate(target), effective, "admission does not edit the rule");
            }
        }
    }

    function test_response_signedAuthorQualifiesNotRelayer() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 target = _post(bob, HASH_B, root, address(deny));
        uint256 deadline = block.timestamp + 1 hours;
        uint64 response =
            _postBySig(aliceKey, alice, HASH_B, target, address(deny), 7, deadline, NO_DATA);
        (address author, uint64 parent,,) = board.getMessage(response);
        assertEq(author, alice);
        assertEq(parent, target);
        assertEq(board.nonceBitmap(alice, 0), 1 << 7);
        // Bob may answer Alice's response even though that response also closes replies.
        assertEq(board.checkReply(response, bob, NO_DATA), NO_GATE);
        _reply(bob, response);

        bytes memory sig = _sign(bobKey, _postStruct(bob, HASH_B, target, NO_GATE, 8, deadline));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        board.postBySig(bob, HASH_B, target, NO_GATE, 8, deadline, sig, NO_DATA);
        assertEq(board.nonceBitmap(bob, 0), 0, "refusal rolls back nonce use");
    }

    function test_response_onlyImmediateParentAuthorQualifies() public {
        address carol = makeAddr("carol");
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 middle = _post(carol, HASH_B, root, NO_GATE);
        uint64 target = _post(bob, HASH_B, middle, address(deny));
        assertEq(board.checkReply(target, carol, NO_DATA), NO_GATE);
        _reply(carol, target);
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
            board.checkReply(target, who, NO_DATA);
            vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
            _reply(who, target);
        }
    }

    function test_response_selfReplyIsNotABlanketSelfExemption() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 target = _post(alice, HASH_B, root, address(deny));
        assertEq(board.checkReply(target, alice, NO_DATA), NO_GATE);
        _reply(alice, target);
        uint64 top = _post(alice, HASH_A, 0, address(deny));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(alice, top);
    }

    function test_response_survivesAncestorDeletionAndRuleChanges() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 target = _reply(bob, root);
        assertEq(board.checkReply(target, alice, NO_DATA), NO_GATE);
        vm.prank(alice);
        board.setReplyGate(root, TOMBSTONE);
        vm.prank(bob);
        board.setReplyGate(target, address(deny));
        _reply(alice, target);
        vm.prank(bob);
        board.setReplyGate(target, NO_GATE);
        vm.prank(bob);
        board.setAuthorGate(TOMBSTONE);
        _reply(alice, target);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRetracted.selector, target));
        _reply(relayer, target);
    }

    function test_response_survivesAncestorRemoval() public {
        address carol = makeAddr("carol");
        uint64 root = _post(carol, HASH_A, 0, NO_GATE);
        uint64 ancestor = _reply(alice, root);
        uint64 target = _post(bob, HASH_B, ancestor, address(deny));
        vm.prank(carol);
        board.setReplyGate(ancestor, REMOVED);
        assertEq(board.checkReply(target, alice, NO_DATA), NO_GATE);
        uint64 response = _reply(alice, target);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ProtectedResponse.selector, response));
        board.setReplyGate(response, REMOVED);
    }

    function test_response_targetDeletionAlwaysWinsIncludingAfterPreview() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        for (uint256 i = 0; i < 3; i++) {
            uint64 target = _post(bob, HASH_B, root, i == 2 ? TOMBSTONE : NO_GATE);
            bytes4 errorSelector =
                i == 1 ? IBoard.ParentRemoved.selector : IBoard.ParentRetracted.selector;
            if (i != 2) {
                assertEq(board.checkReply(target, alice, NO_DATA), NO_GATE);
                vm.prank(i == 1 ? alice : bob);
                board.setReplyGate(target, i == 1 ? REMOVED : TOMBSTONE);
            }
            vm.expectRevert(abi.encodeWithSelector(errorSelector, target));
            board.checkReply(target, alice, NO_DATA);
            vm.expectRevert(abi.encodeWithSelector(errorSelector, target));
            _reply(alice, target);
            uint256 deadline = block.timestamp + 1 hours;
            bytes memory sig =
                _sign(aliceKey, _postStruct(alice, HASH_B, target, NO_GATE, 7, deadline));
            vm.prank(relayer);
            vm.expectRevert(abi.encodeWithSelector(errorSelector, target));
            board.postBySig(alice, HASH_B, target, NO_GATE, 7, deadline, sig, NO_DATA);
            assertEq(board.nonceBitmap(alice, 0), 0);
        }
    }

    function test_response_cannotBeRemovedButItsAuthorCanDeleteIt() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 target = _reply(bob, root);
        uint64 response = _reply(alice, target);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            bobKey,
            keccak256(
                abi.encode(board.SET_REPLY_GATE_TYPEHASH(), bob, response, REMOVED, 3, deadline)
            )
        );
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ProtectedResponse.selector, response));
        board.setReplyGate(response, REMOVED);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ProtectedResponse.selector, response));
        board.setReplyGateBySig(bob, response, REMOVED, 3, deadline, sig);
        assertEq(board.nonceBitmap(bob, 0), 0);
        assertEq(board.replyGate(response), NO_GATE);
        vm.prank(alice);
        board.setReplyGate(response, TOMBSTONE);
        assertEq(board.replyGate(response), TOMBSTONE);
    }

    function test_response_protectionSurvivesPolicyChangesAndAncestorDeletion() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 target = _reply(bob, root);
        uint64 response = _reply(alice, target);
        vm.startPrank(bob);
        board.setReplyGate(target, address(deny));
        board.setAuthorGate(TOMBSTONE);
        board.setReplyGate(target, TOMBSTONE);
        vm.stopPrank();
        vm.prank(alice);
        board.setReplyGate(root, TOMBSTONE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ProtectedResponse.selector, response));
        board.setReplyGate(response, REMOVED);
        assertEq(board.replyGate(response), NO_GATE);
        // Deleting B did not delete C, and Bob may answer live C through the same rule.
        assertEq(board.checkReply(response, bob, NO_DATA), NO_GATE);
    }

    function test_response_unlimitedAndReciprocalProtection() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 target = _post(bob, HASH_B, root, address(deny));
        for (uint256 i = 0; i < 3; i++) {
            uint64 response = _post(alice, HASH_B, target, address(deny));
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(IBoard.ProtectedResponse.selector, response));
            board.setReplyGate(response, REMOVED);
            uint64 answer = _reply(bob, response);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IBoard.ProtectedResponse.selector, answer));
            board.setReplyGate(answer, REMOVED);
        }
    }

    function test_response_quotesGrantNeitherAdmissionNorRemovalProtection() public {
        uint64 quoted = _post(alice, HASH_A, 0, NO_GATE);
        // The Board sees only a content hash, irrespective of which posts its body quotes.
        bytes32 quoting = keccak256(abi.encode("quote", quoted));
        address carol = makeAddr("carol");
        uint64 carols = _post(carol, HASH_A, 0, NO_GATE);
        for (uint256 i = 0; i < 2; i++) {
            uint64 target = _post(bob, quoting, i == 0 ? 0 : carols, address(deny));
            vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
            _reply(alice, target);
            vm.prank(bob);
            board.setReplyGate(target, NO_GATE);
            uint64 response = _reply(alice, target);
            vm.prank(bob);
            board.setReplyGate(response, REMOVED);
            assertEq(board.replyGate(response), REMOVED);
        }
    }

    function test_response_entitlementBelongsToSmartAccountNotItsSigningKey() public {
        SessionWallet wallet = new SessionWallet(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint64 root =
            _postBySig(aliceKey, address(wallet), HASH_A, 0, NO_GATE, 1, deadline, NO_DATA);
        uint64 target = _post(bob, HASH_B, root, address(deny));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(alice, target);
        uint64 response =
            _postBySig(aliceKey, address(wallet), HASH_B, target, NO_GATE, 2, deadline, NO_DATA);
        (address author,,,) = board.getMessage(response);
        assertEq(author, address(wallet));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ProtectedResponse.selector, response));
        board.setReplyGate(response, REMOVED);
    }

    function testFuzz_response_relationshipAndFinality(address responder, bool deleted) public {
        vm.assume(responder != address(0));
        uint64 root = _post(responder, HASH_A, 0, NO_GATE);
        uint64 target = _post(bob, HASH_B, root, address(deny));
        if (deleted) {
            vm.prank(bob);
            board.setReplyGate(target, TOMBSTONE);
            vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRetracted.selector, target));
            _reply(responder, target);
        } else {
            assertEq(board.checkReply(target, responder, NO_DATA), NO_GATE);
            _reply(responder, target);
        }
    }

    // ---- deactivation and tombstones (§5.6, §5.7) ------------------------------

    function test_authorTombstone_deactivatesAndIsReversible() public {
        uint64 unpinned = _post(alice, HASH_A, 0, NO_GATE);
        uint64 pinned = _post(alice, HASH_A, 0, address(allow));

        vm.prank(alice);
        board.setAuthorGate(TOMBSTONE);
        assertEq(board.effectiveGate(unpinned), TOMBSTONE);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRetracted.selector, unpinned));
        _reply(bob, unpinned);
        // A per-message pointer always wins, even over deactivation.
        _reply(bob, pinned);
        // The deactivated author can still post and still moderate.
        _post(alice, HASH_A, 0, NO_GATE);

        vm.prank(alice);
        board.setAuthorGate(NO_GATE);
        assertEq(board.effectiveGate(unpinned), NO_GATE);
        _reply(bob, unpinned);
    }

    function test_tombstone_isPermanentAndKeepsTheRecord() public {
        uint64 id = _post(alice, HASH_A, 0, address(allow));
        uint64 earlier = _reply(bob, id);

        vm.prank(alice);
        vm.expectEmit(address(board));
        emit IBoard.ReplyGateChanged(id, address(allow), TOMBSTONE);
        board.setReplyGate(id, TOMBSTONE);

        // Replies stop; the message and its existing replies remain.
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRetracted.selector, id));
        _reply(bob, id);
        assertTrue(board.exists(id));
        (address author,,, bytes32 hash) = board.getMessage(id);
        assertEq(author, alice);
        assertEq(hash, HASH_A);
        assertTrue(board.exists(earlier));
        assertEq(board.replyGate(id), TOMBSTONE);

        // Nothing the author does can lift it.
        address[3] memory attempts = [NO_GATE, address(allow), address(deny)];
        for (uint256 i = 0; i < attempts.length; i++) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IBoard.MessageTombstoned.selector, id));
            board.setReplyGate(id, attempts[i]);
        }
    }

    function test_setReplyGate_authorOnly() public {
        uint64 id = _post(alice, HASH_A, 0, NO_GATE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NotAuthor.selector, id, bob));
        board.setReplyGate(id, address(deny));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageNotFound.selector, uint64(9)));
        board.setReplyGate(9, address(deny));
    }

    function test_setReplyGate_swapsAreForwardOnly() public {
        uint64 id = _post(alice, HASH_A, 0, address(allow));
        uint64 admitted = _reply(bob, id);
        vm.prank(alice);
        board.setReplyGate(id, address(deny));
        // The earlier reply stands; new ones bounce.
        assertTrue(board.exists(admitted));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(bob, id);
        // And the author can reopen.
        vm.prank(alice);
        board.setReplyGate(id, NO_GATE);
        _reply(bob, id);
    }

    function test_post_checksCurrentGateAfterPreview() public {
        uint64 id = _post(alice, HASH_A, 0, address(allow));
        assertEq(board.checkReply(id, bob, NO_DATA), address(allow));
        vm.prank(alice);
        board.setReplyGate(id, address(deny));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(deny)));
        _reply(bob, id);
        address replacement = address(new ReturnBombGate(1, 32));
        vm.prank(alice);
        board.setReplyGate(id, replacement);
        _reply(bob, id);
    }

    // ---- hostile and malformed gates (§5.1, §8) --------------------------------

    function test_gate_cannotWriteState() public {
        StateWritingGate g = new StateWritingGate();
        uint64 id = _post(alice, HASH_A, 0, address(g));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(g)));
        _reply(bob, id);
        assertEq(g.calls(), 0, "STATICCALL must prevent the write");
    }

    function testFuzz_gate_receivesAuthorNotRelayer(bytes memory proof) public {
        RecordingGate g = new RecordingGate();
        uint64 id = _post(alice, HASH_A, 0, address(g));
        g.expect(id, bob, proof);

        // Anyone can preview bob's admission; the query is not authentication.
        vm.prank(relayer);
        assertEq(board.checkReply(id, bob, proof), address(g));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(g)));
        board.checkReply(id, alice, proof);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(g)));
        board.checkReply(id, bob, bytes.concat(proof, hex"00"));

        // Direct: replier is msg.sender.
        vm.prank(bob);
        uint64 direct = board.post(HASH_B, id, NO_GATE, proof);
        (,,, bytes32 directHash) = board.getMessage(direct);
        assertEq(directHash, HASH_B);

        // By-sig: replier is the signer, not the relayer who pays. The same gate data works for
        // different content; the board still stores its hash.
        uint64 relayed = _postBySig(bobKey, bob, HASH_A, id, NO_GATE, 1, block.timestamp, proof);
        (,,, bytes32 relayedHash) = board.getMessage(relayed);
        assertEq(relayedHash, HASH_A);

        // Another author cannot borrow bob's admission by supplying the same data.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(g)));
        board.post(HASH_B, id, NO_GATE, proof);

        // Wrong data: rejected.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(g)));
        board.post(HASH_B, id, NO_GATE, bytes.concat(proof, hex"00"));
    }

    // ---- removal by the parent's author (§5.6) ---------------------------------

    function test_removal_byParentAuthorIsPermanentAndClosesReplies() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 reply = _post(bob, HASH_B, root, NO_GATE);
        vm.expectEmit(address(board));
        emit IBoard.ReplyGateChanged(reply, NO_GATE, REMOVED);
        vm.prank(alice);
        board.setReplyGate(reply, REMOVED);
        // The value records who acted; the message itself stays intact.
        assertEq(board.replyGate(reply), REMOVED);
        assertEq(board.effectiveGate(reply), REMOVED);
        assertTrue(board.exists(reply));
        (address author,,, bytes32 hash) = board.getMessage(reply);
        assertEq(author, bob);
        assertEq(hash, HASH_B);
        // Replies to it are closed, with a reason of their own.
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.ParentRemoved.selector, reply));
        board.post(HASH_A, reply, NO_GATE, NO_DATA);
        // Final: neither the author nor the remover can change it again.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageTombstoned.selector, reply));
        board.setReplyGate(reply, TOMBSTONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageTombstoned.selector, reply));
        board.setReplyGate(reply, REMOVED);
        // The parent is untouched, and bob may still reply to it.
        assertEq(board.replyGate(root), NO_GATE);
        _post(bob, HASH_A, root, NO_GATE);
    }

    function test_removal_onlyTheImmediateParentAuthorAndOnlyRemoved() public {
        address carol = makeAddr("carol");
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 reply = _post(bob, HASH_B, root, NO_GATE);
        uint64 nested = _post(carol, HASH_A, reply, NO_GATE);
        // The parent's author may set nothing but REMOVED on someone else's message.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NotAuthor.selector, reply, alice));
        board.setReplyGate(reply, address(deny));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NotAuthor.selector, reply, alice));
        board.setReplyGate(reply, TOMBSTONE);
        // A grandparent's author and a stranger cannot remove it (the reply's own author cannot
        // either: test_removed_isNeverSetByTheAuthor).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NotParentAuthor.selector, nested, alice));
        board.setReplyGate(nested, REMOVED);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NotParentAuthor.selector, reply, carol));
        board.setReplyGate(reply, REMOVED);
        // A top-level post has no parent whose author could remove it.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NotParentAuthor.selector, root, bob));
        board.setReplyGate(root, REMOVED);
        // Once the author retracted, there is nothing left to remove.
        vm.prank(bob);
        board.setReplyGate(reply, TOMBSTONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.MessageTombstoned.selector, reply));
        board.setReplyGate(reply, REMOVED);
    }

    function test_removal_bySigIsSignedByTheParentAuthor() public {
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 reply = _post(bob, HASH_B, root, NO_GATE);
        uint256 dl = block.timestamp + 1 hours;
        // alice, the parent's author, removes it through any relayer.
        bytes memory aliceSig = _sign(
            aliceKey,
            keccak256(abi.encode(board.SET_REPLY_GATE_TYPEHASH(), alice, reply, REMOVED, 1, dl))
        );
        vm.prank(relayer);
        board.setReplyGateBySig(alice, reply, REMOVED, 1, dl, aliceSig);
        assertEq(board.replyGate(reply), REMOVED);
    }

    function test_removed_isNeverSetByTheAuthor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidGate.selector, REMOVED));
        board.setAuthorGate(REMOVED);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidGate.selector, REMOVED));
        board.post(HASH_A, 0, REMOVED, NO_DATA);
        // A self-reply: alice is both the author and the parent's author, and may only delete it,
        // so REMOVED keeps meaning that someone else acted.
        uint64 root = _post(alice, HASH_A, 0, NO_GATE);
        uint64 self = _post(alice, HASH_B, root, NO_GATE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidGate.selector, REMOVED));
        board.setReplyGate(self, REMOVED);
        // Nor by signature through a relayer: the signer is the author.
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            aliceKey,
            keccak256(abi.encode(board.SET_REPLY_GATE_TYPEHASH(), alice, self, REMOVED, 1, dl))
        );
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidGate.selector, REMOVED));
        board.setReplyGateBySig(alice, self, REMOVED, 1, dl, sig);
        // A reply to one's own post is deleted like any message of one's own.
        vm.prank(alice);
        board.setReplyGate(self, TOMBSTONE);
        assertEq(board.replyGate(self), TOMBSTONE);
    }

    // ---- by-sig (§4.2, §8) ----------------------------------------------------

    function test_domainSeparator_matchesEip712() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Board"),
                keccak256("1"),
                block.chainid,
                address(board)
            )
        );
        assertEq(board.DOMAIN_SEPARATOR(), expected);
        assertEq(
            board.POST_TYPEHASH(),
            keccak256(
                "Post(address author,bytes32 contentHash,uint64 parentId,address replyGate,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(
            board.SET_REPLY_GATE_TYPEHASH(),
            keccak256(
                "SetReplyGate(address author,uint64 id,address gate,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(
            board.SET_AUTHOR_GATE_TYPEHASH(),
            keccak256("SetAuthorGate(address author,address gate,uint256 nonce,uint256 deadline)")
        );
    }

    function test_postBySig_attributesToSignerNotRelayer() public {
        vm.expectEmit(address(board));
        emit IBoard.Posted(alice, 0, address(0), 1, HASH_A, address(deny));
        uint64 id = _postBySig(
            aliceKey, alice, HASH_A, 0, address(deny), 42, block.timestamp + 1 hours, NO_DATA
        );
        (address author,,,) = board.getMessage(id);
        assertEq(author, alice);
        assertEq(board.replyGate(id), address(deny));
        assertEq(board.nonceBitmap(alice, 0), 1 << 42);
    }

    function test_postBySig_wrongSigner_reverts() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = _sign(bobKey, _postStruct(alice, HASH_A, 0, NO_GATE, 1, deadline));
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidSigner.selector, alice, bob));
        board.postBySig(alice, HASH_A, 0, NO_GATE, 1, deadline, sig, NO_DATA);
    }

    function test_postBySig_tamperedField_reverts() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, 1, deadline));
        vm.prank(relayer);
        // Relayer swaps in a gate the author never signed: recovers a stranger.
        vm.expectRevert(); // InvalidSigner with an unpredictable recovered address
        board.postBySig(alice, HASH_A, 0, address(deny), 1, deadline, sig, NO_DATA);
        assertEq(board.nextId(), 1);
    }

    function test_postBySig_replay_reverts() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, 5, deadline));
        vm.prank(relayer);
        board.postBySig(alice, HASH_A, 0, NO_GATE, 5, deadline, sig, NO_DATA);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NonceAlreadyUsed.selector, 5));
        board.postBySig(alice, HASH_A, 0, NO_GATE, 5, deadline, sig, NO_DATA);
        assertEq(board.nextId(), 2);
    }

    function test_postBySig_deadline() public {
        uint256 deadline = block.timestamp + 10;
        bytes memory sig = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, 1, deadline));
        vm.warp(deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.SignatureExpired.selector, deadline));
        board.postBySig(alice, HASH_A, 0, NO_GATE, 1, deadline, sig, NO_DATA);
        // Exactly at the deadline is still valid.
        vm.warp(deadline);
        vm.prank(relayer);
        board.postBySig(alice, HASH_A, 0, NO_GATE, 1, deadline, sig, NO_DATA);
    }

    function test_postBySig_noncesLandInAnyOrder() public {
        uint256 dl = block.timestamp + 1;
        _postBySig(aliceKey, alice, HASH_A, 0, NO_GATE, 300, dl, NO_DATA);
        _postBySig(aliceKey, alice, HASH_A, 0, NO_GATE, 0, dl, NO_DATA);
        _postBySig(aliceKey, alice, HASH_A, 0, NO_GATE, 5, dl, NO_DATA);
        assertEq(board.nextId(), 4);
        assertEq(board.nonceBitmap(alice, 0), (1 << 0) | (1 << 5));
        assertEq(board.nonceBitmap(alice, 1), 1 << (300 - 256));
    }

    function test_invalidateNonces_revokesOutstandingSignature() public {
        uint256 dl = block.timestamp + 1;
        bytes memory sig = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, 7, dl));
        vm.prank(alice);
        vm.expectEmit(address(board));
        emit IBoard.NoncesInvalidated(alice, 0, 1 << 7);
        board.invalidateNonces(0, 1 << 7);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NonceAlreadyUsed.selector, 7));
        board.postBySig(alice, HASH_A, 0, NO_GATE, 7, dl, sig, NO_DATA);
        // Other nonces are untouched.
        _postBySig(aliceKey, alice, HASH_A, 0, NO_GATE, 8, dl, NO_DATA);
    }

    function test_bySig_nonceSpaceIsSharedAcrossOperations() public {
        uint256 dl = block.timestamp + 1;
        _postBySig(aliceKey, alice, HASH_A, 0, NO_GATE, 1, dl, NO_DATA);
        bytes32 structHash =
            keccak256(abi.encode(board.SET_AUTHOR_GATE_TYPEHASH(), alice, address(deny), 1, dl));
        bytes memory sig = _sign(aliceKey, structHash);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NonceAlreadyUsed.selector, 1));
        board.setAuthorGateBySig(alice, address(deny), 1, dl, sig);
    }

    function test_postBySig_otherChain_reverts() public {
        uint256 dl = block.timestamp + 1;
        bytes memory sig = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, 1, dl));
        vm.chainId(block.chainid + 1); // the domain separator now differs
        vm.prank(relayer);
        vm.expectRevert(); // InvalidSigner with an unpredictable recovered address
        board.postBySig(alice, HASH_A, 0, NO_GATE, 1, dl, sig, NO_DATA);
    }

    function test_postBySig_wrongLengthSignature_reverts() public {
        uint256 dl = block.timestamp + 1;
        bytes memory short = new bytes(64);
        vm.prank(relayer);
        vm.expectRevert();
        board.postBySig(alice, HASH_A, 0, NO_GATE, 1, dl, short, NO_DATA);
        assertEq(board.nextId(), 1);
    }

    function test_postBySig_malleableTwin_reverts() public {
        // The twin (s' = n - s, v flipped) is a second valid ECDSA signature for the same message.
        // OpenZeppelin rejects its high-s form; the nonce bitmap prevents replay independently of
        // this canonicality check.
        uint256 dl = block.timestamp + 1;
        bytes memory good = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, 1, dl));
        bytes memory twin = _malleableTwin(good);
        vm.prank(relayer);
        vm.expectRevert();
        board.postBySig(alice, HASH_A, 0, NO_GATE, 1, dl, twin, NO_DATA);
        // The original still works: only the twin is rejected.
        vm.prank(relayer);
        board.postBySig(alice, HASH_A, 0, NO_GATE, 1, dl, good, NO_DATA);
    }

    function test_postBySig_zeroSignature_reverts() public {
        // A garbage signature makes ecrecover yield address(0); this must revert rather than
        // attribute a post to the zero address.
        uint256 dl = block.timestamp + 1;
        bytes memory zero = new bytes(65);
        vm.prank(relayer);
        vm.expectRevert();
        board.postBySig(address(0), HASH_A, 0, NO_GATE, 1, dl, zero, NO_DATA);
        assertEq(board.nextId(), 1);
    }

    function test_setReplyGateBySig_and_setAuthorGateBySig() public {
        uint64 id = _post(alice, HASH_A, 0, NO_GATE);
        uint256 dl = block.timestamp + 1;

        bytes memory sig1 = _sign(
            aliceKey,
            keccak256(abi.encode(board.SET_REPLY_GATE_TYPEHASH(), alice, id, address(deny), 1, dl))
        );
        vm.prank(relayer);
        vm.expectEmit(address(board));
        emit IBoard.ReplyGateChanged(id, NO_GATE, address(deny));
        board.setReplyGateBySig(alice, id, address(deny), 1, dl, sig1);

        bytes memory sig2 = _sign(
            aliceKey,
            keccak256(abi.encode(board.SET_AUTHOR_GATE_TYPEHASH(), alice, address(allow), 2, dl))
        );
        vm.prank(relayer);
        board.setAuthorGateBySig(alice, address(allow), 2, dl, sig2);
        assertEq(board.authorGate(alice), address(allow));

        // Bob cannot sign changes to Alice's message.
        bytes memory sig3 = _sign(
            bobKey, keccak256(abi.encode(board.SET_REPLY_GATE_TYPEHASH(), bob, id, NO_GATE, 1, dl))
        );
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NotAuthor.selector, id, bob));
        board.setReplyGateBySig(bob, id, NO_GATE, 1, dl, sig3);
    }

    function _malleableTwin(bytes memory sig) internal pure returns (bytes memory) {
        bytes32 r;
        bytes32 s_;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s_ := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        return abi.encodePacked(r, bytes32(n - uint256(s_)), v == 27 ? uint8(28) : uint8(27));
    }

    // ---- fuzz -----------------------------------------------------------------

    function testFuzz_post_roundTrip(bytes32 hash, address gate, uint32 when) public {
        vm.assume(gate != REMOVED); // set only by a removal, never at posting
        vm.warp(when);
        uint64 id = _post(alice, hash, 0, gate);
        (address author, uint64 parent, uint32 ts, bytes32 h) = board.getMessage(id);
        assertEq(author, alice);
        assertEq(parent, 0);
        assertEq(ts, when);
        assertEq(h, hash);
        assertEq(board.replyGate(id), gate);
    }

    function testFuzz_nonce_singleUse(uint256 nonce) public {
        uint256 dl = block.timestamp + 1;
        _postBySig(aliceKey, alice, HASH_A, 0, NO_GATE, nonce, dl, NO_DATA);
        assertEq(board.nonceBitmap(alice, nonce >> 8) & (1 << (nonce & 0xff)), 1 << (nonce & 0xff));
        bytes memory sig = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, nonce, dl));
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IBoard.NonceAlreadyUsed.selector, nonce));
        board.postBySig(alice, HASH_A, 0, NO_GATE, nonce, dl, sig, NO_DATA);
    }

    function testFuzz_invalidateNonces_coversExactlyTheMask(
        uint256 wordPos,
        uint256 mask,
        uint8 bit
    ) public {
        vm.prank(alice);
        board.invalidateNonces(wordPos, mask);
        assertEq(board.nonceBitmap(alice, wordPos), mask);
        uint256 nonce;
        unchecked {
            nonce = wordPos * 256 + bit;
        }
        vm.assume(nonce >> 8 == wordPos); // skip the overflow corner
        uint256 dl = block.timestamp + 1;
        bytes memory sig = _sign(aliceKey, _postStruct(alice, HASH_A, 0, NO_GATE, nonce, dl));
        vm.prank(relayer);
        if (mask & (1 << bit) != 0) {
            vm.expectRevert(abi.encodeWithSelector(IBoard.NonceAlreadyUsed.selector, nonce));
        }
        board.postBySig(alice, HASH_A, 0, NO_GATE, nonce, dl, sig, NO_DATA);
    }

    // ---- contract authors (§4.2: ERC-1271, EIP-7702) ---------------------------

    function _sigFor(address author, uint256 key) internal view returns (bytes memory) {
        return _sign(key, _postStruct(author, HASH_A, 0, NO_GATE, 1, block.timestamp));
    }

    function _postAs(address author, bytes memory sig) internal returns (uint64) {
        vm.prank(relayer);
        return board.postBySig(author, HASH_A, 0, NO_GATE, 1, block.timestamp, sig, NO_DATA);
    }

    function test_postBySig_contractAuthor_ownerKey() public {
        SessionWallet wallet = new SessionWallet(alice);
        uint64 id = _postAs(address(wallet), _sigFor(address(wallet), aliceKey));
        (address author,,,) = board.getMessage(id);
        assertEq(author, address(wallet), "the account is the author, not the key");
        assertEq(board.nonceBitmap(address(wallet), 0), 2, "the account's nonce was used");
    }

    function test_postBySig_contractAuthor_sessionKey() public {
        SessionWallet wallet = new SessionWallet(alice);
        vm.prank(alice);
        wallet.setSession(bob, true);
        uint64 id = _postAs(address(wallet), _sigFor(address(wallet), bobKey));
        (address author,,,) = board.getMessage(id);
        assertEq(author, address(wallet));
    }

    function test_postBySig_contractAuthor_unknownKeyRejected() public {
        SessionWallet wallet = new SessionWallet(alice);
        bytes memory sig = _sigFor(address(wallet), bobKey);
        vm.expectRevert(
            abi.encodeWithSelector(IBoard.InvalidSigner.selector, address(wallet), address(0))
        );
        _postAs(address(wallet), sig);
    }

    function test_postBySig_contractAuthor_rejectingRevertingShortAllRefused() public {
        address[3] memory wallets = [
            address(new RejectingWallet()),
            address(new RevertingWallet()),
            address(new ShortReturnWallet())
        ];
        for (uint256 i = 0; i < wallets.length; i++) {
            bytes memory sig = _sigFor(wallets[i], aliceKey);
            vm.expectRevert(
                abi.encodeWithSelector(IBoard.InvalidSigner.selector, wallets[i], address(0))
            );
            _postAs(wallets[i], sig);
        }
    }

    function test_postBySig_contractAuthor_greedyReturnIsBounded() public {
        // The magic value followed by 64 KiB more: only the first word is read, so the post is
        // accepted and the Board's side stays cheap. (The account pays for its own memory; that gas
        // is the payer's to bound, as with gates, §8.)
        address greedy = address(new GreedyWallet());
        uint256 before = gasleft();
        uint64 id = _postAs(greedy, _sigFor(greedy, aliceKey));
        assertLt(before - gasleft(), 200_000, "the Board must not copy the payload");
        (address author,,,) = board.getMessage(id);
        assertEq(author, greedy);
    }

    function test_postBySig_eoaAuthorGetsNoContractCall() public {
        // A plain key with someone else's signature: refused without ever calling the (code-less)
        // author.
        bytes memory sig = _sigFor(alice, bobKey);
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidSigner.selector, alice, bob));
        _postAs(alice, sig);
    }

    function test_postBySig_eoaMalformedSignatureRecoversToZero() public {
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidSigner.selector, alice, address(0)));
        _postAs(alice, hex"deadbeef");
    }

    function test_postBySig_delegatedKey_ownKeyAndSessionKey() public {
        // EIP-7702: alice's address takes on SessionAccount's code and stores bob as a session key.
        // Her own key still works (tried first); bob's is accepted by the account (ERC-1271).
        SessionAccount impl = new SessionAccount();
        vm.signAndAttachDelegation(address(impl), aliceKey);
        assertGt(alice.code.length, 0, "delegation designator in place");
        vm.prank(alice);
        SessionAccount(alice).setSession(bob, true);

        uint64 first = _postAs(alice, _sigFor(alice, aliceKey));
        (address author,,,) = board.getMessage(first);
        assertEq(author, alice);

        bytes memory bobSig =
            _sign(bobKey, _postStruct(alice, HASH_B, 0, NO_GATE, 2, block.timestamp));
        vm.prank(relayer);
        uint64 second =
            board.postBySig(alice, HASH_B, 0, NO_GATE, 2, block.timestamp, bobSig, NO_DATA);
        (author,,,) = board.getMessage(second);
        assertEq(author, alice, "the session key posts as alice");

        // A stranger's key is still refused.
        (, uint256 carolKey) = makeAddrAndKey("carol");
        bytes memory carolSig =
            _sign(carolKey, _postStruct(alice, HASH_B, 0, NO_GATE, 3, block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IBoard.InvalidSigner.selector, alice, address(0)));
        vm.prank(relayer);
        board.postBySig(alice, HASH_B, 0, NO_GATE, 3, block.timestamp, carolSig, NO_DATA);
    }

    /// One key behind several identities (its own address, and smart accounts that accept its
    /// signatures) yields one action per signature: the author is inside the signed struct, so the
    /// same bytes submitted under another author hash to a different digest and fail verification.
    function test_bySig_signatureBindsOneIdentity() public {
        SessionWallet a = new SessionWallet(alice);
        SessionWallet b = new SessionWallet(alice);
        uint256 dl = block.timestamp + 1;
        bytes memory sig = _sign(aliceKey, _postStruct(address(a), HASH_A, 0, NO_GATE, 7, dl));
        vm.prank(relayer);
        uint64 id = board.postBySig(address(a), HASH_A, 0, NO_GATE, 7, dl, sig, NO_DATA);
        (address author,,,) = board.getMessage(id);
        assertEq(author, address(a));

        // The sibling account: its digest differs, so the wallet refuses.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IBoard.InvalidSigner.selector, address(b), address(0))
        );
        board.postBySig(address(b), HASH_A, 0, NO_GATE, 7, dl, sig, NO_DATA);
        // The key's own address: the signature recovers to a stranger.
        vm.prank(relayer);
        vm.expectRevert();
        board.postBySig(alice, HASH_A, 0, NO_GATE, 7, dl, sig, NO_DATA);
        assertEq(board.nextId(), id + 1, "one post from one signature");

        // Deactivation binds one account the same way. (The tombstone is read first: expectRevert
        // arms against the very next call, arguments included.)
        address tomb = board.TOMBSTONE();
        bytes memory deact = _sign(
            aliceKey,
            keccak256(abi.encode(board.SET_AUTHOR_GATE_TYPEHASH(), address(a), tomb, 8, dl))
        );
        vm.prank(relayer);
        board.setAuthorGateBySig(address(a), tomb, 8, dl, deact);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IBoard.InvalidSigner.selector, address(b), address(0))
        );
        board.setAuthorGateBySig(address(b), tomb, 8, dl, deact);
        assertEq(board.authorGate(address(a)), tomb);
        assertEq(board.authorGate(address(b)), NO_GATE);
    }
}
