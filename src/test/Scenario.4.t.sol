/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

// Contracts
import "../types/LiquidityTypes.sol";
import "../types/DataTypes.sol";
import "forge-std/console.sol";

// Test Utils
import {MockERC20} from "./mocks/MockERC20.sol";
import "./utils/ProtocolActions.sol";

/// @dev TODO - we should do assertions on final balances of users at the end of each test scenario
/// @dev FIXME - using unoptimized multiDstMultivault function
contract Scenario4Test is ProtocolActions {
    function setUp() public override {
        super.setUp();
        /*//////////////////////////////////////////////////////////////
                !! WARNING !!  DEFINE TEST SETTINGS HERE
    //////////////////////////////////////////////////////////////*/
        /// @dev singleDestinationXChainDeposit Full singleDestinationXChainWithdraw Deposit test case

        primaryAMB = 1;

        secondaryAMBs = [2];

        CHAIN_0 = ETH;
        DST_CHAINS = [ARBI];

        /// @dev define vaults amounts and slippage for every destination chain and for every action
        TARGET_UNDERLYING_VAULTS[ARBI][0] = [2];
        TARGET_UNDERLYING_VAULTS[ARBI][1] = [2];

        AMOUNTS[ARBI][0] = [1000];
        AMOUNTS[ARBI][1] = [1000];

        MAX_SLIPPAGE[ARBI][0] = [1000];
        MAX_SLIPPAGE[ARBI][1] = [1000];

        /// @dev check if we need to have this here (it's being overriden)
        uint256 msgValue = 1 * _getPriceMultiplier(CHAIN_0) * 1e18;

        /// @dev push in order the actions should be executed
        actions.push(
            TestAction({
                action: Actions.Deposit,
                actionKind: LiquidityChange.Full, /// @dev same for all vaults currently / only applies in withdrawals
                multiVaults: false, /// @dev - !!WARNING turn on or off multi vaults
                user: users[0],
                testType: TestType.Pass,
                revertError: "",
                revertRole: "",
                slippage: 0, // 0% <- if we are testing a pass this must be below each maxSlippage,
                multiTx: false,
                adapterParam: "",
                msgValue: msgValue
            })
        );
        actions.push(
            TestAction({
                action: Actions.Withdraw,
                actionKind: LiquidityChange.Full, /// @dev same for all vaults currently / only applies in withdrawals
                multiVaults: false, /// @dev - !!WARNING turn on or off multi vaults
                user: users[0],
                testType: TestType.Pass,
                revertError: "",
                revertRole: "",
                slippage: 0, // 0% <- if we are testing a pass this must be below each maxSlippage,
                multiTx: false,
                adapterParam: "",
                msgValue: msgValue
            })
        );
    }

    /*///////////////////////////////////////////////////////////////
                        SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function xtest_scenario() public {
        _run_actions();
    }
}
