/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {LiqRequest, TransactionType, CallbackType, MultiVaultsSFData, SingleVaultSFData, MultiDstMultiVaultsStateReq, SingleDstMultiVaultsStateReq, MultiDstSingleVaultStateReq, SingleXChainSingleVaultStateReq, SingleDirectSingleVaultStateReq, InitMultiVaultData, InitSingleVaultData, AMBMessage, SingleDstAMBParams} from "./types/DataTypes.sol";
import {IBaseStateRegistry} from "./interfaces/IBaseStateRegistry.sol";
import {ISuperFormFactory} from "./interfaces/ISuperFormFactory.sol";
import {IBaseForm} from "./interfaces/IBaseForm.sol";
import {ISuperRouter} from "./interfaces/ISuperRouter.sol";
import {ISuperRegistry} from "./interfaces/ISuperRegistry.sol";
import {ISuperRBAC} from "./interfaces/ISuperRBAC.sol";
import {IFormBeacon} from "./interfaces/IFormBeacon.sol";
import {IBridgeValidator} from "./interfaces/IBridgeValidator.sol";
import {ISuperPositions} from "./interfaces/ISuperPositions.sol";
import {LiquidityHandler} from "./crosschain-liquidity/LiquidityHandler.sol";
import {Error} from "./utils/Error.sol";
import "./utils/DataPacking.sol";

/// @title Super Router
/// @author Zeropoint Labs.
/// @dev Routes users funds and action information to a remote execution chain.
/// @dev extends Liquidity Handler.
contract SuperRouter is ISuperRouter, LiquidityHandler {
    using SafeERC20 for IERC20;

    /*///////////////////////////////////////////////////////////////
                                State Variables
    //////////////////////////////////////////////////////////////*/

    uint8 public constant STATE_REGISTRY_TYPE = 1;

    ISuperRegistry public immutable superRegistry;

    uint256 public override payloadIds;

    modifier onlyProtocolAdmin() {
        if (!ISuperRBAC(superRegistry.superRBAC()).hasProtocolAdminRole(msg.sender)) revert Error.NOT_PROTOCOL_ADMIN();
        _;
    }

    /// @dev constructor
    /// @param superRegistry_ the superform registry contract
    constructor(address superRegistry_) {
        superRegistry = ISuperRegistry(superRegistry_);
    }

    /*///////////////////////////////////////////////////////////////
                        External Write Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice receive enables processing native token transfers into the smart contract.
    /// @notice liquidity bridge tech fails without a native receive function.
    receive() external payable {}

    /// @inheritdoc ISuperRouter
    function multiDstMultiVaultDeposit(MultiDstMultiVaultsStateReq calldata req) external payable override {
        for (uint256 i = 0; i < req.dstChainIds.length; i++) {
            singleDstMultiVaultDeposit(
                SingleDstMultiVaultsStateReq(
                    req.ambIds,
                    req.dstChainIds[i],
                    req.superFormsData[i],
                    req.extraDataPerDst[i]
                )
            );
        }
    }

    /// @inheritdoc ISuperRouter
    function singleDstMultiVaultDeposit(SingleDstMultiVaultsStateReq memory req) public payable override {
        ActionLocalVars memory vars;
        InitMultiVaultData memory ambData;
        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        /// @dev validate superFormsData
        if (!_validateSuperFormsDepositData(req.superFormsData, req.dstChainId)) revert Error.INVALID_SUPERFORMS_DATA();

        payloadIds++;
        vars.currentPayloadId = payloadIds;

        /// @dev write packed txData
        ambData = InitMultiVaultData(
            vars.currentPayloadId,
            req.superFormsData.superFormIds,
            req.superFormsData.amounts,
            req.superFormsData.maxSlippage,
            new LiqRequest[](0),
            req.superFormsData.extraFormData
        );

        if (vars.srcChainId == vars.dstChainId) {
            /// @dev same chain action
            _directMultiDeposit(vars.srcSender, req.superFormsData.liqRequests, ambData);
            emit Completed(vars.currentPayloadId);
        } else {
            /// @dev cross chain action

            address permit2 = superRegistry.PERMIT2();
            address superForm;
            /// @dev this loop is what allows to deposit to >1 different underlying on destination
            /// @dev if a loop fails in a validation the whole chain should be reverted
            for (uint256 j = 0; j < req.superFormsData.liqRequests.length; j++) {
                vars.liqRequest = req.superFormsData.liqRequests[j];
                /// @dev dispatch liquidity data
                (superForm, , ) = _getSuperForm(req.superFormsData.superFormIds[j]);

                _validateAndDispatchTokens(
                    vars.liqRequest,
                    permit2,
                    superForm,
                    vars.srcChainId,
                    vars.dstChainId,
                    vars.srcSender,
                    true
                );
            }

            _dispatchAmbMessage(
                vars.srcSender,
                TransactionType.DEPOSIT,
                abi.encode(ambData),
                1,
                req.extraData,
                req.ambIds,
                vars.srcChainId,
                vars.dstChainId,
                vars.currentPayloadId
            );

            emit CrossChainInitiated(vars.currentPayloadId);
        }
    }

    /// @inheritdoc ISuperRouter
    function multiDstSingleVaultDeposit(MultiDstSingleVaultStateReq calldata req) external payable override {
        uint64 dstChainId;

        for (uint256 i = 0; i < req.dstChainIds.length; i++) {
            dstChainId = req.dstChainIds[i];
            if (superRegistry.chainId() == dstChainId) {
                singleDirectSingleVaultDeposit(
                    SingleDirectSingleVaultStateReq(dstChainId, req.superFormsData[i], req.extraDataPerDst[i])
                );
            } else {
                singleXChainSingleVaultDeposit(
                    SingleXChainSingleVaultStateReq(
                        req.ambIds,
                        dstChainId,
                        req.superFormsData[i],
                        req.extraDataPerDst[i]
                    )
                );
            }
        }
    }

    /// @inheritdoc ISuperRouter
    function singleXChainSingleVaultDeposit(SingleXChainSingleVaultStateReq memory req) public payable override {
        ActionLocalVars memory vars;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId == vars.dstChainId) revert Error.INVALID_CHAIN_IDS();

        InitSingleVaultData memory ambData;
        (ambData, vars.currentPayloadId) = _buildDepositAmbData(
            vars.srcSender,
            vars.srcChainId,
            vars.dstChainId,
            req.superFormData
        );

        vars.liqRequest = req.superFormData.liqRequest;

        (address superForm, , ) = _getSuperForm(req.superFormData.superFormId);

        _validateAndDispatchTokens(
            vars.liqRequest,
            superRegistry.PERMIT2(),
            superForm,
            vars.srcChainId,
            vars.dstChainId,
            vars.srcSender,
            true
        );

        _dispatchAmbMessage(
            vars.srcSender,
            TransactionType.DEPOSIT,
            abi.encode(ambData),
            0,
            req.extraData,
            req.ambIds,
            vars.dstChainId,
            vars.currentPayloadId
        );

        emit CrossChainInitiated(vars.currentPayloadId);
    }

    /// @inheritdoc ISuperRouter
    function singleDirectSingleVaultDeposit(SingleDirectSingleVaultStateReq memory req) public payable override {
        ActionLocalVars memory vars;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId != vars.dstChainId) revert Error.INVALID_CHAIN_IDS();

        InitSingleVaultData memory ambData;
        (ambData, vars.currentPayloadId) = _buildDepositAmbData(
            vars.srcSender,
            vars.srcChainId,
            vars.dstChainId,
            req.superFormData
        );

        /// @dev same chain action

        _directSingleDeposit(vars.srcSender, req.superFormData.liqRequest, ambData);

        emit Completed(vars.currentPayloadId);
    }

    /// @inheritdoc ISuperRouter
    function multiDstMultiVaultWithdraw(MultiDstMultiVaultsStateReq calldata req) external payable override {
        uint256 nDestinations = req.dstChainIds.length;

        for (uint256 i = 0; i < nDestinations; i++) {
            singleDstMultiVaultWithdraw(
                SingleDstMultiVaultsStateReq(
                    req.ambIds,
                    req.dstChainIds[i],
                    req.superFormsData[i],
                    req.extraDataPerDst[i]
                )
            );
        }
    }

    /// @inheritdoc ISuperRouter
    function singleDstMultiVaultWithdraw(SingleDstMultiVaultsStateReq memory req) public payable override {
        ActionLocalVars memory vars;
        InitMultiVaultData memory ambData;
        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        /// @dev validate superFormsData
        if (!_validateSuperFormsWithdrawData(req.superFormsData, req.dstChainId))
            revert Error.INVALID_SUPERFORMS_DATA();

        ISuperPositions(superRegistry.superPositions()).burnBatchSP(
            vars.srcSender,
            req.superFormsData.superFormIds,
            req.superFormsData.amounts
        );

        payloadIds++;
        vars.currentPayloadId = payloadIds;

        /// @dev write packed txData
        ambData = InitMultiVaultData(
            vars.currentPayloadId,
            req.superFormsData.superFormIds,
            req.superFormsData.amounts,
            req.superFormsData.maxSlippage,
            req.superFormsData.liqRequests,
            req.superFormsData.extraFormData
        );

        /// @dev same chain action
        if (vars.srcChainId == vars.dstChainId) {
            _directMultiWithdraw(req.superFormsData.liqRequests, ambData, vars.srcSender);
            emit Completed(vars.currentPayloadId);
        } else {
            _dispatchAmbMessage(
                vars.srcSender,
                TransactionType.WITHDRAW,
                abi.encode(ambData),
                1,
                req.extraData,
                req.ambIds,
                vars.dstChainId,
                vars.currentPayloadId
            );

            emit CrossChainInitiated(vars.currentPayloadId);
        }
    }

    /// @inheritdoc ISuperRouter
    function multiDstSingleVaultWithdraw(MultiDstSingleVaultStateReq calldata req) external payable override {
        uint64 dstChainId;

        for (uint256 i = 0; i < req.dstChainIds.length; i++) {
            dstChainId = req.dstChainIds[i];
            if (superRegistry.chainId() == dstChainId) {
                singleDirectSingleVaultWithdraw(
                    SingleDirectSingleVaultStateReq(dstChainId, req.superFormsData[i], req.extraDataPerDst[i])
                );
            } else {
                singleXChainSingleVaultWithdraw(
                    SingleXChainSingleVaultStateReq(
                        req.ambIds,
                        dstChainId,
                        req.superFormsData[i],
                        req.extraDataPerDst[i]
                    )
                );
            }
        }
    }

    /// @inheritdoc ISuperRouter
    function singleXChainSingleVaultWithdraw(SingleXChainSingleVaultStateReq memory req) public payable override {
        ActionLocalVars memory vars;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId == vars.dstChainId) revert Error.INVALID_CHAIN_IDS();

        InitSingleVaultData memory ambData;

        (ambData, vars.currentPayloadId) = _buildWithdrawAmbData(
            vars.srcSender,
            vars.srcChainId,
            vars.dstChainId,
            req.superFormData
        );

        _dispatchAmbMessage(
            vars.srcSender,
            TransactionType.WITHDRAW,
            abi.encode(ambData),
            0,
            req.extraData,
            req.ambIds,
            vars.dstChainId,
            vars.currentPayloadId
        );

        emit CrossChainInitiated(vars.currentPayloadId);
    }

    /// @inheritdoc ISuperRouter
    function singleDirectSingleVaultWithdraw(SingleDirectSingleVaultStateReq memory req) public payable override {
        ActionLocalVars memory vars;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId != vars.dstChainId) revert Error.INVALID_CHAIN_IDS();

        InitSingleVaultData memory ambData;

        (ambData, vars.currentPayloadId) = _buildWithdrawAmbData(
            vars.srcSender,
            vars.srcChainId,
            vars.dstChainId,
            req.superFormData
        );

        /// @dev same chain action

        _directSingleWithdraw(req.superFormData.liqRequest, ambData, vars.srcSender);

        emit Completed(vars.currentPayloadId);
    }

    function _buildDepositAmbData(
        address srcSender_,
        uint64 srcChainId_,
        uint64 dstChainId_,
        SingleVaultSFData memory superFormData_
    ) internal returns (InitSingleVaultData memory ambData, uint256 currentPayloadId) {
        /// @dev validate superFormsData

        if (!_validateSuperFormData(dstChainId_, superFormData_)) revert Error.INVALID_SUPERFORMS_DATA();

        if (
            !IBridgeValidator(superRegistry.getBridgeValidator(superFormData_.liqRequest.bridgeId))
                .validateTxDataAmount(superFormData_.liqRequest.txData, superFormData_.amount)
        ) revert Error.INVALID_TXDATA_AMOUNTS();

        payloadIds++;
        currentPayloadId = payloadIds;
        LiqRequest memory emptyRequest;

        ambData = InitSingleVaultData(
            currentPayloadId,
            superFormData_.superFormId,
            superFormData_.amount,
            superFormData_.maxSlippage,
            emptyRequest,
            superFormData_.extraFormData
        );
    }

    function _buildWithdrawAmbData(
        address srcSender_,
        uint64 srcChainId_,
        uint64 dstChainId_,
        SingleVaultSFData memory superFormData_
    ) internal returns (InitSingleVaultData memory ambData, uint256 currentPayloadId) {
        /// @dev validate superFormsData
        if (!_validateSuperFormData(dstChainId_, superFormData_)) revert Error.INVALID_SUPERFORMS_DATA();

        ISuperPositions(superRegistry.superPositions()).burnSingleSP(
            srcSender_,
            superFormData_.superFormId,
            superFormData_.amount
        );

        payloadIds++;
        currentPayloadId = payloadIds;

        ambData = InitSingleVaultData(
            currentPayloadId,
            superFormData_.superFormId,
            superFormData_.amount,
            superFormData_.maxSlippage,
            superFormData_.liqRequest,
            superFormData_.extraFormData
        );
    }

    function _validateAndDispatchTokens(
        LiqRequest memory liqRequest_,
        address permit2_,
        address superForm_,
        uint64 srcChainId_,
        uint64 dstChainId_,
        address srcSender_,
        bool deposit_
    ) internal {
        IBridgeValidator(superRegistry.getBridgeValidator(liqRequest_.bridgeId)).validateTxData(
            liqRequest_.txData,
            srcChainId_,
            dstChainId_,
            deposit_,
            superForm_,
            srcSender_,
            liqRequest_.token
        );
        dispatchTokens(
            superRegistry.getBridgeAddress(liqRequest_.bridgeId),
            liqRequest_.txData,
            liqRequest_.token,
            liqRequest_.amount,
            srcSender_,
            liqRequest_.nativeAmount,
            liqRequest_.permit2data,
            permit2_
        );
    }

    function _dispatchAmbMessage(
        address srcSender_,
        TransactionType txType_,
        bytes memory ambData_,
        uint8 multiVaults_,
        bytes memory extraData_,
        uint8[] memory ambIds_,
        uint64 srcChainId_,
        uint64 dstChainId_,
        uint256 currentTotalTransactions_
    ) internal {
        AMBMessage memory ambMessage = AMBMessage(
            _packTxInfo(
                uint8(txType_),
                uint8(CallbackType.INIT),
                multiVaults_,
                STATE_REGISTRY_TYPE,
                srcSender_,
                srcChainId_
            ),
            ambData_
        );
        SingleDstAMBParams memory ambParams = abi.decode(extraData_, (SingleDstAMBParams));

        /// @dev _liqReq should have path encoded for withdraw to SuperRouter on chain different than chainId
        /// @dev construct txData in this fashion: from FTM SOURCE send message to BSC DESTINATION
        /// @dev so that BSC DISPATCHTOKENS sends tokens to AVAX receiver (EOA/contract/user-specified)
        /// @dev sync could be a problem, how long Socket path stays vaild vs. how fast we bridge/receive on Dst
        IBaseStateRegistry(superRegistry.coreStateRegistry()).dispatchPayload{value: ambParams.gasToPay}(
            srcSender_,
            ambIds_,
            dstChainId_,
            abi.encode(ambMessage),
            ambParams.encodedAMBExtraData
        );

        ISuperPositions(superRegistry.superPositions()).updateTxHistory(currentTotalTransactions_, ambMessage);
    }

    function _directDeposit(
        address superForm,
        uint256 payloadId_,
        uint256 superFormId_,
        uint256 amount_,
        uint256 maxSlippage_,
        LiqRequest memory liqData_,
        bytes memory extraFormData_,
        uint256 msgValue_,
        address srcSender_
    ) internal returns (uint256 dstAmount) {
        /// @dev deposits collateral to a given vault and mint vault positions.
        /// @dev FIXME: in multi deposits we split the msg.value, but this only works if we validate that the user is only depositing from one source asset (native in this case)
        dstAmount = IBaseForm(superForm).directDepositIntoVault{value: msgValue_}(
            InitSingleVaultData(payloadId_, superFormId_, amount_, maxSlippage_, liqData_, extraFormData_),
            srcSender_
        );
    }

    /**
     * @notice deposit() to vaults existing on the same chain as SuperRouter
     * @dev Optimistic transfer & call
     */
    function _directSingleDeposit(
        address srcSender_,
        LiqRequest memory liqRequest_,
        InitSingleVaultData memory ambData_
    ) internal {
        address superForm;
        uint256 dstAmount;
        /// @dev decode superforms
        (superForm, , ) = _getSuperForm(ambData_.superFormId);

        /// @dev deposits collateral to a given vault and mint vault positions.
        dstAmount = _directDeposit(
            superForm,
            ambData_.payloadId,
            ambData_.superFormId,
            ambData_.amount,
            ambData_.maxSlippage,
            liqRequest_,
            ambData_.extraFormData,
            msg.value,
            srcSender_
        );

        ISuperPositions(superRegistry.superPositions()).mintSingleSP(srcSender_, ambData_.superFormId, dstAmount);
    }

    /**
     * @notice deposit() to vaults existing on the same chain as SuperRouter
     * @dev Optimistic transfer & call
     */
    function _directMultiDeposit(
        address srcSender_,
        LiqRequest[] memory liqRequests_,
        InitMultiVaultData memory ambData_
    ) internal {
        uint256 len = ambData_.superFormIds.length;

        address[] memory superForms = new address[](len);

        uint256[] memory dstAmounts = new uint256[](len);
        /// @dev decode superforms
        (superForms, , ) = _getSuperForms(ambData_.superFormIds);

        for (uint256 i = 0; i < len; i++) {
            /// @dev deposits collateral to a given vault and mint vault positions.
            dstAmounts[i] = _directDeposit(
                superForms[i],
                ambData_.payloadId,
                ambData_.superFormIds[i],
                ambData_.amounts[i],
                ambData_.maxSlippage[i],
                liqRequests_[i],
                ambData_.extraFormData,
                msg.value / len, /// @dev FIXME: is this acceptable ? Note that the user fully controls the msg.value being sent
                srcSender_
            );
        }

        /// @dev TEST-CASE: msg.sender to whom we mint. use passed `admin` arg?
        ISuperPositions(superRegistry.superPositions()).mintBatchSP(srcSender_, ambData_.superFormIds, dstAmounts);
    }

    function _directWithdraw(
        address superForm,
        uint256 txData_,
        uint256 superFormId_,
        uint256 amount_,
        uint256 maxSlippage_,
        LiqRequest memory liqData_,
        bytes memory extraFormData_,
        address srcSender_
    ) internal {
        /// @dev to allow bridging somewhere else requires arch change
        IBaseForm(superForm).directWithdrawFromVault(
            InitSingleVaultData(txData_, superFormId_, amount_, maxSlippage_, liqData_, extraFormData_),
            srcSender_
        );
    }

    /**
     * @notice withdraw() to vaults existing on the same chain as SuperRouter
     * @dev Optimistic transfer & call
     */
    function _directSingleWithdraw(
        LiqRequest memory liqRequest_,
        InitSingleVaultData memory ambData_,
        address srcSender_
    ) internal {
        /// @dev decode superforms
        (address superForm, , ) = _getSuperForm(ambData_.superFormId);

        _directWithdraw(
            superForm,
            ambData_.payloadId,
            ambData_.superFormId,
            ambData_.amount,
            ambData_.maxSlippage,
            liqRequest_,
            ambData_.extraFormData,
            srcSender_
        );
    }

    /**
     * @notice withdraw() to vaults existing on the same chain as SuperRouter
     * @dev Optimistic transfer & call
     */
    function _directMultiWithdraw(
        LiqRequest[] memory liqRequests_,
        InitMultiVaultData memory ambData_,
        address srcSender_
    ) internal {
        /// @dev decode superforms
        (address[] memory superForms, , ) = _getSuperForms(ambData_.superFormIds);

        for (uint256 i = 0; i < superForms.length; i++) {
            /// @dev deposits collateral to a given vault and mint vault positions.
            _directWithdraw(
                superForms[i],
                ambData_.payloadId,
                ambData_.superFormIds[i],
                ambData_.amounts[i],
                ambData_.maxSlippage[i],
                liqRequests_[i],
                ambData_.extraFormData,
                srcSender_
            );
        }
    }

    function _validateSuperFormData(
        uint64 dstChainId_,
        SingleVaultSFData memory superFormData_
    ) internal view returns (bool) {
        if (dstChainId_ != _getDestinationChain(superFormData_.superFormId)) return false;

        if (superFormData_.maxSlippage > 10000) return false;

        (, uint32 formBeaconId_, ) = _getSuperForm(superFormData_.superFormId);

        if (IFormBeacon(ISuperFormFactory(superRegistry.superFormFactory()).getFormBeacon(formBeaconId_)).paused())
            return false;

        return true;
    }

    function _validateSuperFormsDepositData(
        MultiVaultsSFData memory superFormsData_,
        uint64 dstChainId
    ) internal view returns (bool) {
        uint256 len = superFormsData_.amounts.length;
        uint256 liqRequestsLen = superFormsData_.liqRequests.length;

        if (len == 0 || liqRequestsLen == 0) return false;
        if (len != liqRequestsLen) return false;

        /// @dev sizes validation
        if (
            !(superFormsData_.superFormIds.length == superFormsData_.amounts.length &&
                superFormsData_.superFormIds.length == superFormsData_.maxSlippage.length)
        ) {
            return false;
        }

        /// @dev slippage and paused validation
        bool txDataAmountValid;
        for (uint256 i = 0; i < len; i++) {
            if (superFormsData_.maxSlippage[i] > 10000) return false;
            (, uint32 formBeaconId_, uint64 sfDstChainId) = _getSuperForm(superFormsData_.superFormIds[i]);
            if (dstChainId != sfDstChainId) return false;

            if (IFormBeacon(ISuperFormFactory(superRegistry.superFormFactory()).getFormBeacon(formBeaconId_)).paused())
                return false;

            txDataAmountValid = IBridgeValidator(
                superRegistry.getBridgeValidator(superFormsData_.liqRequests[i].bridgeId)
            ).validateTxDataAmount(superFormsData_.liqRequests[i].txData, superFormsData_.amounts[i]);

            if (!txDataAmountValid) return false;
        }

        return true;
    }

    function _validateSuperFormsWithdrawData(
        MultiVaultsSFData memory superFormsData_,
        uint64 dstChainId
    ) internal view returns (bool) {
        uint256 len = superFormsData_.amounts.length;
        uint256 liqRequestsLen = superFormsData_.liqRequests.length;

        if (len == 0 || liqRequestsLen == 0) return false;

        /// @dev sizes validation
        /// @dev In multiVault withdraws, the number of liq requests must be equal to number of target vaults
        if (liqRequestsLen != len) {
            return false;
        }

        if (
            !(superFormsData_.superFormIds.length == superFormsData_.amounts.length &&
                superFormsData_.superFormIds.length == superFormsData_.maxSlippage.length)
        ) {
            return false;
        }

        /// @dev slippage and paused validation
        for (uint256 i = 0; i < len; i++) {
            if (superFormsData_.maxSlippage[i] > 10000) return false;
            (, uint32 formBeaconId_, uint64 sfDstChainId) = _getSuperForm(superFormsData_.superFormIds[i]);
            if (dstChainId != sfDstChainId) return false;

            if (IFormBeacon(ISuperFormFactory(superRegistry.superFormFactory()).getFormBeacon(formBeaconId_)).paused())
                return false;
        }

        return true;
    }

    /*///////////////////////////////////////////////////////////////
                            DEV FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev PREVILEGED admin ONLY FUNCTION.
    /// @notice should be removed after end-to-end testing.
    /// @dev allows admin to withdraw lost tokens in the smart contract.
    function withdrawToken(address tokenContract_, uint256 amount_) external onlyProtocolAdmin {
        IERC20 tokenContract = IERC20(tokenContract_);

        /// note: transfer the token from address of this contract
        /// note: to address of the user (executing the withdrawToken() function)
        tokenContract.safeTransfer(msg.sender, amount_);
    }

    /// @dev PREVILEGED admin ONLY FUNCTION.
    /// @dev allows admin to withdraw lost native tokens in the smart contract.
    function withdrawNativeToken(uint256 amount_) external onlyProtocolAdmin {
        (bool success, ) = payable(msg.sender).call{value: amount_}("");
        if (!success) revert Error.NATIVE_TOKEN_TRANSFER_FAILURE();
    }
}
