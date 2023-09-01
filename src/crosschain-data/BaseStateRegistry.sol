// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import { Error } from "../utils/Error.sol";
import { ISuperRBAC } from "../interfaces/ISuperRBAC.sol";
import { ISuperRegistry } from "../interfaces/ISuperRegistry.sol";
import { IBaseStateRegistry } from "../interfaces/IBaseStateRegistry.sol";
import { IAmbImplementation } from "../interfaces/IAmbImplementation.sol";
import { PayloadState, AMBMessage, AMBExtraData } from "../types/DataTypes.sol";

/// @title BaseStateRegistry
/// @author Zeropoint Labs
/// @dev contract module that allows inheriting contracts to implement crosschain messaging & processing mechanisms.
/// @dev This is a lightweight version that allows only dispatching and receiving crosschain
/// @dev payloads (messages). Inheriting children contracts have the flexibility to define their own processing
/// mechanisms.
abstract contract BaseStateRegistry is IBaseStateRegistry {
    /*///////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    ISuperRegistry public immutable superRegistry;

    /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 public payloadsCount;

    mapping(bytes32 => uint256) public messageQuorum;

    /// @dev stores received payload after assigning them an unique identifier upon receiving
    mapping(uint256 => bytes) public payloadBody;

    /// @dev stores received payload's header (txInfo)
    mapping(uint256 => uint256) public payloadHeader;

    /// @dev maps payloads to their current status
    mapping(uint256 => PayloadState) public payloadTracking;

    /// @dev maps payloads to the amb ids that delivered them
    mapping(uint256 => uint8) public msgAMB;

    /// @dev maps payloads to the amb ids that delivered them
    mapping(bytes32 => uint8[]) public proofAMB;

    /// @dev sender varies based on functionality
    /// @notice inheriting contracts should override this function (else not safe)
    /// @dev with general revert to protect dispatchPaylod in case of non override
    modifier onlySender() virtual {
        revert Error.DISABLED();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                        CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(ISuperRegistry superRegistry_) {
        superRegistry = superRegistry_;
    }

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    receive() external payable { }

    /// @inheritdoc IBaseStateRegistry
    function dispatchPayload(
        address srcSender_,
        uint8[] memory ambIds_,
        uint64 dstChainId_,
        bytes memory message_,
        bytes memory extraData_
    )
        external
        payable
        override
        onlySender
    {
        AMBExtraData memory d = abi.decode(extraData_, (AMBExtraData));

        _dispatchPayload(srcSender_, ambIds_[0], dstChainId_, d.gasPerAMB[0], message_, d.extraDataPerAMB[0]);

        if (ambIds_.length > 1) {
            _dispatchProof(srcSender_, ambIds_, dstChainId_, d.gasPerAMB, message_, d.extraDataPerAMB);
        }
    }

    /// @inheritdoc IBaseStateRegistry
    function receivePayload(uint64 srcChainId_, bytes memory message_) external override {
        if (!superRegistry.isValidAmbImpl(msg.sender)) {
            revert Error.NOT_AMB_IMPLEMENTATION();
        }

        AMBMessage memory data = abi.decode(message_, (AMBMessage));

        /// @dev proofHash will always be 32 bytes length due to keccak256
        if (data.params.length == 32) {
            bytes32 proofHash = abi.decode(data.params, (bytes32));
            ++messageQuorum[proofHash];

            proofAMB[proofHash].push(superRegistry.getAmbId(msg.sender));

            emit ProofReceived(data.params);
        } else {
            /// @dev if message, store header and body of it
            ++payloadsCount;

            payloadBody[payloadsCount] = data.params;
            payloadHeader[payloadsCount] = data.txInfo;

            msgAMB[payloadsCount] = superRegistry.getAmbId(msg.sender);

            emit PayloadReceived(srcChainId_, superRegistry.chainId(), payloadsCount);
        }
    }

    /// @inheritdoc IBaseStateRegistry
    function processPayload(uint256 payloadId_) external payable virtual override;

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
    )
        internal
    {
        IAmbImplementation ambImplementation = IAmbImplementation(superRegistry.getAmbAddress(ambId_));

        /// @dev revert if an unknown amb id is used
        if (address(ambImplementation) == address(0)) {
            revert Error.INVALID_BRIDGE_ID();
        }

        ambImplementation.dispatchPayload{ value: gasToPay_ }(srcSender_, dstChainId_, message_, overrideData_);
    }

    /// @dev dispatches the proof(hash of the message_) through individual message bridge implementations
    function _dispatchProof(
        address srcSender_,
        uint8[] memory ambIds_,
        uint64 dstChainId_,
        uint256[] memory gasToPay_,
        bytes memory message_,
        bytes[] memory overrideData_
    )
        internal
    {
        AMBMessage memory data = abi.decode(message_, (AMBMessage));
        data.params = abi.encode(keccak256(message_));

        /// @dev i starts from 1 since 0 is primary amb id which dispatches the message itself
        for (uint8 i = 1; i < ambIds_.length;) {
            uint8 tempAmbId = ambIds_[i];

            if (tempAmbId == ambIds_[0]) {
                revert Error.INVALID_PROOF_BRIDGE_ID();
            }

            IAmbImplementation tempImpl = IAmbImplementation(superRegistry.getAmbAddress(tempAmbId));

            if (address(tempImpl) == address(0)) {
                revert Error.INVALID_BRIDGE_ID();
            }

            /// @dev proof is dispatched in the form of a payload
            tempImpl.dispatchPayload{ value: gasToPay_[i] }(srcSender_, dstChainId_, abi.encode(data), overrideData_[i]);

            unchecked {
                ++i;
            }
        }
    }
}
