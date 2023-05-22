// SPDX-License-Identifer: Apache-2.0
pragma solidity 0.8.19;

import {BaseStateRegistry} from "./BaseStateRegistry.sol";
import {ISuperRBAC} from "../interfaces/ISuperRBAC.sol";
import {PayloadState} from "../types/DataTypes.sol";
import {ISuperRegistry} from "../interfaces/ISuperRegistry.sol";
import {Error} from "../utils/Error.sol";

/// @title RolesStateRegistry
/// @author Zeropoint Labs
/// @dev enables communication between SuperRBAC deployed on all supported networks
contract RolesStateRegistry is BaseStateRegistry {
    /*///////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlySender() override {
        if (msg.sender != superRegistry.superRBAC()) revert Error.NOT_CORE_CONTRACTS();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(ISuperRegistry superRegistry_, uint8 registryType_) BaseStateRegistry(superRegistry_, registryType_) {}

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaseStateRegistry
    function processPayload(
        uint256 payloadId_,
        bytes memory /// not useful here
    ) external payable virtual override onlyProcessor {
        if (payloadId_ > payloadsCount) {
            revert Error.INVALID_PAYLOAD_ID();
        }

        if (payloadTracking[payloadId_] == PayloadState.PROCESSED) {
            revert Error.INVALID_PAYLOAD_STATE();
        }

        payloadTracking[payloadId_] = PayloadState.PROCESSED;
        ISuperRBAC(superRegistry.superRBAC()).stateSync(payload[payloadId_]);
    }
}
