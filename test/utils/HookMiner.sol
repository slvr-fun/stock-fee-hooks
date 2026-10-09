// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice a minimal library for mining hook addresses
library HookMiner {
    // mask to slice out the bottom 14 bit of the address
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK; // 0000 ... 0000 0011 1111 1111 1111

    // Maximum number of iterations to find a salt, avoid infinite loops or MemoryOOG
    // (arbitrarily set)
    uint256 constant MAX_LOOP = 160_444;

    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param flags The desired flags for the hook address. Example `uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`
    /// @param creationCode The creation code of a hook contract. Example: `type(Counter).creationCode`
    /// @param constructorArgs The encoded constructor arguments of a hook contract. Example: `abi.encode(address(manager))`
    /// @return (hookAddress, salt) The hook deploys to `hookAddress` when using `salt` with the syntax: `new Hook{salt: salt}(<constructor arguments>)`
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address, bytes32)
    {
        flags = flags & FLAG_MASK; // mask for only the bottom 14 bits
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        // Hash the creation code ONCE. computeAddress re-hashes the whole blob per call, which
        // allocates a fresh copy of it every iteration — with a large hook that is hundreds of MB of
        // memory across the search and trips MemoryOOG before a matching salt is found.
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);

        address hookAddress;
        for (uint256 salt; salt < MAX_LOOP; salt++) {
            hookAddress = computeAddressFromHash(deployer, salt, initCodeHash);

            // if the hook's bottom 14 bits match the desired flags AND the address does not have bytecode, we found a match
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("HookMiner: could not find salt");
    }

    /// @notice CREATE2 address from a PRE-HASHED init code (hoisted out of mining loops).
    /// @dev    ALLOCATION-FREE, and that matters. `abi.encodePacked` allocates a fresh 85-byte buffer
    ///         on every call and Solidity never frees memory, so a search that runs deep enough grows
    ///         EVM memory until it trips MemoryOOG. That made mining succeed or fail depending on
    ///         which salt happened to match — i.e. on the exact bytecode being mined — so editing a
    ///         COMMENT in the hook could turn every fork test red with an error that points nowhere
    ///         near the change. Writing scratch above the free-memory pointer without advancing it
    ///         keeps the footprint flat, so the whole MAX_LOOP range is searchable for any contract.
    ///         (Writing past the FMP without updating it is explicitly allowed in the memory-safe
    ///         dialect: it is temporary scratch that no other allocation depends on.)
    function computeAddressFromHash(address deployer, uint256 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address addr)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 0x01), shl(96, deployer)) // 20 bytes, left-aligned
            mstore(add(ptr, 0x15), salt)
            mstore(add(ptr, 0x35), initCodeHash)
            addr := and(keccak256(ptr, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCodeWithArgs The creation code of a hook contract, with encoded constructor arguments appended. Example: `abi.encodePacked(type(Counter).creationCode, abi.encode(constructorArg1, constructorArg2))`
    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
