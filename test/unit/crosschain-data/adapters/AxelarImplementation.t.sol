// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.23;

import "test/utils/BaseSetup.sol";
import { ISuperRegistry } from "src/interfaces/ISuperRegistry.sol";
import { IAxelarGateway } from "src/vendor/axelar/IAxelarGateway.sol";
import { IAxelarGasService } from "src/vendor/axelar/IAxelarGasService.sol";
import { IInterchainGasEstimation } from "src/vendor/axelar/IInterchainGasEstimation.sol";
import { Error } from "src/libraries/Error.sol";
import { DataLib } from "src/libraries/DataLib.sol";

contract InvalidReceiver {
    receive() external payable {
        revert();
    }
}

contract AxelarImplementationTest is BaseSetup {
    AxelarImplementation public axelarImpl;
    ISuperRegistry public superRegistry;
    IAxelarGateway public gateway;
    IAxelarGasService public gasService;
    IInterchainGasEstimation public gasEstimator;

    address invalidReceiver;
    address protocolAdmin;

    function setUp() public override {
        super.setUp();

        vm.selectFork(FORKS[ETH]);
        superRegistry = ISuperRegistry(getContract(ETH, "SuperRegistry"));

        axelarImpl = AxelarImplementation(payable(superRegistry.getAmbAddress(5)));
        gateway = IAxelarGateway(axelarGateway[0]);
        gasService = IAxelarGasService(axelarGasService[0]);
        gasEstimator = IInterchainGasEstimation(axelarGasService[0]);
        invalidReceiver = address(new InvalidReceiver());
        protocolAdmin = deployer;
    }

    function test_setAxelarConfig_ZeroAddress() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Error.ZERO_ADDRESS.selector);
        axelarImpl.setAxelarConfig(IAxelarGateway(address(0)));
    }

    function test_setAxelarConfig_GatewayExists() public {
        // Attempt to set the gateway again
        vm.prank(protocolAdmin);
        vm.expectRevert(AxelarImplementation.GATEWAY_EXISTS.selector);
        axelarImpl.setAxelarConfig(IAxelarGateway(address(0x5678)));
    }

    function test_setAxelarGasService_ZeroAddress() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Error.ZERO_ADDRESS.selector);
        axelarImpl.setAxelarGasService(IAxelarGasService(address(0)), IInterchainGasEstimation(address(420)));

        vm.prank(protocolAdmin);
        vm.expectRevert(Error.ZERO_ADDRESS.selector);
        axelarImpl.setAxelarGasService(IAxelarGasService(address(420)), IInterchainGasEstimation(address(0)));
    }

    function test_setChainId_InvalidChainId() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Error.INVALID_CHAIN_ID.selector);
        axelarImpl.setChainId(0, "");

        vm.prank(protocolAdmin);
        vm.expectRevert(Error.INVALID_CHAIN_ID.selector);
        axelarImpl.setChainId(1, "");
    }

    function test_setChainId_NonProtocolAdmin() public {
        vm.prank(address(0x5678));
        vm.expectRevert(Error.NOT_PROTOCOL_ADMIN.selector);
        axelarImpl.setChainId(1, "chain1");
    }

    function test_setReceiver_NonProtocolAdmin() public {
        vm.prank(address(0x5678));
        vm.expectRevert(Error.NOT_PROTOCOL_ADMIN.selector);
        axelarImpl.setReceiver("chain1", address(0x1234));
    }

    function test_dispatchPayload_NonValidStateRegistry() public {
        vm.prank(address(0x5678));
        vm.expectRevert(Error.NOT_STATE_REGISTRY.selector);
        axelarImpl.dispatchPayload(address(this), 1, bytes("testmessage"), abi.encode(1, 500_000));
    }

    function test_setReceiver_ZeroAddress() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Error.ZERO_ADDRESS.selector);
        axelarImpl.setReceiver("chain1", address(0));
    }

    function test_execute_InvalidPayload() public {
        bytes32 commandId = keccak256("test");
        string memory sourceChain = "Polygon";
        string memory sourceAddress = _toString(getContract(POLY, "AxelarImplementation"));

        bytes memory payload = abi.encode(bytes32(0), sourceChain, sourceAddress, bytes(""));

        vm.prank(address(gateway));
        vm.expectRevert(AxelarImplementation.INVALID_CONTRACT_CALL.selector);
        axelarImpl.execute(commandId, sourceChain, sourceAddress, payload);
    }

    function test_execute_InvalidChainId() public {
        vm.prank(protocolAdmin);
        axelarImpl.setReceiver("invalid-chain", address(420));

        bytes32 commandId = keccak256("test");
        string memory sourceChain = "invalid-chain";
        string memory sourceAddress = _toString(address(420));

        AMBMessage memory ambMessage = AMBMessage(
            DataLib.packTxInfo(uint8(TransactionType.DEPOSIT), uint8(CallbackType.INIT), 0, 1, address(this), POLY),
            abi.encode(new uint8[](0), "")
        );

        bytes memory payload = abi.encode(ambMessage);

        vm.mockCall(
            address(axelarImpl.gateway()),
            abi.encodeWithSelector(
                IAxelarGateway(axelarImpl.gateway()).validateContractCall.selector,
                commandId,
                sourceChain,
                sourceAddress,
                keccak256(payload)
            ),
            abi.encode(true)
        );

        vm.prank(address(gateway));
        vm.expectRevert(Error.INVALID_CHAIN_ID.selector);
        axelarImpl.execute(commandId, sourceChain, sourceAddress, payload);
    }

    function test_estimateFees_InvalidChainId() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Error.INVALID_CHAIN_ID.selector);
        axelarImpl.estimateFees(111, "", abi.encode(1, 1));
    }

    function test_dispatchPayload_InvalidChainId() public {
        vm.prank(superRegistry.getAddress(keccak256("CORE_STATE_REGISTRY")));
        vm.expectRevert(Error.INVALID_CHAIN_ID.selector);
        axelarImpl.dispatchPayload(address(this), 111, bytes("testmessage"), abi.encode(1, 500_000));
    }

    function test_execute_InvalidSrcSender() public {
        bytes32 commandId = keccak256("test");
        string memory sourceChain = "source-chain";
        string memory sourceAddress = "source-address";
        bytes memory payload = abi.encode(commandId, sourceChain, sourceAddress, bytes(""));

        vm.mockCall(
            address(axelarImpl.gateway()),
            abi.encodeWithSelector(
                IAxelarGateway(axelarImpl.gateway()).validateContractCall.selector,
                commandId,
                sourceChain,
                sourceAddress,
                keccak256(payload)
            ),
            abi.encode(true)
        );

        vm.prank(address(0x1234));
        vm.expectRevert(Error.INVALID_SRC_SENDER.selector);
        axelarImpl.execute(commandId, sourceChain, sourceAddress, payload);

        vm.clearMockedCalls();
    }

    function test_execute_DuplicatePayload() public {
        bytes32 commandId = keccak256("test");
        string memory sourceChain = "Polygon";
        string memory sourceAddress = _toString(getContract(POLY, "AxelarImplementation"));

        AMBMessage memory ambMessage = AMBMessage(
            DataLib.packTxInfo(uint8(TransactionType.DEPOSIT), uint8(CallbackType.INIT), 0, 1, deployer, ETH),
            abi.encode(new uint8[](0), "")
        );

        bytes memory payload = abi.encode(ambMessage);

        vm.mockCall(
            address(axelarImpl.gateway()),
            abi.encodeWithSelector(
                IAxelarGateway(axelarImpl.gateway()).validateContractCall.selector,
                commandId,
                sourceChain,
                sourceAddress,
                keccak256(payload)
            ),
            abi.encode(true)
        );

        vm.prank(address(gateway));
        axelarImpl.execute(commandId, sourceChain, sourceAddress, payload);

        vm.prank(address(gateway));
        vm.expectRevert(Error.DUPLICATE_PAYLOAD.selector);
        axelarImpl.execute(commandId, sourceChain, sourceAddress, payload);

        vm.clearMockedCalls();
    }

    function _toString(address addr) internal pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(addr);
        uint256 length = addressBytes.length;
        bytes memory characters = "0123456789abcdef";
        bytes memory stringBytes = new bytes(2 + addressBytes.length * 2);

        stringBytes[0] = "0";
        stringBytes[1] = "x";

        for (uint256 i; i < length; ++i) {
            stringBytes[2 + i * 2] = characters[uint8(addressBytes[i] >> 4)];
            stringBytes[3 + i * 2] = characters[uint8(addressBytes[i] & 0x0f)];
        }
        return string(stringBytes);
    }
}
