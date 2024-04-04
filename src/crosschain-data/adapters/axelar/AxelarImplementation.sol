// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Error } from "src/libraries/Error.sol";
import { DataLib } from "src/libraries/DataLib.sol";
import { AMBMessage } from "src/types/DataTypes.sol";
import { ISuperRBAC } from "src/interfaces/ISuperRBAC.sol";
import { IAmbImplementation } from "src/interfaces/IAmbImplementation.sol";
import { IBaseStateRegistry } from "src/interfaces/IBaseStateRegistry.sol";
import { ISuperRegistry } from "src/interfaces/ISuperRegistry.sol";
import { IAxelarGasService } from "src/vendor/axelar/IAxelarGasService.sol";
import { IAxelarGateway } from "src/vendor/axelar/IAxelarGateway.sol";
import { IInterchainGasEstimation } from "src/vendor/axelar/IInterchainGasEstimation.sol";
import { IAxelarExecutable } from "src/vendor/axelar/IAxelarExecutable.sol";
import { StringAddressConversion } from "src/vendor/axelar/StringAddressConversion.sol";

contract AxelarImplementation is IAmbImplementation, IAxelarExecutable {
    using DataLib for uint256;
    using StringAddressConversion for address;
    using StringAddressConversion for string;

    //////////////////////////////////////////////////////////////
    //                         CONSTANTS                        //
    //////////////////////////////////////////////////////////////

    ISuperRegistry public immutable superRegistry;

    //////////////////////////////////////////////////////////////
    //                     STATE VARIABLES                      //
    //////////////////////////////////////////////////////////////
    IAxelarGateway public gateway;
    IAxelarGasService public gasService;
    IInterchainGasEstimation public gasEstimator;

    mapping(uint64 => string) public ambChainId;
    mapping(string => uint64) public superChainId;
    mapping(string => address) public authorizedImpl;
    mapping(bytes32 => bool) public processedMessages;

    //////////////////////////////////////////////////////////////
    //                          EVENTS                          //
    //////////////////////////////////////////////////////////////

    event GatewayAdded(address indexed _newGateway);
    event GasServiceAdded(address indexed _newGasService);
    event GasEstimatorAdded(address indexed _newGasEstimator);

    //////////////////////////////////////////////////////////////
    //                       MODIFIERS                          //
    //////////////////////////////////////////////////////////////

    modifier onlyProtocolAdmin() {
        if (!ISuperRBAC(superRegistry.getAddress(keccak256("SUPER_RBAC"))).hasProtocolAdminRole(msg.sender)) {
            revert Error.NOT_PROTOCOL_ADMIN();
        }
        _;
    }

    modifier onlyValidStateRegistry() {
        if (!superRegistry.isValidStateRegistry(msg.sender)) {
            revert Error.NOT_STATE_REGISTRY();
        }
        _;
    }

    //////////////////////////////////////////////////////////////
    //                      CONSTRUCTOR                         //
    //////////////////////////////////////////////////////////////

    constructor(ISuperRegistry superRegistry_) {
        superRegistry = superRegistry_;
    }

    //////////////////////////////////////////////////////////////
    //                         CONFIG                            //
    //////////////////////////////////////////////////////////////

    /// @dev allows protocol admin to configure axelar gateway, axelar gas service and axelar gas estimator
    /// @param gateway_ is the address of axelar gateway
    /// @param gasService_ is the address of axelar gas service
    /// @param gasEstimator_ is the address of axelar onchain gas estimation service
    function setAxelarConfig(
        IAxelarGateway gateway_,
        IAxelarGasService gasService_,
        IInterchainGasEstimation gasEstimator_
    )
        external
        onlyProtocolAdmin
    {
        if (
            address(gateway_) == address(0) || address(gasService_) == address(0)
                || address(gasEstimator_) == address(0)
        ) revert Error.ZERO_ADDRESS();

        gateway = gateway_;
        gasService = gasService_;
        gasEstimator = gasEstimator_;

        emit GatewayAdded(address(gateway_));
        emit GasServiceAdded(address(gasService_));
        emit GasEstimatorAdded(address(gasEstimator_));
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL VIEW FUNCTIONS                     //
    //////////////////////////////////////////////////////////////

    /// @inheritdoc IAmbImplementation
    function estimateFees(
        uint64 dstChainId_,
        bytes memory message_,
        bytes memory extraData_
    )
        external
        view
        override
        returns (uint256 fees)
    {
        string memory axelarChainId = ambChainId[dstChainId_];
        /// @dev the destinationAddress is not used in the upstream axelar contract; hence passing in zero address
        /// @dev the params is also not used; hence passing in bytes(0)
        return gasEstimator.estimateGasFee(
            axelarChainId, address(0).toString(), message_, abi.decode(extraData_, (uint256)), bytes("")
        );
    }

    /// @inheritdoc IAmbImplementation
    function generateExtraData(uint256 gasLimit) external pure override returns (bytes memory extraData) {
        /// @notice encoded dst gas limit
        extraData = abi.encode(gasLimit);
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL WRITE FUNCTIONS                    //
    //////////////////////////////////////////////////////////////

    /// @inheritdoc IAmbImplementation
    function dispatchPayload(
        address srcSender_,
        uint64 dstChainId_,
        bytes memory message_,
        bytes memory /*e xtraData_ */
    )
        external
        payable
        virtual
        override
        onlyValidStateRegistry
    {
        string memory axelarChainId = ambChainId[dstChainId_];
        string memory axelerDstImpl = authorizedImpl[axelarChainId].toString();

        if (bytes(axelarChainId).length == 0) {
            revert Error.INVALID_CHAIN_ID();
        }

        gateway.callContract(axelarChainId, axelerDstImpl, message_);
        /// FIXME: should the sender be the state registry / address(this) ??
        gasService.payNativeGasForContractCall{ value: msg.value }(
            msg.sender, axelarChainId, axelerDstImpl, message_, srcSender_
        );
    }

    /// @inheritdoc IAmbImplementation
    function retryPayload(bytes memory data_) external payable override { }

    /// @inheritdoc IAxelarExecutable
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    )
        external
        override
    {
        /// @dev 1. validate caller
        /// @dev 2. validate src chain sender
        /// @dev 3. validate message uniqueness

        /// FIXME: if this string equality check is safe
        if (keccak256(bytes(sourceAddress)) != keccak256(bytes(authorizedImpl[sourceChain].toString()))) {
            revert Error.INVALID_SRC_SENDER();
        }

        /// FIXME: add custom error message
        if (!gateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload))) {
            revert();
        }

        /// @dev validateContractCall has native replay protection, this is additional
        bytes32 msgId = keccak256(abi.encode(commandId, payload));

        if (processedMessages[msgId]) {
            revert Error.DUPLICATE_PAYLOAD();
        }

        processedMessages[msgId] = true;

        /// @dev decoding payload
        AMBMessage memory decoded = abi.decode(payload, (AMBMessage));

        /// NOTE: experimental split of registry contracts
        (,,, uint8 registryId,,) = decoded.txInfo.decodeTxInfo();
        IBaseStateRegistry targetRegistry = IBaseStateRegistry(superRegistry.getStateRegistry(registryId));

        uint64 origin = superChainId[sourceChain];

        if (origin == 0) {
            revert Error.INVALID_CHAIN_ID();
        }

        targetRegistry.receivePayload(origin, payload);
    }

    /// @dev allows protocol admin to add new chain ids in future
    /// @param superChainId_ is the identifier of the chain within superform protocol
    /// @param ambChainId_ is the identifier of the chain given by the AMB
    /// NOTE: cannot be defined in an interface as types vary for each message bridge (amb)
    function setChainId(uint64 superChainId_, string memory ambChainId_) external onlyProtocolAdmin {
        if (superChainId_ == 0 || bytes(ambChainId_).length == 0) {
            revert Error.INVALID_CHAIN_ID();
        }

        // @dev  reset old mappings
        uint64 oldSuperChainId = superChainId[ambChainId_];
        string memory oldAmbChainId = ambChainId[superChainId_];

        if (oldSuperChainId != 0) {
            delete ambChainId[oldSuperChainId];
        }

        if (bytes(oldAmbChainId).length != 0) {
            delete superChainId[oldAmbChainId];
        }

        ambChainId[superChainId_] = ambChainId_;
        superChainId[ambChainId_] = superChainId_;

        emit ChainAdded(superChainId_);
    }

    /// @dev allows protocol admin to set receiver implementation on a new chain id
    /// @param ambChainId_ is the identifier of the destination chain within axelar
    /// @param authorizedImpl_ is the implementation of the axelar message bridge on the specified destination
    /// NOTE: cannot be defined in an interface as types vary for each message bridge (amb)
    function setReceiver(string memory ambChainId_, address authorizedImpl_) external onlyProtocolAdmin {
        if (bytes(ambChainId_).length == 0) {
            revert Error.INVALID_CHAIN_ID();
        }

        if (authorizedImpl_ == address(0)) {
            revert Error.ZERO_ADDRESS();
        }

        authorizedImpl[ambChainId_] = authorizedImpl_;

        emit AuthorizedImplAdded(superChainId[ambChainId_], authorizedImpl_);
    }
}
