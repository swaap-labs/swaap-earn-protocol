// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import "src/base/permutations/FundWithShareLockFlashLoansWhitelisting.sol";

contract MockFundWithShareLockFlashLoansWhitelisting is FundWithShareLockFlashLoansWhitelisting {
    constructor(
        address _owner,
        Registry _registry,
        ERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint32 _holdingPosition,
        bytes memory _holdingPositionConfig,
        uint256 _initialDeposit,
        uint192 _shareSupplyCap
    )
        FundWithShareLockFlashLoansWhitelisting(
            _owner,
            _registry,
            _asset,
            _name,
            _symbol,
            _holdingPosition,
            _holdingPositionConfig,
            _initialDeposit,
            _shareSupplyCap
        )
    {}

    function getExpirationDurationSignature() public pure returns (uint256) {
        return WHITELIST_VALIDITY_PERIOD;
    }

    function getHashTypedDataV4(bytes32 structHash) public view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    function mockVerifyWhitelistSignaturePublic(
        address receiver,
        uint256 signedAt,
        bytes memory signature
    ) public view {
        _verifyWhitelistSignature(receiver, signedAt, signature);
    }
}
