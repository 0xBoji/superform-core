// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;
import {LiqRequest} from "../types/DataTypes.sol";

/// @title ICoreStateRegistry
/// @author ZeroPoint Labs
/// @notice Interface for Core State Registry
interface ICoreStateRegistry {
    /// @dev is emitted when any deposit fails
    event FailedXChainDeposits(uint256 indexed payloadId);

    /*///////////////////////////////////////////////////////////////
                            External Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev allows accounts with {UPDATER_ROLE} to modify a received cross-chain deposit payload.
    /// @param payloadId_ is the identifier of the cross-chain payload to be updated.
    /// @param finalAmounts_ is the amount to be updated.
    /// NOTE: amounts cannot be updated beyond user specified safe slippage limit.
    function updateMultiVaultDepositPayload(uint256 payloadId_, uint256[] calldata finalAmounts_) external;

    /// @dev allows accounts with {UPDATER_ROLE} to modify a received cross-chain deposit payload.
    /// @param payloadId_ is the identifier of the cross-chain payload to be updated.
    /// @param finalAmount_ is the amount to be updated.
    /// NOTE: amounts cannot be updated beyond user specified safe slippage limit.
    function updateSingleVaultDepositPayload(uint256 payloadId_, uint256 finalAmount_) external;

    /// @dev allows accounts with {UPDATER_ROLE} to modify a received cross-chain withdraw payload.
    /// @param payloadId_  is the identifier of the cross-chain payload to be updated.
    /// @param txData_ is the transaction data to be updated.
    function updateMultiVaultWithdrawPayload(uint256 payloadId_, bytes[] calldata txData_) external;

    /// @dev allows accounts with {UPDATER_ROLE} to modify a received cross-chain withdraw payload.
    /// @param payloadId_  is the identifier of the cross-chain payload to be updated.
    /// @param txData_ is the transaction data to be updated.
    function updateSingleVaultWithdrawPayload(uint256 payloadId_, bytes calldata txData_) external;

    /// @dev allows accounts with {PROCESSOR_ROLE} to rescue tokens on failed deposits
    /// @param payloadId_ is the identifier of the cross-chain payload.
    /// @param liqDatas_ is the array of liquidity data.
    function rescueFailedDeposits(uint256 payloadId_, LiqRequest[] memory liqDatas_) external payable;
}
