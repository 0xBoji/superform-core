// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

// Contracts
import "contracts/types/socketTypes.sol";
import "contracts/types/lzTypes.sol";
import "forge-std/console.sol";

// Test Utils
import {MockERC20} from "./mocks/MockERC20.sol";
import "./utils/BaseSetup.sol";

/// @dev interchain test cases to do
/// FTM=>BSC: user depositing to a vault requiring swap (stays pending) - REVERTS
/// FTM=>BSC: cross-chain slippage update beyond max slippage - REVERTS
/// FTM=>BSC: cross-chain slippage update above received value - REVERTS
/// FTM=>BSC: cross-chain slippage update from unauthorized wallet - REVERTS

contract BaseProtocolTest is BaseSetup {
    mapping(uint256 => uint256[]) internal VAULTS_ACTIONS;
    mapping(uint256 => mapping(Kind => uint256[])) internal AMOUNTS_ACTIONS;

    /*//////////////////////////////////////////////////////////////
                !! WARNING !!  DEFINE TEST SETTINGS HERE
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant numberOfTestActions = 4; /// @dev <- change this whenever you add/remove test cases

    function setUp() public override {
        super.setUp();

        /*//////////////////////////////////////////////////////////////
                    !! WARNING !!  DEFINE TEST SETTINGS HERE
        //////////////////////////////////////////////////////////////*/
        /// @dev Define Vault-Amount pairs for each type of test case you want to test
        /// @dev These have been done with state variables for direct inline input
        /// @dev You can modify the amounts/vaults at will and create more kinds
        /// @dev Kind partial vs full are only defined for cosmetic purposes in the test for now
        /// !! WARNING - only 3 vaults/underlyings exist, Ids 1,2,3 !!

        // Type 0 - Single Vault x One StateReq/LiqReq
        VAULTS_ACTIONS[0] = [uint256(1)];
        AMOUNTS_ACTIONS[0][Kind.Full] = [uint256(1000)];

        // Type 1 - Single Vault x Two StateReq/LiqReq
        VAULTS_ACTIONS[1] = [uint256(1), 3];
        // With Full withdrawal (note, deposits are always full)
        AMOUNTS_ACTIONS[1][Kind.Full] = [uint256(1000), 5000];
        // With Partial withdrawal
        AMOUNTS_ACTIONS[1][Kind.Partial] = [uint256(500), 2000];
    }

    function _getTestAction(uint256 index_)
        internal
        view
        returns (TestAction memory)
    {
        /*//////////////////////////////////////////////////////////////
                    !! WARNING !!  DEFINE TEST SETTINGS HERE
        //////////////////////////////////////////////////////////////*/
        TestAction[numberOfTestActions] memory testActionCases = [
            /// FTM=>BSC: user depositing to a vault on BSC from Fantom
            TestAction({
                action: Actions.Deposit,
                testType: 0,
                kind: Kind.Full,
                CHAIN_0: FTM,
                CHAIN_1: BSC,
                user: users[0],
                revertString: ""
            }),
            /// FTM=>BSC: user withdrawing tokens from a vault on BSC from/to Fantom
            TestAction({
                action: Actions.Withdraw,
                testType: 0,
                kind: Kind.Full,
                CHAIN_0: FTM,
                CHAIN_1: BSC,
                user: users[0],
                revertString: ""
            }),
            /// FTM=>BSC: multiple LiqReq/StateReq for multi-deposit
            /// BSC=>FTM: user depositing to a vault on Fantom from BSC
            TestAction({
                action: Actions.Deposit,
                testType: 1,
                kind: Kind.Full,
                CHAIN_0: BSC,
                CHAIN_1: FTM,
                user: users[2],
                revertString: ""
            }),
            /// FTM=>BSC: multiple LiqReq/StateReq for multi-deposit
            /// BSC=>FTM: partial withdraw tokens from a vault on Fantom from/to BSC
            TestAction({
                action: Actions.Withdraw,
                testType: 1,
                kind: Kind.Partial,
                CHAIN_0: BSC,
                CHAIN_1: FTM,
                user: users[2],
                revertString: ""
            })
        ];

        return testActionCases[index_];
    }

    /*///////////////////////////////////////////////////////////////
                        SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_actions() public {
        /// @dev do the test actions in order

        for (uint256 i = 0; i < numberOfTestActions; i++) {
            TestAction memory action = _getTestAction(i);

            ActionLocalVars memory vars;

            vars.lzEndpoint_0 = LZ_ENDPOINTS[action.CHAIN_0];
            vars.lzEndpoint_1 = LZ_ENDPOINTS[action.CHAIN_1];
            vars.fromSrc = payable(getContract(action.CHAIN_0, "SuperRouter"));
            vars.toDst = payable(
                getContract(action.CHAIN_1, "SuperDestination")
            );

            (
                vars.targetVaultIds,
                vars.underlyingSrcToken,
                vars.vaultMock,
                vars.TARGET_VAULTS
            ) = _targetVaults(action.testType, action.CHAIN_0, action.CHAIN_1);
            vars.amounts = _amounts(action.testType, action.kind);

            if (action.action == Actions.Deposit) {
                deposit(action, vars);
            } else if (action.action == Actions.Withdraw) {
                withdraw(action, vars);
            }
        }
        _resetPayloadIDs();
    }

    /*///////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev this function is used to build the 2D arrays in the best way possible
    function _targetVaults(
        uint256 action,
        uint16 chain0,
        uint16 chain1
    )
        internal
        view
        returns (
            uint256[][] memory targetVaultsMem,
            address[][] memory underlyingSrcTokensMem,
            address[][] memory vaultMocksMem,
            MockERC20[][] memory TARGET_VAULTSMem
        )
    {
        uint256[] memory vaultIdsTemp = VAULTS_ACTIONS[action];
        uint256 len = vaultIdsTemp.length;
        if (len == 0) revert LEN_VAULTS_ZERO();

        targetVaultsMem = new uint256[][](len);
        underlyingSrcTokensMem = new address[][](len);
        vaultMocksMem = new address[][](len);
        TARGET_VAULTSMem = new MockERC20[][](len);

        for (uint256 i = 0; i < len; i++) {
            uint256[] memory tVaults = new uint256[](
                allowedNumberOfVaultsPerRequest
            );
            address[] memory tUnderlyingSrcTokens = new address[](
                allowedNumberOfVaultsPerRequest
            );
            address[] memory tVaultMocks = new address[](
                allowedNumberOfVaultsPerRequest
            );
            MockERC20[] memory tTARGET_VAULTS = new MockERC20[](
                allowedNumberOfVaultsPerRequest
            );

            for (uint256 j = 0; j < allowedNumberOfVaultsPerRequest; j++) {
                tVaults[j] = vaultIdsTemp[i];
                string memory underlyingToken = UNDERLYING_TOKENS[
                    vaultIdsTemp[i] - 1
                ];
                tUnderlyingSrcTokens[j] = getContract(chain0, underlyingToken);
                tVaultMocks[j] = getContract(
                    chain1,
                    VAULT_NAMES[vaultIdsTemp[i] - 1]
                );
                tTARGET_VAULTS[j] = MockERC20(
                    getContract(chain1, underlyingToken)
                );
            }
            targetVaultsMem[i] = tVaults;
            underlyingSrcTokensMem[i] = tUnderlyingSrcTokens;
            vaultMocksMem[i] = tVaultMocks;
            TARGET_VAULTSMem[i] = tTARGET_VAULTS;
        }
    }

    /// @dev this function is used to build the 2D arrays in the best way possible
    function _amounts(uint256 action, Kind kind)
        internal
        view
        returns (uint256[][] memory targetAmountsMem)
    {
        uint256[] memory amountsTemp = AMOUNTS_ACTIONS[action][kind];
        uint256 len = amountsTemp.length;
        if (len == 0) revert LEN_AMOUNTS_ZERO();

        targetAmountsMem = new uint256[][](len);

        for (uint256 i = 0; i < len; i++) {
            uint256[] memory tAmounts = new uint256[](
                allowedNumberOfVaultsPerRequest
            );

            for (uint256 j = 0; j < allowedNumberOfVaultsPerRequest; j++) {
                tAmounts[j] = amountsTemp[i];
            }
            targetAmountsMem[i] = tAmounts;
        }
    }
}
