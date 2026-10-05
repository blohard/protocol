// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IBoard} from "./IBoard.sol";
import {IReplyGate} from "./IReplyGate.sol";

/// @title Board
/// @notice The protocol's core contract: immutable, ownerless and deliberately small (SPEC.md §4).
///         No admin, no upgrade path, no fees. The EIP-712 signing domain is ("Board", "1").
/// @dev Security posture, in brief:
///      - The only external calls this contract ever makes are STATICCALLs: to a reply gate
///        (§5.1), and, for a signed action whose author is a contract account, to that account's
///        own signature check (§4.2). So foreign code can never change state inside a Board
///        transaction. Return data is copied with a fixed 32-byte bound both times, so a hostile
///        callee cannot inflate the caller's memory costs.
///      - Posting checks precede message writes and id assignment. Signed actions consume their
///        nonce first. Any later revert rolls it back.
///      - Signatures use OpenZeppelin's EIP-712 domain, single-use unordered nonces, and a deadline
///        (§4.2, §8), and every signed struct names the author, so one signature acts for exactly
///        one identity even when a key controls several. The author's own key is tried first
///        (ECDSA). An author with code may instead accept the signature itself (ERC-1271), which is
///        what lets smart accounts and keys that delegated their code (EIP-7702) use every
///        by-signature path.
///      - Reserved gate addresses are compared, never called.
contract Board is IBoard, EIP712 {
    // ---- reserved gate values (§4) -----------------------------------------

    /// @notice On a message, the author deleted it, permanently (§5.6). As an author's default
    ///         gate, the author deactivated their account until they set another default (§5.7).
    address public constant TOMBSTONE = address(1);

    /// @notice On a message, the author of its parent removed it, permanently (§5.6). It is never
    ///         valid as an author's default gate.
    address public constant REMOVED = address(2);

    // ---- EIP-712 type hashes (§4.2) ----------------------------------------

    bytes32 public constant POST_TYPEHASH = keccak256(
        "Post(address author,bytes32 contentHash,uint64 parentId,address replyGate,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_REPLY_GATE_TYPEHASH = keccak256(
        "SetReplyGate(address author,uint64 id,address gate,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_AUTHOR_GATE_TYPEHASH =
        keccak256("SetAuthorGate(address author,address gate,uint256 nonce,uint256 deadline)");

    // ---- storage (§3) --------------------------------------------------------

    /// @dev Exactly two slots: `contentHash`, then author (20) + parentId (8) + timestamp (4)
    ///      packed into one word. `author == 0` means "no message".
    struct Message {
        bytes32 contentHash;
        address author;
        uint64 parentId;
        uint32 timestamp;
    }

    uint64 private _nextId = 1;
    mapping(uint64 id => Message) private _messages;
    /// @dev Kept out of `Message` so a message without its own gate costs no third slot.
    mapping(uint64 id => address gate) private _replyGates;
    /// @dev One slot per author who sets a default (§5.7).
    mapping(address author => address gate) private _authorGates;
    /// @dev Unordered nonces as in Uniswap's Permit2: each nonce is one bit, 256 to a word (§4.2).
    mapping(address author => mapping(uint256 wordPos => uint256 bits)) private _nonceBitmaps;

    constructor() EIP712("Board", "1") {}

    // ---- writes -------------------------------------------------------------

    /// @inheritdoc IBoard
    function post(bytes32 contentHash, uint64 parentId, address replyGate_, bytes calldata gateData)
        external
        returns (uint64 id)
    {
        return _post(msg.sender, contentHash, parentId, replyGate_, gateData);
    }

    /// @inheritdoc IBoard
    function postBySig(
        address author,
        bytes32 contentHash,
        uint64 parentId,
        address replyGate_,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig,
        bytes calldata gateData
    ) external returns (uint64 id) {
        bytes32 structHash = keccak256(
            abi.encode(POST_TYPEHASH, author, contentHash, parentId, replyGate_, nonce, deadline)
        );
        _verify(author, structHash, nonce, deadline, sig);
        return _post(author, contentHash, parentId, replyGate_, gateData);
    }

    /// @inheritdoc IBoard
    function setReplyGate(uint64 id, address gate) external {
        _setReplyGate(msg.sender, id, gate);
    }

    /// @inheritdoc IBoard
    function setReplyGateBySig(
        address author,
        uint64 id,
        address gate,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external {
        bytes32 structHash = keccak256(
            abi.encode(SET_REPLY_GATE_TYPEHASH, author, id, gate, nonce, deadline)
        );
        _verify(author, structHash, nonce, deadline, sig);
        _setReplyGate(author, id, gate);
    }

    /// @inheritdoc IBoard
    function setAuthorGate(address gate) external {
        _setAuthorGate(msg.sender, gate);
    }

    /// @inheritdoc IBoard
    function setAuthorGateBySig(
        address author,
        address gate,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external {
        bytes32 structHash = keccak256(
            abi.encode(SET_AUTHOR_GATE_TYPEHASH, author, gate, nonce, deadline)
        );
        _verify(author, structHash, nonce, deadline, sig);
        _setAuthorGate(author, gate);
    }

    /// @inheritdoc IBoard
    function invalidateNonces(uint256 wordPos, uint256 mask) external {
        _nonceBitmaps[msg.sender][wordPos] |= mask;
        emit NoncesInvalidated(msg.sender, wordPos, mask);
    }

    // ---- views --------------------------------------------------------------

    /// @inheritdoc IBoard
    function getMessage(uint64 id)
        external
        view
        returns (address author, uint64 parentId, uint32 timestamp, bytes32 contentHash)
    {
        Message storage m = _messages[id];
        if (m.author == address(0)) revert MessageNotFound(id);
        return (m.author, m.parentId, m.timestamp, m.contentHash);
    }

    /// @inheritdoc IBoard
    function authorOf(uint64 id) external view returns (address author) {
        author = _messages[id].author;
        if (author == address(0)) revert MessageNotFound(id);
    }

    /// @inheritdoc IBoard
    function exists(uint64 id) external view returns (bool) {
        return _messages[id].author != address(0);
    }

    /// @inheritdoc IBoard
    function replyGate(uint64 id) external view returns (address) {
        return _replyGates[id];
    }

    /// @inheritdoc IBoard
    function authorGate(address author) external view returns (address) {
        return _authorGates[author];
    }

    /// @inheritdoc IBoard
    function effectiveGate(uint64 id) external view returns (address) {
        address author = _messages[id].author;
        if (author == address(0)) revert MessageNotFound(id);
        return _effectiveGate(id, author);
    }

    /// @inheritdoc IBoard
    function checkReply(uint64 parentId, address replier, bytes calldata gateData)
        external
        view
        returns (address gate)
    {
        (gate,) = _checkReply(parentId, replier, gateData);
    }

    /// @inheritdoc IBoard
    function nextId() external view returns (uint64) {
        return _nextId;
    }

    /// @inheritdoc IBoard
    function nonceBitmap(address author, uint256 wordPos) external view returns (uint256) {
        return _nonceBitmaps[author][wordPos];
    }

    /// @inheritdoc IBoard
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---- internals ----------------------------------------------------------

    /// @dev The posting rules of §4.1, checked before assigning an id or writing the message. A
    ///      by-sig caller has already consumed its nonce.
    function _post(
        address author,
        bytes32 contentHash,
        uint64 parentId,
        address replyGate_,
        bytes calldata gateData
    ) internal returns (uint64 id) {
        if (replyGate_ == REMOVED) revert InvalidGate(replyGate_);
        (, address parentAuthor) = _checkReply(parentId, author, gateData);

        id = _nextId++;
        _messages[id] = Message({
            contentHash: contentHash,
            author: author,
            parentId: parentId,
            // uint32 is good until 2106 (§3); the cast is intentional.
            // forge-lint: disable-next-line(unsafe-typecast)
            timestamp: uint32(block.timestamp)
        });
        if (replyGate_ != address(0)) _replyGates[id] = replyGate_;

        // The gate may re-enter read-only code, but cannot write or emit events under STATICCALL
        // (see the reentrancy-events exclusion in foundry.toml).
        emit Posted(author, parentId, parentAuthor, id, contentHash, replyGate_);
    }

    /// @dev Decide whether `replier` may reply to `parentId`, in this order: a deleted or removed
    ///      parent refuses everyone, a protected response (§5.4) is always allowed, and otherwise
    ///      the parent's own gate, or failing that its author's default, decides. Returns the
    ///      parent's author for the `Posted` event even when no gate was called.
    function _checkReply(uint64 parentId, address replier, bytes calldata gateData)
        internal
        view
        returns (address gate, address parentAuthor)
    {
        if (parentId == 0) return (address(0), address(0));
        Message storage parent = _messages[parentId];
        parentAuthor = parent.author;
        if (parentAuthor == address(0)) revert ParentNotFound(parentId);
        gate = _replyGates[parentId];
        if (gate == TOMBSTONE) revert ParentRetracted(parentId);
        if (gate == REMOVED) revert ParentRemoved(parentId);
        if (_respondsTo(parent, replier)) return (address(0), parentAuthor);
        if (gate == address(0)) gate = _authorGates[parentAuthor];
        if (gate == TOMBSTONE) revert ParentRetracted(parentId);
        if (gate != address(0)) _checkGate(gate, parentId, replier, gateData);
    }

    /// @dev Whether `author` wrote the message that `target` replies to, which gives them the right
    ///      of response to `target` (§5.4). Deleting that message doesn't change who wrote it.
    function _respondsTo(Message storage target, address author) internal view returns (bool) {
        return target.parentId != 0 && _messages[target.parentId].author == author;
    }

    /// @dev The message's own gate if it has one, otherwise its author's default, or 0 (§4.1).
    ///      `TOMBSTONE` and `REMOVED` come back as they are, so the caller can refuse without
    ///      calling anything.
    function _effectiveGate(uint64 id, address author) internal view returns (address) {
        address gate = _replyGates[id];
        if (gate != address(0)) return gate;
        return _authorGates[author];
    }

    /// @dev Call the gate with STATICCALL and admit the reply only if it answers exactly `true`.
    ///      The call forwards all remaining gas (§8 rejects fixed stipends) but copies back at
    ///      most 32 bytes, so a gate can't make the replier pay for a huge answer. A revert, an
    ///      answer shorter than 32 bytes, or any word other than `true` fails with `GateRejected`.
    function _checkGate(address gate, uint64 parentId, address replier, bytes calldata gateData)
        internal
        view
    {
        (bool ok, bytes32 word) =
            _staticWord(gate, abi.encodeCall(IReplyGate.canReply, (parentId, replier, gateData)));
        if (!ok || word != bytes32(uint256(1))) revert GateRejected(gate);
    }

    function _setReplyGate(address caller, uint64 id, address gate) internal {
        Message storage m = _messages[id];
        address author = m.author;
        if (author == address(0)) revert MessageNotFound(id);
        if (gate == REMOVED) {
            // Removal (§5.6): the one change someone other than the author may make, and the only
            // change the parent's author may make. An author never marks their own message removed,
            // a self-reply included, so the value always means someone else acted.
            if (author == caller) revert InvalidGate(gate);
            if (m.parentId == 0 || _messages[m.parentId].author != caller) {
                revert NotParentAuthor(id, caller);
            }
        } else if (author != caller) {
            revert NotAuthor(id, caller);
        }
        address old = _replyGates[id];
        if (old == TOMBSTONE || old == REMOVED) revert MessageTombstoned(id);
        if (gate == REMOVED && _respondsTo(_messages[m.parentId], author)) {
            revert ProtectedResponse(id);
        }
        _replyGates[id] = gate;
        emit ReplyGateChanged(id, old, gate);
    }

    function _setAuthorGate(address author, address gate) internal {
        if (gate == REMOVED) revert InvalidGate(gate);
        address old = _authorGates[author];
        _authorGates[author] = gate;
        emit AuthorGateChanged(author, old, gate);
    }

    /// @dev Shared by every by-sig entry point. It checks the deadline, then the signature, and
    ///      then uses up the nonce, which is its only write. The signature is accepted when it
    ///      recovers to the author's own key. Failing that, an author that has code is asked to
    ///      validate it (ERC-1271), so a smart account's session key, or a key that delegated its
    ///      code (EIP-7702), works too. An author without code gets no such call, and
    ///      `InvalidSigner` carries the address the signature recovered to, or zero when it was not
    ///      a well-formed signature.
    function _verify(
        address author,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) internal {
        // A validator can nudge block.timestamp by seconds, which is harmless for a signature
        // deadline (the same pattern as Permit2).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        bytes32 digest = _hashTypedDataV4(structHash);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, sig);
        if (err != ECDSA.RecoverError.NoError || recovered != author) {
            if (author.code.length == 0) revert InvalidSigner(author, recovered);
            _checkContractSignature(author, digest, sig);
        }
        _useNonce(author, nonce);
    }

    /// @dev Ask a contract author whether it stands behind `sig` for `digest` (ERC-1271), with the
    ///      same care as `_checkGate`: a STATICCALL that forwards all gas and copies back at most
    ///      32 bytes. Only the exact magic value is accepted. A revert, a short answer or any other
    ///      data is refused. The account decides what a valid signature is, and the Board only
    ///      insists that it be the account named as author.
    function _checkContractSignature(address author, bytes32 digest, bytes calldata sig)
        internal
        view
    {
        (bool ok, bytes32 word) =
            _staticWord(author, abi.encodeCall(IERC1271.isValidSignature, (digest, sig)));
        if (!ok || word != bytes32(IERC1271.isValidSignature.selector)) {
            revert InvalidSigner(author, address(0));
        }
    }

    /// @dev Forward all gas in a STATICCALL and copy only the first return word. A failed call or
    ///      short return sets `ok` to false; trailing bytes are ignored.
    function _staticWord(address target, bytes memory callData)
        internal
        view
        returns (bool ok, bytes32 word)
    {
        assembly ("memory-safe") {
            // Output lands in the 32-byte scratch space at 0x00.
            ok := staticcall(gas(), target, add(callData, 0x20), mload(callData), 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            word := mload(0x00)
        }
    }

    /// @dev Flip one bit; revert if it was already set (used or invalidated).
    function _useNonce(address author, uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint256 bit = 1 << (nonce & 0xff);
        uint256 word = _nonceBitmaps[author][wordPos];
        if (word & bit != 0) revert NonceAlreadyUsed(nonce);
        _nonceBitmaps[author][wordPos] = word | bit;
    }
}
