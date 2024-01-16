// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { QuorumManager } from "src/crosschain-data/utils/QuorumManager.sol";
import { ISuperRBAC } from "src/interfaces/ISuperRBAC.sol";
import { ISuperRegistry } from "src/interfaces/ISuperRegistry.sol";
import { Error } from "src/libraries/Error.sol";

/// @title SuperRegistry
/// @dev Keeps information on all addresses used in the Superform ecosystem
/// @author Zeropoint Labs
contract SuperRegistry is ISuperRegistry, QuorumManager {
    //////////////////////////////////////////////////////////////
    //                         CONSTANTS                        //
    //////////////////////////////////////////////////////////////

    uint256 private constant MIN_DELAY = 15 minutes;
    uint256 private constant MAX_DELAY = 24 hours;
    uint64 public immutable CHAIN_ID;

    /// @dev core protocol - identifiers
    /// @notice should not be allowed to be changed
    bytes32 public constant override SUPERFORM_ROUTER = keccak256("SUPERFORM_ROUTER");

    /// @dev can be used to set a new factory that has form ids paused
    /// @notice should not be allowed to be changed
    bytes32 public constant override SUPERFORM_FACTORY = keccak256("SUPERFORM_FACTORY");

    /// @dev not accessed in protocol
    /// @dev could be allowed to be changed
    bytes32 public constant override SUPER_TRANSMUTER = keccak256("SUPER_TRANSMUTER");

    /// @dev can be used to set a new paymaster to forward payments to
    /// @dev could be allowed to be changed
    bytes32 public constant override PAYMASTER = keccak256("PAYMASTER");

    /// @dev accessed in some areas of the protocol to calculate AMB fees. Already has a function to alter the
    /// configuration
    /// @dev could be allowed to be changed
    bytes32 public constant override PAYMENT_HELPER = keccak256("PAYMENT_HELPER");

    /// @dev accessed in many areas of the protocol. has direct access to superforms
    /// @notice should not be allowed to be changed
    bytes32 public constant override CORE_STATE_REGISTRY = keccak256("CORE_STATE_REGISTRY");

    /// @dev accessed in many areas of the protocol. has direct access to timelock form
    /// @notice should not be allowed to be changed
    bytes32 public constant override TIMELOCK_STATE_REGISTRY = keccak256("TIMELOCK_STATE_REGISTRY");

    /// @dev used to sync messages for pausing superforms or deploying transmuters
    /// @notice should not be allowed to be changed
    bytes32 public constant override BROADCAST_REGISTRY = keccak256("BROADCAST_REGISTRY");

    /// @dev not accessed in protocol
    /// @notice should not be allowed to be changed
    bytes32 public constant override SUPER_POSITIONS = keccak256("SUPER_POSITIONS");

    /// @dev accessed in many areas of the protocol
    /// @notice should not be allowed to be changed
    bytes32 public constant override SUPER_RBAC = keccak256("SUPER_RBAC");

    /// @dev not accessed in protocol
    /// @dev could be allowed to be changed
    bytes32 public constant override PAYLOAD_HELPER = keccak256("PAYLOAD_HELPER");

    /// @dev accessed in CSR and validators. can be used to alter behaviour of update deposit payloads
    /// @notice should not be allowed to be changed
    bytes32 public constant override DST_SWAPPER = keccak256("DST_SWAPPER");

    /// @dev accessed in base form to send payloads to emergency queue
    /// @notice should not be allowed to be changed
    bytes32 public constant override EMERGENCY_QUEUE = keccak256("EMERGENCY_QUEUE");

    /// @dev receiver of bridge refunds and airdropped tokens
    /// @notice should not be allowed to be changed
    bytes32 public constant override SUPERFORM_RECEIVER = keccak256("SUPERFORM_RECEIVER");

    /// @dev default keepers - identifiers
    /// @dev could be allowed to be changed
    bytes32 public constant override PAYMENT_ADMIN = keccak256("PAYMENT_ADMIN");
    bytes32 public constant override CORE_REGISTRY_PROCESSOR = keccak256("CORE_REGISTRY_PROCESSOR");
    bytes32 public constant override BROADCAST_REGISTRY_PROCESSOR = keccak256("BROADCAST_REGISTRY_PROCESSOR");
    bytes32 public constant override TIMELOCK_REGISTRY_PROCESSOR = keccak256("TIMELOCK_REGISTRY_PROCESSOR");
    bytes32 public constant override CORE_REGISTRY_UPDATER = keccak256("CORE_REGISTRY_UPDATER");
    bytes32 public constant override CORE_REGISTRY_RESCUER = keccak256("CORE_REGISTRY_RESCUER");
    bytes32 public constant override CORE_REGISTRY_DISPUTER = keccak256("CORE_REGISTRY_DISPUTER");
    bytes32 public constant override DST_SWAPPER_PROCESSOR = keccak256("DST_SWAPPER_PROCESSOR");

    //////////////////////////////////////////////////////////////
    //                     STATE VARIABLES                      //
    //////////////////////////////////////////////////////////////

    /// @dev canonical permit2 contract
    address private permit2Address;

    /// @dev rescue timelock delay config
    uint256 public delay;

    mapping(bytes32 id => mapping(uint64 chainid => address moduleAddress)) private registry;
    /// @dev liquidityBridge id is mapped to a liquidityBridge address (to prevent interaction with unauthorized
    /// bridges)
    mapping(uint8 bridgeId => address bridgeAddress) public bridgeAddresses;
    mapping(uint8 bridgeId => address bridgeValidator) public bridgeValidator;
    mapping(uint8 ambId => address ambAddresses) public ambAddresses;
    mapping(uint8 ambId => bool isBroadcastAMB) public isBroadcastAMB;

    mapping(uint64 chainId => uint256 vaultLimitPerDestination) public vaultLimitPerDestination;

    mapping(uint8 registryId => address registryAddress) public registryAddresses;
    /// @dev is the reverse mapping of registryAddresses
    mapping(address registryAddress => uint8 registryId) public stateRegistryIds;
    /// @dev is the reverse mapping of ambAddresses
    mapping(address ambAddress => uint8 ambId) public ambIds;

    //////////////////////////////////////////////////////////////
    //                       MODIFIERS                          //
    //////////////////////////////////////////////////////////////

    modifier onlyEmergencyAdmin() {
        if (!ISuperRBAC(registry[SUPER_RBAC][CHAIN_ID]).hasEmergencyAdminRole(msg.sender)) {
            revert Error.NOT_EMERGENCY_ADMIN();
        }
        _;
    }

    modifier onlyProtocolAdmin() {
        if (!ISuperRBAC(registry[SUPER_RBAC][CHAIN_ID]).hasProtocolAdminRole(msg.sender)) {
            revert Error.NOT_PROTOCOL_ADMIN();
        }
        _;
    }

    //////////////////////////////////////////////////////////////
    //                      CONSTRUCTOR                         //
    //////////////////////////////////////////////////////////////

    constructor(address superRBAC_) {
        if (superRBAC_ == address(0)) {
            revert Error.ZERO_ADDRESS();
        }

        if (block.chainid > type(uint64).max) {
            revert Error.BLOCK_CHAIN_ID_OUT_OF_BOUNDS();
        }

        CHAIN_ID = uint64(block.chainid);
        registry[SUPER_RBAC][CHAIN_ID] = superRBAC_;

        emit AddressUpdated(SUPER_RBAC, CHAIN_ID, address(0), superRBAC_);
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL VIEW FUNCTIONS                     //
    //////////////////////////////////////////////////////////////

    /// @inheritdoc ISuperRegistry
    function getAddress(bytes32 id_) external view override returns (address addr) {
        addr = registry[id_][CHAIN_ID];
        if (addr == address(0)) revert Error.ZERO_ADDRESS();
    }

    /// @inheritdoc ISuperRegistry
    function getAddressByChainId(bytes32 id_, uint64 chainId_) external view override returns (address addr) {
        addr = registry[id_][chainId_];
        if (addr == address(0)) revert Error.ZERO_ADDRESS();
    }

    /// @inheritdoc ISuperRegistry
    function getBridgeAddress(uint8 bridgeId_) external view override returns (address bridgeAddress_) {
        bridgeAddress_ = bridgeAddresses[bridgeId_];
        if (bridgeAddress_ == address(0)) revert Error.ZERO_ADDRESS();
    }

    /// @inheritdoc ISuperRegistry
    function getBridgeValidator(uint8 bridgeId_) external view override returns (address bridgeValidator_) {
        bridgeValidator_ = bridgeValidator[bridgeId_];
        if (bridgeValidator_ == address(0)) revert Error.ZERO_ADDRESS();
    }

    /// @inheritdoc ISuperRegistry
    function getAmbAddress(uint8 ambId_) external view override returns (address ambAddress_) {
        ambAddress_ = ambAddresses[ambId_];
        if (ambAddress_ == address(0)) revert Error.ZERO_ADDRESS();
    }

    /// @inheritdoc ISuperRegistry
    function getAmbId(address ambAddress_) external view override returns (uint8 ambId_) {
        ambId_ = ambIds[ambAddress_];
    }

    /// @inheritdoc ISuperRegistry
    function getStateRegistry(uint8 registryId_) external view override returns (address registryAddress_) {
        registryAddress_ = registryAddresses[registryId_];
        if (registryAddress_ == address(0)) revert Error.ZERO_ADDRESS();
    }

    /// @inheritdoc ISuperRegistry
    function getStateRegistryId(address registryAddress_) external view override returns (uint8 registryId_) {
        registryId_ = stateRegistryIds[registryAddress_];
        if (registryId_ == 0) revert Error.INVALID_REGISTRY_ID();
    }

    /// @inheritdoc ISuperRegistry
    function getVaultLimitPerDestination(uint64 chainId_)
        external
        view
        override
        returns (uint256 vaultLimitPerDestination_)
    {
        vaultLimitPerDestination_ = vaultLimitPerDestination[chainId_];
    }

    /// @inheritdoc ISuperRegistry
    function isValidStateRegistry(address registryAddress_) external view override returns (bool valid_) {
        if (stateRegistryIds[registryAddress_] != 0) return true;

        return false;
    }

    /// @inheritdoc ISuperRegistry
    function isValidAmbImpl(address ambAddress_) external view override returns (bool valid_) {
        uint8 ambId = ambIds[ambAddress_];
        if (ambId != 0 && !isBroadcastAMB[ambId]) return true;

        return false;
    }

    /// @inheritdoc ISuperRegistry
    function isValidBroadcastAmbImpl(address ambAddress_) external view override returns (bool valid_) {
        uint8 ambId = ambIds[ambAddress_];
        if (ambId != 0 && isBroadcastAMB[ambId]) return true;

        return false;
    }

    /// @inheritdoc ISuperRegistry
    function PERMIT2() external view override returns (address) {
        if (permit2Address == address(0)) revert Error.ZERO_ADDRESS();
        return permit2Address;
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL WRITE FUNCTIONS                    //
    //////////////////////////////////////////////////////////////

    /// @inheritdoc ISuperRegistry
    function setVaultLimitPerDestination(uint64 chainId_, uint256 vaultLimit_) external override onlyEmergencyAdmin {
        if (vaultLimit_ == 0) {
            revert Error.ZERO_INPUT_VALUE();
        }

        vaultLimitPerDestination[chainId_] = vaultLimit_;
        emit SetVaultLimitPerDestination(chainId_, vaultLimit_);
    }

    /// @inheritdoc ISuperRegistry
    function setDelay(uint256 delay_) external override onlyProtocolAdmin {
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) {
            revert Error.INVALID_TIMELOCK_DELAY();
        }

        uint256 oldDelay_ = delay;
        delay = delay_;

        emit SetDelay(oldDelay_, delay_);
    }

    /// @inheritdoc ISuperRegistry
    function setPermit2(address permit2_) external override onlyProtocolAdmin {
        if (permit2Address != address(0)) revert Error.DISABLED();
        if (permit2_ == address(0)) revert Error.ZERO_ADDRESS();

        permit2Address = permit2_;

        emit SetPermit2(permit2_);
    }

    /// @inheritdoc ISuperRegistry
    function batchSetAddress(
        bytes32[] memory ids_,
        address[] memory newAddresses_,
        uint64[] memory chainIds_
    )
        external
        override
        onlyProtocolAdmin
    {
        uint256 len = ids_.length;

        if (len != newAddresses_.length || len != chainIds_.length) revert Error.ARRAY_LENGTH_MISMATCH();

        for (uint256 i; i < len; ++i) {
            setAddress(ids_[i], newAddresses_[i], chainIds_[i]);
        }
    }

    /// @inheritdoc ISuperRegistry
    function setAddress(bytes32 id_, address newAddress_, uint64 chainId_) public override onlyProtocolAdmin {
        address oldAddress = registry[id_][chainId_];
        if (oldAddress != address(0)) {
            /// @notice SUPERFORM_FACTORY, CORE_STATE_REGISTRY, TIMELOCK_STATE_REGISTRY, BROADCAST_REGISTRY, SUPER_RBAC,
            /// DST_SWAPPER, EMERGENCY_QUEUE, SUPER_POSITIONS and SUPERFORM_ROUTER  cannot be changed once set
            if (
                id_ == SUPERFORM_FACTORY || id_ == CORE_STATE_REGISTRY || id_ == TIMELOCK_STATE_REGISTRY
                    || id_ == BROADCAST_REGISTRY || id_ == SUPER_RBAC || id_ == DST_SWAPPER || id_ == EMERGENCY_QUEUE
                    || id_ == SUPER_POSITIONS || id_ == SUPERFORM_ROUTER
            ) {
                revert Error.DISABLED();
            }
        }

        registry[id_][chainId_] = newAddress_;

        emit AddressUpdated(id_, chainId_, oldAddress, newAddress_);
    }

    /// @inheritdoc ISuperRegistry
    function setBridgeAddresses(
        uint8[] memory bridgeId_,
        address[] memory bridgeAddress_,
        address[] memory bridgeValidator_
    )
        external
        override
        onlyProtocolAdmin
    {
        uint256 len = bridgeId_.length;
        if (len != bridgeAddress_.length || len != bridgeValidator_.length) revert Error.ARRAY_LENGTH_MISMATCH();

        for (uint256 i; i < len; ++i) {
            uint8 bridgeId = bridgeId_[i];
            address bridgeAddress = bridgeAddress_[i];
            address bridgeValidatorT = bridgeValidator_[i];
            if (bridgeAddress == address(0)) revert Error.ZERO_ADDRESS();
            if (bridgeId == 0) revert Error.ZERO_INPUT_VALUE();
            if (bridgeValidatorT == address(0)) revert Error.ZERO_ADDRESS();

            if (bridgeAddresses[bridgeId] != address(0)) revert Error.DISABLED();

            bridgeAddresses[bridgeId] = bridgeAddress;
            bridgeValidator[bridgeId] = bridgeValidatorT;
            emit SetBridgeAddress(bridgeId, bridgeAddress);
            emit SetBridgeValidator(bridgeId, bridgeValidatorT);
        }
    }

    /// @inheritdoc ISuperRegistry
    function setAmbAddress(
        uint8[] memory ambId_,
        address[] memory ambAddress_,
        bool[] memory isBroadcastAMB_
    )
        external
        override
        onlyProtocolAdmin
    {
        uint256 len = ambId_.length;
        if (len != ambAddress_.length || len != isBroadcastAMB_.length) revert Error.ARRAY_LENGTH_MISMATCH();

        for (uint256 i; i < len; ++i) {
            address ambAddress = ambAddress_[i];
            uint8 ambId = ambId_[i];
            bool broadcastAMB = isBroadcastAMB_[i];

            if (ambAddress == address(0)) revert Error.ZERO_ADDRESS();
            if (ambId == 0) revert Error.ZERO_INPUT_VALUE();
            if (ambAddresses[ambId] != address(0)) revert Error.DISABLED();

            ambAddresses[ambId] = ambAddress;
            ambIds[ambAddress] = ambId;
            isBroadcastAMB[ambId] = broadcastAMB;
            emit SetAmbAddress(ambId, ambAddress, broadcastAMB);
        }
    }

    /// @inheritdoc ISuperRegistry
    function setStateRegistryAddress(
        uint8[] memory registryId_,
        address[] memory registryAddress_
    )
        external
        override
        onlyProtocolAdmin
    {
        uint256 len = registryId_.length;
        if (len != registryAddress_.length) revert Error.ARRAY_LENGTH_MISMATCH();

        for (uint256 i; i < len; ++i) {
            address registryAddress = registryAddress_[i];
            uint8 registryId = registryId_[i];
            if (registryAddress == address(0)) revert Error.ZERO_ADDRESS();
            if (registryId == 0) revert Error.ZERO_INPUT_VALUE();
            if (registryAddresses[registryId] != address(0)) {
                revert Error.DISABLED();
            }

            registryAddresses[registryId] = registryAddress;
            stateRegistryIds[registryAddress] = registryId;
            emit SetStateRegistryAddress(registryId, registryAddress);
        }
    }

    /// @inheritdoc QuorumManager
    function setRequiredMessagingQuorum(uint64 srcChainId_, uint256 quorum_) external override onlyProtocolAdmin {
        if (srcChainId_ == 0) {
            revert Error.INVALID_CHAIN_ID();
        }

        requiredQuorum[srcChainId_] = quorum_;

        emit QuorumSet(srcChainId_, quorum_);
    }
}
