// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IReplyGate} from "./IReplyGate.sol";

/// @title ClosedReplyGate
/// @notice "No new replies": refuses every ordinary reply, including one from the message's own
///         author.
/// @dev The Board still admits protected responses (the right of response) without calling this
///      gate. Setting a different gate reopens replies, and existing replies are untouched.
contract ClosedReplyGate is IReplyGate {
    /// @inheritdoc IReplyGate
    function canReply(uint64, address, bytes calldata) external pure returns (bool) {
        return false;
    }
}
