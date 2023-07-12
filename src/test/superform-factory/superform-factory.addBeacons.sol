// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.19;

import {ISuperFormFactory} from "src/interfaces/ISuperFormFactory.sol";
import {ISuperRegistry} from "src/interfaces/ISuperRegistry.sol";
import {SuperFormFactory} from "src/SuperFormFactory.sol";
import {FactoryStateRegistry} from "src/crosschain-data/extensions/FactoryStateRegistry.sol";
import {ERC4626Form} from "src/forms/ERC4626Form.sol";
import {ERC4626TimelockForm} from "src/forms/ERC4626TimelockForm.sol";
import "src/test/utils/BaseSetup.sol";
import "src/test/utils/Utilities.sol";
import {Error} from "src/utils/Error.sol";
import "src/utils/DataPacking.sol";

contract SuperFormFactoryTest is BaseSetup {
    uint64 internal chainId = ETH;

    /*///////////////////////////////////////////////////////////////
                            Constants
    //////////////////////////////////////////////////////////////*/
    uint32 constant MAX_FORMS = 2;

    function setUp() public override {
        super.setUp();
    }
    
    /// Testing superform creation by adding multiple forms
    /// TODO: Implement create2 in superform ID to assert superform address is same as the one provided
    function test_addForms() public {
        vm.startPrank(deployer);

        address[] memory formImplementations = new address[](MAX_FORMS);
        uint32[] memory formBeaconIds = new uint32[](MAX_FORMS);
        
        for (uint32 i = 0; i < MAX_FORMS; i++) {
            formImplementations[i]= (address(new ERC4626Form(getContract(chainId, "SuperRegistry"))));
            formBeaconIds[i]= i + 10;
        }

        SuperFormFactory(getContract(chainId, "SuperFormFactory")).addFormBeacons(
            formImplementations,
            formBeaconIds,
            salt
        );
    }

    /// Testing adding same beacon id multiple times
    /// Should Revert With BEACON_ID_ALREADY_EXISTS
    function test_revert_addForms_sameBeaconID() public {
        address[] memory formImplementations = new address[](MAX_FORMS);
        uint32[] memory formBeaconIds = new uint32[](MAX_FORMS);
        uint32 FORM_BEACON_ID = 0;
        
        for (uint32 i = 0; i < MAX_FORMS; i++) {
            formImplementations[i]= address(new ERC4626Form(getContract(chainId, "SuperRegistry")));
            formBeaconIds[i]= FORM_BEACON_ID;
        }

        vm.prank(deployer);

        vm.expectRevert(Error.BEACON_ID_ALREADY_EXISTS.selector);
        SuperFormFactory(getContract(chainId, "SuperFormFactory")).addFormBeacons(
            formImplementations,
            formBeaconIds,
            salt
        );

    }

    /// Testing adding form with form address 0
    /// Should Revert With ZERO_ADDRESS
    function test_revert_addForms_addressZero() public {
        address[] memory formImplementations = new address[](MAX_FORMS);
        uint32[] memory formBeaconIds = new uint32[](MAX_FORMS);
        
        /// Providing zero address to each of the forms
        for (uint32 i = 0; i < MAX_FORMS; i++) {
            formImplementations[i]= address(0);
            formBeaconIds[i]= i;
        }

        vm.prank(deployer);

        vm.expectRevert(Error.ZERO_ADDRESS.selector);
        SuperFormFactory(getContract(chainId, "SuperFormFactory")).addFormBeacons(
            formImplementations,
            formBeaconIds,
            salt
        );
    }

    /// Testing adding form with wrong form
    /// Should Revert With ERC165_UNSUPPORTED
    function test_revert_addForms_interfaceUnsupported() public {
        address[] memory formImplementations = new address[](MAX_FORMS);
        uint32[] memory formBeaconIds = new uint32[](MAX_FORMS);
        
        /// Keeping all but one beacon with right form
        for (uint32 i = 0; i < MAX_FORMS - 1; i++) {
            formImplementations[i]= address(new ERC4626Form(getContract(chainId, "SuperRegistry")));
            formBeaconIds[i]= i;
        }

        /// Last Beacon with wrong form
        formImplementations[MAX_FORMS-1]= address(0x1);
        formBeaconIds[MAX_FORMS-1]= formBeaconIds[MAX_FORMS-2] + 1;

        vm.prank(deployer);

        vm.expectRevert(Error.ERC165_UNSUPPORTED.selector);
        SuperFormFactory(getContract(chainId, "SuperFormFactory")).addFormBeacons(
            formImplementations,
            formBeaconIds,
            salt
        );
    }
}
