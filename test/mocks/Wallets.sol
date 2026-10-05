// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// A contract account with one owner key and any number of session keys: it stands behind a
/// signature from any of them (ERC-1271).
contract SessionWallet is IERC1271 {
    address public owner;
    mapping(address => bool) public isSession;

    constructor(address owner_) {
        owner = owner_;
    }

    function setSession(address key, bool on) external {
        require(msg.sender == owner || msg.sender == address(this), "not owner");
        isSession[key] = on;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.NoError && (signer == owner || isSession[signer])) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// Account code for an EIP-7702 delegation: the key's own address runs this, and accepts signatures
/// from the session keys it stored. (The key itself still signs as usual; the Board tries that
/// first.)
contract SessionAccount is IERC1271 {
    mapping(address => bool) public isSession;

    function setSession(address key, bool on) external {
        require(msg.sender == address(this), "only the account");
        isSession[key] = on;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.NoError && isSession[signer]) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// Refuses every signature.
contract RejectingWallet is IERC1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

/// Reverts on every signature.
contract RevertingWallet {
    error Nope();

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert Nope();
    }
}

/// Answers with a single byte: not a valid magic value.
contract ShortReturnWallet {
    fallback() external {
        assembly {
            mstore(0x00, 0)
            return(0x00, 1)
        }
    }
}

/// Answers with the magic value followed by 64 KiB of nothing: the Board must copy only the first
/// word.
contract GreedyWallet {
    fallback() external {
        assembly {
            mstore(0x00, 0x1626ba7e00000000000000000000000000000000000000000000000000000000)
            return(0x00, 0x10000)
        }
    }
}
