/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

// Contracts
import "../types/LiquidityTypes.sol";
import "../types/DataTypes.sol";
// Test Utils
import {MockERC20} from "./mocks/MockERC20.sol";
import "./utils/ProtocolActions.sol";
import "./utils/AmbParams.sol";

/// @dev TODO - we should do assertions on final balances of users at the end of each test scenario
/// @dev FIXME - using unoptimized multiDstMultivault function
contract Scenario3Test is ProtocolActions {
    function setUp() public override {
        super.setUp();
        /*//////////////////////////////////////////////////////////////
                !! WARNING !!  DEFINE TEST SETTINGS HERE
    //////////////////////////////////////////////////////////////*/
        /// @dev MultiDestinationMultiVault Deposit test case

        AMBs = [1, 2];

        CHAIN_0 = OP;
        DST_CHAINS = [ARBI, ETH];

        /// @dev define vaults amounts and slippage for every destination chain and for every action
        TARGET_UNDERLYING_VAULTS[ARBI][0] = [1, 2];
        TARGET_FORM_KINDS[ARBI][0] = [0, 0];

        TARGET_UNDERLYING_VAULTS[ETH][0] = [0];
        TARGET_FORM_KINDS[ETH][0] = [0];

        AMOUNTS[ARBI][0] = [1000, 500];
        AMOUNTS[ETH][0] = [100];

        MAX_SLIPPAGE[ARBI][0] = [1000, 1000];
        MAX_SLIPPAGE[ETH][0] = [1000];

        actions.push(
            TestAction({
                action: Actions.Deposit,
                multiVaults: true, //!!WARNING turn on or off multi vaults
                user: 0,
                testType: TestType.Pass,
                revertError: "",
                revertRole: "",
                slippage: 0, // 0% <- if we are testing a pass this must be below each maxSlippage,
                multiTx: false,
                ambParams: generateAmbParams(DST_CHAINS.length, 2),
                msgValue: 50 * 10 ** 18,
                externalToken: 0 // 0 = DAI, 1 = USDT, 2 = WETH
            })
        );
    }

    /*///////////////////////////////////////////////////////////////
                        SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_scenario() public {
        for (uint256 act = 0; act < actions.length; act++) {
            TestAction memory action = actions[act];
            MultiVaultsSFData[] memory multiSuperFormsData;
            SingleVaultSFData[] memory singleSuperFormsData;
            MessagingAssertVars[] memory aV;
            StagesLocalVars memory vars;
            bool success;

            (
                multiSuperFormsData,
                singleSuperFormsData,
                vars
            ) = _stage1_buildReqData(action, act);

            vars = _stage2_run_src_action(
                action,
                multiSuperFormsData,
                singleSuperFormsData,
                vars
            );

            aV = _stage3_src_to_dst_amb_delivery(
                action,
                vars,
                multiSuperFormsData,
                singleSuperFormsData
            );

            success = _stage4_process_src_dst_payload(
                action,
                vars,
                aV,
                singleSuperFormsData,
                act
            );

            if (!success) {
                continue;
            }

            if (
                action.action == Actions.Deposit ||
                action.action == Actions.DepositPermit2
            ) {
                success = _stage5_process_superPositions_mint(action, vars);
                if (!success) {
                    continue;
                }
            }
        }
    }
}
