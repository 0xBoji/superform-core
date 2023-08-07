/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBaseStateRegistry} from "./interfaces/IBaseStateRegistry.sol";
import {IPayMaster} from "./interfaces/IPayMaster.sol";
import {ISuperformFactory} from "./interfaces/ISuperformFactory.sol";
import {IBaseForm} from "./interfaces/IBaseForm.sol";
import {ISuperformRouter} from "./interfaces/ISuperformRouter.sol";
import {ISuperRegistry} from "./interfaces/ISuperRegistry.sol";
import {ISuperRBAC} from "./interfaces/ISuperRBAC.sol";
import {IFormBeacon} from "./interfaces/IFormBeacon.sol";
import {IBridgeValidator} from "./interfaces/IBridgeValidator.sol";
import {ISuperPositions} from "./interfaces/ISuperPositions.sol";
import {LiquidityHandler} from "./crosschain-liquidity/LiquidityHandler.sol";
import {DataLib} from "./libraries/DataLib.sol";
import {Error} from "./utils/Error.sol";
import "./types/DataTypes.sol";

/// @title SuperformRouter
/// @author Zeropoint Labs.
/// @dev Routes users funds and action information to a remote execution chain.
/// @dev extends Liquidity Handler.
contract SuperformRouter is ISuperformRouter, LiquidityHandler {
    using SafeERC20 for IERC20;
    using DataLib for uint256;

    /*///////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev SuperformRouter connects to CORE_STATE_REGISTRY (type 1)
    uint8 public constant STATE_REGISTRY_TYPE = 1;
    ISuperRegistry public immutable superRegistry;

    /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev tracks the total payloads
    uint256 public override payloadIds;

    /*///////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProtocolAdmin() {
        if (!ISuperRBAC(superRegistry.superRBAC()).hasProtocolAdminRole(msg.sender)) revert Error.NOT_PROTOCOL_ADMIN();
        _;
    }

    modifier onlyEmergencyAdmin() {
        if (!ISuperRBAC(superRegistry.superRBAC()).hasEmergencyAdminRole(msg.sender))
            revert Error.NOT_EMERGENCY_ADMIN();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param superRegistry_ the superform registry contract
    constructor(address superRegistry_) {
        superRegistry = ISuperRegistry(superRegistry_);
    }

    /*///////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice receive enables processing native token transfers into the smart contract.
    /// @notice liquidity bridge fails without a native receive function.
    receive() external payable {}

    /// @inheritdoc ISuperformRouter
    function multiDstMultiVaultDeposit(MultiDstMultiVaultStateReq calldata req) external payable override {
        uint256 chainId = superRegistry.chainId();
        uint256 balanceBefore = address(this).balance - msg.value;

        for (uint256 i; i < req.dstChainIds.length; ) {
            if (chainId == req.dstChainIds[i]) {
                _singleDirectMultiVaultDeposit(SingleDirectMultiVaultStateReq(req.superFormsData[i]));
            } else {
                _singleXChainMultiVaultDeposit(
                    SingleXChainMultiVaultStateReq(
                        req.ambIds[i],
                        req.dstChainIds[i],
                        req.superFormsData[i],
                        req.extraDataPerDst[i]
                    )
                );
            }
            unchecked {
                ++i;
            }
        }

        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function multiDstSingleVaultDeposit(MultiDstSingleVaultStateReq calldata req) external payable override {
        uint64 srcChainId = superRegistry.chainId();
        uint256 balanceBefore = address(this).balance - msg.value;

        uint64 dstChainId;

        for (uint256 i = 0; i < req.dstChainIds.length; i++) {
            dstChainId = req.dstChainIds[i];
            if (srcChainId == dstChainId) {
                _singleDirectSingleVaultDeposit(SingleDirectSingleVaultStateReq(req.superFormsData[i]));
            } else {
                _singleXChainSingleVaultDeposit(
                    SingleXChainSingleVaultStateReq(
                        req.ambIds[i],
                        dstChainId,
                        req.superFormsData[i],
                        req.extraDataPerDst[i]
                    )
                );
            }
        }

        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleXChainMultiVaultDeposit(SingleXChainMultiVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleXChainMultiVaultDeposit(req);
        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleXChainSingleVaultDeposit(SingleXChainSingleVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleXChainSingleVaultDeposit(req);
        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleDirectSingleVaultDeposit(SingleDirectSingleVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleDirectSingleVaultDeposit(req);
        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleDirectMultiVaultDeposit(SingleDirectMultiVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleDirectMultiVaultDeposit(req);
        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function multiDstMultiVaultWithdraw(MultiDstMultiVaultStateReq calldata req) external payable override {
        uint256 chainId = superRegistry.chainId();
        uint256 balanceBefore = address(this).balance - msg.value;

        for (uint256 i; i < req.dstChainIds.length; ) {
            if (chainId == req.dstChainIds[i]) {
                _singleDirectMultiVaultWithdraw(SingleDirectMultiVaultStateReq(req.superFormsData[i]));
            } else {
                _singleXChainMultiVaultWithdraw(
                    SingleXChainMultiVaultStateReq(
                        req.ambIds[i],
                        req.dstChainIds[i],
                        req.superFormsData[i],
                        req.extraDataPerDst[i]
                    )
                );
            }

            unchecked {
                ++i;
            }
        }

        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function multiDstSingleVaultWithdraw(MultiDstSingleVaultStateReq calldata req) external payable override {
        uint64 dstChainId;
        uint256 balanceBefore = address(this).balance - msg.value;

        for (uint256 i = 0; i < req.dstChainIds.length; i++) {
            dstChainId = req.dstChainIds[i];
            if (superRegistry.chainId() == dstChainId) {
                _singleDirectSingleVaultWithdraw(SingleDirectSingleVaultStateReq(req.superFormsData[i]));
            } else {
                _singleXChainSingleVaultWithdraw(
                    SingleXChainSingleVaultStateReq(
                        req.ambIds[i],
                        dstChainId,
                        req.superFormsData[i],
                        req.extraDataPerDst[i]
                    )
                );
            }
        }

        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleXChainMultiVaultWithdraw(SingleXChainMultiVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleXChainMultiVaultWithdraw(req);
        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleXChainSingleVaultWithdraw(SingleXChainSingleVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleXChainSingleVaultWithdraw(req);
        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleDirectSingleVaultWithdraw(SingleDirectSingleVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleDirectSingleVaultWithdraw(req);
        _forwardFee(balanceBefore);
    }

    /// @inheritdoc ISuperformRouter
    function singleDirectMultiVaultWithdraw(SingleDirectMultiVaultStateReq memory req) external payable override {
        uint256 balanceBefore = address(this).balance - msg.value;

        _singleDirectMultiVaultWithdraw(req);
        _forwardFee(balanceBefore);
    }

    /*///////////////////////////////////////////////////////////////
                        INTERNAL/HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev handles cross-chain multi vault deposit
    function _singleXChainMultiVaultDeposit(SingleXChainMultiVaultStateReq memory req) internal {
        /// @dev validate superFormsData
        if (!_validateSuperformsDepositData(req.superFormsData, req.dstChainId)) revert Error.INVALID_SUPERFORMS_DATA();

        ActionLocalVars memory vars;
        InitMultiVaultData memory ambData;

        vars.srcChainId = superRegistry.chainId();
        vars.currentPayloadId = ++payloadIds;

        ambData = InitMultiVaultData(
            vars.currentPayloadId,
            req.superFormsData.superFormIds,
            req.superFormsData.amounts,
            req.superFormsData.maxSlippages,
            new LiqRequest[](0),
            req.superFormsData.extraFormData
        );

        address permit2 = superRegistry.PERMIT2();
        address superForm;

        /// @dev this loop is what allows to deposit to >1 different underlying on destination
        /// @dev if a loop fails in a validation the whole chain should be reverted
        for (uint256 j = 0; j < req.superFormsData.liqRequests.length; ) {
            vars.liqRequest = req.superFormsData.liqRequests[j];

            (superForm, , ) = req.superFormsData.superFormIds[j].getSuperform();

            /// @dev dispatch liquidity data
            _validateAndDispatchTokens(
                vars.liqRequest,
                permit2,
                superForm,
                vars.srcChainId,
                req.dstChainId,
                msg.sender,
                true
            );
            unchecked {
                ++j;
            }
        }

        /// @dev dispatch message information, notice multiVaults is set to 1
        _dispatchAmbMessage(
            DispatchAMBMessageVars(
                TransactionType.DEPOSIT,
                abi.encode(ambData),
                req.superFormsData.superFormIds,
                req.extraData,
                msg.sender,
                req.ambIds,
                1,
                vars.srcChainId,
                req.dstChainId,
                vars.currentPayloadId
            )
        );

        emit CrossChainInitiated(vars.currentPayloadId);
    }

    /// @dev handles cross-chain single vault deposit
    function _singleXChainSingleVaultDeposit(SingleXChainSingleVaultStateReq memory req) internal {
        ActionLocalVars memory vars;

        vars.srcChainId = superRegistry.chainId();

        /// @dev disallow direct chain actions
        if (vars.srcChainId == req.dstChainId) revert Error.INVALID_CHAIN_IDS();

        InitSingleVaultData memory ambData;

        /// @dev this step validates and returns ambData from the state request
        (ambData, vars.currentPayloadId) = _buildDepositAmbData(req.dstChainId, req.superFormData);

        vars.liqRequest = req.superFormData.liqRequest;
        (address superForm, , ) = req.superFormData.superFormId.getSuperform();

        /// @dev dispatch liquidity data
        _validateAndDispatchTokens(
            vars.liqRequest,
            superRegistry.PERMIT2(),
            superForm,
            vars.srcChainId,
            req.dstChainId,
            msg.sender,
            true
        );

        uint256[] memory superFormIds = new uint256[](1);
        superFormIds[0] = req.superFormData.superFormId;

        /// @dev dispatch message information, notice multiVaults is set to 0
        _dispatchAmbMessage(
            DispatchAMBMessageVars(
                TransactionType.DEPOSIT,
                abi.encode(ambData),
                superFormIds,
                req.extraData,
                msg.sender,
                req.ambIds,
                0,
                vars.srcChainId,
                req.dstChainId,
                vars.currentPayloadId
            )
        );

        emit CrossChainInitiated(vars.currentPayloadId);
    }

    /// @dev handles same-chain single vault deposit
    function _singleDirectSingleVaultDeposit(SingleDirectSingleVaultStateReq memory req) internal {
        ActionLocalVars memory vars;
        vars.srcChainId = superRegistry.chainId();
        vars.currentPayloadId = ++payloadIds;

        InitSingleVaultData memory vaultData = InitSingleVaultData(
            vars.currentPayloadId,
            req.superFormData.superFormId,
            req.superFormData.amount,
            req.superFormData.maxSlippage,
            req.superFormData.liqRequest,
            req.superFormData.extraFormData
        );

        /// @dev same chain action & forward residual fee to fee collector
        _directSingleDeposit(msg.sender, vaultData);
        emit Completed(vars.currentPayloadId);
    }

    /// @dev handles same-chain multi vault deposit
    function _singleDirectMultiVaultDeposit(SingleDirectMultiVaultStateReq memory req) internal {
        ActionLocalVars memory vars;
        vars.srcChainId = superRegistry.chainId();
        vars.currentPayloadId = ++payloadIds;

        InitMultiVaultData memory vaultData = InitMultiVaultData(
            vars.currentPayloadId,
            req.superFormData.superFormIds,
            req.superFormData.amounts,
            req.superFormData.maxSlippages,
            req.superFormData.liqRequests,
            req.superFormData.extraFormData
        );

        /// @dev same chain action & forward residual fee to fee collector
        _directMultiDeposit(msg.sender, vaultData);
        emit Completed(vars.currentPayloadId);
    }

    /// @dev handles cross-chain multi vault withdraw
    function _singleXChainMultiVaultWithdraw(SingleXChainMultiVaultStateReq memory req) internal {
        /// @dev validate superFormsData
        if (!_validateSuperformsWithdrawData(req.superFormsData, req.dstChainId))
            revert Error.INVALID_SUPERFORMS_DATA();

        ISuperPositions(superRegistry.superPositions()).burnBatchSP(
            msg.sender,
            req.superFormsData.superFormIds,
            req.superFormsData.amounts
        );

        ActionLocalVars memory vars;
        InitMultiVaultData memory ambData;

        vars.srcChainId = superRegistry.chainId();
        vars.currentPayloadId = ++payloadIds;

        /// @dev write packed txData
        ambData = InitMultiVaultData(
            vars.currentPayloadId,
            req.superFormsData.superFormIds,
            req.superFormsData.amounts,
            req.superFormsData.maxSlippages,
            req.superFormsData.liqRequests,
            req.superFormsData.extraFormData
        );

        /// @dev dispatch message information, notice multiVaults is set to 1
        _dispatchAmbMessage(
            DispatchAMBMessageVars(
                TransactionType.WITHDRAW,
                abi.encode(ambData),
                req.superFormsData.superFormIds,
                req.extraData,
                msg.sender,
                req.ambIds,
                1,
                vars.srcChainId,
                req.dstChainId,
                vars.currentPayloadId
            )
        );

        emit CrossChainInitiated(vars.currentPayloadId);
    }

    /// @dev handles cross-chain single vault withdraw
    function _singleXChainSingleVaultWithdraw(SingleXChainSingleVaultStateReq memory req) internal {
        ActionLocalVars memory vars;

        vars.srcChainId = superRegistry.chainId();
        if (vars.srcChainId == req.dstChainId) revert Error.INVALID_CHAIN_IDS();

        InitSingleVaultData memory ambData;

        /// @dev this step validates and returns ambData from the state request
        (ambData, vars.currentPayloadId) = _buildWithdrawAmbData(msg.sender, req.dstChainId, req.superFormData);

        uint256[] memory superFormIds = new uint256[](1);
        superFormIds[0] = req.superFormData.superFormId;

        /// @dev dispatch message information, notice multiVaults is set to 0
        _dispatchAmbMessage(
            DispatchAMBMessageVars(
                TransactionType.WITHDRAW,
                abi.encode(ambData),
                superFormIds,
                req.extraData,
                msg.sender,
                req.ambIds,
                0,
                vars.srcChainId,
                req.dstChainId,
                vars.currentPayloadId
            )
        );

        emit CrossChainInitiated(vars.currentPayloadId);
    }

    /// @dev handles same-chain single vault withdraw
    function _singleDirectSingleVaultWithdraw(SingleDirectSingleVaultStateReq memory req) internal {
        ActionLocalVars memory vars;
        vars.srcChainId = superRegistry.chainId();

        InitSingleVaultData memory ambData;

        (ambData, vars.currentPayloadId) = _buildWithdrawAmbData(msg.sender, vars.srcChainId, req.superFormData);

        /// @dev same chain action
        _directSingleWithdraw(ambData, msg.sender);
        emit Completed(vars.currentPayloadId);
    }

    /// @dev handles same-chain multi vault withdraw
    function _singleDirectMultiVaultWithdraw(SingleDirectMultiVaultStateReq memory req) internal {
        ActionLocalVars memory vars;
        vars.srcChainId = superRegistry.chainId();
        vars.currentPayloadId = ++payloadIds;

        /// @dev SuperPositions are burnt optimistically here
        ISuperPositions(superRegistry.superPositions()).burnBatchSP(
            msg.sender,
            req.superFormData.superFormIds,
            req.superFormData.amounts
        );

        InitMultiVaultData memory vaultData = InitMultiVaultData(
            vars.currentPayloadId,
            req.superFormData.superFormIds,
            req.superFormData.amounts,
            req.superFormData.maxSlippages,
            req.superFormData.liqRequests,
            req.superFormData.extraFormData
        );

        /// @dev same chain action & forward residual fee to fee collector
        _directMultiWithdraw(vaultData, msg.sender);
        emit Completed(vars.currentPayloadId);
    }

    /*///////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev internal function used for validation and ambData building across different entry points
    function _buildDepositAmbData(
        uint64 dstChainId_,
        SingleVaultSFData memory superFormData_
    ) internal returns (InitSingleVaultData memory ambData, uint256 currentPayloadId) {
        /// @dev validate superFormsData
        if (!_validateSuperformData(dstChainId_, superFormData_)) revert Error.INVALID_SUPERFORMS_DATA();

        if (
            !IBridgeValidator(superRegistry.getBridgeValidator(superFormData_.liqRequest.bridgeId))
                .validateTxDataAmount(superFormData_.liqRequest.txData, superFormData_.amount)
        ) revert Error.INVALID_TXDATA_AMOUNTS();

        currentPayloadId = ++payloadIds;
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
        uint64 dstChainId_,
        SingleVaultSFData memory superFormData_
    ) internal returns (InitSingleVaultData memory ambData, uint256 currentPayloadId) {
        /// @dev validate superFormsData
        if (!_validateSuperformData(dstChainId_, superFormData_)) revert Error.INVALID_SUPERFORMS_DATA();

        ISuperPositions(superRegistry.superPositions()).burnSingleSP(
            srcSender_,
            superFormData_.superFormId,
            superFormData_.amount
        );

        currentPayloadId = ++payloadIds;

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
        /// @dev validates remaining params of txData
        IBridgeValidator(superRegistry.getBridgeValidator(liqRequest_.bridgeId)).validateTxData(
            liqRequest_.txData,
            srcChainId_,
            dstChainId_,
            deposit_,
            superForm_,
            srcSender_,
            liqRequest_.token
        );

        /// @dev dispatches tokens through the selected liquidity bridge to the destnation contract (CoreStateRegistry or MultiTxProcessor)
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

    function _dispatchAmbMessage(DispatchAMBMessageVars memory vars) internal {
        AMBMessage memory ambMessage = AMBMessage(
            DataLib.packTxInfo(
                uint8(vars.txType),
                uint8(CallbackType.INIT),
                vars.multiVaults,
                STATE_REGISTRY_TYPE,
                vars.srcSender,
                vars.srcChainId
            ),
            vars.ambData
        );
        SingleDstAMBParams memory ambParams = abi.decode(vars.extraData, (SingleDstAMBParams));

        /// @dev this call dispatches the message to the AMB bridge through dispatchPayload
        IBaseStateRegistry(superRegistry.coreStateRegistry()).dispatchPayload{value: ambParams.gasToPay}(
            vars.srcSender,
            vars.ambIds,
            vars.dstChainId,
            abi.encode(ambMessage),
            ambParams.encodedAMBExtraData
        );

        ISuperPositions(superRegistry.superPositions()).updateTxHistory(vars.currentPayloadId, ambMessage.txInfo);
    }

    /*///////////////////////////////////////////////////////////////
                            DEPOSIT HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice deposits to single vault on the same chain
    /// @dev calls `_directDeposit`
    function _directSingleDeposit(address srcSender_, InitSingleVaultData memory vaultData_) internal {
        address superForm;
        uint256 dstAmount;

        /// @dev decode superforms
        (superForm, , ) = vaultData_.superFormId.getSuperform();

        /// @dev deposits collateral to a given vault and mint vault positions.
        dstAmount = _directDeposit(
            superForm,
            vaultData_.payloadId,
            vaultData_.superFormId,
            vaultData_.amount,
            vaultData_.maxSlippage,
            vaultData_.liqData,
            vaultData_.extraFormData,
            vaultData_.liqData.nativeAmount,
            srcSender_
        );

        /// @dev mint super positions at the end of the deposit action
        ISuperPositions(superRegistry.superPositions()).mintSingleSP(srcSender_, vaultData_.superFormId, dstAmount);
    }

    /// @notice deposits to multiple vaults on the same chain
    /// @dev loops and call `_directDeposit`
    function _directMultiDeposit(address srcSender_, InitMultiVaultData memory vaultData_) internal {
        uint256 len = vaultData_.superFormIds.length;

        address[] memory superForms = new address[](len);
        uint256[] memory dstAmounts = new uint256[](len);

        /// @dev decode superforms
        (superForms, , ) = DataLib.getSuperforms(vaultData_.superFormIds);

        for (uint256 i; i < len; ) {
            /// @dev deposits collateral to a given vault and mint vault positions.
            dstAmounts[i] = _directDeposit(
                superForms[i],
                vaultData_.payloadId,
                vaultData_.superFormIds[i],
                vaultData_.amounts[i],
                vaultData_.maxSlippage[i],
                vaultData_.liqData[i],
                vaultData_.extraFormData,
                vaultData_.liqData[i].nativeAmount,
                srcSender_
            );

            unchecked {
                ++i;
            }
        }

        /// @dev in direct deposits, SuperPositions are minted right after depositing to vaults
        ISuperPositions(superRegistry.superPositions()).mintBatchSP(srcSender_, vaultData_.superFormIds, dstAmounts);
    }

    /// @notice fulfils the final stage of same chain deposit action
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
        /// @dev validates if superFormId exists on factory
        (, , uint64 chainId) = ISuperformFactory(superRegistry.superFormFactory()).getSuperform(superFormId_);

        if (chainId != superRegistry.chainId()) {
            revert Error.INVALID_CHAIN_ID();
        }

        /// @dev deposits collateral to a given vault and mint vault positions directly through the form
        dstAmount = IBaseForm(superForm).directDepositIntoVault{value: msgValue_}(
            InitSingleVaultData(payloadId_, superFormId_, amount_, maxSlippage_, liqData_, extraFormData_),
            srcSender_
        );
    }

    /*///////////////////////////////////////////////////////////////
                            WITHDRAW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice withdraws from single vault on the same chain
    /// @dev call `_directWithdraw`
    function _directSingleWithdraw(InitSingleVaultData memory vaultData_, address srcSender_) internal {
        /// @dev decode superforms
        (address superForm, , ) = vaultData_.superFormId.getSuperform();

        _directWithdraw(
            superForm,
            vaultData_.payloadId,
            vaultData_.superFormId,
            vaultData_.amount,
            vaultData_.maxSlippage,
            vaultData_.liqData,
            vaultData_.extraFormData,
            srcSender_
        );
    }

    /// @notice withdraws from multiple vaults on the same chain
    /// @dev loops and call `_directWithdraw`
    function _directMultiWithdraw(InitMultiVaultData memory vaultData_, address srcSender_) internal {
        /// @dev decode superforms
        (address[] memory superForms, , ) = DataLib.getSuperforms(vaultData_.superFormIds);

        for (uint256 i; i < superForms.length; ) {
            /// @dev deposits collateral to a given vault and mint vault positions.
            _directWithdraw(
                superForms[i],
                vaultData_.payloadId,
                vaultData_.superFormIds[i],
                vaultData_.amounts[i],
                vaultData_.maxSlippage[i],
                vaultData_.liqData[i],
                vaultData_.extraFormData,
                srcSender_
            );

            unchecked {
                ++i;
            }
        }
    }

    /// @notice fulfils the final stage of same chain withdrawal action
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
        /// @dev validates if superFormId exists on factory
        (, , uint64 chainId) = ISuperformFactory(superRegistry.superFormFactory()).getSuperform(superFormId_);

        if (chainId != superRegistry.chainId()) {
            revert Error.INVALID_CHAIN_ID();
        }

        /// @dev in direct withdraws, form is called directly
        IBaseForm(superForm).directWithdrawFromVault(
            InitSingleVaultData(txData_, superFormId_, amount_, maxSlippage_, liqData_, extraFormData_),
            srcSender_
        );
    }

    /*///////////////////////////////////////////////////////////////
                            VALIDATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _validateSuperformData(
        uint64 dstChainId_,
        SingleVaultSFData memory superFormData_
    ) internal view returns (bool) {
        /// @dev the dstChainId_ (in the state request) must match the superForms' chainId (superForm must exist on destinatiom)
        if (dstChainId_ != DataLib.getDestinationChain(superFormData_.superFormId)) return false;

        /// @dev 10000 = 100% slippage
        if (superFormData_.maxSlippage > 10000) return false;

        (, uint32 formBeaconId_, ) = superFormData_.superFormId.getSuperform();

        return !IFormBeacon(ISuperformFactory(superRegistry.superFormFactory()).getFormBeacon(formBeaconId_)).paused();
    }

    function _validateSuperformsDepositData(
        MultiVaultSFData memory superFormsData_,
        uint64 dstChainId
    ) internal view returns (bool) {
        uint256 len = superFormsData_.amounts.length;
        uint256 liqRequestsLen = superFormsData_.liqRequests.length;

        /// @dev empty requests are not allowed, as well as requests with length mismatch
        if (len == 0 || liqRequestsLen == 0) return false;
        if (len != liqRequestsLen) return false;

        /// @dev superformIds/amounts/slippages array sizes validation
        if (
            !(superFormsData_.superFormIds.length == superFormsData_.amounts.length &&
                superFormsData_.superFormIds.length == superFormsData_.maxSlippages.length)
        ) {
            return false;
        }

        /// @dev slippage, amounts and paused status validation
        bool txDataAmountValid;
        for (uint256 i = 0; i < len; ) {
            /// @dev 10000 = 100% slippage
            if (superFormsData_.maxSlippages[i] > 10000) return false;
            (, uint32 formBeaconId_, uint64 sfDstChainId) = superFormsData_.superFormIds[i].getSuperform();
            if (dstChainId != sfDstChainId) return false;

            if (IFormBeacon(ISuperformFactory(superRegistry.superFormFactory()).getFormBeacon(formBeaconId_)).paused())
                return false;

            /// @dev amounts in liqRequests must match amounts in superFormsData_
            txDataAmountValid = IBridgeValidator(
                superRegistry.getBridgeValidator(superFormsData_.liqRequests[i].bridgeId)
            ).validateTxDataAmount(superFormsData_.liqRequests[i].txData, superFormsData_.amounts[i]);

            if (!txDataAmountValid) return false;

            unchecked {
                ++i;
            }
        }

        return true;
    }

    function _validateSuperformsWithdrawData(
        MultiVaultSFData memory superFormsData_,
        uint64 dstChainId
    ) internal view returns (bool) {
        uint256 len = superFormsData_.amounts.length;
        uint256 liqRequestsLen = superFormsData_.liqRequests.length;

        /// @dev empty requests are not allowed, as well as requests with length mismatch
        if (len == 0 || liqRequestsLen == 0) return false;

        if (liqRequestsLen != len) {
            return false;
        }

        /// @dev superformIds/amounts/slippages array sizes validation
        if (
            !(superFormsData_.superFormIds.length == superFormsData_.amounts.length &&
                superFormsData_.superFormIds.length == superFormsData_.maxSlippages.length)
        ) {
            return false;
        }

        /// @dev slippage and paused status validation
        for (uint256 i; i < len; ) {
            /// @dev 10000 = 100% slippage
            if (superFormsData_.maxSlippages[i] > 10000) return false;
            (, uint32 formBeaconId_, uint64 sfDstChainId) = superFormsData_.superFormIds[i].getSuperform();
            if (dstChainId != sfDstChainId) return false;

            if (IFormBeacon(ISuperformFactory(superRegistry.superFormFactory()).getFormBeacon(formBeaconId_)).paused())
                return false;

            unchecked {
                ++i;
            }
        }

        return true;
    }

    /*///////////////////////////////////////////////////////////////
                        FEE FORWARDING HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev forwards the residual fees to fee collector
    function _forwardFee(uint256 _balanceBefore) internal {
        /// @dev deducts what's already available sends what's left in msg.value to fee collector
        uint256 residualFee = address(this).balance - _balanceBefore;

        if (residualFee > 0) {
            IPayMaster(superRegistry.getPayMaster()).makePayment{value: residualFee}(msg.sender);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev EMERGENCY_ADMIN ONLY FUNCTION.
    /// @dev allows admin to withdraw lost tokens in the smart contract.
    function emergencyWithdrawToken(address tokenContract_, uint256 amount_) external onlyEmergencyAdmin {
        IERC20 tokenContract = IERC20(tokenContract_);

        /// note: transfer the token from address of this contract
        /// note: to address of the user (executing the withdrawToken() function)
        tokenContract.safeTransfer(msg.sender, amount_);
    }

    /// @dev EMERGENCY_ADMIN ONLY FUNCTION.
    /// @dev allows admin to withdraw lost native tokens in the smart contract.
    function emergencyWithdrawNativeToken(uint256 amount_) external onlyEmergencyAdmin {
        (bool success, ) = payable(msg.sender).call{value: amount_}("");
        if (!success) revert Error.NATIVE_TOKEN_TRANSFER_FAILURE();
    }
}
