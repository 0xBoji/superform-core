/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {LiqRequest, TransactionType, ReturnMultiData, ReturnSingleData, CallbackType, MultiVaultsSFData, SingleVaultSFData, MultiDstMultiVaultsStateReq, SingleDstMultiVaultsStateReq, MultiDstSingleVaultStateReq, SingleXChainSingleVaultStateReq, SingleDirectSingleVaultStateReq, InitMultiVaultData, InitSingleVaultData, AMBMessage, MultiDstExtraData} from "./types/DataTypes.sol";
import {IBaseStateRegistry} from "./interfaces/IBaseStateRegistry.sol";
import {ISuperFormFactory} from "./interfaces/ISuperFormFactory.sol";
import {ISuperPositions} from "./interfaces/ISuperPositions.sol";
import {IBaseForm} from "./interfaces/IBaseForm.sol";
import {ISuperRouter} from "./interfaces/ISuperRouter.sol";
import {ISuperRegistry} from "./interfaces/ISuperRegistry.sol";
import {ISuperRBAC} from "./interfaces/ISuperRBAC.sol";
import {IFormBeacon} from "./interfaces/IFormBeacon.sol";
import {IBridgeValidator} from "./interfaces/IBridgeValidator.sol";
import {LiquidityHandler} from "./crosschain-liquidity/LiquidityHandler.sol";
import {Error} from "./utils/Error.sol";
import "./utils/DataPacking.sol";

/// @title Super Router
/// @author Zeropoint Labs.
/// @dev Routes users funds and deposit information to a remote execution chain.
/// @dev extends Liquidity Handler.
contract SuperRouter is ISuperRouter, LiquidityHandler {
    using SafeTransferLib for ERC20;
    using Strings for string;

    /*///////////////////////////////////////////////////////////////
                                State Variables
    //////////////////////////////////////////////////////////////*/

    uint8 public constant STATE_REGISTRY_TYPE = 0;

    ISuperRegistry public immutable superRegistry;

    uint80 public totalTransactions;

    /// @notice history of state sent across chains are used for debugging.
    /// @dev maps all transaction data routed through the smart contract.
    mapping(uint80 => AMBMessage) public txHistory;

    modifier onlyProtocolAdmin() {
        if (
            !ISuperRBAC(superRegistry.superRBAC()).hasProtocolAdminRole(
                msg.sender
            )
        ) revert Error.NOT_PROTOCOL_ADMIN();
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
    /// @dev socket.tech fails without a native receive function.
    receive() external payable {}

    /// @inheritdoc ISuperRouter
    function multiDstMultiVaultDeposit(
        MultiDstMultiVaultsStateReq calldata req
    ) external payable override {
        uint256 nDestinations = req.dstChainIds.length;

        MultiDstExtraData memory d = abi.decode(
            req.extraData,
            (MultiDstExtraData)
        );

        for (uint256 i = 0; i < nDestinations; i++) {
            singleDstMultiVaultDeposit(
                SingleDstMultiVaultsStateReq(
                    req.ambIds,
                    req.dstChainIds[i],
                    d.gasPerDst[i],
                    req.superFormsData[i],
                    d.extraDataPerDst[i]
                )
            );
        }
    }

    /// @inheritdoc ISuperRouter
    function singleDstMultiVaultDeposit(
        SingleDstMultiVaultsStateReq memory req
    ) public payable override {
        ActionLocalVars memory vars;
        InitMultiVaultData memory ambData;
        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        /// @dev validate superFormsData
        if (!_validateSuperFormsDepositData(req.superFormsData))
            revert Error.INVALID_SUPERFORMS_DATA();

        totalTransactions++;
        vars.currentTotalTransactions = totalTransactions;

        /// @dev write packed txData
        ambData = InitMultiVaultData(
            _packTxData(
                vars.srcSender,
                vars.srcChainId,
                vars.currentTotalTransactions
            ),
            req.superFormsData.superFormIds,
            req.superFormsData.amounts,
            req.superFormsData.maxSlippage,
            new LiqRequest[](0),
            req.superFormsData.extraFormData
        );

        /// @dev write amb message
        vars.ambMessage = AMBMessage(
            _packTxInfo(
                uint120(TransactionType.DEPOSIT),
                uint120(CallbackType.INIT),
                true,
                STATE_REGISTRY_TYPE
            ),
            abi.encode(ambData)
        );

        /// @dev same chain action
        if (vars.srcChainId == vars.dstChainId) {
            _directMultiDeposit(
                vars.srcSender,
                req.superFormsData.liqRequests,
                ambData
            );
            emit Completed(vars.currentTotalTransactions);
        } else {
            vars.liqRequestsLen = req.superFormsData.liqRequests.length;
            address permit2 = superRegistry.PERMIT2();
            /// @dev this loop is what allows to deposit to >1 different underlying on destination
            /// @dev if a loop fails in a validation the whole chain should be reverted
            for (uint256 j = 0; j < vars.liqRequestsLen; j++) {
                vars.liqRequest = req.superFormsData.liqRequests[j];
                /// @dev dispatch liquidity data
                (address superForm, , ) = _getSuperForm(
                    req.superFormsData.superFormIds[j]
                );

                IBridgeValidator(
                    superRegistry.getBridgeValidator(vars.liqRequest.bridgeId)
                ).validateTxData(
                        vars.liqRequest.txData,
                        vars.srcChainId,
                        vars.dstChainId,
                        true,
                        superForm,
                        vars.srcSender
                    );

                dispatchTokens(
                    superRegistry.getBridgeAddress(vars.liqRequest.bridgeId),
                    vars.liqRequest.txData,
                    vars.liqRequest.token,
                    vars.liqRequest.amount,
                    vars.srcSender,
                    vars.liqRequest.nativeAmount,
                    vars.liqRequest.permit2data,
                    permit2
                );
            }

            IBaseStateRegistry(superRegistry.coreStateRegistry())
                .dispatchPayload{value: req.gasToPay}(
                req.ambIds,
                vars.dstChainId,
                abi.encode(vars.ambMessage),
                req.extraData
            );

            txHistory[vars.currentTotalTransactions] = vars.ambMessage;

            emit CrossChainInitiated(vars.currentTotalTransactions);
        }
    }

    /// @inheritdoc ISuperRouter
    function multiDstSingleVaultDeposit(
        MultiDstSingleVaultStateReq calldata req
    ) external payable override {
        uint16 dstChainId;
        uint256 nDestinations = req.dstChainIds.length;

        MultiDstExtraData memory d = abi.decode(
            req.extraData,
            (MultiDstExtraData)
        );
        for (uint256 i = 0; i < nDestinations; i++) {
            dstChainId = req.dstChainIds[i];
            if (superRegistry.chainId() == dstChainId) {
                singleDirectSingleVaultDeposit(
                    SingleDirectSingleVaultStateReq(
                        dstChainId,
                        req.superFormsData[i],
                        req.extraData
                    )
                );
            } else {
                singleXChainSingleVaultDeposit(
                    SingleXChainSingleVaultStateReq(
                        req.ambIds,
                        dstChainId,
                        d.gasPerDst[i],
                        req.superFormsData[i],
                        d.extraDataPerDst[i]
                    )
                );
            }
        }
    }

    function singleXChainSingleVaultDeposit(
        SingleXChainSingleVaultStateReq memory req
    ) public payable override {
        ActionLocalVars memory vars;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId == vars.dstChainId)
            revert Error.INVALID_CHAIN_IDS();

        /// @dev validate superFormsData

        if (!_validateSuperFormData(vars.dstChainId, req.superFormData))
            revert Error.INVALID_SUPERFORMS_DATA();

        totalTransactions++;
        vars.currentTotalTransactions = totalTransactions;
        LiqRequest memory emptyRequest;
        /// @dev write amb message
        vars.ambMessage = AMBMessage(
            _packTxInfo(
                uint120(TransactionType.DEPOSIT),
                uint120(CallbackType.INIT),
                false,
                STATE_REGISTRY_TYPE
            ),
            abi.encode(
                InitSingleVaultData(
                    _packTxData(
                        vars.srcSender,
                        vars.srcChainId,
                        vars.currentTotalTransactions
                    ),
                    req.superFormData.superFormId,
                    req.superFormData.amount,
                    req.superFormData.maxSlippage,
                    emptyRequest,
                    req.superFormData.extraFormData
                )
            )
        );

        vars.liqRequest = req.superFormData.liqRequest;

        (address superForm, , ) = _getSuperForm(req.superFormData.superFormId);

        IBridgeValidator(
            superRegistry.getBridgeValidator(vars.liqRequest.bridgeId)
        ).validateTxData(
                vars.liqRequest.txData,
                vars.srcChainId,
                vars.dstChainId,
                true,
                superForm,
                vars.srcSender
            );

        /// @dev dispatch liquidity data
        dispatchTokens(
            superRegistry.getBridgeAddress(vars.liqRequest.bridgeId),
            vars.liqRequest.txData,
            vars.liqRequest.token,
            vars.liqRequest.amount,
            vars.srcSender,
            vars.liqRequest.nativeAmount,
            vars.liqRequest.permit2data,
            superRegistry.PERMIT2()
        );

        IBaseStateRegistry(superRegistry.coreStateRegistry()).dispatchPayload{
            value: req.gasToPay
        }(
            req.ambIds,
            vars.dstChainId,
            abi.encode(vars.ambMessage),
            req.extraData
        );
        txHistory[vars.currentTotalTransactions] = vars.ambMessage;

        emit CrossChainInitiated(vars.currentTotalTransactions);
    }

    function singleDirectSingleVaultDeposit(
        SingleDirectSingleVaultStateReq memory req
    ) public payable override {
        ActionLocalVars memory vars;
        InitSingleVaultData memory ambData;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId != vars.dstChainId)
            revert Error.INVALID_CHAIN_IDS();

        /// @dev validate superFormsData

        if (!_validateSuperFormData(vars.dstChainId, req.superFormData))
            revert Error.INVALID_SUPERFORMS_DATA();

        totalTransactions++;
        vars.currentTotalTransactions = totalTransactions;
        LiqRequest memory emptyRequest;

        ambData = InitSingleVaultData(
            _packTxData(
                vars.srcSender,
                vars.srcChainId,
                vars.currentTotalTransactions
            ),
            req.superFormData.superFormId,
            req.superFormData.amount,
            req.superFormData.maxSlippage,
            emptyRequest,
            req.superFormData.extraFormData
        );

        /// @dev same chain action

        _directSingleDeposit(
            vars.srcSender,
            req.superFormData.liqRequest,
            ambData
        );

        emit Completed(vars.currentTotalTransactions);
    }

    /// @inheritdoc ISuperRouter
    function multiDstMultiVaultWithdraw(
        MultiDstMultiVaultsStateReq calldata req
    ) external payable override {
        uint256 nDestinations = req.dstChainIds.length;
        MultiDstExtraData memory d = abi.decode(
            req.extraData,
            (MultiDstExtraData)
        );
        for (uint256 i = 0; i < nDestinations; i++) {
            singleDstMultiVaultWithdraw(
                SingleDstMultiVaultsStateReq(
                    req.ambIds,
                    req.dstChainIds[i],
                    d.gasPerDst[i],
                    req.superFormsData[i],
                    d.extraDataPerDst[i]
                )
            );
        }
    }

    /// @inheritdoc ISuperRouter
    function singleDstMultiVaultWithdraw(
        SingleDstMultiVaultsStateReq memory req
    ) public payable override {
        ActionLocalVars memory vars;
        InitMultiVaultData memory ambData;
        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        /// @dev validate superFormsData
        if (!_validateSuperFormsWithdrawData(req.superFormsData))
            revert Error.INVALID_SUPERFORMS_DATA();

        /// @dev burn SuperPositions
        ISuperPositions(superRegistry.superPositions()).burnBatchSP(
            vars.srcSender,
            req.superFormsData.superFormIds,
            req.superFormsData.amounts
        );

        totalTransactions++;
        vars.currentTotalTransactions = totalTransactions;

        /// @dev write packed txData

        ambData = InitMultiVaultData(
            _packTxData(
                vars.srcSender,
                vars.srcChainId,
                vars.currentTotalTransactions
            ),
            req.superFormsData.superFormIds,
            req.superFormsData.amounts,
            req.superFormsData.maxSlippage,
            req.superFormsData.liqRequests,
            req.superFormsData.extraFormData
        );

        /// @dev write amb message
        vars.ambMessage = AMBMessage(
            _packTxInfo(
                uint120(TransactionType.WITHDRAW),
                uint120(CallbackType.INIT),
                true,
                STATE_REGISTRY_TYPE
            ),
            abi.encode(ambData)
        );

        /// @dev same chain action
        if (vars.srcChainId == vars.dstChainId) {
            _directMultiWithdraw(req.superFormsData.liqRequests, ambData);
            emit Completed(vars.currentTotalTransactions);
        } else {
            /// @dev _liqReq should have path encoded for withdraw to SuperRouter on chain different than chainId
            /// @dev construct txData in this fashion: from FTM SOURCE send message to BSC DESTINATION
            /// @dev so that BSC DISPATCHTOKENS sends tokens to AVAX receiver (EOA/contract/user-specified)
            /// @dev sync could be a problem, how long Socket path stays vaild vs. how fast we bridge/receive on Dst
            IBaseStateRegistry(superRegistry.coreStateRegistry())
                .dispatchPayload{value: req.gasToPay}(
                req.ambIds,
                vars.dstChainId,
                abi.encode(vars.ambMessage),
                req.extraData
            );
            txHistory[vars.currentTotalTransactions] = vars.ambMessage;

            emit CrossChainInitiated(vars.currentTotalTransactions);
        }
    }

    /// @inheritdoc ISuperRouter
    function multiDstSingleVaultWithdraw(
        MultiDstSingleVaultStateReq calldata req
    ) external payable override {
        uint16 dstChainId;
        uint256 nDestinations = req.dstChainIds.length;

        MultiDstExtraData memory d = abi.decode(
            req.extraData,
            (MultiDstExtraData)
        );

        for (uint256 i = 0; i < nDestinations; i++) {
            dstChainId = req.dstChainIds[i];
            if (superRegistry.chainId() == dstChainId) {
                singleDirectSingleVaultWithdraw(
                    SingleDirectSingleVaultStateReq(
                        dstChainId,
                        req.superFormsData[i],
                        req.extraData
                    )
                );
            } else {
                singleXChainSingleVaultWithdraw(
                    SingleXChainSingleVaultStateReq(
                        req.ambIds,
                        dstChainId,
                        d.gasPerDst[i],
                        req.superFormsData[i],
                        d.extraDataPerDst[i]
                    )
                );
            }
        }
    }

    /// @inheritdoc ISuperRouter
    function singleXChainSingleVaultWithdraw(
        SingleXChainSingleVaultStateReq memory req
    ) public payable override {
        ActionLocalVars memory vars;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId == vars.dstChainId)
            revert Error.INVALID_CHAIN_IDS();

        /// @dev validate superFormsData
        if (!_validateSuperFormData(vars.dstChainId, req.superFormData))
            revert Error.INVALID_SUPERFORMS_DATA();

        /// @dev burn SuperPositions
        ISuperPositions(superRegistry.superPositions()).burnSingleSP(
            vars.srcSender,
            req.superFormData.superFormId,
            req.superFormData.amount
        );

        totalTransactions++;
        vars.currentTotalTransactions = totalTransactions;

        /// @dev write amb message
        vars.ambMessage = AMBMessage(
            _packTxInfo(
                uint120(TransactionType.WITHDRAW),
                uint120(CallbackType.INIT),
                false,
                STATE_REGISTRY_TYPE
            ),
            abi.encode(
                InitSingleVaultData(
                    _packTxData(
                        vars.srcSender,
                        vars.srcChainId,
                        vars.currentTotalTransactions
                    ),
                    req.superFormData.superFormId,
                    req.superFormData.amount,
                    req.superFormData.maxSlippage,
                    req.superFormData.liqRequest,
                    req.superFormData.extraFormData
                )
            )
        );

        IBaseStateRegistry(superRegistry.coreStateRegistry()).dispatchPayload{
            value: req.gasToPay
        }(
            req.ambIds,
            vars.dstChainId,
            abi.encode(vars.ambMessage),
            req.extraData
        );

        txHistory[vars.currentTotalTransactions] = vars.ambMessage;

        emit CrossChainInitiated(vars.currentTotalTransactions);
    }

    /// @inheritdoc ISuperRouter
    function singleDirectSingleVaultWithdraw(
        SingleDirectSingleVaultStateReq memory req
    ) public payable override {
        ActionLocalVars memory vars;
        InitSingleVaultData memory ambData;

        vars.srcSender = msg.sender;

        vars.srcChainId = superRegistry.chainId();
        vars.dstChainId = req.dstChainId;

        if (vars.srcChainId != vars.dstChainId)
            revert Error.INVALID_CHAIN_IDS();

        /// @dev validate superFormsData

        if (!_validateSuperFormData(vars.dstChainId, req.superFormData))
            revert Error.INVALID_SUPERFORMS_DATA();

        /// @dev burn SuperPositions
        ISuperPositions(superRegistry.superPositions()).burnSingleSP(
            vars.srcSender,
            req.superFormData.superFormId,
            req.superFormData.amount
        );

        totalTransactions++;
        vars.currentTotalTransactions = totalTransactions;

        ambData = InitSingleVaultData(
            _packTxData(
                vars.srcSender,
                vars.srcChainId,
                vars.currentTotalTransactions
            ),
            req.superFormData.superFormId,
            req.superFormData.amount,
            req.superFormData.maxSlippage,
            req.superFormData.liqRequest,
            req.superFormData.extraFormData
        );

        /// @dev same chain action

        _directSingleWithdraw(req.superFormData.liqRequest, ambData);

        emit Completed(vars.currentTotalTransactions);
    }

    function _directDeposit(
        address superForm,
        uint256 txData_,
        uint256 superFormId_,
        uint256 amount_,
        uint256 maxSlippage_,
        LiqRequest memory liqData_,
        bytes memory extraFormData_,
        uint256 msgValue_
    ) internal returns (uint256 dstAmount) {
        /// @dev deposits collateral to a given vault and mint vault positions.
        /// @dev FIXME: in multi deposits we split the msg.value, but this only works if we validate that the user is only depositing from one source asset (native in this case)
        dstAmount = IBaseForm(superForm).directDepositIntoVault{
            value: msgValue_
        }(
            InitSingleVaultData(
                txData_,
                superFormId_,
                amount_,
                maxSlippage_,
                liqData_,
                extraFormData_
            )
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
            ambData_.txData,
            ambData_.superFormId,
            ambData_.amount,
            ambData_.maxSlippage,
            liqRequest_,
            ambData_.extraFormData,
            msg.value
        );

        /// @dev TEST-CASE: msg.sender to whom we mint. use passed `admin` arg?
        ISuperPositions(superRegistry.superPositions()).mintSingleSP(
            srcSender_,
            ambData_.superFormId,
            dstAmount,
            ""
        );
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
                ambData_.txData,
                ambData_.superFormIds[i],
                ambData_.amounts[i],
                ambData_.maxSlippage[i],
                liqRequests_[i],
                ambData_.extraFormData,
                msg.value / len /// @dev FIXME: is this acceptable ? Note that the user fully controls the msg.value being sent
            );
        }

        /// @dev TEST-CASE: msg.sender to whom we mint. use passed `admin` arg?
        ISuperPositions(superRegistry.superPositions()).mintBatchSP(
            srcSender_,
            ambData_.superFormIds,
            dstAmounts,
            ""
        );
    }

    function _directWithdraw(
        address superForm,
        uint256 txData_,
        uint256 superFormId_,
        uint256 amount_,
        uint256 maxSlippage_,
        LiqRequest memory liqData_,
        bytes memory extraFormData_
    ) internal {
        /// @dev to allow bridging somewhere else requires arch change
        IBaseForm(superForm).directWithdrawFromVault(
            InitSingleVaultData(
                txData_,
                superFormId_,
                amount_,
                maxSlippage_,
                liqData_,
                extraFormData_
            )
        );
    }

    /**
     * @notice withdraw() to vaults existing on the same chain as SuperRouter
     * @dev Optimistic transfer & call
     */
    function _directSingleWithdraw(
        LiqRequest memory liqRequest_,
        InitSingleVaultData memory ambData_
    ) internal {
        /// @dev decode superforms
        (address superForm, , ) = _getSuperForm(ambData_.superFormId);

        _directWithdraw(
            superForm,
            ambData_.txData,
            ambData_.superFormId,
            ambData_.amount,
            ambData_.maxSlippage,
            liqRequest_,
            ambData_.extraFormData
        );
    }

    /**
     * @notice withdraw() to vaults existing on the same chain as SuperRouter
     * @dev Optimistic transfer & call
     */
    function _directMultiWithdraw(
        LiqRequest[] memory liqRequests_,
        InitMultiVaultData memory ambData_
    ) internal {
        /// @dev decode superforms
        (address[] memory superForms, , ) = _getSuperForms(
            ambData_.superFormIds
        );

        for (uint256 i = 0; i < superForms.length; i++) {
            /// @dev deposits collateral to a given vault and mint vault positions.
            _directWithdraw(
                superForms[i],
                ambData_.txData,
                ambData_.superFormIds[i],
                ambData_.amounts[i],
                ambData_.maxSlippage[i],
                liqRequests_[i],
                ambData_.extraFormData
            );
        }
    }

    /// @dev allows registry contract to send payload for processing to the router contract.
    /// @param data_ is the received information to be processed.
    function stateMultiSync(AMBMessage memory data_) external payable override {
        if (msg.sender != superRegistry.coreStateRegistry())
            revert Error.REQUEST_DENIED();

        (uint256 txType, uint256 callbackType, , ) = _decodeTxInfo(
            data_.txInfo
        );

        if (callbackType != uint256(CallbackType.RETURN))
            revert Error.INVALID_PAYLOAD();

        ReturnMultiData memory returnData = abi.decode(
            data_.params,
            (ReturnMultiData)
        );

        (, , , uint80 returnTxId) = _decodeReturnTxInfo(
            returnData.returnTxInfo
        );
        AMBMessage memory stored = txHistory[returnTxId];

        (, , bool multi, ) = _decodeTxInfo(stored.txInfo);

        if (!multi) revert Error.INVALID_PAYLOAD();

        (
            bool status,
            uint16 returnDataSrcChainId,
            uint16 returnDataDstChainId,
            uint80 returnDataTxId
        ) = _decodeReturnTxInfo(returnData.returnTxInfo);

        InitMultiVaultData memory multiVaultData = abi.decode(
            stored.params,
            (InitMultiVaultData)
        );
        (address srcSender, uint16 srcChainId, ) = _decodeTxData(
            multiVaultData.txData
        );

        if (returnDataSrcChainId != srcChainId)
            revert Error.SRC_CHAIN_IDS_MISMATCH();

        if (
            returnDataDstChainId !=
            _getDestinationChain(multiVaultData.superFormIds[0])
        ) revert Error.DST_CHAIN_IDS_MISMATCH();

        if (txType == uint256(TransactionType.DEPOSIT) && status) {
            ISuperPositions(superRegistry.superPositions()).mintBatchSP(
                srcSender,
                multiVaultData.superFormIds,
                returnData.amounts,
                ""
            );
        } else if (txType == uint256(TransactionType.WITHDRAW) && !status) {
            ISuperPositions(superRegistry.superPositions()).mintBatchSP(
                srcSender,
                multiVaultData.superFormIds,
                returnData.amounts,
                ""
            );
        } else {
            revert Error.INVALID_PAYLOAD_STATUS();
        }

        emit Completed(returnDataTxId);
    }

    /// @dev allows registry contract to send payload for processing to the router contract.
    /// @param data_ is the received information to be processed.
    function stateSync(AMBMessage memory data_) external payable override {
        if (msg.sender != superRegistry.coreStateRegistry())
            revert Error.REQUEST_DENIED();

        (uint256 txType, uint256 callbackType, , ) = _decodeTxInfo(
            data_.txInfo
        );

        if (callbackType != uint256(CallbackType.RETURN))
            revert Error.INVALID_PAYLOAD();

        ReturnSingleData memory returnData = abi.decode(
            data_.params,
            (ReturnSingleData)
        );

        (, , , uint80 returnTxId) = _decodeReturnTxInfo(
            returnData.returnTxInfo
        );
        AMBMessage memory stored = txHistory[returnTxId];
        (, , bool multi, ) = _decodeTxInfo(stored.txInfo);

        if (multi) revert Error.INVALID_PAYLOAD();

        (
            bool status,
            uint16 returnDataSrcChainId,
            uint16 returnDataDstChainId,
            uint80 returnDataTxId
        ) = _decodeReturnTxInfo(returnData.returnTxInfo);

        InitSingleVaultData memory singleVaultData = abi.decode(
            stored.params,
            (InitSingleVaultData)
        );
        (address srcSender, uint16 srcChainId, ) = _decodeTxData(
            singleVaultData.txData
        );

        if (returnDataSrcChainId != srcChainId)
            revert Error.SRC_CHAIN_IDS_MISMATCH();

        if (
            returnDataDstChainId !=
            _getDestinationChain(singleVaultData.superFormId)
        ) revert Error.DST_CHAIN_IDS_MISMATCH();

        if (txType == uint256(TransactionType.DEPOSIT) && status) {
            ISuperPositions(superRegistry.superPositions()).mintSingleSP(
                srcSender,
                singleVaultData.superFormId,
                returnData.amount,
                ""
            );
        } else if (txType == uint256(TransactionType.WITHDRAW) && !status) {
            /// @dev FIXME: need to create returnData MULTI AMOUNTS and update this to _mint
            ISuperPositions(superRegistry.superPositions()).mintSingleSP(
                srcSender,
                singleVaultData.superFormId,
                returnData.amount,
                ""
            );
        } else {
            revert Error.INVALID_PAYLOAD_STATUS();
        }

        emit Completed(returnDataTxId);
    }

    /*///////////////////////////////////////////////////////////////
                            DEV FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev PREVILEGED admin ONLY FUNCTION.
    /// @notice should be removed after end-to-end testing.
    /// @dev allows admin to withdraw lost tokens in the smart contract.
    function withdrawToken(
        address _tokenContract,
        uint256 _amount
    ) external onlyProtocolAdmin {
        ERC20 tokenContract = ERC20(_tokenContract);

        /// note: transfer the token from address of this contract
        /// note: to address of the user (executing the withdrawToken() function)
        tokenContract.safeTransfer(superRegistry.protocolAdmin(), _amount);
    }

    /// @dev PREVILEGED admin ONLY FUNCTION.
    /// @dev allows admin to withdraw lost native tokens in the smart contract.
    function withdrawNativeToken(uint256 _amount) external onlyProtocolAdmin {
        payable(superRegistry.protocolAdmin()).transfer(_amount);
    }

    /*///////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev validates slippage parameter;
    /// slippages should always be within 0 - 100
    /// decimal is handles in the form of 10s
    /// for eg. 0.05 = 5
    ///       100 = 10000
    function _validateSlippage(
        uint256[] calldata slippages_
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < slippages_.length; i++) {
            if (slippages_[i] < 0 || slippages_[i] > 10000) {
                return false;
            }
        }
        return true;
    }

    function _validateSuperFormData(
        uint16 dstChainId_,
        SingleVaultSFData memory superFormData_
    ) internal view returns (bool) {
        if (dstChainId_ != _getDestinationChain(superFormData_.superFormId))
            return false;

        if (superFormData_.maxSlippage > 10000) return false;

        (, uint256 formBeaconId_, ) = _getSuperForm(superFormData_.superFormId);

        if (
            IFormBeacon(
                ISuperFormFactory(superRegistry.superFormFactory())
                    .getFormBeacon(formBeaconId_)
            ).paused()
        ) return false;

        /// @dev TODO validate TxData to avoid exploits

        return true;
    }

    function _validateSuperFormsDepositData(
        MultiVaultsSFData memory superFormsData_
    ) internal view returns (bool) {
        uint256 len = superFormsData_.amounts.length;
        uint256 liqRequestsLen = superFormsData_.liqRequests.length;

        if (len == 0 || liqRequestsLen == 0) return false;

        uint256 sumAmounts;
        /// @dev size validation
        if (
            !(superFormsData_.superFormIds.length ==
                superFormsData_.amounts.length &&
                superFormsData_.superFormIds.length ==
                superFormsData_.maxSlippage.length)
        ) {
            return false;
        }
        (address firstSuperForm, , ) = _getSuperForm(
            superFormsData_.superFormIds[0]
        );
        address collateral = address(
            IBaseForm(firstSuperForm).getUnderlyingOfVault()
        );

        if (collateral == address(0)) return false;

        for (uint256 i = 0; i < len; i++) {
            if (superFormsData_.maxSlippage[i] > 10000) return false;
            sumAmounts += superFormsData_.amounts[i];
            (, uint256 formBeaconId_, ) = _getSuperForm(
                superFormsData_.superFormIds[i]
            );
            if (
                IFormBeacon(
                    ISuperFormFactory(superRegistry.superFormFactory())
                        .getFormBeacon(formBeaconId_)
                ).paused()
            ) return false;

            /// @dev compare underlyings with the first superForm. If there is at least one different mark collateral as 0
            if (collateral != address(0) && i + 1 < len) {
                (address superForm, , ) = _getSuperForm(
                    superFormsData_.superFormIds[i + 1]
                );

                if (
                    collateral !=
                    address(IBaseForm(superForm).getUnderlyingOfVault())
                ) collateral = address(0);
            }
        }

        /// @dev TODO validate TxData to avoid exploits

        /// @dev In multiVaults, if there is only one liqRequest, then the sum of the amounts must be equal to the amount in the liqRequest and all underlyings must be equal
        if (
            liqRequestsLen == 1 &&
            (liqRequestsLen != len) &&
            (superFormsData_.liqRequests[0].amount == sumAmounts) &&
            collateral == address(0)
        ) {
            return false;
            /// @dev else if number of liq request >1, length must be equal to the number of superForms sent in this request
        } else if (liqRequestsLen > 1) {
            if (liqRequestsLen != len) {
                return false;
            }
        }

        return true;
    }

    function _validateSuperFormsWithdrawData(
        MultiVaultsSFData memory superFormsData_
    ) internal view returns (bool) {
        uint256 len = superFormsData_.amounts.length;
        uint256 liqRequestsLen = superFormsData_.liqRequests.length;

        if (len == 0 || liqRequestsLen == 0) return false;

        /// @dev size validation
        if (
            !(superFormsData_.superFormIds.length ==
                superFormsData_.amounts.length &&
                superFormsData_.superFormIds.length ==
                superFormsData_.maxSlippage.length)
        ) {
            return false;
        }

        for (uint256 i = 0; i < len; i++) {
            if (superFormsData_.maxSlippage[i] > 10000) return false;
            (, uint256 formBeaconId_, ) = _getSuperForm(
                superFormsData_.superFormIds[i]
            );
            if (
                IFormBeacon(
                    ISuperFormFactory(superRegistry.superFormFactory())
                        .getFormBeacon(formBeaconId_)
                ).paused()
            ) return false;
        }

        /// @dev TODO validate TxData to avoid exploits

        /// @dev In multiVault withdraws, the number of liq requests must be equal to number of target vaults
        if (liqRequestsLen != len) {
            return false;
        }

        return true;
    }
}
