// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IReplyGate
/// @notice A reply gate decides who may reply to a specific message (SPEC.md §5).
/// @dev The Board calls `canReply` with STATICCALL, so a gate can only read, never change state.
///      Returning `false`, reverting, returning fewer than 32 bytes, or returning anything other
///      than exactly `true` all reject the reply. An address without code (precompiles aside)
///      returns no data, so a gate set to it rejects every reply until a contract is deployed
///      there.
interface IReplyGate {
    /// @param parentId    the gated message being replied to
    /// @param replier     the prospective reply author; authenticated by the Board when posting,
    ///                    but not during a `checkReply` preview
    /// @param data        opaque extension data; the standard gates ignore it and the reference
    ///                    client sends empty bytes
    /// @dev The Board's post signature does not cover `data`: any submitter may supply or alter it,
    ///      so a gate must independently verify any authorization it carries.
    /// @return allowed    `true` admits the reply; anything else rejects it
    function canReply(uint64 parentId, address replier, bytes calldata data)
        external
        view
        returns (bool allowed);
}
