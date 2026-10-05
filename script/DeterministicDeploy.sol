// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from "forge-std/Script.sol";

/// Deploys through the deterministic deployer proxy (`CREATE2_FACTORY` in forge-std) by calling it
/// directly with the salt followed by the init code. Forge can turn `new C{salt: s}()` into that
/// call by itself, but not on every chain: forge 1.8.1 deploys from the sender instead when the
/// chain id is Base's or Base Sepolia's, which lands the contract at a different address.
abstract contract DeterministicDeploy is Script {
    /// Deploys `initCode` with `salt` and returns its address. When code is already there, it
    /// reports the existing deployment and sends nothing.
    function deploy(string memory name, bytes32 salt, bytes memory initCode)
        internal
        returns (address deployed)
    {
        require(CREATE2_FACTORY.code.length > 0, "no deterministic deployer");
        deployed = vm.computeCreate2Address(salt, keccak256(initCode));
        if (deployed.code.length > 0) {
            console.log(string.concat(name, " already at"), deployed);
            return deployed;
        }

        vm.startBroadcast();
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        require(ok && deployed.code.length > 0, "deterministic deployment failed");

        console.log(string.concat(name, " deployed at"), deployed);
        console.log("chain id", block.chainid);
    }
}
