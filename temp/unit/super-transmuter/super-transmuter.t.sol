// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "test/utils/BaseSetup.sol";
import "test/utils/Utilities.sol";
import "test/utils/AmbParams.sol";

import { DataLib } from "src/libraries/DataLib.sol";
import { Transmuter } from "ERC1155A/transmuter/Transmuter.sol";
import { SuperTransmuter } from "src/SuperTransmuter.sol";
import { Error } from "src/utils/Error.sol";
import { VaultMock } from "test/mocks/VaultMock.sol";

contract SuperTransmuterTest is BaseSetup {
    SuperTransmuter public superTransmuter;
    address formImplementation;
    address vault;
    uint32 formBeaconId = 4;

    function setUp() public override {
        super.setUp();
        vm.selectFork(FORKS[ETH]);
        superTransmuter = SuperTransmuter(payable(getContract(ETH, "SuperTransmuter")));

        address superRegistry = getContract(ETH, "SuperRegistry");

        formImplementation = address(new ERC4626Form(superRegistry));
        vault = getContract(ETH, VAULT_NAMES[0][0]);
        vm.prank(deployer);
        SuperformFactory(getContract(ETH, "SuperformFactory")).addFormBeacon(formImplementation, formBeaconId, salt);
    }

    function test_registerTransmuter_invalid_interface() public {
        (uint256 superformId,) =
            SuperformFactory(getContract(ETH, "SuperformFactory")).createSuperform(formBeaconId, vault);
        vm.expectRevert(Error.DISABLED.selector);
        superTransmuter.registerTransmuter(1, "", "", 1);
    }

    function test_registerTransmuter() public {
        (uint256 superformId,) =
            SuperformFactory(getContract(ETH, "SuperformFactory")).createSuperform(formBeaconId, vault);
        superTransmuter.registerTransmuter(superformId, "");
    }

    function test_registerTransmuter_invalidExtraData() public {
        uint8[] memory ambId = new uint8[](1);
        ambId[0] = 4;
        (uint256 superformId,) =
            SuperformFactory(getContract(ETH, "SuperformFactory")).createSuperform(formBeaconId, vault);
        vm.expectRevert();
        superTransmuter.registerTransmuter(superformId, abi.encode(ambId, 1));
    }

    function test_registerTransmuter_invalidBroadcastRegistryAddress() public {
        vm.prank(deployer);
        SuperRegistry(getContract(ETH, "SuperRegistry")).setAddress(keccak256("BROADCAST_REGISTRY"), address(0), ETH);

        (uint256 superformId,) =
            SuperformFactory(getContract(ETH, "SuperformFactory")).createSuperform(formBeaconId, vault);
        vm.expectRevert();
        superTransmuter.registerTransmuter(superformId, generateBroadcastParams(5, 1));
    }

    function test_withdrawFromInvalidChainId() public {
        address superform =
            getContract(ETH, string.concat("USDT", "VaultMock", "Superform", Strings.toString(FORM_BEACON_IDS[0])));

        uint256 superformId = DataLib.packSuperform(superform, FORM_BEACON_IDS[0], ARBI);

        vm.expectRevert(Error.INVALID_CHAIN_ID.selector);

        superTransmuter.registerTransmuter(superformId, "");
    }

    function test_InvalidSuperFormAddress() public {
        uint256 invalidSuperFormId = DataLib.packSuperform(address(0), 4, ETH);
        vm.expectRevert(Error.NOT_SUPERFORM.selector);
        superTransmuter.registerTransmuter(invalidSuperFormId, "");
    }

    function test_InvalidFormBeacon() public {
        uint256 invalidSuperFormId = DataLib.packSuperform(address(0x777), 0, ETH);
        vm.expectRevert(Error.FORM_DOES_NOT_EXIST.selector);
        superTransmuter.registerTransmuter(invalidSuperFormId, "");
    }

    function test_alreadyRegistered() public {
        (uint256 superformId,) =
            SuperformFactory(getContract(ETH, "SuperformFactory")).createSuperform(formBeaconId, vault);
        superTransmuter.registerTransmuter(superformId, "");
        vm.expectRevert(Transmuter.TRANSMUTER_ALREADY_REGISTERED.selector);

        superTransmuter.registerTransmuter(superformId, "");
    }

    function test_broadcastAndDeploy() public {
        (uint256 superformId,) =
            SuperformFactory(getContract(ETH, "SuperformFactory")).createSuperform(formBeaconId, vault);

        vm.recordLogs();
        superTransmuter.registerTransmuter(superformId, generateBroadcastParams(5, 1));

        vm.startPrank(deployer);
        _broadcastPayloadHelper(ETH, vm.getRecordedLogs());

        for (uint256 i; i < chainIds.length; i++) {
            if (chainIds[i] != ETH) {
                vm.selectFork(FORKS[chainIds[i]]);
                BroadcastRegistry(payable(getContract(chainIds[i], "BroadcastRegistry"))).processPayload(1);

                assertGt(
                    uint256(
                        uint160(
                            SuperTransmuter(getContract(chainIds[i], "SuperTransmuter")).synthethicTokenId(superformId)
                        )
                    ),
                    uint256(0)
                );
            }
        }
    }
}
