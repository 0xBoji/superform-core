// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;
import {LiqRequest, MultiDstMultiVaultsStateReq, SingleDstMultiVaultsStateReq, MultiDstSingleVaultStateReq, SingleXChainSingleVaultStateReq, SingleDirectSingleVaultStateReq, AMBMessage} from "../types/DataTypes.sol";

/// @title ISuperRouter
/// @author Zeropoint Labs.
interface ISuperRouter {
    /*///////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/
    struct ActionLocalVars {
        AMBMessage ambMessage;
        LiqRequest liqRequest;
        uint16 srcChainId;
        uint16 dstChainId;
        uint80 currentTotalTransactions;
        address srcSender;
        uint256 liqRequestsLen;
    }
    /*///////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev FIXME: to remove? - is emitted when a cross-chain transaction is initiated.
    event Initiated(uint256 txId, address fromToken, uint256 fromAmount);

    /// @dev is emitted when a cross-chain transaction is initiated.
    event CrossChainInitiated(uint80 indexed txId);

    /// @dev is emitted when a cross-chain transaction is completed.
    event Completed(uint256 txId);

    /// @dev is emitted when the super registry is updated.
    event SuperRegistryUpdated(address indexed superRegistry);

    /*///////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev is emitted when the chain id input is invalid.
    error INVALID_INPUT_CHAIN_ID();

    /// @dev is emitted when the amb ids input is invalid.
    error INVALID_AMB_IDS();

    /// @dev is emitted when the vaults data is invalid
    error INVALID_SUPERFORMS_DATA();

    /// @dev is emitted when the chain ids data is invalid
    error INVALID_CHAIN_IDS();

    /// @dev is emitted if anything other than state Registry calls stateSync
    error REQUEST_DENIED();

    /// @dev is emitted when the payload is invalid
    error INVALID_PAYLOAD();

    /// @dev is emitted if srchain ids mismatch in state sync
    error SRC_CHAIN_IDS_MISMATCH();

    /// @dev is emitted if dsthain ids mismatch in state sync
    error DST_CHAIN_IDS_MISMATCH();

    /// @dev is emitted if the payload status is invalid
    error INVALID_PAYLOAD_STATUS();

    /// @dev is emitted when an address is being set to 0
    error ZERO_ADDRESS();

    /*///////////////////////////////////////////////////////////////
                        EXTERNAL DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function multiDstMultiVaultDeposit(
        MultiDstMultiVaultsStateReq calldata req
    ) external payable;

    function singleDstMultiVaultDeposit(
        SingleDstMultiVaultsStateReq memory req
    ) external payable;

    function multiDstSingleVaultDeposit(
        MultiDstSingleVaultStateReq calldata req
    ) external payable;

    function singleXChainSingleVaultDeposit(
        SingleXChainSingleVaultStateReq memory req
    ) external payable;

    function singleDirectSingleVaultDeposit(
        SingleDirectSingleVaultStateReq memory req
    ) external payable;

    /*///////////////////////////////////////////////////////////////
                        EXTERNAL WITHDRAW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function multiDstMultiVaultWithdraw(
        MultiDstMultiVaultsStateReq calldata req
    ) external payable;

    function singleDstMultiVaultWithdraw(
        SingleDstMultiVaultsStateReq memory req
    ) external payable;

    function multiDstSingleVaultWithdraw(
        MultiDstSingleVaultStateReq calldata req
    ) external payable;

    function singleXChainSingleVaultWithdraw(
        SingleXChainSingleVaultStateReq memory req
    ) external payable;

    function singleDirectSingleVaultWithdraw(
        SingleDirectSingleVaultStateReq memory req
    ) external payable;

    /*///////////////////////////////////////////////////////////////
                        OTHER EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// set super registry
    /// @dev allows an admin to set the super registry
    /// @param superRegistry_ is the address of the super registry
    function setSuperRegistry(address superRegistry_) external;

    /// @dev allows registry contract to send payload for processing to the router contract.
    /// @param data_ is the received information to be processed.
    function stateMultiSync(AMBMessage memory data_) external payable;

    /// @dev allows registry contract to send payload for processing to the router contract.
    /// @param data_ is the received information to be processed.
    function stateSync(AMBMessage memory data_) external payable;

    /*///////////////////////////////////////////////////////////////
                        External View Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev returns the chain id of the router contract
    function chainId() external view returns (uint16);

    /// @dev returns the total individual vault transactions made through the router.
    function totalTransactions() external view returns (uint80);

    /// @dev returns the off-chain metadata URI for each ERC1155 super position.
    /// @param id_ is the unique identifier of the ERC1155 super position aka the vault id.
    /// @return string pointing to the off-chain metadata of the 1155 super position.
    function tokenURI(uint256 id_) external view returns (string memory);
}
