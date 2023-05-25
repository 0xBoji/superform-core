// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import {Error} from "../utils/Error.sol";
import "../utils/DataPacking.sol";
import {ISuperRBAC} from "../interfaces/ISuperRBAC.sol";
import {ISuperRegistry} from "../interfaces/ISuperRegistry.sol";
import {IBaseStateRegistry} from "../interfaces/IBaseStateRegistry.sol";
import {IAmbImplementation} from "../interfaces/IAmbImplementation.sol";
import {PayloadState, AMBMessage, AMBFactoryMessage, AMBExtraData} from "../types/DataTypes.sol";

/// @title BaseStateRegistry
/// @author Zeropoint Labs
/// @dev contract module that allows children to implement crosschain messaging
/// & processing mechanisms. This is a lightweight version that allows only dispatching and receiving crosschain
/// payloads (messages). Inheriting children contracts has the flexibility to define their own processing mechanisms.
abstract contract BaseStateRegistry is IBaseStateRegistry {
    /*///////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint8 public immutable STATE_REGISTRY_TYPE;
    ISuperRegistry public immutable superRegistry;

    /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 public payloadsCount;

    mapping(bytes => uint256) public messageQuorum;
    /// @dev stores all received payloads after assigning them an unique identifier upon receiving
    mapping(uint256 => bytes) public payload;
    /// @dev maps payloads to their current status
    mapping(uint256 => PayloadState) public payloadTracking;

    /*///////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyProtocolAdmin() {
        if (!ISuperRBAC(superRegistry.superRBAC()).hasProtocolAdminRole(msg.sender)) revert Error.NOT_PROTOCOL_ADMIN();
        _;
    }

    modifier onlyProcessor() {
        if (!ISuperRBAC(superRegistry.superRBAC()).hasProcessorRole(msg.sender)) revert Error.NOT_PROCESSOR();
        _;
    }

    modifier onlyUpdater() {
        if (!ISuperRBAC(superRegistry.superRBAC()).hasUpdaterRole(msg.sender)) revert Error.NOT_UPDATER();
        _;
    }

    /// @dev sender varies based on functionality
    /// NOTE: children contracts should override this function (else not safe)
    modifier onlySender() virtual {
        _;
    }

    /*///////////////////////////////////////////////////////////////
                        CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(ISuperRegistry superRegistry_, uint8 stateRegistryType_) {
        superRegistry = superRegistry_;

        /// TODO: move state registry type to superregistry??
        STATE_REGISTRY_TYPE = stateRegistryType_;
    }

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {}

    /// @inheritdoc IBaseStateRegistry
    function dispatchPayload(
        address srcSender_,
        uint8[] memory ambIds_,
        uint64 dstChainId_,
        bytes memory message_,
        bytes memory extraData_
    ) external payable override onlySender {
        AMBExtraData memory d = abi.decode(extraData_, (AMBExtraData));

        _dispatchPayload(srcSender_, ambIds_[0], dstChainId_, d.gasPerAMB[0], message_, d.extraDataPerAMB[0]);

        if (ambIds_.length > 1) {
            _dispatchProof(srcSender_, ambIds_, dstChainId_, d.gasPerAMB, message_, d.extraDataPerAMB);
        }
    }

    /// @inheritdoc IBaseStateRegistry
    function broadcastPayload(
        address srcSender_,
        uint8[] memory ambIds_,
        bytes memory message_,
        bytes memory extraData_
    ) external payable override onlySender {
        AMBExtraData memory d = abi.decode(extraData_, (AMBExtraData));

        _broadcastPayload(srcSender_, ambIds_[0], d.gasPerAMB[0], message_, d.extraDataPerAMB[0]);

        if (ambIds_.length > 1) {
            _broadcastProof(srcSender_, ambIds_, d.gasPerAMB, message_, d.extraDataPerAMB);
        }
    }

    /// @inheritdoc IBaseStateRegistry
    function receivePayload(uint64 srcChainId_, bytes memory message_) external override {
        if (!superRegistry.isValidAmbImpl(msg.sender)) {
            revert Error.INVALID_CALLER();
        }

        AMBMessage memory data = abi.decode(message_, (AMBMessage));

        if (data.params.length == 32) {
            /// FIXME: assuming 32 bytes length is always proof
            /// NOTE: should validate this assumption
            messageQuorum[data.params] += 1;

            emit ProofReceived(data.params);
        } else {
            ++payloadsCount;
            payload[payloadsCount] = message_;

            emit PayloadReceived(srcChainId_, superRegistry.chainId(), payloadsCount);
        }
    }

    /// @inheritdoc IBaseStateRegistry
    function processPayload(
        uint256 payloadId_,
        bytes memory ambOverride_
    ) external payable virtual override onlyProcessor {}

    /// @inheritdoc IBaseStateRegistry
    function revertPayload(
        uint256 payloadId_,
        uint256 ambId_,
        bytes memory extraData_
    ) external payable virtual override onlyProcessor {}

    /*///////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev dispatches the payload(message_) through individual message bridge implementations
    function _dispatchPayload(
        address srcSender_,
        uint8 ambId_,
        uint64 dstChainId_,
        uint256 gasToPay_,
        bytes memory message_,
        bytes memory overrideData_
    ) internal {
        IAmbImplementation ambImplementation = IAmbImplementation(superRegistry.getAmbAddress(ambId_));

        if (address(ambImplementation) == address(0)) {
            revert Error.INVALID_BRIDGE_ID();
        }

        ambImplementation.dispatchPayload{value: gasToPay_}(srcSender_, dstChainId_, message_, overrideData_);
    }

    /// @dev dispatches the proof(hash of the message_) through individual message bridge implementations
    function _dispatchProof(
        address srcSender_,
        uint8[] memory ambIds_,
        uint64 dstChainId_,
        uint256[] memory gasToPay_,
        bytes memory message_,
        bytes[] memory overrideData_
    ) internal {
        bytes memory proof = abi.encode(keccak256(message_));

        AMBMessage memory data = abi.decode(message_, (AMBMessage));
        data.params = proof;

        for (uint8 i = 1; i < ambIds_.length; i++) {
            uint8 tempAmbId = ambIds_[i];

            if (tempAmbId == ambIds_[0]) {
                revert Error.INVALID_PROOF_BRIDGE_ID();
            }

            IAmbImplementation tempImpl = IAmbImplementation(superRegistry.getAmbAddress(tempAmbId));

            if (address(tempImpl) == address(0)) {
                revert Error.INVALID_BRIDGE_ID();
            }

            tempImpl.dispatchPayload{value: gasToPay_[i]}(srcSender_, dstChainId_, abi.encode(data), overrideData_[i]);
        }
    }

    /// @dev broadcasts the payload(message_) through individual message bridge implementations
    function _broadcastPayload(
        address srcSender_,
        uint8 ambId_,
        uint256 gasToPay_,
        bytes memory message_,
        bytes memory extraData_
    ) internal {
        AMBMessage memory newData = AMBMessage(
            _packTxInfo(0, 0, 0, STATE_REGISTRY_TYPE, srcSender_, superRegistry.chainId()),
            message_
        );

        IAmbImplementation ambImplementation = IAmbImplementation(superRegistry.getAmbAddress(ambId_));

        if (address(ambImplementation) == address(0)) {
            revert Error.INVALID_BRIDGE_ID();
        }

        ambImplementation.broadcastPayload{value: gasToPay_}(srcSender_, abi.encode(newData), extraData_);
    }

    /// @dev broadcasts the proof(hash of the message_) through individual message bridge implementations
    function _broadcastProof(
        address srcSender_,
        uint8[] memory ambIds_,
        uint256[] memory gasToPay_,
        bytes memory message_,
        bytes[] memory extraData_
    ) internal {
        bytes memory proof = abi.encode(keccak256(message_));
        AMBMessage memory newData = AMBMessage(
            _packTxInfo(0, 0, 0, STATE_REGISTRY_TYPE, srcSender_, superRegistry.chainId()),
            proof
        );

        for (uint8 i = 1; i < ambIds_.length; i++) {
            uint8 tempAmbId = ambIds_[i];

            if (tempAmbId == ambIds_[0]) {
                revert Error.INVALID_PROOF_BRIDGE_ID();
            }

            IAmbImplementation tempImpl = IAmbImplementation(superRegistry.getAmbAddress(tempAmbId));

            if (address(tempImpl) == address(0)) {
                revert Error.INVALID_BRIDGE_ID();
            }

            tempImpl.broadcastPayload{value: gasToPay_[i]}(srcSender_, abi.encode(newData), extraData_[i]);
        }
    }
}
