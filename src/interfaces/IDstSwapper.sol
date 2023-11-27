// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

/// @title IDstSwapper
/// @author Zeropoint Labs
/// @dev handles all destination chain swaps.
/// @notice all write functions can only be accessed by superform keepers.
interface IDstSwapper {
    //////////////////////////////////////////////////////////////
    //                           STRUCTS                         //
    //////////////////////////////////////////////////////////////

    struct FailedSwap {
        address interimToken;
        uint256 amount;
    }

    //////////////////////////////////////////////////////////////
    //                          EVENTS                          //
    //////////////////////////////////////////////////////////////

    /// @dev is emitted when the super registry is updated.
    event SuperRegistryUpdated(address indexed superRegistry);

    /// @dev is emitted when a dst swap transaction is processed
    event SwapProcessed(uint256 payloadId, uint256 index, uint256 bridgeId, uint256 finalAmount);

    /// @dev is emitted when a dst swap fails and intermediary tokens are sent to CoreStateRegistry for rescue
    event SwapFailed(uint256 payloadId, uint256 index, address intermediaryToken, uint256 amount);

    //////////////////////////////////////////////////////////////
    //              EXTERNAL VIEW FUNCTIONS                     //
    //////////////////////////////////////////////////////////////

    /// @notice returns the swapped amounts (if dst swap is successful)
    /// @param payloadId_ is the id of payload
    /// @param index_ represents the index in the payload (0 for single vault payload)
    /// @return amount is the amount forwarded to core state registry after the swap
    function swappedAmount(uint256 payloadId_, uint256 index_) external view returns (uint256 amount);

    /// @notice returns the interim amounts (if dst swap is failing)
    /// @param payloadId_ is the id of payload
    /// @param index_ represents the index in the payload (0 for single vault payload)
    /// @return interimToken is the token that is to be refunded
    /// @return amount is the amount of interim token to be refunded
    function getPostDstSwapFailureUpdatedTokenAmount(
        uint256 payloadId_,
        uint256 index_
    )
        external
        view
        returns (address interimToken, uint256 amount);

    //////////////////////////////////////////////////////////////
    //              EXTERNAL WRITE FUNCTIONS                    //
    //////////////////////////////////////////////////////////////

    /// @notice will process dst swap through a liquidity bridge
    /// @param payloadId_ represents the id of the payload
    /// @param index_ represents the index of the superformid in the payload
    /// @param bridgeId_ represents the id of liquidity bridge used
    /// @param txData_ represents the transaction data generated by liquidity bridge API.
    function processTx(uint256 payloadId_, uint256 index_, uint8 bridgeId_, bytes calldata txData_) external;

    /// @notice updates the amounts of intermediary tokens stuck because of failing dst swap
    /// @param payloadId_ represents the id of the payload
    /// @param index_ represents the failing index in the payload
    /// @param interimToken_ is the intermediary token that cannot be swapped to the vault underlying
    /// @param amount_ is the amount of the intermediary token
    function updateFailedTx(uint256 payloadId_, uint256 index_, address interimToken_, uint256 amount_) external;

    /// @notice updates the amounts of intermediary tokens stuck because of failing dst swap in batch
    /// @param payloadId_ represents the id of the payload
    /// @param indices_ represents the failing indices in the payload
    /// @param interimTokens_ is the list of intermediary tokens that cannot be swapped
    /// @param amounts_ are the amount of intermediary tokens that need to be refunded to the user
    function batchUpdateFailedTx(
        uint256 payloadId_,
        uint256[] calldata indices_,
        address[] calldata interimTokens_,
        uint256[] calldata amounts_
    )
        external;

    /// @notice will process dst swaps in batch through a liquidity bridge
    /// @param payloadId_ represents the array of payload ids used
    /// @param indices_ represents the index of the superformid in the payload
    /// @param bridgeIds_ represents the array of ids of liquidity bridges used
    /// @param txData_  represents the array of transaction data generated by liquidity bridge API
    function batchProcessTx(
        uint256 payloadId_,
        uint256[] calldata indices_,
        uint8[] calldata bridgeIds_,
        bytes[] calldata txData_
    )
        external;

    /// @notice is a privileged function that allows Core State Registry to process refunds
    /// @param user_ is the final refund receiver of the interimToken_
    /// @param interimToken_ is the refund token
    /// @param amount_ is the refund amount
    function processFailedTx(address user_, address interimToken_, uint256 amount_) external;
}