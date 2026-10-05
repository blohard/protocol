// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IBoard
/// @notice The core of a minimal on-chain messaging protocol (SPEC.md §4).
/// @dev Every message is two storage slots: its content hash, and its author, parent link and
///      timestamp packed together. Reply control is delegated to pluggable read-only gate
///      contracts. Two gate addresses are reserved and never called: `TOMBSTONE` (address(1)) and
///      `REMOVED` (address(2)).
interface IBoard {
    // ---- events -------------------------------------------------------------

    /// @notice A message was stored. Indexed fields support author, parent and parent-author
    ///         queries. The reference host reads each event once and answers these queries from its
    ///         own indexes. The id is in the data; contracts can read it through `getMessage`, and
    ///         a transaction's event is available from its receipt.
    /// @param parentAuthor the author of the message replied to; `address(0)` for a top-level post.
    /// @param replyGate    the message's own gate, set when it was posted. `address(0)` means its
    ///                     author's default gate applies (§5.7).
    event Posted(
        address indexed author,
        uint64 indexed parentId,
        address indexed parentAuthor,
        uint64 id,
        bytes32 contentHash,
        address replyGate
    );

    /// @notice A message's own gate changed (§5.2, §5.6).
    event ReplyGateChanged(uint64 indexed id, address oldGate, address newGate);

    /// @notice An author's default gate changed (§5.7).
    event AuthorGateChanged(address indexed author, address oldGate, address newGate);

    /// @notice An author revoked outstanding signatures by marking nonces used.
    event NoncesInvalidated(address indexed author, uint256 wordPos, uint256 mask);

    // ---- errors -------------------------------------------------------------

    /// @notice `parentId` does not reference an existing message.
    error ParentNotFound(uint64 parentId);
    /// @notice The parent was deleted, or its author's account is deactivated (§5.6, §5.7).
    error ParentRetracted(uint64 parentId);
    /// @notice The parent was removed by the author of its own parent (§5.6).
    error ParentRemoved(uint64 parentId);
    /// @notice The parent's gate rejected the reply: returned false, reverted, or returned
    ///         malformed data.
    error GateRejected(address gate);
    /// @notice No message has this id.
    error MessageNotFound(uint64 id);
    /// @notice Only the author may change a message's gate (a removal is the one exception, see
    ///         `NotParentAuthor`).
    error NotAuthor(uint64 id, address caller);
    /// @notice Only the author of a message's immediate parent may remove it (§5.6).
    error NotParentAuthor(uint64 id, address caller);
    /// @notice The reply answers someone who replied to its author, so it cannot be removed.
    error ProtectedResponse(uint64 id);
    /// @notice The message was deleted or removed, so its gate can never change again (§5.6).
    error MessageTombstoned(uint64 id);
    /// @notice The gate can't be `REMOVED` here. Only the author of a message's parent may set it,
    ///         and never on their own message, when posting, or as an author's default.
    error InvalidGate(address gate);
    /// @notice The signature's deadline has passed.
    error SignatureExpired(uint256 deadline);
    /// @notice The signature was not produced by the claimed author: it recovers to `recovered`
    ///         instead (zero when it is not a well-formed ECDSA signature), and if the author is a
    ///         contract account, that account did not accept it either (ERC-1271).
    error InvalidSigner(address expected, address recovered);
    /// @notice The nonce was already used or invalidated.
    error NonceAlreadyUsed(uint256 nonce);

    // ---- writes -------------------------------------------------------------

    /// @notice Post a message as `msg.sender`.
    /// @param contentHash        keccak256 of the exact content bytes
    /// @param parentId           0 for a top-level post, else an existing message id
    /// @param replyGate          the gate for replies to this message. 0 leaves them to the
    ///                           author's default gate. To exempt one message from that default,
    ///                           give it a gate that admits everyone
    /// @param gateData           opaque data for the parent's gate; empty when the gate needs none
    /// @return id                the new message's id
    function post(bytes32 contentHash, uint64 parentId, address replyGate, bytes calldata gateData)
        external
        returns (uint64 id);

    /// @notice Post a message on behalf of `author`, who signed it (EIP-712, §4.2). Anyone may
    ///         submit; `msg.sender` pays gas and gains nothing else.
    /// @dev `gateData` is deliberately NOT covered by the signature (§4.2).
    function postBySig(
        address author,
        bytes32 contentHash,
        uint64 parentId,
        address replyGate,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig,
        bytes calldata gateData
    ) external returns (uint64 id);

    /// @notice Change a message's gate. Only its author may, with one exception: the author of the
    ///         message's immediate parent may set `REMOVED` on someone else's reply, unless it is a
    ///         protected response (§5.4), and may set nothing else. `TOMBSTONE` deletes the
    ///         message and `REMOVED` removes it. Both are permanent, and the value says who acted
    ///         (§5.6).
    function setReplyGate(uint64 id, address gate) external;

    /// @notice Signed variant of `setReplyGate`.
    function setReplyGateBySig(
        address author,
        uint64 id,
        address gate,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external;

    /// @notice Set `msg.sender`'s default gate (§5.7). 0 clears it, `TOMBSTONE` deactivates the
    ///         account until another default is set, and `REMOVED` is refused.
    function setAuthorGate(address gate) external;

    /// @notice Signed variant of `setAuthorGate`.
    function setAuthorGateBySig(
        address author,
        address gate,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external;

    /// @notice Mark nonces as used so outstanding signatures can never land.
    /// @param wordPos which 256-nonce word to modify (nonce >> 8)
    /// @param mask    bits to set (bit i covers nonce wordPos*256 + i)
    function invalidateNonces(uint256 wordPos, uint256 mask) external;

    // ---- views --------------------------------------------------------------

    /// @notice A message's stored fields. Reverts with `MessageNotFound` for an unknown id, so
    ///         callers never mistake zeroes for a message.
    function getMessage(uint64 id)
        external
        view
        returns (address author, uint64 parentId, uint32 timestamp, bytes32 contentHash);

    /// @notice A message's author alone. Gates that resolve the parent's author (the shared
    ///         blocklist gate, §5.7) need nothing else, and this reads only the packed slot, never
    ///         the content hash. Reverts with `MessageNotFound` for an unknown id.
    function authorOf(uint64 id) external view returns (address author);

    /// @notice Whether a message with this id exists.
    function exists(uint64 id) external view returns (bool);

    /// @notice A message's own gate: 0 if it has none, `TOMBSTONE` if it was deleted, `REMOVED` if
    ///         it was removed.
    function replyGate(uint64 id) external view returns (address);

    /// @notice An author's default gate (may be `TOMBSTONE`, or 0 if unset).
    function authorGate(address author) external view returns (address);

    /// @notice The gate that applies to replies to `id` right now (§4): the message's own gate
    ///         if it has one, otherwise its author's default, or 0 if neither is set. So
    ///         `TOMBSTONE` means the message was deleted or its author deactivated, and `REMOVED`
    ///         that it was removed. It ignores the right of response, which `checkReply` applies
    ///         (§5.4). Reverts with `MessageNotFound` for an unknown id.
    function effectiveGate(uint64 id) external view returns (address);

    /// @notice Check whether `replier` could reply to `parentId` now, with the same checks posting
    ///         makes.
    /// @param parentId the parent message, or 0 for a top-level post, which no gate governs
    /// @param replier  the would-be author; this query does not check that it is really them
    /// @param gateData opaque data for the parent's gate
    /// @return gate   the gate that admitted the reply, or 0 when no gate was called
    /// @dev Reverts with the same errors as posting: a missing, deleted or removed parent, a
    ///      deactivated author, or a gate rejection. Writes nothing and consumes no nonce. It is
    ///      only a preview: state, gas and transaction context may differ when the post lands. A
    ///      protected response (§5.4) passes whatever the gate, and returns 0.
    function checkReply(uint64 parentId, address replier, bytes calldata gateData)
        external
        view
        returns (address gate);

    /// @notice The id the next post will receive.
    function nextId() external view returns (uint64);

    /// @notice One 256-bit word of an author's nonce bitmap.
    function nonceBitmap(address author, uint256 wordPos) external view returns (uint256);

    /// @notice The EIP-712 domain separator signatures must be bound to.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
