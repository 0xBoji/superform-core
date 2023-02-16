// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

/// @dev lib imports
import "@std/Test.sol";
import "@ds-test/test.sol";
import "forge-std/console.sol";
import {LayerZeroHelper} from "@pigeon/layerzero/LayerZeroHelper.sol";
import {FixedPointMathLib} from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

/// @dev src imports

import {LZEndpointMock} from "contracts/mocks/LzEndpointMock.sol";
import {VaultMock} from "contracts/mocks/VaultMock.sol";
import {IStateHandler} from "contracts/interface/layerzero/IStateHandler.sol";
import {StateHandler} from "contracts/layerzero/stateHandler.sol";
import {IController} from "contracts/interface/ISource.sol";
import {IDestination} from "contracts/interface/IDestination.sol";
import {IERC4626} from "contracts/interface/IERC4626.sol";
import {SuperRouter} from "contracts/SuperRouter.sol";
import {SuperDestination} from "contracts/SuperDestination.sol";

/// @dev local test imports
import {SocketRouterMockFork} from "../mocks/SocketRouterMockFork.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import "./TestTypes.sol";

abstract contract BaseSetup is DSTest, Test {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                        GENERAL VARIABLES
    //////////////////////////////////////////////////////////////*/

    address public deployer = address(777);
    address[] public users;
    mapping(uint16 => mapping(bytes32 => address)) public contracts;

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL VARIABLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant CORE_CONTRACTS_ROLE =
        keccak256("CORE_CONTRACTS_ROLE");
    bytes32 public constant PROCESSOR_CONTRACTS_ROLE =
        keccak256("PROCESSOR_CONTRACTS_ROLE");

    /// @dev one vault per request at the moment - do not change for now
    uint256 internal constant allowedNumberOfVaultsPerRequest = 1;

    /// @dev we should fork these instead of mocking
    string[] public UNDERLYING_TOKENS = ["DAI", "USDT", "WETH"];
    string[] public VAULT_NAMES;

    mapping(uint16 => IERC4626[]) vaults;
    mapping(uint16 => uint256[]) vaultIds;
    mapping(uint16 => uint256) PAYLOAD_ID; // chaindId => payloadId

    uint8[] bridgeIds;
    address[] bridgeAddresses;

    /*//////////////////////////////////////////////////////////////
                        LAYER ZERO VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(uint16 => address) public LZ_ENDPOINTS;

    address public constant ETH_lzEndpoint =
        0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675;
    address public constant BSC_lzEndpoint =
        0x3c2269811836af69497E5F486A85D7316753cf62;
    address public constant AVAX_lzEndpoint =
        0x3c2269811836af69497E5F486A85D7316753cf62;
    address public constant POLY_lzEndpoint =
        0x3c2269811836af69497E5F486A85D7316753cf62;
    address public constant ARBI_lzEndpoint =
        0x3c2269811836af69497E5F486A85D7316753cf62;
    address public constant OP_lzEndpoint =
        0x3c2269811836af69497E5F486A85D7316753cf62;
    address public constant FTM_lzEndpoint =
        0xb6319cC6c8c27A8F5dAF0dD3DF91EA35C4720dd7;

    address[7] public lzEndpoints = [
        0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675,
        0x3c2269811836af69497E5F486A85D7316753cf62,
        0x3c2269811836af69497E5F486A85D7316753cf62,
        0x3c2269811836af69497E5F486A85D7316753cf62,
        0x3c2269811836af69497E5F486A85D7316753cf62,
        0x3c2269811836af69497E5F486A85D7316753cf62,
        0xb6319cC6c8c27A8F5dAF0dD3DF91EA35C4720dd7
    ];

    /// @dev reference for chain ids https://layerzero.gitbook.io/docs/technical-reference/mainnet/supported-chain-ids
    uint16 public constant ETH = 101;
    uint16 public constant BSC = 102;
    uint16 public constant AVAX = 106;
    uint16 public constant POLY = 109;
    uint16 public constant ARBI = 110;
    uint16 public constant OP = 111;
    uint16 public constant FTM = 112;

    uint16[7] public chainIds = [101, 102, 106, 109, 110, 111, 112];

    uint16 public constant version = 1;
    uint256 public constant gasLimit = 1000000;
    uint256 public constant mockEstimatedNativeFee = 1000000000000000; // 0.001 Native Tokens
    uint256 public constant mockEstimatedZroFee = 250000000000000; // 0.00025 Native Tokens
    uint256 public constant milionTokensE18 = 1 ether;

    /*//////////////////////////////////////////////////////////////
                        CHAINLINK VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(uint16 => address) public PRICE_FEEDS;

    address public constant ETHEREUM_ETH_USD_FEED =
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant BSC_BNB_USD_FEED =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address public constant AVALANCHE_AVAX_USD_FEED =
        0x0A77230d17318075983913bC2145DB16C7366156;
    address public constant POLYGON_MATIC_USD_FEED =
        0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;
    address public constant FANTOM_FTM_USD_FEED =
        0xf4766552D15AE4d256Ad41B6cf2933482B0680dc;

    /*//////////////////////////////////////////////////////////////
                        RPC VARIABLES
    //////////////////////////////////////////////////////////////*/

    // chainID => FORK
    mapping(uint16 => uint256) public FORKS;
    mapping(uint16 => string) public RPC_URLS;

    string public ETHEREUM_RPC_URL = vm.envString("ETHEREUM_RPC_URL"); // Native token: ETH
    string public BSC_RPC_URL = vm.envString("BSC_RPC_URL"); // Native token: BNB
    string public AVALANCHE_RPC_URL = vm.envString("AVALANCHE_RPC_URL"); // Native token: AVAX
    string public POLYGON_RPC_URL = vm.envString("POLYGON_RPC_URL"); // Native token: MATIC
    string public ARBITRUM_RPC_URL = vm.envString("ARBITRUM_RPC_URL"); // Native token: ETH
    string public OPTIMISM_RPC_URL = vm.envString("OPTIMISM_RPC_URL"); // Native token: ETH
    string public FANTOM_RPC_URL = vm.envString("FANTOM_RPC_URL"); // Native token: FTM

    /*//////////////////////////////////////////////////////////////
                    PUBLIC FUNCTIONS FOR TESTS
            THESE FUNCTIONS SHOULD BE USED WHENEVER POSSIBLE
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        _preDeploymentSetup();

        _fundNativeTokens();

        _deployProtocol();

        _fundUnderlyingTokens(100);
    }

    function deposit(TestAction memory action, ActionLocalVars memory vars)
        public
        returns (bool)
    {
        TestAssertionVars memory aV;
        aV.lenRequests = vars.amounts.length;

        if (vars.targetVaultIds.length != aV.lenRequests || aV.lenRequests == 0)
            revert LEN_MISMATCH();

        vars.stateReqs = new StateReq[](aV.lenRequests);
        vars.liqReqs = new LiqRequest[](aV.lenRequests);

        for (uint256 i = 0; i < aV.lenRequests; i++) {
            (vars.stateReqs[i], vars.liqReqs[i]) = _buildDepositCallData(
                BuildDepositCallDataArgs(
                    action.user,
                    vars.fromSrc,
                    vars.toDst,
                    vars.underlyingSrcToken[i], ///!!!WARNING !!! @dev we probably need to create liq request with both src and dst tokens
                    vars.targetVaultIds[i],
                    vars.amounts[i],
                    action.CHAIN_0,
                    action.CHAIN_1
                )
            );
        }

        /// @dev calculate amounts before deposit

        aV.superPositionsAmountBefore = new uint256[][](aV.lenRequests);
        aV.destinationSharesBefore = new uint256[][](aV.lenRequests);

        for (uint256 i = 0; i < aV.lenRequests; i++) {
            aV.tSPAmtBefore = new uint256[](allowedNumberOfVaultsPerRequest);
            aV.tDestinationSharesAmtBefore = new uint256[](
                allowedNumberOfVaultsPerRequest
            );
            for (uint256 j = 0; j < allowedNumberOfVaultsPerRequest; j++) {
                vm.selectFork(FORKS[action.CHAIN_0]);
                aV.tSPAmtBefore[j] = SuperRouter(vars.fromSrc).balanceOf(
                    action.user,
                    vars.targetVaultIds[i][j]
                );

                vm.selectFork(FORKS[action.CHAIN_1]);
                aV.tDestinationSharesAmtBefore[j] = VaultMock(
                    vars.vaultMock[i][j]
                ).balanceOf(getContract(action.CHAIN_1, "SuperDestination"));
            }
            aV.superPositionsAmountBefore[i] = aV.tSPAmtBefore;
            aV.destinationSharesBefore[i] = aV.tDestinationSharesAmtBefore;
        }
        /// @dev deposit happens here
        _actionToSuperRouter(
            InternalActionArgs(
                vars.fromSrc,
                vars.toDst,
                vars.lzEndpoint_1,
                action.user,
                vars.stateReqs,
                vars.liqReqs,
                action.CHAIN_0,
                action.CHAIN_1,
                action.action,
                action.testType,
                action.revertString
            )
        );
        bool success;
        for (uint256 i = 0; i < aV.lenRequests; i++) {
            unchecked {
                PAYLOAD_ID[action.CHAIN_1]++;
            }
            if (action.testType == TestType.Pass) {
                _updateState(
                    PAYLOAD_ID[action.CHAIN_1],
                    vars.amounts[i],
                    action.CHAIN_1
                );
                vm.recordLogs();
                _processPayload(
                    PAYLOAD_ID[action.CHAIN_1],
                    action.CHAIN_1,
                    action.revertString,
                    action.testType
                );

                vars.logs = vm.getRecordedLogs();
                LayerZeroHelper(getContract(action.CHAIN_1, "LayerZeroHelper"))
                    .helpWithEstimates(
                        vars.lzEndpoint_0,
                        1000000, /// @dev This is the gas value to send - value needs to be tested and probably be lower
                        FORKS[action.CHAIN_0],
                        vars.logs
                    );
                unchecked {
                    PAYLOAD_ID[action.CHAIN_0]++;
                }
                _processPayload(
                    PAYLOAD_ID[action.CHAIN_0],
                    action.CHAIN_0,
                    action.revertString,
                    action.testType
                );
            } else if (action.testType == TestType.RevertProcessPayload) {
                success = _processPayload(
                    PAYLOAD_ID[action.CHAIN_1],
                    action.CHAIN_1,
                    action.revertString,
                    action.testType
                );
                if (!success) {
                    return false;
                }
            }
        }

        /// @dev asserts for verification
        for (uint256 i = 0; i < aV.lenRequests; i++) {
            for (uint256 j = 0; j < allowedNumberOfVaultsPerRequest; j++) {
                vm.selectFork(FORKS[action.CHAIN_0]);

                assertEq(
                    SuperRouter(vars.fromSrc).balanceOf(
                        action.user,
                        vars.targetVaultIds[i][j]
                    ),
                    aV.superPositionsAmountBefore[i][j] + vars.amounts[i][j]
                );

                vm.selectFork(FORKS[action.CHAIN_1]);

                assertEq(
                    VaultMock(vars.vaultMock[i][j]).balanceOf(
                        getContract(action.CHAIN_1, "SuperDestination")
                    ),
                    aV.destinationSharesBefore[i][j] + vars.amounts[i][j]
                );
            }
        }

        return true;
    }

    function withdraw(TestAction memory action, ActionLocalVars memory vars)
        public
        returns (bool)
    {
        TestAssertionVars memory aV;

        aV.lenRequests = vars.amounts.length;
        if (vars.targetVaultIds.length != aV.lenRequests && aV.lenRequests == 0)
            revert LEN_MISMATCH();

        vars.stateReqs = new StateReq[](aV.lenRequests);
        vars.liqReqs = new LiqRequest[](aV.lenRequests);

        for (uint256 i = 0; i < aV.lenRequests; i++) {
            (vars.stateReqs[i], vars.liqReqs[i]) = _buildWithdrawCallData(
                BuildWithdrawCallDataArgs(
                    action.user,
                    payable(vars.fromSrc),
                    vars.toDst,
                    vars.underlyingSrcToken[i], /// @dev we probably need to create liq request with both src and dst tokens
                    vars.vaultMock[i],
                    vars.targetVaultIds[i],
                    vars.amounts[i],
                    action.actionKind,
                    action.CHAIN_0,
                    action.CHAIN_1
                )
            );
        }

        /// @dev calculate amounts before withdraw
        aV.superPositionsAmountBefore = new uint256[][](aV.lenRequests);
        aV.destinationSharesBefore = new uint256[][](aV.lenRequests);

        for (uint256 i = 0; i < aV.lenRequests; i++) {
            aV.tSPAmtBefore = new uint256[](allowedNumberOfVaultsPerRequest);
            aV.tDestinationSharesAmtBefore = new uint256[](
                allowedNumberOfVaultsPerRequest
            );
            for (uint256 j = 0; j < allowedNumberOfVaultsPerRequest; j++) {
                vm.selectFork(FORKS[action.CHAIN_0]);
                aV.tSPAmtBefore[j] = SuperRouter(vars.fromSrc).balanceOf(
                    action.user,
                    vars.targetVaultIds[i][j]
                );

                vm.selectFork(FORKS[action.CHAIN_1]);
                aV.tDestinationSharesAmtBefore[j] = VaultMock(
                    vars.vaultMock[i][j]
                ).balanceOf(getContract(action.CHAIN_1, "SuperDestination"));
            }
            aV.superPositionsAmountBefore[i] = aV.tSPAmtBefore;
            aV.destinationSharesBefore[i] = aV.tDestinationSharesAmtBefore;
        }

        _actionToSuperRouter(
            InternalActionArgs(
                vars.fromSrc,
                vars.toDst,
                vars.lzEndpoint_1,
                action.user,
                vars.stateReqs,
                vars.liqReqs,
                action.CHAIN_0,
                action.CHAIN_1,
                action.action,
                action.testType,
                action.revertString
            )
        );
        for (uint256 i = 0; i < aV.lenRequests; i++) {
            PAYLOAD_ID[action.CHAIN_1]++;
            _processPayload(
                PAYLOAD_ID[action.CHAIN_1],
                action.CHAIN_1,
                action.revertString,
                action.testType
            );
        }

        /// @dev asserts for verification
        for (uint256 i = 0; i < aV.lenRequests; i++) {
            for (uint256 j = 0; j < allowedNumberOfVaultsPerRequest; j++) {
                vm.selectFork(FORKS[action.CHAIN_0]);

                assertEq(
                    SuperRouter(vars.fromSrc).balanceOf(
                        action.user,
                        vars.targetVaultIds[i][j]
                    ),
                    aV.superPositionsAmountBefore[i][j] - vars.amounts[i][j]
                );

                vm.selectFork(FORKS[action.CHAIN_1]);

                assertEq(
                    VaultMock(vars.vaultMock[i][j]).balanceOf(
                        getContract(action.CHAIN_1, "SuperDestination")
                    ),
                    aV.destinationSharesBefore[i][j] - vars.amounts[i][j]
                );
            }
        }

        return true;
    }

    function getContract(uint16 chainId, string memory _name)
        public
        view
        returns (address)
    {
        return contracts[chainId][bytes32(bytes(_name))];
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPERS: DEPLOY
    //////////////////////////////////////////////////////////////*/

    function _deployProtocol() internal {
        SetupVars memory vars;

        vm.startPrank(deployer);
        /// @dev deployments
        for (uint256 i = 0; i < chainIds.length; i++) {
            vars.chainId = chainIds[i];
            vars.fork = FORKS[vars.chainId];
            vm.selectFork(vars.fork);

            /// @dev 1- deploy LZ Helper from Pigeon
            vars.lzHelper = address(new LayerZeroHelper());
            vm.allowCheatcodes(vars.lzHelper);

            contracts[vars.chainId][bytes32(bytes("LayerZeroHelper"))] = vars
                .lzHelper;

            /// @dev 2- deploy StateHandler pointing to lzEndpoints (constants)
            vars.stateHandler = address(new StateHandler(lzEndpoints[i]));
            contracts[vars.chainId][bytes32(bytes("StateHandler"))] = vars
                .stateHandler;

            /// @dev 3- deploy SocketRouterMockFork
            vars.socketRouter = address(new SocketRouterMockFork());
            contracts[vars.chainId][
                bytes32(bytes("SocketRouterMockFork"))
            ] = vars.socketRouter;
            vm.allowCheatcodes(vars.socketRouter);

            if (i == 0) {
                bridgeAddresses.push(vars.socketRouter);
            }

            /// @dev 4 - Deploy UNDERLYING_TOKENS and VAULTS
            for (uint256 j = 0; j < UNDERLYING_TOKENS.length; j++) {
                vars.UNDERLYING_TOKEN = address(
                    new MockERC20(
                        UNDERLYING_TOKENS[j],
                        UNDERLYING_TOKENS[j],
                        18,
                        deployer,
                        milionTokensE18
                    )
                );
                contracts[vars.chainId][
                    bytes32(bytes(UNDERLYING_TOKENS[j]))
                ] = vars.UNDERLYING_TOKEN;

                /// @dev 5 - Deploy mock Vault
                vars.vault = address(
                    new VaultMock(
                        MockERC20(vars.UNDERLYING_TOKEN),
                        VAULT_NAMES[j],
                        VAULT_NAMES[j]
                    )
                );
                contracts[vars.chainId][
                    bytes32(bytes(string.concat(UNDERLYING_TOKENS[j], "Vault")))
                ] = vars.vault;

                vaults[vars.chainId].push(IERC4626(vars.vault));
                vaultIds[vars.chainId].push(j + 1);
            }

            /// @dev 6 - Deploy SuperDestination
            vars.superDestination = address(
                new SuperDestination(
                    vars.chainId,
                    IStateHandler(payable(vars.stateHandler))
                )
            );
            contracts[vars.chainId][bytes32(bytes("SuperDestination"))] = vars
                .superDestination;

            /// @dev 7 - Deploy SuperRouter
            contracts[vars.chainId][bytes32(bytes("SuperRouter"))] = address(
                new SuperRouter(
                    vars.chainId,
                    "test.com/",
                    IStateHandler(payable(vars.stateHandler)),
                    IDestination(vars.superDestination)
                )
            );

            /// @dev 8 - Deploy SWAP token with no associated vault with 18 decimals
            contracts[vars.chainId][bytes32(bytes("Swap"))] = address(
                new MockERC20("Swap", "SWP", 18, deployer, milionTokensE18)
            );
        }

        for (uint256 i = 0; i < chainIds.length; i++) {
            vars.chainId = chainIds[i];
            vars.fork = FORKS[vars.chainId];
            vm.selectFork(vars.fork);

            vars.srcStateHandler = getContract(vars.chainId, "StateHandler");
            vars.srcSuperRouter = getContract(vars.chainId, "SuperRouter");
            vars.srcSuperDestination = getContract(
                vars.chainId,
                "SuperDestination"
            );

            /// @dev - Add vaults to super destination
            SuperDestination(payable(vars.srcSuperDestination)).addVault(
                vaults[vars.chainId],
                vaultIds[vars.chainId]
            );

            SuperDestination(payable(vars.srcSuperDestination))
                .updateSafeGasParam(abi.encodePacked(version, gasLimit));

            /// @dev - RBAC
            StateHandler(payable(vars.srcStateHandler)).setHandlerController(
                IController(vars.srcSuperRouter),
                IController(vars.srcSuperDestination)
            );

            StateHandler(payable(vars.srcStateHandler)).grantRole(
                CORE_CONTRACTS_ROLE,
                vars.srcSuperRouter
            );
            StateHandler(payable(vars.srcStateHandler)).grantRole(
                CORE_CONTRACTS_ROLE,
                vars.srcSuperDestination
            );
            StateHandler(payable(vars.srcStateHandler)).grantRole(
                PROCESSOR_CONTRACTS_ROLE,
                deployer
            );

            /// @dev Set all trusted remotes for each chain
            for (uint256 j = 0; j < chainIds.length; j++) {
                if (j != i) {
                    vars.dstChainId = chainIds[j];
                    vars.dstStateHandler = getContract(
                        vars.dstChainId,
                        "StateHandler"
                    );
                    StateHandler(payable(vars.srcStateHandler))
                        .setTrustedRemote(
                            vars.dstChainId,
                            abi.encodePacked(
                                vars.srcStateHandler,
                                vars.dstStateHandler
                            )
                        );
                }
            }

            /// @dev - Set bridge addresses
            SuperRouter(payable(vars.srcSuperRouter)).setBridgeAddress(
                bridgeIds,
                bridgeAddresses
            );
            SuperDestination(payable(vars.srcSuperDestination))
                .setBridgeAddress(bridgeIds, bridgeAddresses);
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS:
            (ADVANCED DIRECT USAGE ALLOWED (see Attack.t.sol))
    //////////////////////////////////////////////////////////////*/

    function _actionToSuperRouter(InternalActionArgs memory args) internal {
        InternalActionVars memory vars;
        vars.initialFork = vm.activeFork();

        vars.msgValue = 5 * _getPriceMultiplier(args.srcChainId) * 1e18;

        StateHandler stateHandler = StateHandler(
            payable(getContract(args.toChainId, "StateHandler"))
        );
        SuperRouter superRouter = SuperRouter(args.fromSrc);

        vm.selectFork(FORKS[args.srcChainId]);
        vars.txIdBefore = superRouter.totalTransactions();

        if (args.testType != TestType.RevertMainAction) {
            vm.prank(args.user);
            /// @dev see pigeon for this implementation
            vm.recordLogs();
            /// @dev Value == fee paid to relayer. API call in our design
            if (args.action == Actions.Deposit) {
                superRouter.deposit{value: vars.msgValue}(
                    args.liqReqs,
                    args.stateReqs
                );
            } else if (args.action == Actions.Withdraw) {
                superRouter.withdraw{value: vars.msgValue}(
                    args.stateReqs,
                    args.liqReqs
                );
            }
            vars.logs = vm.getRecordedLogs();
            /// @dev see pigeon for this implementation
            LayerZeroHelper(getContract(args.srcChainId, "LayerZeroHelper"))
                .helpWithEstimates(
                    args.toLzEndpoint,
                    1000000, /// @dev This is the gas value to send - value needs to be tested and probably be lower
                    FORKS[args.toChainId],
                    vars.logs
                );

            vm.selectFork(FORKS[args.toChainId]);

            vars.payloadNumberBefore = stateHandler.totalPayloads();

            vars.lenRequests = args.liqReqs.length;

            /// @dev to assert LzMessage hasn't been tampered with (later we can assert tampers of this message)
            for (uint256 i = 0; i < vars.lenRequests; i++) {
                /// @dev - assert the payload reached destination state handler
                vars.expectedInitData = InitData(
                    args.srcChainId,
                    args.toChainId,
                    args.user,
                    args.stateReqs[i].vaultIds,
                    args.stateReqs[i].amounts,
                    args.stateReqs[i].maxSlippage,
                    vars.txIdBefore + i + 1,
                    bytes("")
                );

                vars.data = abi.decode(
                    stateHandler.payload(
                        vars.payloadNumberBefore + 1 - vars.lenRequests + i
                    ),
                    (StateData)
                );
                vars.receivedInitData = abi.decode(
                    vars.data.params,
                    (InitData)
                );

                assertEq(
                    vars.receivedInitData.srcChainId,
                    vars.expectedInitData.srcChainId
                );
                assertEq(
                    vars.receivedInitData.dstChainId,
                    vars.expectedInitData.dstChainId
                );
                assertEq(
                    vars.receivedInitData.user,
                    vars.expectedInitData.user
                );

                assertEq(
                    vars.receivedInitData.vaultIds,
                    vars.expectedInitData.vaultIds
                );

                assertEq(
                    vars.receivedInitData.amounts,
                    vars.expectedInitData.amounts
                );
                assertEq(
                    vars.receivedInitData.maxSlippage,
                    vars.expectedInitData.maxSlippage
                );

                assertEq(
                    vars.receivedInitData.txId,
                    vars.expectedInitData.txId
                );
            }
        } else {
            /// @dev empty for now
        }

        vm.selectFork(vars.initialFork);
    }

    function _buildDepositCallData(BuildDepositCallDataArgs memory args)
        internal
        returns (StateReq memory stateReq, LiqRequest memory liqReq)
    {
        /// @dev set to empty bytes for now
        bytes memory adapterParam;
        /*
            adapterParam = abi.encodePacked(version, gasLimit);
        */
        uint256 lenDeposits = args.amounts.length;

        if (args.targetVaultIds.length != lenDeposits || lenDeposits == 0)
            revert LEN_MISMATCH();
        /// @dev Build State req

        uint256[] memory slippage = new uint256[](lenDeposits);

        for (uint256 i = 0; i < lenDeposits; i++) {
            slippage[i] = 1000;
        }

        uint256 msgValue = 1 * _getPriceMultiplier(args.srcChainId) * 1e18;

        stateReq = StateReq(
            args.toChainId,
            args.amounts,
            args.targetVaultIds,
            slippage,
            adapterParam,
            msgValue
        );

        /// @dev Build Liq request

        // !! WARNING !! - sending single amount here - todo change
        // !! WARNING !! - if collateral is the same we can actually send multi vault

        /// @dev check this from down here when contracts are fixed for multi vault
        /// @dev build socket tx data for a mock socket transfer (using new Mock contract because of the two forks)
        bytes memory socketTxData = abi.encodeWithSignature(
            "mockSocketTransfer(address,address,address,uint256,uint256)",
            args.fromSrc,
            args.toDst,
            args.underlyingToken[0], /// @dev - needs fix because it should have an array of underlying like state req
            args.amounts[0], /// @dev - 1 amount is sent, not testing sum of amounts (different vaults)
            FORKS[args.toChainId]
        );

        liqReq = LiqRequest(
            1,
            socketTxData,
            args.underlyingToken[0], /// @dev - needs fix because it should have an array of underlying like state req
            getContract(args.srcChainId, "SocketRouterMockFork"),
            args.amounts[0], /// @dev - 1 amount is sent, not testing sum of amounts (different vaults)
            0
        );

        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[args.srcChainId]);

        /// @dev - APPROVE transfer to SuperRouter (because of Socket)
        vm.prank(args.user);
        MockERC20(args.underlyingToken[0]).approve(
            args.fromSrc,
            args.amounts[0]
        );
        vm.selectFork(initialFork);
    }

    function _buildWithdrawCallData(BuildWithdrawCallDataArgs memory args)
        internal
        returns (StateReq memory stateReq, LiqRequest memory liqReq)
    {
        /// @dev set to empty bytes for now
        bytes memory adapterParam;

        uint256 lenWithdraws = args.targetVaultIds.length;

        if (lenWithdraws == 0) revert LEN_MISMATCH();

        uint256[] memory slippage = new uint256[](lenWithdraws);
        uint256[] memory amountsToWithdraw = new uint256[](lenWithdraws);

        if (args.actionKind == LiquidityChange.Full) {
            uint256 sharesBalanceBeforeWithdraw;
            for (uint256 i = 0; i < lenWithdraws; i++) {
                slippage[i] = 1000;
                vm.selectFork(FORKS[args.srcChainId]);

                sharesBalanceBeforeWithdraw = SuperRouter(args.fromSrc)
                    .balanceOf(args.user, args.targetVaultIds[i]);

                vm.selectFork(FORKS[args.toChainId]);

                amountsToWithdraw[i] = VaultMock(args.vaultMock[i])
                    .previewRedeem(sharesBalanceBeforeWithdraw);
            }
        } else if (args.actionKind == LiquidityChange.Partial) {
            amountsToWithdraw = args.amounts;
        }

        uint256 msgValue = 1 * _getPriceMultiplier(args.srcChainId) * 1e18;

        stateReq = StateReq(
            args.toChainId,
            amountsToWithdraw,
            args.targetVaultIds,
            slippage,
            adapterParam,
            msgValue
        );

        // !! WARNING !! - sending single amount here - todo change
        /// @dev check this from down here when contracts are fixed for multi vault
        /// @dev build socket tx data for a mock socket transfer (using new Mock contract because of the two forks)
        bytes memory socketTxData = abi.encodeWithSignature(
            "mockSocketTransfer(address,address,address,uint256,uint256)",
            args.toDst,
            args.fromSrc,
            args.underlyingToken[0], /// @dev - needs fix
            amountsToWithdraw[0], /// @dev - needs fix
            FORKS[args.toChainId]
        );

        liqReq = LiqRequest(
            1,
            socketTxData,
            args.underlyingToken[0], /// @dev - needs fix
            getContract(args.srcChainId, "SocketRouterMockFork"),
            amountsToWithdraw[0],
            0
        );
    }

    function _updateState(
        uint256 payloadId_,
        uint256[] memory finalAmounts_,
        uint16 targetChainId_
    ) internal {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[targetChainId_]);

        vm.prank(deployer);
        StateHandler(payable(getContract(targetChainId_, "StateHandler")))
            .updateState(payloadId_, finalAmounts_);

        vm.selectFork(initialFork);
    }

    function _processPayload(
        uint256 payloadId_,
        uint16 targetChainId_,
        bytes memory revertString,
        TestType testType
    ) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[targetChainId_]);

        uint256 msgValue = 5 * _getPriceMultiplier(targetChainId_) * 1e18;

        bytes memory hashZero;
        vm.prank(deployer);
        if (testType == TestType.Pass) {
            StateHandler(payable(getContract(targetChainId_, "StateHandler")))
                .processPayload{value: msgValue}(payloadId_, hashZero);
        } else if (testType == TestType.RevertProcessPayload) {
            vm.expectRevert(revertString);

            StateHandler(payable(getContract(targetChainId_, "StateHandler")))
                .processPayload{value: msgValue}(payloadId_, hashZero);

            return false;
        }

        vm.selectFork(initialFork);
        return true;
    }

    function _resetPayloadIDs() internal {
        mapping(uint16 => uint256) storage payloadID = PAYLOAD_ID; // chaindId => payloadId

        payloadID[ETH] = 0;
        payloadID[BSC] = 0;
        payloadID[AVAX] = 0;
        payloadID[POLY] = 0;
        payloadID[ARBI] = 0;
        payloadID[OP] = 0;
        payloadID[FTM] = 0;
    }

    /*//////////////////////////////////////////////////////////////
                        MISC. HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _preDeploymentSetup() private {
        mapping(uint16 => uint256) storage forks = FORKS;
        forks[ETH] = vm.createFork(ETHEREUM_RPC_URL);
        forks[BSC] = vm.createFork(BSC_RPC_URL);
        forks[AVAX] = vm.createFork(AVALANCHE_RPC_URL);
        forks[POLY] = vm.createFork(POLYGON_RPC_URL);
        forks[ARBI] = vm.createFork(ARBITRUM_RPC_URL);
        forks[OP] = vm.createFork(OPTIMISM_RPC_URL);
        forks[FTM] = vm.createFork(FANTOM_RPC_URL);

        mapping(uint16 => string) storage rpcURLs = RPC_URLS;
        rpcURLs[ETH] = ETHEREUM_RPC_URL;
        rpcURLs[BSC] = BSC_RPC_URL;
        rpcURLs[AVAX] = AVALANCHE_RPC_URL;
        rpcURLs[POLY] = POLYGON_RPC_URL;
        rpcURLs[ARBI] = ARBITRUM_RPC_URL;
        rpcURLs[OP] = OPTIMISM_RPC_URL;
        rpcURLs[FTM] = FANTOM_RPC_URL;

        mapping(uint16 => address) storage lzEndpointsStorage = LZ_ENDPOINTS;
        lzEndpointsStorage[ETH] = ETH_lzEndpoint;
        lzEndpointsStorage[BSC] = BSC_lzEndpoint;
        lzEndpointsStorage[AVAX] = AVAX_lzEndpoint;
        lzEndpointsStorage[POLY] = POLY_lzEndpoint;
        lzEndpointsStorage[ARBI] = ARBI_lzEndpoint;
        lzEndpointsStorage[OP] = OP_lzEndpoint;
        lzEndpointsStorage[FTM] = FTM_lzEndpoint;

        mapping(uint16 => address) storage priceFeeds = PRICE_FEEDS;
        priceFeeds[ETH] = ETHEREUM_ETH_USD_FEED;
        priceFeeds[BSC] = BSC_BNB_USD_FEED;
        priceFeeds[AVAX] = AVALANCHE_AVAX_USD_FEED;
        priceFeeds[POLY] = POLYGON_MATIC_USD_FEED;
        priceFeeds[ARBI] = address(0);
        priceFeeds[OP] = address(0);
        priceFeeds[FTM] = FANTOM_FTM_USD_FEED;

        /// @dev setup bridges. Only bridgeId 1 available for tests (Socket)
        bridgeIds.push(1);

        /// @dev setup users
        users.push(address(1));
        users.push(address(2));
        users.push(address(3));
        users.push(address(4));
        users.push(address(5));
        users.push(address(6));
        users.push(address(7));
        users.push(address(8));
        users.push(address(9));
        users.push(address(10));
        string[] memory underlyingTokens = UNDERLYING_TOKENS;
        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            VAULT_NAMES.push(string.concat(underlyingTokens[i], "Vault"));
        }
    }

    function _fundNativeTokens() private {
        for (uint256 i = 0; i < chainIds.length; i++) {
            vm.selectFork(FORKS[chainIds[i]]);

            uint256 multiplier = _getPriceMultiplier(chainIds[i]);

            uint256 amountDeployer = 100000 * multiplier * 1e18;
            uint256 amountUSER = 1000 * multiplier * 1e18;

            vm.deal(deployer, amountDeployer);

            vm.deal(address(1), amountUSER);
            vm.deal(address(2), amountUSER);
            vm.deal(address(3), amountUSER);
        }
    }

    function _getPriceMultiplier(uint16 targetChainId_)
        internal
        returns (uint256)
    {
        uint256 multiplier;

        if (
            targetChainId_ == ETH ||
            targetChainId_ == ARBI ||
            targetChainId_ == OP
        ) {
            /// @dev default multiplier for chains with ETH native token

            multiplier = 1;
        } else {
            uint256 initialFork = vm.activeFork();

            vm.selectFork(FORKS[ETH]);

            int256 ethUsdPrice = _getLatestPrice(PRICE_FEEDS[ETH]);

            vm.selectFork(FORKS[targetChainId_]);
            int256 price = _getLatestPrice(PRICE_FEEDS[targetChainId_]);

            multiplier = uint256(ethUsdPrice / price);

            /// @dev return to initial fork

            vm.selectFork(initialFork);
        }

        return multiplier;
    }

    function _getLatestPrice(address priceFeed_)
        internal
        view
        returns (int256)
    {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = AggregatorV3Interface(priceFeed_).latestRoundData();
        return price;
    }

    function _fundUnderlyingTokens(uint256 amount) private {
        for (uint256 j = 0; j < UNDERLYING_TOKENS.length; j++) {
            if (getContract(chainIds[0], UNDERLYING_TOKENS[j]) == address(0))
                revert INVALID_UNDERLYING_TOKEN_NAME();

            for (uint256 i = 0; i < chainIds.length; i++) {
                vm.selectFork(FORKS[chainIds[i]]);
                address token = getContract(chainIds[i], UNDERLYING_TOKENS[j]);
                deal(token, address(1), 1 ether * amount);
                deal(token, address(2), 1 ether * amount);
                deal(token, address(3), 1 ether * amount);

                address swap = getContract(chainIds[i], "Swap");
                deal(swap, address(1), 1 ether * amount);
                deal(swap, address(2), 1 ether * amount);
                deal(swap, address(3), 1 ether * amount);
            }
        }
    }
}
