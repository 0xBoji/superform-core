// SPDX-License-Identifer: Apache-2.0
pragma solidity 0.8.19;

import { Broadcaster } from "../utils/Broadcaster.sol";
import { ISuperRBAC } from "../../interfaces/ISuperRBAC.sol";
import { PayloadState } from "../../types/DataTypes.sol";
import { ISuperRegistry } from "../../interfaces/ISuperRegistry.sol";
import { Error } from "../../utils/Error.sol";

/// @title RolesStateRegistry
/// @author Zeropoint Labs
/// @dev enables communication between SuperRBAC deployed on all supported networks
contract RolesStateRegistry is Broadcaster {
    /*///////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySender() override {
        if (superRegistry.getAddress(keccak256("SUPER_RBAC")) != msg.sender) revert Error.NOT_SUPER_RBAC();
        _;
    }

    modifier onlyRolesStateRegistryProcessor() {
        if (
            !ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).hasRolesStateRegistryProcessorRole(msg.sender)
        ) revert Error.NOT_PROCESSOR();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(ISuperRegistry superRegistry_) Broadcaster(superRegistry_) { }

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function processPayload(uint256 payloadId_)
        /// not useful here
        external
        payable
        virtual
        override
        onlyRolesStateRegistryProcessor
    {
        if (payloadId_ > payloadsCount) {
            revert Error.INVALID_PAYLOAD_ID();
        }

        if (payloadTracking[payloadId_] == PayloadState.PROCESSED) {
            revert Error.PAYLOAD_ALREADY_PROCESSED();
        }

        payloadTracking[payloadId_] = PayloadState.PROCESSED;
        ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).stateSync(payloadBody[payloadId_]);
    }
}
