// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { BaseStateRegistry } from "../BaseStateRegistry.sol";
import { LiquidityHandler } from "../../crosschain-liquidity/LiquidityHandler.sol";
import { IStateSyncer } from "../../interfaces/IStateSyncer.sol";
import { ICoreStateRegistry } from "../../interfaces/ICoreStateRegistry.sol";
import { ISuperRegistry } from "../../interfaces/ISuperRegistry.sol";
import { IQuorumManager } from "../../interfaces/IQuorumManager.sol";
import { IPaymentHelper } from "../../interfaces/IPaymentHelper.sol";
import { IBaseForm } from "../../interfaces/IBaseForm.sol";
import { IBridgeValidator } from "../../interfaces/IBridgeValidator.sol";
import { LiqRequest } from "../../types/DataTypes.sol";
import { ISuperRBAC } from "../../interfaces/ISuperRBAC.sol";
import { DataLib } from "../../libraries/DataLib.sol";
import { PayloadUpdaterLib } from "../../libraries/PayloadUpdaterLib.sol";
import { Error } from "../../utils/Error.sol";

import "../../types/DataTypes.sol";

/// @title CoreStateRegistry
/// @author Zeropoint Labs
/// @dev enables communication between Superform Core Contracts deployed on all supported networks
contract CoreStateRegistry is LiquidityHandler, BaseStateRegistry, ICoreStateRegistry {
    using SafeERC20 for IERC20;
    using DataLib for uint256;

    /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev just stores the superformIds that failed in a specific payload id
    mapping(uint256 payloadId => uint256[] superformIds) internal failedDeposits;

    /*///////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCoreStateRegistryProcessor() {
        if (
            !ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).hasCoreStateRegistryProcessorRole(msg.sender)
        ) revert Error.NOT_PROCESSOR();
        _;
    }

    modifier onlyCoreStateRegistryUpdater() {
        if (!ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).hasCoreStateRegistryUpdaterRole(msg.sender))
        {
            revert Error.NOT_UPDATER();
        }
        _;
    }

    modifier onlySender() override {
        if (superRegistry.getSuperformRouterId(msg.sender) == 0) revert Error.NOT_SUPER_ROUTER();
        _;
    }

    modifier isValidPayloadId(uint256 payloadId_) {
        if (payloadId_ > payloadsCount) {
            revert Error.INVALID_PAYLOAD_ID();
        }
        _;
    }

    /*///////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(ISuperRegistry superRegistry_) BaseStateRegistry(superRegistry_) { }

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoreStateRegistry
    function updateDepositPayload(
        uint256 payloadId_,
        uint256[] calldata finalAmounts_
    )
        external
        virtual
        override
        onlyCoreStateRegistryUpdater
        isValidPayloadId(payloadId_)
    {
        UpdateDepositPayloadVars memory v;

        v.prevPayloadHeader = payloadHeader[payloadId_];
        v.prevPayloadBody = payloadBody[payloadId_];

        v.prevPayloadProof = keccak256(abi.encode(AMBMessage(v.prevPayloadHeader, v.prevPayloadBody)));

        (,, v.isMulti,,, v.srcChainId) = v.prevPayloadHeader.decodeTxInfo();

        if (messageQuorum[v.prevPayloadProof] < getRequiredMessagingQuorum(v.srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        PayloadUpdaterLib.validateDepositPayloadUpdate(v.prevPayloadHeader, payloadTracking[payloadId_], v.isMulti);

        bytes memory newPayloadBody;
        if (v.isMulti != 0) {
            newPayloadBody = _updateMultiVaultDepositPayload(v.prevPayloadBody, finalAmounts_);
        } else {
            newPayloadBody = _updateSingleVaultDepositPayload(v.prevPayloadBody, finalAmounts_[0]);
        }

        /// @dev set the new payload body
        payloadBody[payloadId_] = newPayloadBody;
        bytes32 newPayloadProof = keccak256(abi.encode(AMBMessage(v.prevPayloadHeader, newPayloadBody)));

        if (newPayloadProof != v.prevPayloadProof) {
            /// @dev set new message quorum
            messageQuorum[newPayloadProof] = messageQuorum[v.prevPayloadProof];
            proofAMB[newPayloadProof] = proofAMB[v.prevPayloadProof];

            /// @dev re-set previous message quorum to 0
            delete messageQuorum[v.prevPayloadProof];
            delete proofAMB[v.prevPayloadProof];
        }

        /// @dev define the payload status as updated
        payloadTracking[payloadId_] = PayloadState.UPDATED;

        emit PayloadUpdated(payloadId_);
    }

    /// @inheritdoc ICoreStateRegistry
    function updateWithdrawPayload(
        uint256 payloadId_,
        bytes[] calldata txData_
    )
        external
        virtual
        override
        onlyCoreStateRegistryUpdater
        isValidPayloadId(payloadId_)
    {
        UpdateWithdrawPayloadVars memory v;

        /// @dev load header and body of payload
        v.prevPayloadHeader = payloadHeader[payloadId_];
        v.prevPayloadBody = payloadBody[payloadId_];

        v.prevPayloadProof = keccak256(abi.encode(AMBMessage(v.prevPayloadHeader, v.prevPayloadBody)));
        (,, v.isMulti,, v.srcSender, v.srcChainId) = v.prevPayloadHeader.decodeTxInfo();

        if (messageQuorum[v.prevPayloadProof] < getRequiredMessagingQuorum(v.srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        /// @dev validate payload update
        PayloadUpdaterLib.validateWithdrawPayloadUpdate(v.prevPayloadHeader, payloadTracking[payloadId_], v.isMulti);
        v.dstChainId = superRegistry.chainId();

        bytes memory newPayloadBody = _updateWithdrawPayload(v, txData_, v.isMulti);

        /// @dev set the new payload body
        payloadBody[payloadId_] = newPayloadBody;
        bytes32 newPayloadProof = keccak256(abi.encode(AMBMessage(v.prevPayloadHeader, newPayloadBody)));

        if (newPayloadProof != v.prevPayloadProof) {
            /// @dev set new message quorum
            messageQuorum[newPayloadProof] = messageQuorum[v.prevPayloadProof];
            proofAMB[newPayloadProof] = proofAMB[v.prevPayloadProof];

            /// @dev re-set previous message quorum to 0
            delete messageQuorum[v.prevPayloadProof];
            delete proofAMB[v.prevPayloadProof];
        }

        /// @dev define the payload status as updated
        payloadTracking[payloadId_] = PayloadState.UPDATED;

        emit PayloadUpdated(payloadId_);
    }

    /// @inheritdoc BaseStateRegistry
    function processPayload(uint256 payloadId_)
        external
        payable
        virtual
        override
        onlyCoreStateRegistryProcessor
        isValidPayloadId(payloadId_)
    {
        CoreProcessPayloadLocalVars memory v;

        v._payloadBody = payloadBody[payloadId_];
        v._payloadHeader = payloadHeader[payloadId_];

        if (payloadTracking[payloadId_] == PayloadState.PROCESSED) {
            revert Error.PAYLOAD_ALREADY_PROCESSED();
        }

        (v.txType, v.callbackType, v.multi,, v.srcSender, v.srcChainId) = v._payloadHeader.decodeTxInfo();

        v._message = AMBMessage(v._payloadHeader, v._payloadBody);

        /// @dev validates quorum
        v._proof = keccak256(abi.encode(v._message));

        /// @dev The number of valid proofs (quorum) must be equal to the required messaging quorum
        if (messageQuorum[v._proof] < getRequiredMessagingQuorum(v.srcChainId)) {
            revert Error.QUORUM_NOT_REACHED();
        }

        /// @dev mint superPositions for successful deposits or remint for failed withdraws
        if (v.callbackType == uint256(CallbackType.RETURN) || v.callbackType == uint256(CallbackType.FAIL)) {
            v.multi == 1
                ? IStateSyncer(
                    superRegistry.getStateSyncer(abi.decode(v._payloadBody, (ReturnMultiData)).superformRouterId)
                ).stateMultiSync(v._message)
                : IStateSyncer(
                    superRegistry.getStateSyncer(abi.decode(v._payloadBody, (ReturnSingleData)).superformRouterId)
                ).stateSync(v._message);
        }

        bytes memory returnMessage;
        /// @dev for initial payload processing
        if (v.callbackType == uint8(CallbackType.INIT)) {
            if (v.txType == uint8(TransactionType.WITHDRAW)) {
                returnMessage = v.multi == 1
                    ? _processMultiWithdrawal(payloadId_, v._payloadBody, v.srcSender, v.srcChainId)
                    : _processSingleWithdrawal(v._payloadBody, v.srcSender, v.srcChainId);
            }

            if (v.txType == uint8(TransactionType.DEPOSIT)) {
                returnMessage = v.multi == 1
                    ? _processMultiDeposit(payloadId_, v._payloadBody, v.srcSender, v.srcChainId)
                    : _processSingleDeposit(payloadId_, v._payloadBody, v.srcSender, v.srcChainId);
            }
        }

        uint8[] memory proofIds = proofAMB[v._proof];

        /// @dev if deposits succeeded or some withdrawal failed, dispatch a callback
        if (returnMessage.length > 0) {
            uint8[] memory ambIds = new uint8[](proofIds.length + 1);

            ambIds[0] = msgAMB[payloadId_];
            for (uint256 i; i < proofIds.length;) {
                ambIds[i + 1] = proofIds[i];

                unchecked {
                    ++i;
                }
            }

            _dispatchAcknowledgement(v.srcChainId, ambIds, returnMessage);
        }

        /// @dev sets status as processed
        /// @dev check for re-entrancy & relocate if needed
        payloadTracking[payloadId_] = PayloadState.PROCESSED;
    }

    /// @dev local struct to avoid stack too deep errors
    struct RescueFailedDepositsLocalVars {
        uint64 dstChainId;
        address srcSender;
        uint64 srcChainId;
        address superform;
        address bridgeValidator;
        uint256 i;
        uint256 l1;
        uint256 l2;
        uint256 _payloadHeader;
        uint256[] superformIds;
    }

    /// @inheritdoc ICoreStateRegistry
    function rescueFailedDeposits(
        uint256 payloadId_,
        LiqRequest[] memory liqData_
    )
        external
        payable
        override
        onlyCoreStateRegistryProcessor
    {
        RescueFailedDepositsLocalVars memory v;

        v.superformIds = failedDeposits[payloadId_];

        v.l1 = v.superformIds.length;
        v.l2 = liqData_.length;

        if (v.l1 == 0 || v.l2 == 0 || v.l1 != v.l2) {
            revert Error.INVALID_RESCUE_DATA();
        }
        v._payloadHeader = payloadHeader[payloadId_];

        (,,,, v.srcSender, v.srcChainId) = v._payloadHeader.decodeTxInfo();

        delete failedDeposits[payloadId_];

        v.dstChainId = superRegistry.chainId();

        for (v.i; v.i < v.l1;) {
            (v.superform,,) = v.superformIds[v.i].getSuperform();
            v.bridgeValidator = superRegistry.getBridgeValidator(liqData_[v.i].bridgeId);

            IBridgeValidator(v.bridgeValidator).validateTxData(
                liqData_[v.i].txData,
                v.dstChainId,
                v.srcChainId,
                v.srcChainId,
                /// @dev in rescuing tokens, the destination chain is the same as the source chain
                false,
                /// @dev - this acts like a withdraw where funds are bridged back to user
                v.superform,
                v.srcSender,
                liqData_[v.i].token
            );

            dispatchTokens(
                superRegistry.getBridgeAddress(liqData_[v.i].bridgeId),
                liqData_[v.i].txData,
                liqData_[v.i].token,
                IBridgeValidator(v.bridgeValidator).decodeAmount(liqData_[v.i].txData),
                address(this),
                liqData_[v.i].nativeAmount,
                liqData_[v.i].permit2data,
                superRegistry.PERMIT2()
            );

            unchecked {
                ++v.i;
            }
        }
    }

    /// @dev returns the required quorum for the src chain id from super registry
    /// @param chainId is the src chain id
    /// @return the quorum configured for the chain id
    function getRequiredMessagingQuorum(uint64 chainId) public view returns (uint256) {
        return IQuorumManager(address(superRegistry)).getRequiredMessagingQuorum(chainId);
    }

    /// @dev returns array of superformIds whose deposits need to be rescued, for a given payloadId
    function getFailedDeposits(uint256 payloadId) external view returns (uint256[] memory) {
        return failedDeposits[payloadId];
    }

    /*///////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev helper function to update multi vault deposit payload
    function _updateMultiVaultDepositPayload(
        bytes memory prevPayloadBody_,
        uint256[] calldata finalAmounts_
    )
        internal
        pure
        returns (bytes memory newPayloadBody_)
    {
        InitMultiVaultData memory multiVaultData = abi.decode(prevPayloadBody_, (InitMultiVaultData));

        /// @dev compare number of vaults to update with provided finalAmounts length
        if (multiVaultData.amounts.length != finalAmounts_.length) {
            revert Error.DIFFERENT_PAYLOAD_UPDATE_AMOUNTS_LENGTH();
        }

        /// @dev validate payload update
        PayloadUpdaterLib.validateSlippageArray(finalAmounts_, multiVaultData.amounts, multiVaultData.maxSlippage);
        multiVaultData.amounts = finalAmounts_;

        newPayloadBody_ = abi.encode(multiVaultData);
    }

    /// @dev helper function to update single vault deposit payload
    function _updateSingleVaultDepositPayload(
        bytes memory prevPayloadBody_,
        uint256 finalAmount_
    )
        internal
        pure
        returns (bytes memory newPayloadBody_)
    {
        InitSingleVaultData memory singleVaultData = abi.decode(prevPayloadBody_, (InitSingleVaultData));

        /// @dev validate payload update
        PayloadUpdaterLib.validateSlippage(finalAmount_, singleVaultData.amount, singleVaultData.maxSlippage);
        singleVaultData.amount = finalAmount_;

        newPayloadBody_ = abi.encode(singleVaultData);
    }

    struct UpdateMultiVaultWithdrawPayloadLocalVars {
        InitMultiVaultData multiVaultData;
        InitSingleVaultData singleVaultData;
        uint256 len;
        uint256 i;
        address superform;
        uint256[] tSuperFormIds;
        uint256[] tAmounts;
        uint256[] tMaxSlippage;
        LiqRequest[] tLiqData;
        uint256 finalAmount;
        IBridgeValidator bridgeValidator;
    }

    /// @dev helper function to update multi vault withdraw payload
    function _updateWithdrawPayload(
        UpdateWithdrawPayloadVars memory v_,
        bytes[] calldata txData_,
        uint8 multi
    )
        internal
        view
        returns (bytes memory)
    {
        UpdateMultiVaultWithdrawPayloadLocalVars memory lV;
        if (multi == 1) {
            lV.multiVaultData = abi.decode(v_.prevPayloadBody, (InitMultiVaultData));
        } else {
            lV.singleVaultData = abi.decode(v_.prevPayloadBody, (InitSingleVaultData));

            lV.tSuperFormIds = new uint256[](1);
            lV.tSuperFormIds[0] = lV.singleVaultData.superformId;

            lV.tAmounts = new uint256[](1);
            lV.tAmounts[0] = lV.singleVaultData.amount;

            lV.tMaxSlippage = new uint256[](1);
            lV.tMaxSlippage[0] = lV.singleVaultData.maxSlippage;

            lV.tLiqData = new LiqRequest[](1);
            lV.tLiqData[0] = lV.singleVaultData.liqData;

            lV.multiVaultData = InitMultiVaultData(
                lV.singleVaultData.superformRouterId,
                lV.singleVaultData.payloadId,
                lV.tSuperFormIds,
                lV.tAmounts,
                lV.tMaxSlippage,
                lV.tLiqData,
                lV.singleVaultData.extraFormData
            );
        }

        lV.len = lV.multiVaultData.liqData.length;

        if (lV.len != txData_.length) {
            revert Error.DIFFERENT_PAYLOAD_UPDATE_TX_DATA_LENGTH();
        }

        /// @dev validates if the incoming update is valid
        for (lV.i; lV.i < lV.len;) {
            if (txData_[lV.i].length != 0 && lV.multiVaultData.liqData[lV.i].txData.length == 0) {
                (address superform,,) = lV.multiVaultData.superformIds[lV.i].getSuperform();

                if (IBaseForm(superform).getStateRegistryId() == superRegistry.getStateRegistryId(address(this))) {
                    PayloadUpdaterLib.validateLiqReq(lV.multiVaultData.liqData[lV.i]);

                    lV.bridgeValidator =
                        IBridgeValidator(superRegistry.getBridgeValidator(lV.multiVaultData.liqData[lV.i].bridgeId));

                    lV.bridgeValidator.validateTxData(
                        txData_[lV.i],
                        v_.dstChainId,
                        v_.srcChainId,
                        lV.multiVaultData.liqData[lV.i].liqDstChainId,
                        false,
                        superform,
                        v_.srcSender,
                        lV.multiVaultData.liqData[lV.i].token
                    );

                    lV.finalAmount = lV.bridgeValidator.decodeAmount(txData_[lV.i]);

                    PayloadUpdaterLib.validateSlippage(
                        lV.finalAmount, lV.multiVaultData.amounts[lV.i], lV.multiVaultData.maxSlippage[lV.i]
                    );

                    lV.multiVaultData.liqData[lV.i].txData = txData_[lV.i];
                }
            }

            unchecked {
                ++lV.i;
            }
        }

        if (multi == 0) {
            lV.singleVaultData.liqData.txData = txData_[0];

            return abi.encode(lV.singleVaultData);
        }

        return abi.encode(lV.multiVaultData);
    }

    function _processMultiWithdrawal(
        uint256 payloadId_,
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    )
        internal
        returns (bytes memory)
    {
        InitMultiVaultData memory multiVaultData = abi.decode(payload_, (InitMultiVaultData));

        InitSingleVaultData memory singleVaultData;
        bool errors;

        for (uint256 i; i < multiVaultData.superformIds.length;) {
            /// @dev it is critical to validate that the action is being performed to the correct chainId coming from
            /// the superform
            DataLib.validateSuperformChainId(multiVaultData.superformIds[i], superRegistry.chainId());

            singleVaultData = InitSingleVaultData({
                superformRouterId: multiVaultData.superformRouterId,
                payloadId: multiVaultData.payloadId,
                superformId: multiVaultData.superformIds[i],
                amount: multiVaultData.amounts[i],
                maxSlippage: multiVaultData.maxSlippage[i],
                liqData: multiVaultData.liqData[i],
                extraFormData: abi.encode(payloadId_, i)
            });
            /// @dev Store destination payloadId_ & index in extraFormData (tbd: 1-step flow doesnt need this)

            (address superform_,,) = singleVaultData.superformId.getSuperform();

            try IBaseForm(superform_).xChainWithdrawFromVault(singleVaultData, srcSender_, srcChainId_) {
                /// @dev marks the indexes that don't require a callback re-mint of shares (successful
                /// withdraws)
                multiVaultData.amounts[i] = 0;
            } catch {
                /// @dev detect if there is at least one failed withdraw
                if (!errors) errors = true;
            }

            unchecked {
                ++i;
            }
        }

        /// @dev if at least one error happens, the shares will be re-minted for the affected superformIds
        if (errors) {
            return _constructMultiReturnData(
                srcSender_,
                multiVaultData.payloadId,
                multiVaultData.superformRouterId,
                TransactionType.WITHDRAW,
                CallbackType.FAIL,
                multiVaultData.superformIds,
                multiVaultData.amounts
            );
        }

        return "";
    }

    function _processMultiDeposit(
        uint256 payloadId_,
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    )
        internal
        returns (bytes memory)
    {
        if (payloadTracking[payloadId_] != PayloadState.UPDATED) {
            revert Error.PAYLOAD_NOT_UPDATED();
        }

        InitMultiVaultData memory multiVaultData = abi.decode(payload_, (InitMultiVaultData));

        (address[] memory superforms,,) = DataLib.getSuperforms(multiVaultData.superformIds);

        IERC20 underlying;
        uint256 numberOfVaults = multiVaultData.superformIds.length;
        uint256[] memory dstAmounts = new uint256[](numberOfVaults);

        bool fulfilment;
        bool errors;

        for (uint256 i; i < numberOfVaults;) {
            underlying = IERC20(IBaseForm(superforms[i]).getVaultAsset());

            if (underlying.balanceOf(address(this)) >= multiVaultData.amounts[i]) {
                underlying.approve(superforms[i], multiVaultData.amounts[i]);
                LiqRequest memory emptyRequest;

                /// @dev it is critical to validate that the action is being performed to the correct chainId coming
                /// from the superform
                DataLib.validateSuperformChainId(multiVaultData.superformIds[i], superRegistry.chainId());

                /// @notice dstAmounts has same size of the number of vaults. If a given deposit fails, we are minting 0
                /// SPs back on source (slight gas waste)
                try IBaseForm(superforms[i]).xChainDepositIntoVault(
                    InitSingleVaultData({
                        superformRouterId: multiVaultData.superformRouterId,
                        payloadId: multiVaultData.payloadId,
                        superformId: multiVaultData.superformIds[i],
                        amount: multiVaultData.amounts[i],
                        maxSlippage: multiVaultData.maxSlippage[i],
                        liqData: emptyRequest,
                        extraFormData: multiVaultData.extraFormData
                    }),
                    srcSender_,
                    srcChainId_
                ) returns (uint256 dstAmount) {
                    if (!fulfilment) fulfilment = true;
                    /// @dev marks the indexes that require a callback mint of shares (successful)
                    dstAmounts[i] = dstAmount;
                } catch {
                    /// @dev cleaning unused approval
                    underlying.approve(superforms[i], 0);

                    /// @dev if any deposit fails, we mark errors as true and add it to failedDeposits mapping for
                    /// future rescuing
                    if (!errors) errors = true;

                    failedDeposits[payloadId_].push(multiVaultData.superformIds[i]);
                }
            } else {
                revert Error.BRIDGE_TOKENS_PENDING();
            }
            unchecked {
                ++i;
            }
        }

        /// @dev issue superPositions if at least one vault deposit passed
        if (fulfilment) {
            return _constructMultiReturnData(
                srcSender_,
                multiVaultData.payloadId,
                multiVaultData.superformRouterId,
                TransactionType.DEPOSIT,
                CallbackType.RETURN,
                multiVaultData.superformIds,
                dstAmounts
            );
        }

        if (errors) {
            emit FailedXChainDeposits(payloadId_);
        }

        return "";
    }

    function _processSingleWithdrawal(
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    )
        internal
        returns (bytes memory)
    {
        InitSingleVaultData memory singleVaultData = abi.decode(payload_, (InitSingleVaultData));

        DataLib.validateSuperformChainId(singleVaultData.superformId, superRegistry.chainId());

        (address superform_,,) = singleVaultData.superformId.getSuperform();
        /// @dev Withdraw from superform
        try IBaseForm(superform_).xChainWithdrawFromVault(singleVaultData, srcSender_, srcChainId_) {
            // Handle the case when the external call succeeds
        } catch {
            // Handle the case when the external call reverts for whatever reason
            /// https://solidity-by-example.org/try-catch/
            return _constructSingleReturnData(
                srcSender_,
                singleVaultData.payloadId,
                singleVaultData.superformRouterId,
                TransactionType.WITHDRAW,
                CallbackType.FAIL,
                singleVaultData.superformId,
                singleVaultData.amount
            );
        }

        return "";
    }

    function _processSingleDeposit(
        uint256 payloadId_,
        bytes memory payload_,
        address srcSender_,
        uint64 srcChainId_
    )
        internal
        returns (bytes memory)
    {
        InitSingleVaultData memory singleVaultData = abi.decode(payload_, (InitSingleVaultData));
        if (payloadTracking[payloadId_] != PayloadState.UPDATED) {
            revert Error.PAYLOAD_NOT_UPDATED();
        }

        DataLib.validateSuperformChainId(singleVaultData.superformId, superRegistry.chainId());

        (address superform_,,) = singleVaultData.superformId.getSuperform();

        IERC20 underlying = IERC20(IBaseForm(superform_).getVaultAsset());

        if (underlying.balanceOf(address(this)) >= singleVaultData.amount) {
            underlying.approve(superform_, singleVaultData.amount);

            /// @dev deposit to superform
            try IBaseForm(superform_).xChainDepositIntoVault(singleVaultData, srcSender_, srcChainId_) returns (
                uint256 dstAmount
            ) {
                return _constructSingleReturnData(
                    srcSender_,
                    singleVaultData.payloadId,
                    singleVaultData.superformRouterId,
                    TransactionType.DEPOSIT,
                    CallbackType.RETURN,
                    singleVaultData.superformId,
                    dstAmount
                );
            } catch {
                /// @dev cleaning unused approval
                underlying.approve(superform_, 0);
                /// @dev if any deposit fails, add it to failedDeposits mapping for future rescuing
                failedDeposits[payloadId_].push(singleVaultData.superformId);

                emit FailedXChainDeposits(payloadId_);
            }
        } else {
            revert Error.BRIDGE_TOKENS_PENDING();
        }

        return "";
    }

    /// @notice depositSync and withdrawSync internal method for sending message back to the source chain
    function _constructMultiReturnData(
        address srcSender_,
        uint256 payloadId_,
        uint8 superformRouterId_,
        TransactionType txType,
        CallbackType returnType,
        uint256[] memory superformIds_,
        uint256[] memory amounts
    )
        internal
        view
        returns (bytes memory)
    {
        /// @dev Send Data to Source to issue superform positions (failed withdraws and successful deposits)
        return abi.encode(
            AMBMessage(
                DataLib.packTxInfo(
                    uint8(txType),
                    uint8(returnType),
                    1,
                    superRegistry.getStateRegistryId(address(this)),
                    srcSender_,
                    superRegistry.chainId()
                ),
                abi.encode(ReturnMultiData(superformRouterId_, payloadId_, superformIds_, amounts))
            )
        );
    }

    /// @notice depositSync and withdrawSync internal method for sending message back to the source chain
    function _constructSingleReturnData(
        address srcSender_,
        uint256 payloadId_,
        uint8 superformRouterId_,
        TransactionType txType,
        CallbackType returnType,
        uint256 superformId_,
        uint256 amount
    )
        internal
        view
        returns (bytes memory)
    {
        /// @dev Send Data to Source to issue superform positions (failed withdraws and successful deposits)
        return abi.encode(
            AMBMessage(
                DataLib.packTxInfo(
                    uint8(txType),
                    uint8(returnType),
                    0,
                    superRegistry.getStateRegistryId(address(this)),
                    srcSender_,
                    superRegistry.chainId()
                ),
                abi.encode(ReturnSingleData(superformRouterId_, payloadId_, superformId_, amount))
            )
        );
    }

    /// @dev calls the appropriate dispatch function according to the ackExtraData the keeper fed initially
    function _dispatchAcknowledgement(uint64 dstChainId_, uint8[] memory ambIds_, bytes memory message_) internal {
        (, bytes memory extraData) = IPaymentHelper(superRegistry.getAddress(keccak256("PAYMENT_HELPER")))
            .calculateAMBData(dstChainId_, ambIds_, message_);

        AMBExtraData memory d = abi.decode(extraData, (AMBExtraData));

        _dispatchPayload(msg.sender, ambIds_[0], dstChainId_, d.gasPerAMB[0], message_, d.extraDataPerAMB[0]);

        if (ambIds_.length > 1) {
            _dispatchProof(msg.sender, ambIds_, dstChainId_, d.gasPerAMB, message_, d.extraDataPerAMB);
        }
    }
}
