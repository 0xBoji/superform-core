// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

interface IFormStateRegistry {
    /*///////////////////////////////////////////////////////////////
                            Events
    //////////////////////////////////////////////////////////////*/

    /// @dev is emitted when core contracts are updated
    event CoreContractsUpdated(
        address routerContract,
        address tokenBankContract
    );

    /*///////////////////////////////////////////////////////////////
                            External Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev allows accounts with {UPDATER_ROLE} to modify a received cross-chain payload.
    /// @param payloadId_ is the identifier of the cross-chain payload to be updated.
    /// @param finalAmounts_ is the amount to be updated.
    /// NOTE: amounts cannot be updated beyond user specified safe slippage limit.
    function updateMultiVaultPayload(
        uint256 payloadId_,
        uint256[] calldata finalAmounts_
    ) external;

    /// @dev allows accounts with {UPDATER_ROLE} to modify a received cross-chain payload.
    /// @param payloadId_ is the identifier of the cross-chain payload to be updated.
    /// @param finalAmount_ is the amount to be updated.
    /// NOTE: amounts cannot be updated beyond user specified safe slippage limit.
    function updateSingleVaultPayload(
        uint256 payloadId_,
        uint256 finalAmount_
    ) external;

    function receivePayload(uint256 payloadId, uint256 superFormId) external;

    function initPayload(uint256 payloadId) external;
}
