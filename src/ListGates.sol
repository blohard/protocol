// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IBoard} from "./IBoard.sol";
import {IReplyGate} from "./IReplyGate.sol";
import {ListRegistry} from "./ListRegistry.sol";

/// @dev Reject zero addresses for a gate's registry, list owner or board: a gate bound to nothing
///      would decide the same way for everyone, forever.
error ZeroAddress();

/// @title ListGate
/// @notice The base of a gate over one list in a `ListRegistry`: the registry, list owner and list
///         id are fixed at deployment.
abstract contract ListGate is IReplyGate {
    ListRegistry public immutable REGISTRY;
    address public immutable LIST_OWNER;
    bytes32 public immutable LIST_ID;

    constructor(ListRegistry registry, address listOwner, bytes32 listId) {
        if (address(registry) == address(0) || listOwner == address(0)) revert ZeroAddress();
        REGISTRY = registry;
        LIST_OWNER = listOwner;
        LIST_ID = listId;
    }
}

/// @title BlocklistGate
/// @notice Admits everyone except members of one list in a `ListRegistry`. An empty list admits
///         everyone.
contract BlocklistGate is ListGate {
    constructor(ListRegistry registry, address listOwner, bytes32 listId)
        ListGate(registry, listOwner, listId)
    {}

    /// @inheritdoc IReplyGate
    function canReply(uint64, address replier, bytes calldata) external view returns (bool) {
        return !REGISTRY.contains(LIST_OWNER, LIST_ID, replier);
    }
}

/// @title AuthorBlocklistGate
/// @notice One gate for every author. Installed as an author gate, it refuses repliers on the
///         *parent's author's* list `LIST_ID` in the registry. Because it resolves the list owner
///         from the parent, a single deployment serves everyone: each author points their author
///         gate at it once and maintains their own list (SPEC.md §5.7). Clients also re-apply it
///         to existing replies and fold those it now refuses (SPEC.md §5.7).
/// @dev Its immutables are the board and the registry, not a fixed list owner as in `ListGate`,
///      which is why it is a contract of its own. Like the Board and the registry it lives at a
///      documented CREATE2 address, so a change to its bytecode moves it (SPEC.md §9).
contract AuthorBlocklistGate is IReplyGate {
    IBoard public immutable BOARD;
    ListRegistry public immutable REGISTRY;
    bytes32 public immutable LIST_ID;

    constructor(IBoard board, ListRegistry registry, bytes32 listId) {
        if (address(board) == address(0) || address(registry) == address(0)) revert ZeroAddress();
        BOARD = board;
        REGISTRY = registry;
        LIST_ID = listId;
    }

    /// @inheritdoc IReplyGate
    function canReply(uint64 parentId, address replier, bytes calldata)
        external
        view
        returns (bool)
    {
        return !REGISTRY.contains(BOARD.authorOf(parentId), LIST_ID, replier);
    }
}
