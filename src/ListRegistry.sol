// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title ListRegistry
/// @notice Named lists of addresses, each maintained by whoever owns it (SPEC.md §5.3):
///         `owner => listId => member => bool`. Anyone may keep any number of lists; only the
///         owner writes to theirs. Gates such as `BlocklistGate` read them, and a relayer that
///         sponsors gas can check membership before paying.
/// @dev Deliberately minimal: no ownership transfer (a list is keyed by its owner's address), no
///      enumeration on-chain (the `Added` / `Removed` events reconstruct any list, and every change
///      emits exactly one event). Indexers rebuild membership and sizes from those events. Writes
///      are idempotent, so re-sending a batch is harmless. Writes name the owner: a wallet signing
///      from any other account reverts, at simulation time, instead of quietly writing to a list
///      nobody reads.
contract ListRegistry {
    /// @notice `member` joined `owner`'s list `listId`.
    event Added(address indexed owner, bytes32 indexed listId, address indexed member);
    /// @notice `member` left `owner`'s list `listId`.
    event Removed(address indexed owner, bytes32 indexed listId, address indexed member);

    /// @notice The caller is not the owner of the list it tried to change.
    error NotOwner(address owner, address caller);

    mapping(address owner => mapping(bytes32 listId => mapping(address member => bool))) private
        _member;

    /// @notice Add `members` to `owner`'s list `listId`; the caller must be `owner`.
    ///         Already-present addresses are skipped.
    function add(address owner, bytes32 listId, address[] calldata members) external {
        if (msg.sender != owner) revert NotOwner(owner, msg.sender);
        mapping(address => bool) storage list = _member[owner][listId];
        for (uint256 i = 0; i < members.length; ++i) {
            address m = members[i];
            if (list[m]) continue;
            list[m] = true;
            emit Added(owner, listId, m);
        }
    }

    /// @notice Remove `members` from `owner`'s list `listId`; the caller must be `owner`. Absent
    ///         addresses are skipped.
    function remove(address owner, bytes32 listId, address[] calldata members) external {
        if (msg.sender != owner) revert NotOwner(owner, msg.sender);
        mapping(address => bool) storage list = _member[owner][listId];
        for (uint256 i = 0; i < members.length; ++i) {
            address m = members[i];
            if (!list[m]) continue;
            list[m] = false;
            emit Removed(owner, listId, m);
        }
    }

    /// @notice Is `member` on `owner`'s list `listId`?
    function contains(address owner, bytes32 listId, address member) external view returns (bool) {
        return _member[owner][listId][member];
    }
}
