// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AaveV3AccountExtension } from "./AaveV3AccountExtension.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { AaveV3ATokenAdaptor } from "./AaveV3ATokenAdaptor.sol";
import { AaveV3DebtTokenAdaptor } from "./AaveV3DebtTokenAdaptor.sol";
import { IPoolV3 } from "src/interfaces/external/IPoolV3.sol";

/**
 * @title Aave V3 Account Helper Contract
 * @notice Allows Cellars to create multiple aave accounts and get their addresses.
 */
abstract contract AaveV3AccountHelper {
    /**
     * @notice The Aave V3 Pool contract on current network.
     * @dev For mainnet use 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2.
     */
    IPoolV3 public immutable pool;

    bytes32 public immutable bytecodeHash;

    constructor(address v3Pool) {
        pool = IPoolV3(v3Pool);

        bytes memory creationCode = _getCreationCode();
        bytecodeHash = keccak256(creationCode);
    }

    error AaveV3AccountHelper__AccountExtensionDoesNotExist();

    function createAccountExtension(bytes memory adaptorData) external returns (address) {
        (uint8 accountId, ) = _decodeAdaptorData(adaptorData);
        bytes32 salt = _getSaltById(accountId);

        bytes memory creationCode = _getCreationCode();
        // Create 2 will check if the account extension already exists and reverts if it does
        address accountAddress = Create2.deploy(0, salt, creationCode);

        // by default the account does not have any E mode enabled on Aave
        if (accountId != 0) {
            AaveV3AccountExtension(accountAddress).changeEMode(accountId);
        }

        return accountAddress;
    }

    function _extractAdaptorData(bytes memory adaptorData) internal view returns (address, address) {
        (uint8 id, address aaveToken) = _decodeAdaptorData(adaptorData);

        // should revert if account extension does not exist
        address accountAddress = _getAccountExtensionAddress(id);

        return (accountAddress, aaveToken);
    }

    function _getAccountExtensionAddress(uint8 id) internal view returns (address) {
        bytes32 salt = _getSaltById(id);
        // create 2 is necessary to have a deterministic address for the account extension using the bytecode hash
        address accountAddress = Create2.computeAddress(salt, bytecodeHash);

        if (!Address.isContract(accountAddress)) {
            revert AaveV3AccountHelper__AccountExtensionDoesNotExist();
        }

        return accountAddress;
    }

    function _getCreationCode() internal view returns (bytes memory) {
        bytes memory constructorArgs = abi.encode(pool);
        return abi.encodePacked(type(AaveV3AccountExtension).creationCode, constructorArgs);
    }

    function _getSaltById(uint8 accountId) internal pure returns (bytes32) {
        return bytes32(uint256(accountId));
    }

    function _decodeAdaptorData(bytes memory adaptorData) internal pure returns (uint8, address) {
        (uint8 accountId, address aaveToken) = abi.decode(adaptorData, (uint8, address));
        return (accountId, aaveToken);
    }
}
