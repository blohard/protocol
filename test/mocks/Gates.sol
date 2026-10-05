// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IReplyGate} from "../../src/IReplyGate.sol";

/// Admits everyone.
contract AllowAllGate is IReplyGate {
    function canReply(uint64, address, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// Admits no one.
contract DenyGate is IReplyGate {
    function canReply(uint64, address, bytes calldata) external pure returns (bool) {
        return false;
    }
}

/// Always reverts.
contract RevertingGate is IReplyGate {
    error Nope();

    function canReply(uint64, address, bytes calldata) external pure returns (bool) {
        revert Nope();
    }
}

/// Returns no data at all (not a valid bool).
contract ShortReturnGate {
    function canReply(uint64, address, bytes calldata) external pure returns (bool) {
        assembly {
            return(0, 0)
        }
    }
}

/// Returns a 32-byte word that is neither 0 nor 1.
contract MalformedBoolGate {
    function canReply(uint64, address, bytes calldata) external pure returns (bool) {
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// Returns `size` bytes whose first word is `first`. It plays a gate that tries to inflate the
/// caller's memory cost with a huge answer.
contract ReturnBombGate {
    uint256 public immutable first;
    uint256 public immutable size;

    constructor(uint256 first_, uint256 size_) {
        first = first_;
        size = size_;
    }

    function canReply(uint64, address, bytes calldata) external view returns (bool) {
        uint256 f = first;
        uint256 n = size;
        assembly {
            let p := mload(0x40)
            mstore(p, f)
            return(p, n)
        }
    }
}

/// Admits a reply only when its arguments exactly match what the test primed. This proves the Board
/// passes on the parent id, the real author and the opaque data.
contract RecordingGate is IReplyGate {
    uint64 public expectedParent;
    address public expectedReplier;
    bytes public expectedData;

    function expect(uint64 parent, address replier, bytes calldata data) external {
        expectedParent = parent;
        expectedReplier = replier;
        expectedData = data;
    }

    function canReply(uint64 parentId, address replier, bytes calldata data)
        external
        view
        returns (bool)
    {
        return parentId == expectedParent && replier == expectedReplier
            && keccak256(data) == keccak256(expectedData);
    }
}

/// Not `view`: tries to write state when consulted. The core's STATICCALL must make this revert,
/// and the write must never land.
contract StateWritingGate {
    uint256 public calls;

    function canReply(uint64, address, bytes calldata) external returns (bool) {
        calls++;
        return true;
    }
}
