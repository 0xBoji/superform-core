// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { AbstractDeploySingle } from "./Abstract.Deploy.Single.s.sol";

contract MainnetDeploy is AbstractDeploySingle {
    /*//////////////////////////////////////////////////////////////
                        SELECT CHAIN IDS TO DEPLOY HERE
    //////////////////////////////////////////////////////////////*/
    uint64[] TARGET_DEPLOYMENT_CHAINS = [ETH, BSC, AVAX, POLY, ARBI, OP, BASE];

    ///@dev ORIGINAL SALT
    bytes32 constant salt = "SunNeverSetsOnSuperformRealm";

    /// @notice The main stage 1 script entrypoint
    function deployStage1(uint256 selectedChainIndex) external {
        PAYMENT_ADMIN = 0xD911673eAF0D3e15fe662D58De15511c5509bAbB;
        CSR_PROCESSOR = 0x23c658FE050B4eAeB9401768bF5911D11621629c;
        CSR_UPDATER = 0xaEbb4b9f7e16BEE2a0963569a5E33eE10E478a5f;
        DST_SWAPPER = 0x1666660D2F506e754CB5c8E21BDedC7DdEc6Be1C;
        CSR_RESCUER = 0x90ed07A867bDb6a73565D7abBc7434Dd810Fafc5;
        CSR_DISPUTER = 0x7c9c8C0A9aA5D8a2c2e6C746641117Cc9591296a;
        SUPERFORM_RECEIVER = 0x1a6805487322565202848f239C1B5bC32303C2FE;
        EMERGENCY_ADMIN = 0x73009CE7cFFc6C4c5363734d1b429f0b848e0490;

        _preDeploymentSetup();


        uint256 trueIndex;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (TARGET_DEPLOYMENT_CHAINS[selectedChainIndex] == chainIds[i]) {
                trueIndex = i;

                break;
            }
        }

        _deployStage1(selectedChainIndex, trueIndex, Cycle.Prod, TARGET_DEPLOYMENT_CHAINS, salt);
    }

    /// @dev stage 2 must be called only after stage 1 is complete for all chains!
    function deployStage2(uint256 selectedChainIndex) external {
        _preDeploymentSetup();

        uint256 trueIndex;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (TARGET_DEPLOYMENT_CHAINS[selectedChainIndex] == chainIds[i]) {
                trueIndex = i;
                break;
            }
        }

        _deployStage2(selectedChainIndex, trueIndex, Cycle.Prod, TARGET_DEPLOYMENT_CHAINS, TARGET_DEPLOYMENT_CHAINS);
    }

    /// @dev stage 3 must be called only after stage 1 is complete for all chains!
    function deployStage3(uint256 selectedChainIndex) external {
        _preDeploymentSetup();

        uint256 trueIndex;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (TARGET_DEPLOYMENT_CHAINS[selectedChainIndex] == chainIds[i]) {
                trueIndex = i;
                break;
            }
        }

        _deployStage3(selectedChainIndex, trueIndex, Cycle.Prod, TARGET_DEPLOYMENT_CHAINS);
    }
}
