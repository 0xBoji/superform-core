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
                        EXTERNAL DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Performs multi destination x multi vault deposits
    /// @param req is the request object containing all the necessary data for the action
    function multiDstMultiVaultDeposit(
        MultiDstMultiVaultsStateReq calldata req
    ) external payable;

    /// @dev Performs single destination x multi vault deposits
    /// @param req is the request object containing all the necessary data for the action
    function singleDstMultiVaultDeposit(
        SingleDstMultiVaultsStateReq memory req
    ) external payable;

    /// @dev Performs multi destination x single vault deposits
    /// @param req is the request object containing all the necessary data for the action
    function multiDstSingleVaultDeposit(
        MultiDstSingleVaultStateReq calldata req
    ) external payable;

    /// @dev Performs single xchain destination x single vault deposits
    /// @param req is the request object containing all the necessary data for the action
    function singleXChainSingleVaultDeposit(
        SingleXChainSingleVaultStateReq memory req
    ) external payable;

    /// @dev Performs single direct x single vault deposits
    /// @param req is the request object containing all the necessary data for the action
    function singleDirectSingleVaultDeposit(
        SingleDirectSingleVaultStateReq memory req
    ) external payable;

    /*///////////////////////////////////////////////////////////////
                        EXTERNAL WITHDRAW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Performs multi destination x multi vault withdraws
    /// @param req is the request object containing all the necessary data for the action
    function multiDstMultiVaultWithdraw(
        MultiDstMultiVaultsStateReq calldata req
    ) external payable;

    /// @dev Performs single destination x multi vault withdraws
    /// @param req is the request object containing all the necessary data for the action
    function singleDstMultiVaultWithdraw(
        SingleDstMultiVaultsStateReq memory req
    ) external payable;

    /// @dev Performs multi destination x single vault withdraws
    /// @param req is the request object containing all the necessary data for the action
    function multiDstSingleVaultWithdraw(
        MultiDstSingleVaultStateReq calldata req
    ) external payable;

    /// @dev Performs single xchain destination x single vault withdraws
    /// @param req is the request object containing all the necessary data for the action
    function singleXChainSingleVaultWithdraw(
        SingleXChainSingleVaultStateReq memory req
    ) external payable;

    /// @dev Performs single direct x single vault withdraws
    /// @param req is the request object containing all the necessary data for the action
    function singleDirectSingleVaultWithdraw(
        SingleDirectSingleVaultStateReq memory req
    ) external payable;

    /// @dev Perform burn of SuperPositions initiated by SuperPositionBank (RBAC'd)
    function burnPositionSingle(
        address _owner,
        uint256 _tokenId,
        uint256 _amount
    ) external;

    /// @dev Perform burn of SuperPositions initiated by SuperPositionBank (RBAC'd)
    function burnPositionBatch(
        address _owner,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts
    ) external;

    /*///////////////////////////////////////////////////////////////
                        OTHER EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev allows registry contract to send payload for processing to the router contract.
    /// @param data_ is the received information to be processed.
    function stateMultiSync(AMBMessage memory data_) external payable;

    /// @dev allows registry contract to send payload for processing to the router contract.
    /// @param data_ is the received information to be processed.
    function stateSync(AMBMessage memory data_) external payable;

    /*///////////////////////////////////////////////////////////////
                        External View Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev returns the total individual vault transactions made through the router.
    function totalTransactions() external view returns (uint80);
}
