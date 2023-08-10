/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

/// @dev lib imports
import "./BaseSetup.sol";
import {IPermit2} from "../../vendor/dragonfly-xyz/IPermit2.sol";
import {ISocketRegistry} from "../../vendor/socket/ISocketRegistry.sol";
import {ILiFi} from "../../vendor/lifi/ILiFi.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {SocketRouterMock} from "../mocks/SocketRouterMock.sol";
import {LiFiMock} from "../mocks/LiFiMock.sol";
import {ISuperRegistry} from "../../interfaces/ISuperRegistry.sol";
import {ITwoStepsFormStateRegistry} from "../../interfaces/ITwoStepsFormStateRegistry.sol";
import {IERC1155s} from "ERC1155s/interfaces/IERC1155s.sol";

import {IBaseForm} from "../../interfaces/IBaseForm.sol";
import {IBaseStateRegistry} from "../../interfaces/IBaseStateRegistry.sol";

abstract contract ProtocolActions is BaseSetup {
    using DataLib for uint256;

    event FailedXChainDeposits(uint256 indexed payloadId);

    mapping(uint256 chainIdIndex => uint256) countTimelocked;

    uint8[] public AMBs;

    uint8[][] public MultiDstAMBs;

    uint64 public CHAIN_0;

    uint64[] public DST_CHAINS;

    uint64[] public uniqueDSTs;

    uint256 public msgValue;
    uint256 public dstValue;

    uint256[][] public revertingDepositSFs;
    uint256[][] public revertingWithdrawSFs;
    uint256[][] public revertingWithdrawTimelockedSFs;

    /// @dev temp dynamic arrays to insert in the double array above
    uint256[] public revertingDepositSFsPerDst;
    uint256[] public revertingWithdrawSFsPerDst;
    uint256[] public revertingWithdrawTimelockedSFsPerDst;
    struct UniqueDSTInfo {
        uint256 payloadNumber;
        uint256 nRepetitions;
    }

    uint256 SLIPPAGE;

    uint256 MAX_SLIPPAGE;

    bool GENERATE_WITHDRAW_TX_DATA_ON_DST;

    mapping(uint64 chainId => UniqueDSTInfo info) public usedDSTs;

    mapping(uint64 chainId => mapping(uint256 timelockId => uint256 index)) public timeLockedIndexes;

    mapping(uint64 chainId => mapping(uint256 action => uint256[] underlyingTokenIds)) public TARGET_UNDERLYINGS;

    mapping(uint64 chainId => mapping(uint256 action => uint256[] vaultIds)) public TARGET_VAULTS;

    mapping(uint64 chainId => mapping(uint256 action => uint32[] formKinds)) public TARGET_FORM_KINDS;

    mapping(uint64 chainId => mapping(uint256 index => uint256[] action)) public AMOUNTS;

    mapping(uint64 chainId => mapping(uint256 index => bool[] action)) public PARTIAL;

    mapping(uint64 chainId => bytes[] generatedTxData) public TX_DATA_TO_UPDATE_ON_DST;

    /// @dev 1 for socket, 2 for lifi
    mapping(uint64 chainId => mapping(uint256 index => uint8[] liqBridgeId)) public LIQ_BRIDGES;

    mapping(uint64 chainId => mapping(uint256 index => TestType testType)) public TEST_TYPE_PER_DST;

    /// NOTE: Now that we can pass individual actions, this array is only useful for more extended simulations
    TestAction[] public actions;

    function setUp() public virtual override {
        super.setUp();
    }

    /*///////////////////////////////////////////////////////////////
                            MAIN INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev 'n' deposits rescued per payloadId per destination chain
    function _rescueFailedDeposits(TestAction memory action, uint256 actionIndex) internal {
        if (action.action == Actions.RescueFailedDeposit && action.testType == TestType.Pass) {
            vm.selectFork(FORKS[CHAIN_0]);
            uint256 userWethBalanceBefore = MockERC20(getContract(CHAIN_0, UNDERLYING_TOKENS[2])).balanceOf(users[0]);

            vm.selectFork(FORKS[DST_CHAINS[0]]);

            address payable coreStateRegistryDst = payable(getContract(DST_CHAINS[0], "CoreStateRegistry"));
            uint256[] memory rescueSuperformIds;

            rescueSuperformIds = CoreStateRegistry(coreStateRegistryDst).getFailedDeposits(PAYLOAD_ID[DST_CHAINS[0]]);

            LiqRequest[] memory liqRequests = new LiqRequest[](rescueSuperformIds.length);

            uint256 finalAmount;
            /// @dev simulating slippage from bridges
            for (uint256 i; i < AMOUNTS[CHAIN_0][actionIndex].length; ++i) {
                finalAmount += (AMOUNTS[CHAIN_0][actionIndex][i] * (10000 - uint256(action.slippage))) / 10000;
            }

            SingleVaultCallDataArgs memory singleVaultCallDataArgs = SingleVaultCallDataArgs(
                action.user,
                coreStateRegistryDst,
                getContract(CHAIN_0, UNDERLYING_TOKENS[TARGET_UNDERLYINGS[CHAIN_0][1][0]]), /// @dev needs to correspond to `underlyingTokenDst_` in _buildLiqBridgeTxData()
                coreStateRegistryDst,
                action.externalToken == 3 /// @dev needs to correspond to `underlyingToken` in _buildLiqBridgeTxData()
                    ? NATIVE_TOKEN
                    : getContract(DST_CHAINS[0], UNDERLYING_TOKENS[action.externalToken]),
                getContract(DST_CHAINS[0], UNDERLYING_TOKENS[TARGET_UNDERLYINGS[DST_CHAINS[0]][0][0]]),
                rescueSuperformIds[0], /// @dev initiating with first rescueSuperformId
                (AMOUNTS[CHAIN_0][actionIndex][0] * (10000 - uint256(action.slippage))) / 10000, /// @dev initiating with slippage adjusted amount of first vault
                LIQ_BRIDGES[CHAIN_0][actionIndex][0],
                MAX_SLIPPAGE,
                action.externalToken == 3
                    ? NATIVE_TOKEN
                    : getContract(DST_CHAINS[0], UNDERLYING_TOKENS[action.externalToken]),
                CHAIN_0,
                DST_CHAINS[0], /// unsure about its usage
                CHAIN_0,
                DST_CHAINS[0],
                action.multiTx,
                false
            );

            for (uint256 i = 0; i < rescueSuperformIds.length; ++i) {
                singleVaultCallDataArgs.superFormId = rescueSuperformIds[i];
                /// @dev slippage adjusted amount that'll be withdrawn
                singleVaultCallDataArgs.amount =
                    (AMOUNTS[CHAIN_0][actionIndex][i] * (10000 - uint256(action.slippage))) /
                    10000;
                liqRequests[i] = _buildSingleVaultWithdrawCallData(singleVaultCallDataArgs).liqRequest;
            }

            vm.prank(deployer);
            CoreStateRegistry(coreStateRegistryDst).rescueFailedDeposits(PAYLOAD_ID[DST_CHAINS[0]], liqRequests);

            vm.selectFork(FORKS[CHAIN_0]);
            uint256 userWethBalanceAfter = MockERC20(getContract(CHAIN_0, UNDERLYING_TOKENS[2])).balanceOf(users[0]);

            assertEq(userWethBalanceAfter, userWethBalanceBefore + finalAmount);
        }
    }

    function _runMainStages(
        TestAction memory action,
        uint256 act,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        MessagingAssertVars[] memory aV,
        StagesLocalVars memory vars,
        bool success
    ) internal {
        console.log("new-action");
        (multiSuperformsData, singleSuperformsData, vars) = _stage1_buildReqData(action, act);

        uint256[][] memory spAmountSummed = new uint256[][](vars.nDestinations);
        uint256[] memory spAmountBeforeWithdrawPerDst;
        uint256 inputBalanceBefore;

        (, spAmountSummed, spAmountBeforeWithdrawPerDst, inputBalanceBefore) = _assertBeforeAction(
            action,
            multiSuperformsData,
            singleSuperformsData,
            vars
        );

        vars = _stage2_run_src_action(action, multiSuperformsData, singleSuperformsData, vars);
        console.log("Stage 2 complete");

        aV = _stage3_src_to_dst_amb_delivery(action, vars, multiSuperformsData, singleSuperformsData);
        console.log("Stage 3 complete");

        success = _stage4_process_src_dst_payload(action, vars, aV, singleSuperformsData, act);

        if (!success) {
            console.log("Stage 4 failed");
            return;
        } else if (action.action == Actions.Withdraw && action.testType == TestType.Pass) {
            console.log("Stage 4 complete");

            /// @dev fully successful withdraws finish here
            _assertAfterStage4Withdraw(
                action,
                multiSuperformsData,
                singleSuperformsData,
                vars,
                spAmountSummed,
                spAmountBeforeWithdrawPerDst
            );
        }

        if (
            (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) &&
            !(action.testType == TestType.RevertXChainDeposit)
        ) {
            success = _stage5_process_superPositions_mint(action, vars, multiSuperformsData);
            if (!success) {
                console.log("Stage 5 failed");

                return;
            } else if (action.testType != TestType.RevertMainAction) {
                console.log("Stage 5 complete");

                /// @dev if we don't even process main action there is nothing to assert
                _assertAfterDeposit(action, multiSuperformsData, singleSuperformsData, vars, inputBalanceBefore);
            }
        }
        bytes[] memory returnMessagesNormalWithdraw;

        /// @dev for all form kinds including timelocked (first stage)
        /// @dev if there is a failure we immediately re-mint superShares
        /// @dev stage 6 is only required if there is any failed cross chain withdraws
        if (action.action == Actions.Withdraw) {
            bool toAssert;
            (success, returnMessagesNormalWithdraw, toAssert) = _stage6_process_superPositions_withdraw(
                action,
                vars,
                multiSuperformsData
            );
            if (!success) {
                console.log("Stage 6 failed");
                return;
            } else if (toAssert) {
                console.log("Stage 6 complete - asserting");

                _assertAfterFailedWithdraw(
                    action,
                    multiSuperformsData,
                    singleSuperformsData,
                    vars,
                    spAmountSummed,
                    spAmountBeforeWithdrawPerDst,
                    returnMessagesNormalWithdraw
                );
            }
        }
        bytes[] memory returnMessagesTimelockedWithdraw;

        /// @dev stage 7 and 8 are only required for timelocked forms
        if (action.action == Actions.Withdraw) {
            /// @dev Keeper needs to know this value to be able to process unlock
            returnMessagesTimelockedWithdraw = _stage7_finalize_timelocked_payload(action, vars);

            console.log("Stage 7 complete");

            if (action.testType == TestType.Pass) {
                _assertAfterStage7Withdraw(
                    action,
                    multiSuperformsData,
                    singleSuperformsData,
                    vars,
                    spAmountSummed,
                    spAmountBeforeWithdrawPerDst
                );
            }
        }

        if (action.action == Actions.Withdraw) {
            /// @dev Process payload received on source from destination (withdraw callback, for failed withdraws)
            _stage8_process_failed_timelocked_xchain_remint(action, vars);

            console.log("Stage 8 complete");
            /// @dev should assert here but issue is the current assert failure function isn't adaptible
            _assertAfterTimelockFailedWithdraw(
                action,
                multiSuperformsData,
                singleSuperformsData,
                vars,
                spAmountSummed,
                spAmountBeforeWithdrawPerDst,
                returnMessagesNormalWithdraw,
                returnMessagesTimelockedWithdraw
            );
        }

        delete revertingDepositSFs;
        delete revertingWithdrawSFs;
        delete revertingWithdrawTimelockedSFs;

        for (uint256 i = 0; i < vars.nDestinations; ++i) {
            delete countTimelocked[i];
            delete TX_DATA_TO_UPDATE_ON_DST[DST_CHAINS[i]];
        }
    }

    struct BuildReqDataVars {
        uint256 i;
        uint256 j;
        uint256 k;
        uint256 finalAmount;
    }

    /// @dev STEP 1: Build Request Data
    /// NOTE: This whole step should be looked upon as PROTOCOL action, not USER action
    /// Request is built for user, but all of operations here would be performed by protocol and not even it's smart contracts
    /// It's worth checking out if we are not making to many of the assumptions here too.
    function _stage1_buildReqData(
        TestAction memory action,
        uint256 actionIndex
    )
        internal
        returns (
            MultiVaultSFData[] memory multiSuperformsData,
            SingleVaultSFData[] memory singleSuperformsData,
            StagesLocalVars memory vars
        )
    {
        if (action.revertError != bytes4(0) && action.testType == TestType.Pass) revert MISMATCH_TEST_TYPE();

        if (
            (action.testType != TestType.RevertUpdateStateRBAC && action.revertRole != bytes32(0)) ||
            (action.testType == TestType.RevertUpdateStateRBAC && action.revertRole == bytes32(0))
        ) revert MISMATCH_RBAC_TEST();

        for (uint256 i = 0; i < chainIds.length; i++) {
            if (CHAIN_0 == chainIds[i]) {
                vars.chain0Index = i;
                break;
            }
        }

        vars.lzEndpoint_0 = LZ_ENDPOINTS[CHAIN_0];
        vars.fromSrc = payable(getContract(CHAIN_0, "SuperformRouter"));

        vars.nDestinations = DST_CHAINS.length;

        vars.lzEndpoints_1 = new address[](vars.nDestinations);
        vars.toDst = new address[](vars.nDestinations);

        if (action.multiVaults) {
            multiSuperformsData = new MultiVaultSFData[](vars.nDestinations);
        } else {
            singleSuperformsData = new SingleVaultSFData[](vars.nDestinations);
        }

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            for (uint256 j = 0; j < chainIds.length; j++) {
                if (DST_CHAINS[i] == chainIds[j]) {
                    vars.chainDstIndex = j;
                    break;
                }
            }
            vars.lzEndpoints_1[i] = LZ_ENDPOINTS[DST_CHAINS[i]];
            (
                vars.targetSuperformIds,
                vars.underlyingSrcToken,
                vars.underlyingDstToken,
                vars.vaultMock,
                vars.partialWithdrawVaults
            ) = _targetVaults(CHAIN_0, DST_CHAINS[i], actionIndex, i);

            vars.toDst = new address[](vars.targetSuperformIds.length);

            /// @dev action is sameChain, if there is a liquidity swap it should go to the same form
            /// @dev if action is cross chain withdraw, user can select to receive a different kind of underlying from source

            for (uint256 k = 0; k < vars.targetSuperformIds.length; k++) {
                if (CHAIN_0 == DST_CHAINS[i] || (action.action == Actions.Withdraw && CHAIN_0 != DST_CHAINS[i])) {
                    (vars.superFormT, , ) = vars.targetSuperformIds[k].getSuperform();
                    vars.toDst[k] = payable(vars.superFormT);
                } else {
                    vars.toDst[k] = payable(getContract(DST_CHAINS[i], "CoreStateRegistry"));
                }
            }

            vars.amounts = AMOUNTS[DST_CHAINS[i]][actionIndex];

            vars.liqBridges = LIQ_BRIDGES[DST_CHAINS[i]][actionIndex];

            if (action.multiVaults) {
                multiSuperformsData[i] = _buildMultiVaultCallData(
                    MultiVaultCallDataArgs(
                        action.user,
                        vars.fromSrc,
                        action.externalToken == 3
                            ? NATIVE_TOKEN
                            : getContract(CHAIN_0, UNDERLYING_TOKENS[action.externalToken]),
                        vars.toDst,
                        vars.underlyingSrcToken,
                        vars.underlyingDstToken,
                        vars.targetSuperformIds,
                        vars.amounts,
                        vars.liqBridges,
                        MAX_SLIPPAGE,
                        vars.vaultMock,
                        CHAIN_0,
                        DST_CHAINS[i],
                        uint256(chainIds[vars.chain0Index]),
                        uint256(chainIds[vars.chainDstIndex]),
                        action.multiTx,
                        action.action,
                        action.slippage,
                        vars.partialWithdrawVaults
                    )
                );
            } else {
                uint256 finalAmount = vars.amounts[0];

                /// @dev in sameChain deposit actions, slippage is encoded in the request (extracted from bridge api)
                /// @dev for all withdraw actions we also encode slippage to simulate a maxWithdraw case (if we input same amount in scenario)
                /// @note for partial withdraws its negligible the effect of this extra slippage param as it is just for testing
                if (
                    action.slippage != 0 &&
                    ((CHAIN_0 == DST_CHAINS[i] &&
                        (action.action == Actions.Deposit || action.action == Actions.DepositPermit2)) ||
                        (action.action == Actions.Withdraw))
                ) {
                    finalAmount = (vars.amounts[0] * (10000 - uint256(action.slippage))) / 10000;
                }

                SingleVaultCallDataArgs memory singleVaultCallDataArgs = SingleVaultCallDataArgs(
                    action.user,
                    vars.fromSrc,
                    action.externalToken == 3
                        ? NATIVE_TOKEN
                        : getContract(CHAIN_0, UNDERLYING_TOKENS[action.externalToken]),
                    vars.toDst[0],
                    vars.underlyingSrcToken[0],
                    vars.underlyingDstToken[0],
                    vars.targetSuperformIds[0],
                    finalAmount,
                    vars.liqBridges[0],
                    MAX_SLIPPAGE,
                    vars.vaultMock[0],
                    CHAIN_0,
                    DST_CHAINS[i],
                    uint256(chainIds[vars.chain0Index]),
                    uint256(chainIds[vars.chainDstIndex]),
                    action.multiTx,
                    vars.partialWithdrawVaults.length > 0 ? vars.partialWithdrawVaults[0] : false
                );

                if (
                    action.action == Actions.Deposit ||
                    action.action == Actions.DepositPermit2 ||
                    action.action == Actions.RescueFailedDeposit
                ) {
                    singleSuperformsData[i] = _buildSingleVaultDepositCallData(singleVaultCallDataArgs, action.action);
                } else {
                    singleSuperformsData[i] = _buildSingleVaultWithdrawCallData(singleVaultCallDataArgs);
                }
            }
        }

        vm.selectFork(FORKS[CHAIN_0]);
    }

    /// @dev STEP 2: Run Source Chain Action
    function _stage2_run_src_action(
        TestAction memory action,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        StagesLocalVars memory vars
    ) internal returns (StagesLocalVars memory) {
        vm.selectFork(FORKS[CHAIN_0]);
        SuperformRouter superRouter = SuperformRouter(vars.fromSrc);

        PaymentHelper paymentHelper = PaymentHelper(getContract(CHAIN_0, "PaymentHelper"));
        bool sameChainDstHasRevertingVault;
        for (uint256 i = 0; i < vars.nDestinations; ++i) {
            if (CHAIN_0 == DST_CHAINS[i]) {
                if (revertingDepositSFs.length > 0) {
                    if (
                        revertingDepositSFs[i].length > 0 &&
                        (action.action == Actions.Deposit || action.action == Actions.DepositPermit2)
                    ) {
                        sameChainDstHasRevertingVault = true;
                        break;
                    }
                }
                if (revertingWithdrawSFs.length > 0) {
                    if (revertingWithdrawSFs[i].length > 0 && action.action == Actions.Withdraw) {
                        sameChainDstHasRevertingVault = true;
                        break;
                    }
                }
            }
        }
        /// @dev see @pigeon for this implementation
        vm.recordLogs();

        if (action.multiVaults) {
            if (vars.nDestinations == 1) {
                vars.singleDstMultiVaultStateReq = SingleXChainMultiVaultStateReq(
                    AMBs,
                    DST_CHAINS[0],
                    multiSuperformsData[0]
                );

                if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                    (, , dstValue, msgValue) = CHAIN_0 != DST_CHAINS[0]
                        ? paymentHelper.estimateSingleXChainMultiVault(vars.singleDstMultiVaultStateReq, true)
                        : paymentHelper.estimateSingleDirectMultiVault(
                            SingleDirectMultiVaultStateReq(multiSuperformsData[0]),
                            true
                        );

                    vm.prank(users[action.user]);

                    if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                        vm.expectRevert();
                    }

                    CHAIN_0 != DST_CHAINS[0]
                        ? superRouter.singleXChainMultiVaultDeposit{value: msgValue}(vars.singleDstMultiVaultStateReq)
                        : superRouter.singleDirectMultiVaultDeposit{value: msgValue}(
                            SingleDirectMultiVaultStateReq(multiSuperformsData[0])
                        );
                } else if (action.action == Actions.Withdraw) {
                    (, , dstValue, msgValue) = CHAIN_0 != DST_CHAINS[0]
                        ? paymentHelper.estimateSingleXChainMultiVault(vars.singleDstMultiVaultStateReq, false)
                        : paymentHelper.estimateSingleDirectMultiVault(
                            SingleDirectMultiVaultStateReq(multiSuperformsData[0]),
                            false
                        );

                    vm.prank(users[action.user]);

                    if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                        vm.expectRevert();
                    }

                    CHAIN_0 != DST_CHAINS[0]
                        ? superRouter.singleXChainMultiVaultWithdraw{value: msgValue}(vars.singleDstMultiVaultStateReq)
                        : superRouter.singleDirectMultiVaultWithdraw{value: msgValue}(
                            SingleDirectMultiVaultStateReq(multiSuperformsData[0])
                        );
                }
            } else if (vars.nDestinations > 1) {
                vars.multiDstMultiVaultStateReq = MultiDstMultiVaultStateReq(
                    MultiDstAMBs,
                    DST_CHAINS,
                    multiSuperformsData
                );

                if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                    (, , dstValue, msgValue) = paymentHelper.estimateMultiDstMultiVault(
                        vars.multiDstMultiVaultStateReq,
                        true
                    );
                    vm.prank(users[action.user]);

                    if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                        vm.expectRevert();
                    }

                    superRouter.multiDstMultiVaultDeposit{value: msgValue}(vars.multiDstMultiVaultStateReq);
                } else if (action.action == Actions.Withdraw) {
                    (, , dstValue, msgValue) = paymentHelper.estimateMultiDstMultiVault(
                        vars.multiDstMultiVaultStateReq,
                        false
                    );
                    vm.prank(users[action.user]);

                    if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                        vm.expectRevert();
                    }

                    superRouter.multiDstMultiVaultWithdraw{value: msgValue}(vars.multiDstMultiVaultStateReq);
                }
            }
        } else {
            if (vars.nDestinations == 1) {
                if (CHAIN_0 != DST_CHAINS[0]) {
                    vars.singleXChainSingleVaultStateReq = SingleXChainSingleVaultStateReq(
                        AMBs,
                        DST_CHAINS[0],
                        singleSuperformsData[0]
                    );

                    if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                        (, , dstValue, msgValue) = paymentHelper.estimateSingleXChainSingleVault(
                            vars.singleXChainSingleVaultStateReq,
                            true
                        );
                        vm.prank(users[action.user]);

                        if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                            vm.expectRevert();
                        }

                        superRouter.singleXChainSingleVaultDeposit{value: msgValue}(
                            vars.singleXChainSingleVaultStateReq
                        );
                    } else if (action.action == Actions.Withdraw) {
                        (, , dstValue, msgValue) = paymentHelper.estimateSingleXChainSingleVault(
                            vars.singleXChainSingleVaultStateReq,
                            false
                        );
                        vm.prank(users[action.user]);

                        if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                            vm.expectRevert();
                        }

                        superRouter.singleXChainSingleVaultWithdraw{value: msgValue}(
                            vars.singleXChainSingleVaultStateReq
                        );
                    }
                } else {
                    vars.singleDirectSingleVaultStateReq = SingleDirectSingleVaultStateReq(singleSuperformsData[0]);

                    if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                        (, , dstValue, msgValue) = paymentHelper.estimateSingleDirectSingleVault(
                            vars.singleDirectSingleVaultStateReq,
                            true
                        );
                        vm.prank(users[action.user]);

                        if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                            vm.expectRevert();
                        }

                        superRouter.singleDirectSingleVaultDeposit{value: msgValue}(
                            vars.singleDirectSingleVaultStateReq
                        );
                    } else if (action.action == Actions.Withdraw) {
                        (, , dstValue, msgValue) = paymentHelper.estimateSingleDirectSingleVault(
                            vars.singleDirectSingleVaultStateReq,
                            false
                        );
                        vm.prank(users[action.user]);

                        if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                            vm.expectRevert();
                        }

                        superRouter.singleDirectSingleVaultWithdraw{value: msgValue}(
                            vars.singleDirectSingleVaultStateReq
                        );
                    }
                }
            } else if (vars.nDestinations > 1) {
                vars.multiDstSingleVaultStateReq = MultiDstSingleVaultStateReq(
                    MultiDstAMBs,
                    DST_CHAINS,
                    singleSuperformsData
                );
                if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                    (, , dstValue, msgValue) = paymentHelper.estimateMultiDstSingleVault(
                        vars.multiDstSingleVaultStateReq,
                        true
                    );
                    vm.prank(users[action.user]);

                    if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                        vm.expectRevert();
                    }

                    superRouter.multiDstSingleVaultDeposit{value: msgValue}(vars.multiDstSingleVaultStateReq);
                } else if (action.action == Actions.Withdraw) {
                    (, , dstValue, msgValue) = paymentHelper.estimateMultiDstSingleVault(
                        vars.multiDstSingleVaultStateReq,
                        true
                    );
                    vm.prank(users[action.user]);

                    if (sameChainDstHasRevertingVault || action.testType == TestType.RevertMainAction) {
                        vm.expectRevert();
                    }

                    superRouter.multiDstSingleVaultWithdraw{value: msgValue}(vars.multiDstSingleVaultStateReq);
                }
            }
        }

        return vars;
    }

    struct Stage3InternalVars {
        address[] toMailboxes;
        uint32[] expDstDomains;
        address[] endpoints;
        uint16[] lzChainIds;
        uint64[] celerChainIds;
        address[] celerBusses;
        uint256[] forkIds;
        uint256 k;
    }

    /// @dev STEP 3 (FOR XCHAIN) Use corresponding AMB helper to get the message data and assert
    function _stage3_src_to_dst_amb_delivery(
        TestAction memory action,
        StagesLocalVars memory vars,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData
    ) internal returns (MessagingAssertVars[] memory) {
        Stage3InternalVars memory internalVars;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            if (usedDSTs[DST_CHAINS[i]].payloadNumber == 0) {
                /// @dev NOTE: re-set struct to 0 to reset repetitions for multi action
                delete usedDSTs[DST_CHAINS[i]];

                ++usedDSTs[DST_CHAINS[i]].payloadNumber;
                uniqueDSTs.push(DST_CHAINS[i]);
            } else {
                // add repetitions
                ++usedDSTs[DST_CHAINS[i]].payloadNumber;
            }
        }
        vars.nUniqueDsts = uniqueDSTs.length;

        /// @dev STEP 3 (FOR XCHAIN) Use corresponding AMB helper to get the message data and assert
        internalVars.toMailboxes = new address[](vars.nUniqueDsts);
        internalVars.expDstDomains = new uint32[](vars.nUniqueDsts);

        internalVars.endpoints = new address[](vars.nUniqueDsts);
        internalVars.lzChainIds = new uint16[](vars.nUniqueDsts);

        internalVars.celerBusses = new address[](vars.nUniqueDsts);
        internalVars.celerChainIds = new uint64[](vars.nUniqueDsts);

        internalVars.forkIds = new uint256[](vars.nUniqueDsts);

        internalVars.k = 0;
        for (uint256 i = 0; i < chainIds.length; i++) {
            for (uint256 j = 0; j < vars.nUniqueDsts; j++) {
                if (uniqueDSTs[j] == chainIds[i]) {
                    internalVars.toMailboxes[internalVars.k] = hyperlaneMailboxes[i];
                    internalVars.expDstDomains[internalVars.k] = hyperlane_chainIds[i];

                    internalVars.endpoints[internalVars.k] = lzEndpoints[i];
                    internalVars.lzChainIds[internalVars.k] = lz_chainIds[i];

                    internalVars.celerChainIds[internalVars.k] = celer_chainIds[i];
                    internalVars.celerBusses[internalVars.k] = celerMessageBusses[i];

                    internalVars.forkIds[internalVars.k] = FORKS[chainIds[i]];

                    internalVars.k++;
                }
            }
        }
        delete uniqueDSTs;
        vars.logs = vm.getRecordedLogs();

        for (uint256 index; index < AMBs.length; index++) {
            if (AMBs[index] == 1) {
                LayerZeroHelper(getContract(CHAIN_0, "LayerZeroHelper")).help(
                    internalVars.endpoints,
                    internalVars.lzChainIds,
                    5000000, /// note: using some max limit
                    internalVars.forkIds,
                    vars.logs
                );
            }

            if (AMBs[index] == 2) {
                /// @dev see pigeon for this implementation
                HyperlaneHelper(getContract(CHAIN_0, "HyperlaneHelper")).help(
                    address(HyperlaneMailbox),
                    internalVars.toMailboxes,
                    internalVars.expDstDomains,
                    internalVars.forkIds,
                    vars.logs
                );
            }

            if (AMBs[index] == 3) {
                CelerHelper(getContract(CHAIN_0, "CelerHelper")).help(
                    CELER_CHAIN_IDS[CHAIN_0],
                    CELER_BUSSES[CHAIN_0],
                    internalVars.celerBusses,
                    internalVars.celerChainIds,
                    internalVars.forkIds,
                    vars.logs
                );
            }
        }

        MessagingAssertVars[] memory aV = new MessagingAssertVars[](vars.nDestinations);

        CoreStateRegistry stateRegistry;
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            aV[i].toChainId = DST_CHAINS[i];
            if (usedDSTs[aV[i].toChainId].nRepetitions == 0) {
                usedDSTs[aV[i].toChainId].nRepetitions = usedDSTs[aV[i].toChainId].payloadNumber;
            }
            vm.selectFork(FORKS[aV[i].toChainId]);

            if (CHAIN_0 != aV[i].toChainId) {
                stateRegistry = CoreStateRegistry(payable(getContract(aV[i].toChainId, "CoreStateRegistry")));

                /// @dev NOTE: it's better to assert here inside the loop
                aV[i].receivedPayloadId = stateRegistry.payloadsCount() - usedDSTs[aV[i].toChainId].payloadNumber + 1;
                aV[i].data = abi.decode(stateRegistry.payload(aV[i].receivedPayloadId), (AMBMessage));

                /// @dev to assert LzMessage hasn't been tampered with (later we can assert tampers of this message)
                /// @dev - assert the payload reached destination state registry
                if (action.multiVaults) {
                    aV[i].expectedMultiVaultsData = multiSuperformsData[i];
                    aV[i].receivedMultiVaultData = abi.decode(aV[i].data.params, (InitMultiVaultData));

                    assertEq(aV[i].expectedMultiVaultsData.superFormIds, aV[i].receivedMultiVaultData.superFormIds);

                    assertEq(aV[i].expectedMultiVaultsData.amounts, aV[i].receivedMultiVaultData.amounts);
                } else {
                    aV[i].expectedSingleVaultData = singleSuperformsData[i];

                    aV[i].receivedSingleVaultData = abi.decode(aV[i].data.params, (InitSingleVaultData));

                    assertEq(aV[i].expectedSingleVaultData.superFormId, aV[i].receivedSingleVaultData.superFormId);

                    assertEq(aV[i].expectedSingleVaultData.amount, aV[i].receivedSingleVaultData.amount);
                }

                --usedDSTs[aV[i].toChainId].payloadNumber;
            }
        }
        return aV;
    }

    /// @dev STEP 4 Update state and process src to dst payload
    function _stage4_process_src_dst_payload(
        TestAction memory action,
        StagesLocalVars memory vars,
        MessagingAssertVars[] memory aV,
        SingleVaultSFData[] memory singleSuperformsData,
        uint256 actionIndex
    ) internal returns (bool success) {
        success = true;
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            aV[i].toChainId = DST_CHAINS[i];
            if (CHAIN_0 != aV[i].toChainId) {
                vm.selectFork(FORKS[aV[i].toChainId]);

                if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                    unchecked {
                        PAYLOAD_ID[aV[i].toChainId]++;
                    }

                    vars.multiVaultsPayloadArg = updateMultiVaultDepositPayloadArgs(
                        PAYLOAD_ID[aV[i].toChainId],
                        aV[i].receivedMultiVaultData.amounts,
                        action.slippage,
                        aV[i].toChainId,
                        action.testType,
                        action.revertError,
                        action.revertRole
                    );

                    vars.singleVaultsPayloadArg = updateSingleVaultDepositPayloadArgs(
                        PAYLOAD_ID[aV[i].toChainId],
                        aV[i].receivedSingleVaultData.amount,
                        action.slippage,
                        aV[i].toChainId,
                        action.testType,
                        action.revertError,
                        action.revertRole
                    );

                    if (action.testType == TestType.Pass) {
                        if (action.multiTx) {
                            (, vars.underlyingSrcToken, vars.underlyingDstToken, , ) = _targetVaults(
                                CHAIN_0,
                                DST_CHAINS[i],
                                actionIndex,
                                i
                            );
                            if (action.multiVaults) {
                                vars.amounts = AMOUNTS[DST_CHAINS[i]][actionIndex];
                                _batchProcessMultiTx(
                                    vars.liqBridges,
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    vars.underlyingSrcToken,
                                    vars.underlyingDstToken,
                                    vars.amounts
                                );
                            } else {
                                _processMultiTx(
                                    vars.liqBridges[0],
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    vars.underlyingSrcToken[0],
                                    vars.underlyingDstToken[0],
                                    singleSuperformsData[i].amount
                                );
                            }
                        }

                        if (action.multiVaults) {
                            _updateMultiVaultDepositPayload(vars.multiVaultsPayloadArg);
                        } else if (singleSuperformsData.length > 0) {
                            _updateSingleVaultDepositPayload(vars.singleVaultsPayloadArg);
                        }
                        console.log("grabbing logs");

                        vm.recordLogs();

                        (success, , ) = _processPayload(
                            PAYLOAD_ID[aV[i].toChainId],
                            aV[i].toChainId,
                            action.testType,
                            action.revertError
                        );
                        vars.logs = vm.getRecordedLogs();

                        _payloadDeliveryHelper(CHAIN_0, aV[i].toChainId, vars.logs);
                    } else if (action.testType == TestType.RevertProcessPayload) {
                        if (action.multiTx) {
                            (, vars.underlyingSrcToken, vars.underlyingDstToken, , ) = _targetVaults(
                                CHAIN_0,
                                DST_CHAINS[i],
                                actionIndex,
                                i
                            );
                            if (action.multiVaults) {
                                vars.amounts = AMOUNTS[DST_CHAINS[i]][actionIndex];
                                _batchProcessMultiTx(
                                    vars.liqBridges,
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    vars.underlyingSrcToken,
                                    vars.underlyingDstToken,
                                    vars.amounts
                                );
                            } else {
                                _processMultiTx(
                                    vars.liqBridges[0],
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    vars.underlyingSrcToken[0],
                                    vars.underlyingDstToken[0],
                                    singleSuperformsData[i].amount
                                );
                            }
                        }
                        if (action.multiVaults) {
                            _updateMultiVaultDepositPayload(vars.multiVaultsPayloadArg);
                        } else if (singleSuperformsData.length > 0) {
                            _updateSingleVaultDepositPayload(vars.singleVaultsPayloadArg);
                        }
                        (success, , ) = _processPayload(
                            PAYLOAD_ID[aV[i].toChainId],
                            aV[i].toChainId,
                            action.testType,
                            action.revertError
                        );
                        if (!success) {
                            return success;
                        }
                    } else if (
                        action.testType == TestType.RevertUpdateStateSlippage ||
                        action.testType == TestType.RevertUpdateStateRBAC
                    ) {
                        if (action.multiVaults) {
                            success = _updateMultiVaultDepositPayload(vars.multiVaultsPayloadArg);
                        } else {
                            success = _updateSingleVaultDepositPayload(vars.singleVaultsPayloadArg);
                        }

                        if (!success) {
                            return success;
                        }
                    }
                } else if (
                    action.action == Actions.Withdraw &&
                    (action.testType == TestType.Pass || action.testType == TestType.RevertVaultsWithdraw)
                ) {
                    unchecked {
                        PAYLOAD_ID[aV[i].toChainId]++;
                    }
                    console.log("grabbing logs");

                    if (GENERATE_WITHDRAW_TX_DATA_ON_DST) {
                        if (action.multiVaults) {
                            _updateMultiVaultWithdrawPayload(PAYLOAD_ID[aV[i].toChainId], aV[i].toChainId);
                        } else {
                            if (countTimelocked[i] == 0) {
                                _updateSingleVaultWithdrawPayload(PAYLOAD_ID[aV[i].toChainId], aV[i].toChainId);
                            }
                        }
                    }

                    vm.recordLogs();
                    /// note: this is high-lvl processPayload function, even if this happens outside of the user view
                    /// we need to manually process payloads by invoking sending actual messages
                    (success, , ) = _processPayload(
                        PAYLOAD_ID[aV[i].toChainId],
                        aV[i].toChainId,
                        action.testType,
                        action.revertError
                    );
                    vars.logs = vm.getRecordedLogs();

                    _payloadDeliveryHelper(CHAIN_0, aV[i].toChainId, vars.logs);
                }
            }
            vm.selectFork(aV[i].initialFork);
        }
    }

    /// @dev STEP 5 Process dst to src payload (mint of SuperPositions for deposits)
    function _stage5_process_superPositions_mint(
        TestAction memory action,
        StagesLocalVars memory vars,
        MultiVaultSFData[] memory multiSuperformsData
    ) internal returns (bool success) {
        /// assume it will pass by default
        success = true;

        console.log("stage5");
        vm.selectFork(FORKS[CHAIN_0]);

        uint256 toChainId;
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            toChainId = DST_CHAINS[i];

            if (CHAIN_0 != toChainId) {
                if (action.testType == TestType.Pass) {
                    if (action.multiVaults) {
                        if (revertingDepositSFs[i].length == multiSuperformsData[i].superFormIds.length) {
                            continue;
                        }
                    } else {
                        if (revertingDepositSFs[i].length == 1) {
                            continue;
                        }
                    }
                    unchecked {
                        PAYLOAD_ID[CHAIN_0]++;
                    }

                    (success, , ) = _processPayload(PAYLOAD_ID[CHAIN_0], CHAIN_0, action.testType, action.revertError);
                }
            }
        }
    }

    /// @dev STEP 6 Process dst to src payload (re-mint of SuperPositions for failed withdraws (inc. 1st stage timelock failures - unlock request))
    function _stage6_process_superPositions_withdraw(
        TestAction memory action,
        StagesLocalVars memory vars,
        MultiVaultSFData[] memory multiSuperformsData
    ) internal returns (bool success, bytes[] memory returnMessages, bool toAssert) {
        /// assume it will pass by default
        success = true;
        toAssert = false;
        vm.selectFork(FORKS[CHAIN_0]);

        uint256 toChainId;
        returnMessages = new bytes[](vars.nDestinations);
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            toChainId = DST_CHAINS[i];

            if (CHAIN_0 != toChainId) {
                /// @dev this must not be called if all vaults are reverting timelocked in a given destination
                if (action.multiVaults) {
                    if (revertingWithdrawTimelockedSFs[i].length == multiSuperformsData[i].superFormIds.length) {
                        continue;
                    }
                } else {
                    if (revertingWithdrawTimelockedSFs[i].length == 1) {
                        continue;
                    }
                }
                if (revertingWithdrawSFs[i].length > 0) {
                    toAssert = true;
                    unchecked {
                        PAYLOAD_ID[CHAIN_0]++;
                    }

                    (, returnMessages[i], ) = _processPayload(
                        PAYLOAD_ID[CHAIN_0],
                        CHAIN_0,
                        action.testType,
                        action.revertError
                    );
                }
            }
        }
    }

    function _stage7_finalize_timelocked_payload(
        TestAction memory action,
        StagesLocalVars memory vars
    ) internal returns (bytes[] memory returnMessages) {
        uint256 initialFork;
        uint256 currentUnlockId;
        returnMessages = new bytes[](vars.nDestinations);
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            if (countTimelocked[i] > 0) {
                initialFork = vm.activeFork();

                vm.selectFork(FORKS[DST_CHAINS[i]]);

                ITwoStepsFormStateRegistry twoStepsFormStateRegistry = ITwoStepsFormStateRegistry(
                    contracts[DST_CHAINS[i]][bytes32(bytes("TwoStepsFormStateRegistry"))]
                );

                currentUnlockId = twoStepsFormStateRegistry.timeLockPayloadCounter();
                if (currentUnlockId > 0) {
                    vm.recordLogs();

                    for (uint256 j = countTimelocked[i]; j > 0; j--) {
                        /// increase time by 5 days
                        vm.warp(block.timestamp + (86400 * 5));
                        (uint256 nativeFee, bytes memory ackAmbParams) = _generateAckGasFeesAndParamsForTimeLock(
                            abi.encode(CHAIN_0, DST_CHAINS[i]),
                            AMBs,
                            currentUnlockId - j + 1
                        );

                        vm.prank(deployer);

                        returnMessages[i] = twoStepsFormStateRegistry.finalizePayload{value: nativeFee}(
                            currentUnlockId - j + 1,
                            GENERATE_WITHDRAW_TX_DATA_ON_DST
                                ? TX_DATA_TO_UPDATE_ON_DST[DST_CHAINS[i]][timeLockedIndexes[DST_CHAINS[i]][j]]
                                : bytes(""),
                            ackAmbParams
                        );
                    }

                    Vm.Log[] memory logs = vm.getRecordedLogs();
                    _payloadDeliveryHelper(CHAIN_0, DST_CHAINS[i], logs);
                }
            }
        }
        vm.selectFork(initialFork);
    }

    /// NOTE: to process failed messages from 2 step forms registry on xchain withdraws
    function _stage8_process_failed_timelocked_xchain_remint(
        TestAction memory action,
        StagesLocalVars memory vars
    ) internal returns (bool success) {
        /// assume it will pass by default
        success = true;
        vm.selectFork(FORKS[CHAIN_0]);

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            if (CHAIN_0 != DST_CHAINS[i] && revertingWithdrawTimelockedSFs[i].length > 0) {
                IBaseStateRegistry twoStepsFormStateRegistry = IBaseStateRegistry(
                    contracts[CHAIN_0][bytes32(bytes("TwoStepsFormStateRegistry"))]
                );

                if (twoStepsFormStateRegistry.payload(TWO_STEP_PAYLOAD_ID[CHAIN_0] + 1).length > 0) {
                    unchecked {
                        TWO_STEP_PAYLOAD_ID[CHAIN_0]++;
                    }

                    success = _processTwoStepPayload(
                        TWO_STEP_PAYLOAD_ID[CHAIN_0],
                        CHAIN_0,
                        action.testType,
                        action.revertError
                    );
                }
            }
        }
    }

    function _buildMultiVaultCallData(
        MultiVaultCallDataArgs memory args
    ) internal returns (MultiVaultSFData memory superFormsData) {
        SingleVaultSFData memory superFormData;
        uint256 len = args.superFormIds.length;
        LiqRequest[] memory liqRequests = new LiqRequest[](len);
        SingleVaultCallDataArgs memory callDataArgs;

        if (len == 0) revert LEN_MISMATCH();
        uint256[] memory finalAmounts = new uint256[](len);
        uint256[] memory maxSlippageTemp = new uint256[](len);
        for (uint i = 0; i < len; i++) {
            finalAmounts[i] = args.amounts[i];
            /// @dev in sameChain actions, slippage is encoded in the request (extracted from bridge api)

            if (
                args.slippage != 0 &&
                ((args.srcChainId == args.toChainId &&
                    (args.action == Actions.Deposit || args.action == Actions.DepositPermit2)) ||
                    (args.action == Actions.Withdraw))
            ) {
                finalAmounts[i] = (args.amounts[i] * (10000 - uint256(args.slippage))) / 10000;
            }
            callDataArgs = SingleVaultCallDataArgs(
                args.user,
                args.fromSrc,
                args.externalToken,
                args.toDst[i],
                args.underlyingTokens[i],
                args.underlyingTokensDst[i],
                args.superFormIds[i],
                finalAmounts[i],
                args.liqBridges[i],
                args.maxSlippage,
                args.vaultMock[i],
                args.srcChainId,
                args.toChainId,
                args.liquidityBridgeSrcChainId,
                args.liquidityBridgeToChainId,
                args.multiTx,
                args.partialWithdrawVaults.length > 0 ? args.partialWithdrawVaults[i] : false
            );
            if (args.action == Actions.Deposit || args.action == Actions.DepositPermit2) {
                superFormData = _buildSingleVaultDepositCallData(callDataArgs, args.action);
            } else if (args.action == Actions.Withdraw) {
                superFormData = _buildSingleVaultWithdrawCallData(callDataArgs);
            }
            liqRequests[i] = superFormData.liqRequest;
            maxSlippageTemp[i] = args.maxSlippage;
        }

        superFormsData = MultiVaultSFData(
            args.superFormIds,
            finalAmounts,
            maxSlippageTemp,
            liqRequests,
            abi.encode(args.partialWithdrawVaults)
        );
    }

    function _buildLiqBridgeTxData(
        uint8 liqBridgeKind_,
        address externalToken_, // this is underlyingTokenDst for withdraws
        address underlyingToken_,
        address underlyingTokenDst_, // this is external token (to receive in the end) for withdraws
        address from_,
        uint64 toChainId_,
        bool multiTx_,
        address toDst_,
        uint256 liqBridgeToChainId_,
        uint256 amount_,
        bool withdraw
    ) internal returns (bytes memory txData) {
        if (liqBridgeKind_ == 1) {
            ISocketRegistry.BridgeRequest memory bridgeRequest;
            ISocketRegistry.MiddlewareRequest memory middlewareRequest;
            ISocketRegistry.UserRequest memory userRequest;
            /// @dev middlware request is used if there is a swap involved before the bridging action
            /// @dev the input token should be the token the user deposits, which will be swapped to the input token of bridging request
            if (externalToken_ != underlyingToken_) {
                middlewareRequest = ISocketRegistry.MiddlewareRequest(
                    1, /// request id
                    0,
                    externalToken_,
                    abi.encode(from_)
                );

                bridgeRequest = ISocketRegistry.BridgeRequest(
                    1, /// request id
                    0,
                    withdraw ? externalToken_ : underlyingToken_,
                    abi.encode(from_, FORKS[toChainId_], underlyingTokenDst_)
                );
            } else {
                bridgeRequest = ISocketRegistry.BridgeRequest(
                    1, /// request id
                    0,
                    withdraw ? externalToken_ : underlyingToken_,
                    abi.encode(from_, FORKS[toChainId_], underlyingTokenDst_)
                );
            }

            userRequest = ISocketRegistry.UserRequest(
                multiTx_ && CHAIN_0 != toChainId_ ? getContract(toChainId_, "MultiTxProcessor") : toDst_,
                liqBridgeToChainId_,
                amount_,
                middlewareRequest,
                bridgeRequest
            );

            txData = abi.encodeWithSelector(SocketRouterMock.outboundTransferTo.selector, userRequest);
        } else if (liqBridgeKind_ == 2) {
            ILiFi.BridgeData memory bridgeData;
            ILiFi.SwapData[] memory swapData = new ILiFi.SwapData[](1);

            swapData[0] = ILiFi.SwapData(
                address(0), /// callTo (arbitrary)
                address(0), /// callTo (approveTo)
                externalToken_,
                withdraw ? externalToken_ : underlyingToken_,
                amount_,
                abi.encode(from_, FORKS[toChainId_], underlyingTokenDst_),
                false // arbitrary
            );

            if (externalToken_ != underlyingToken_) {
                bridgeData = ILiFi.BridgeData(
                    bytes32("1"), /// request id
                    "",
                    "",
                    address(0),
                    withdraw ? externalToken_ : underlyingToken_,
                    multiTx_ && CHAIN_0 != toChainId_ ? getContract(toChainId_, "MultiTxProcessor") : toDst_,
                    amount_,
                    liqBridgeToChainId_,
                    true,
                    false
                );
            } else {
                bridgeData = ILiFi.BridgeData(
                    bytes32("1"), /// request id
                    "",
                    "",
                    address(0),
                    withdraw ? externalToken_ : underlyingToken_,
                    multiTx_ && CHAIN_0 != toChainId_ ? getContract(toChainId_, "MultiTxProcessor") : toDst_,
                    amount_,
                    liqBridgeToChainId_,
                    false,
                    false
                );
            }

            txData = abi.encodeWithSelector(LiFiMock.swapAndStartBridgeTokensViaBridge.selector, bridgeData, swapData);
        }
    }

    struct SingleVaultDepositLocalVars {
        uint256 initialFork;
        address from;
        IPermit2.PermitTransferFrom permit;
        bytes txData;
        bytes sig;
        bytes permit2Calldata;
        LiqRequest liqReq;
    }

    function _buildSingleVaultDepositCallData(
        SingleVaultCallDataArgs memory args,
        Actions action
    ) internal returns (SingleVaultSFData memory superFormData) {
        SingleVaultDepositLocalVars memory v;
        v.initialFork = vm.activeFork();

        v.from = args.fromSrc;

        if (args.srcChainId == args.toChainId) {
            /// @dev same chain deposit, from is Form
            v.from = args.toDst;
        }

        v.txData = _buildLiqBridgeTxData(
            args.liqBridge,
            args.externalToken,
            args.underlyingToken,
            args.underlyingTokenDst,
            v.from,
            args.toChainId,
            args.multiTx,
            args.toDst,
            args.liquidityBridgeToChainId,
            args.amount,
            false
        );

        address liqRequestToken = args.externalToken != args.underlyingToken
            ? args.externalToken
            : args.underlyingToken;

        /// DOMAIN SEPARATOR 0x7f58c5e4853ee1044a9464ec09890a6a21093dfc1fe4952ad7a8723718e3717e
        /// @dev permit2 calldata

        vm.selectFork(FORKS[args.srcChainId]);

        if (action == Actions.DepositPermit2) {
            v.permit = IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: IERC20(address(liqRequestToken)), amount: args.amount}),
                nonce: _randomUint256(),
                deadline: block.timestamp
            });
            v.sig = _signPermit(v.permit, v.from, userKeys[args.user], args.srcChainId); /// @dev from is either SuperformRouter (xchain) or the form (direct deposit)

            v.permit2Calldata = abi.encode(v.permit.nonce, v.permit.deadline, v.sig);
        }

        v.liqReq = LiqRequest(
            args.liqBridge,
            v.txData,
            liqRequestToken,
            args.amount,
            liqRequestToken == NATIVE_TOKEN ? args.amount : 0,
            v.permit2Calldata /// @dev will be empty if action == Actions.Deposit
        );

        if (liqRequestToken != NATIVE_TOKEN) {
            /// @dev - APPROVE transfer to SuperformRouter (because of Socket)
            vm.prank(users[args.user]);

            if (action == Actions.DepositPermit2) {
                MockERC20(liqRequestToken).approve(getContract(args.srcChainId, "CanonicalPermit2"), type(uint256).max);
            } else if (action == Actions.Deposit && liqRequestToken != NATIVE_TOKEN) {
                /// @dev this assumes that if same underlying is present in >1 vault in a multi vault, that the amounts are ordered from lowest to highest,
                /// @dev this is because the approves override each other and may lead to Arithmetic over/underflow
                MockERC20(liqRequestToken).increaseAllowance(v.from, args.amount);
            }
        }
        vm.selectFork(v.initialFork);

        superFormData = SingleVaultSFData(args.superFormId, args.amount, args.maxSlippage, v.liqReq, abi.encode(false));
    }

    struct SingleVaultWithdrawLocalVars {
        ISocketRegistry.MiddlewareRequest middlewareRequest;
        ISocketRegistry.BridgeRequest bridgeRequest;
        address superRouter;
        address stateRegistry;
        IERC1155s superPositions;
        bytes txData;
        LiqRequest liqReq;
    }

    function _buildSingleVaultWithdrawCallData(
        SingleVaultCallDataArgs memory args
    ) internal returns (SingleVaultSFData memory superFormData) {
        SingleVaultWithdrawLocalVars memory vars;

        uint256 initialFork = vm.activeFork();
        vm.selectFork(FORKS[CHAIN_0]);

        vars.superRouter = contracts[CHAIN_0][bytes32(bytes("SuperformRouter"))];
        vars.stateRegistry = contracts[CHAIN_0][bytes32(bytes("SuperRegistry"))];
        vars.superPositions = IERC1155s(ISuperRegistry(vars.stateRegistry).superPositions());
        vm.prank(users[args.user]);

        vars.superPositions.setApprovalForOne(vars.superRouter, args.superFormId, args.amount);

        vm.selectFork(initialFork);

        vars.txData = _buildLiqBridgeTxData(
            args.liqBridge,
            args.underlyingTokenDst,
            args.underlyingToken,
            args.externalToken,
            args.toDst,
            args.srcChainId,
            false,
            users[args.user],
            args.liquidityBridgeSrcChainId,
            args.amount,
            true
        );

        if (GENERATE_WITHDRAW_TX_DATA_ON_DST) {
            TX_DATA_TO_UPDATE_ON_DST[args.toChainId].push(vars.txData);
        }

        vars.liqReq = LiqRequest(
            args.liqBridge,
            GENERATE_WITHDRAW_TX_DATA_ON_DST ? bytes("") : vars.txData,
            args.underlyingTokenDst,
            args.amount,
            0,
            ""
        );

        superFormData = SingleVaultSFData(
            args.superFormId,
            args.amount,
            args.maxSlippage,
            vars.liqReq,
            abi.encode(args.partialWithdrawVault)
        );
    }

    /*///////////////////////////////////////////////////////////////
                             HELPERS
    //////////////////////////////////////////////////////////////*/

    struct TargetVaultsVars {
        uint256[] underlyingTokens;
        uint256[] vaultIds;
        uint32[] formKinds;
        uint256[] superFormIdsTemp;
        uint256 len;
        string underlyingToken;
    }

    /// @dev this function is used to build the 2D arrays in the best way possible
    function _targetVaults(
        uint64 chain0,
        uint64 chain1,
        uint256 action,
        uint256 dst
    )
        internal
        returns (
            uint256[] memory targetSuperformsMem,
            address[] memory underlyingSrcTokensMem,
            address[] memory underlyingDstTokensMem,
            address[] memory vaultMocksMem,
            bool[] memory partialWithdrawVaults
        )
    {
        TargetVaultsVars memory vars;
        vars.underlyingTokens = TARGET_UNDERLYINGS[chain1][action];
        vars.vaultIds = TARGET_VAULTS[chain1][action];
        vars.formKinds = TARGET_FORM_KINDS[chain1][action];

        partialWithdrawVaults = PARTIAL[chain1][action];

        vars.superFormIdsTemp = _superFormIds(vars.underlyingTokens, vars.vaultIds, vars.formKinds, chain1);

        vars.len = vars.superFormIdsTemp.length;

        if (vars.len == 0) revert LEN_VAULTS_ZERO();

        targetSuperformsMem = new uint256[](vars.len);
        underlyingSrcTokensMem = new address[](vars.len);
        underlyingDstTokensMem = new address[](vars.len);
        vaultMocksMem = new address[](vars.len);

        for (uint256 i = 0; i < vars.len; i++) {
            vars.underlyingToken = UNDERLYING_TOKENS[
                vars.underlyingTokens[i] // 1
            ];

            targetSuperformsMem[i] = vars.superFormIdsTemp[i];
            underlyingSrcTokensMem[i] = getContract(chain0, vars.underlyingToken);
            underlyingDstTokensMem[i] = getContract(chain1, vars.underlyingToken);
            vaultMocksMem[i] = getContract(chain1, VAULT_NAMES[vars.vaultIds[i]][vars.underlyingTokens[i]]);
            if (vars.vaultIds[i] == 3 || vars.vaultIds[i] == 5 || vars.vaultIds[i] == 6) {
                revertingDepositSFsPerDst.push(vars.superFormIdsTemp[i]);
            }
            if (vars.vaultIds[i] == 4) {
                revertingWithdrawTimelockedSFsPerDst.push(vars.superFormIdsTemp[i]);
            }
            if (vars.vaultIds[i] == 7 || vars.vaultIds[i] == 8) {
                revertingWithdrawSFsPerDst.push(vars.superFormIdsTemp[i]);
            }
            /// @dev need more if else conditions for other kinds of vaults
        }

        revertingDepositSFs.push(revertingDepositSFsPerDst);
        revertingWithdrawSFs.push(revertingWithdrawSFsPerDst);
        revertingWithdrawTimelockedSFs.push(revertingWithdrawTimelockedSFsPerDst);

        delete revertingDepositSFsPerDst;
        delete revertingWithdrawSFsPerDst;
        delete revertingWithdrawTimelockedSFsPerDst;

        for (uint256 j; j < vars.formKinds.length; j++) {
            if (vars.formKinds[j] == 1) ++countTimelocked[dst];
            timeLockedIndexes[chain1][countTimelocked[dst]] = j;
        }
    }

    function _superFormIds(
        uint256[] memory underlyingTokens_,
        uint256[] memory vaultIds_,
        uint32[] memory formKinds_,
        uint64 chainId_
    ) internal view returns (uint256[] memory) {
        uint256[] memory superFormIds_ = new uint256[](vaultIds_.length);
        if (vaultIds_.length != formKinds_.length) revert INVALID_TARGETS();
        if (vaultIds_.length != underlyingTokens_.length) revert INVALID_TARGETS();

        for (uint256 i = 0; i < vaultIds_.length; i++) {
            address superForm = getContract(
                chainId_,
                string.concat(
                    UNDERLYING_TOKENS[underlyingTokens_[i]],
                    VAULT_KINDS[vaultIds_[i]],
                    "Superform",
                    Strings.toString(FORM_BEACON_IDS[formKinds_[i]])
                )
            );

            superFormIds_[i] = DataLib.packSuperform(superForm, FORM_BEACON_IDS[formKinds_[i]], chainId_);
        }

        return superFormIds_;
    }

    function _updateMultiVaultDepositPayload(updateMultiVaultDepositPayloadArgs memory args) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[args.targetChainId]);
        uint256 len = args.amounts.length;
        uint256[] memory finalAmounts = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            finalAmounts[i] = args.amounts[i];
            if (args.slippage > 0) {
                finalAmounts[i] = (args.amounts[i] * (10000 - uint256(args.slippage))) / 10000;
            }
        }

        if (args.testType == TestType.Pass || args.testType == TestType.RevertProcessPayload) {
            vm.prank(deployer);

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry")))
                .updateMultiVaultDepositPayload(args.payloadId, finalAmounts);
        } else if (args.testType == TestType.RevertUpdateStateSlippage) {
            vm.prank(deployer);

            vm.expectRevert(args.revertError); /// @dev removed string here: come to this later

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry")))
                .updateMultiVaultDepositPayload(args.payloadId, finalAmounts);

            return false;
        } else if (args.testType == TestType.RevertUpdateStateRBAC) {
            vm.prank(users[2]);
            bytes memory errorMsg = getAccessControlErrorMsg(users[2], args.revertRole);
            vm.expectRevert(errorMsg);

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry")))
                .updateMultiVaultDepositPayload(args.payloadId, finalAmounts);

            return false;
        }

        vm.selectFork(initialFork);

        return true;
    }

    function _updateSingleVaultDepositPayload(updateSingleVaultDepositPayloadArgs memory args) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[args.targetChainId]);
        uint256 finalAmount;

        finalAmount = args.amount;
        if (args.slippage > 0) {
            finalAmount = (args.amount * (10000 - uint256(args.slippage))) / 10000;
        }

        if (args.testType == TestType.Pass || args.testType == TestType.RevertProcessPayload) {
            vm.prank(deployer);

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry")))
                .updateSingleVaultDepositPayload(args.payloadId, finalAmount);
        } else if (args.testType == TestType.RevertUpdateStateSlippage) {
            vm.prank(deployer);

            vm.expectRevert(args.revertError); /// @dev removed string here: come to this later

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry")))
                .updateSingleVaultDepositPayload(args.payloadId, finalAmount);

            return false;
        } else if (args.testType == TestType.RevertUpdateStateRBAC) {
            vm.prank(users[2]);
            bytes memory errorMsg = getAccessControlErrorMsg(users[2], args.revertRole);
            vm.expectRevert(errorMsg);

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry")))
                .updateSingleVaultDepositPayload(args.payloadId, finalAmount);

            return false;
        }

        vm.selectFork(initialFork);

        return true;
    }

    function _updateMultiVaultWithdrawPayload(uint256 payloadId, uint64 chainId) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[chainId]);
        vm.prank(deployer);

        CoreStateRegistry(payable(getContract(chainId, "CoreStateRegistry"))).updateMultiVaultWithdrawPayload(
            payloadId,
            TX_DATA_TO_UPDATE_ON_DST[chainId]
        );

        vm.selectFork(initialFork);

        return true;
    }

    function _updateSingleVaultWithdrawPayload(uint256 payloadId, uint64 chainId) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[chainId]);
        vm.prank(deployer);

        CoreStateRegistry(payable(getContract(chainId, "CoreStateRegistry"))).updateSingleVaultWithdrawPayload(
            payloadId,
            TX_DATA_TO_UPDATE_ON_DST[chainId][0]
        );

        vm.selectFork(initialFork);
        return true;
    }

    function _processPayload(
        uint256 payloadId_,
        uint64 targetChainId_,
        TestType testType,
        bytes4 revertError
    ) internal returns (bool, bytes memory savedMessage, bytes memory returnMessage) {
        uint256 initialFork = vm.activeFork();
        vm.selectFork(FORKS[targetChainId_]);

        uint256 nativeFee;
        bytes memory ackAmbParams;

        /// @dev only generate if acknowledgement is needed
        if (targetChainId_ != CHAIN_0) {
            (nativeFee, ackAmbParams) = _generateAckGasFeesAndParams(CHAIN_0, targetChainId_, AMBs, payloadId_);
        }

        vm.prank(deployer);
        if (testType == TestType.Pass) {
            (savedMessage, returnMessage) = CoreStateRegistry(payable(getContract(targetChainId_, "CoreStateRegistry")))
                .processPayload{value: nativeFee}(payloadId_, ackAmbParams);
        } else if (testType == TestType.RevertProcessPayload) {
            /// @dev WARNING the try catch silences the revert, therefore the only way to assert is via emit
            vm.expectEmit();
            // We emit the event we expect to see.
            emit FailedXChainDeposits(payloadId_);

            (savedMessage, returnMessage) = CoreStateRegistry(payable(getContract(targetChainId_, "CoreStateRegistry")))
                .processPayload{value: nativeFee}(payloadId_, ackAmbParams);
            return (false, savedMessage, returnMessage);
        }

        vm.selectFork(initialFork);
        return (true, savedMessage, returnMessage);
    }

    function _processTwoStepPayload(
        uint256 payloadId_,
        uint64 targetChainId_,
        TestType testType,
        bytes4
    ) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[targetChainId_]);

        /// @dev no acknowledgement is needed;
        bytes memory ackParams;

        vm.prank(deployer);

        TwoStepsFormStateRegistry(payable(getContract(targetChainId_, "TwoStepsFormStateRegistry"))).processPayload{
            value: msgValue
        }(payloadId_, ackParams);

        vm.selectFork(initialFork);
        return true;
    }

    function _buildLiqBridgeTxDataMultiTx(
        uint8 liqBridgeKind_,
        address underlyingToken_,
        address underlyingTokenDst_,
        address from_,
        uint64 toChainId_,
        uint256 amount_
    ) internal returns (bytes memory txData) {
        if (liqBridgeKind_ == 1) {
            ISocketRegistry.BridgeRequest memory bridgeRequest;
            ISocketRegistry.MiddlewareRequest memory middlewareRequest;
            ISocketRegistry.UserRequest memory userRequest;
            /// @dev middlware request is used if there is a swap involved before the bridging action
            /// @dev the input token should be the token the user deposits, which will be swapped to the input token of bridging request
            middlewareRequest = ISocketRegistry.MiddlewareRequest(
                1, /// request id
                0,
                underlyingTokenDst_,
                abi.encode(getContract(toChainId_, "MultiTxProcessor"), FORKS[toChainId_], underlyingTokenDst_)
            );

            /// @dev empty bridge request
            bridgeRequest = ISocketRegistry.BridgeRequest(
                0, /// id
                0,
                address(0),
                abi.encode(getContract(toChainId_, "MultiTxProcessor"), FORKS[toChainId_], underlyingTokenDst_)
            );

            userRequest = ISocketRegistry.UserRequest(
                getContract(toChainId_, "CoreStateRegistry"),
                uint256(toChainId_),
                amount_,
                middlewareRequest,
                bridgeRequest
            );

            txData = abi.encodeWithSelector(SocketRouterMock.outboundTransferTo.selector, userRequest);
        } else if (liqBridgeKind_ == 2) {
            ILiFi.BridgeData memory bridgeData;
            ILiFi.SwapData[] memory swapData = new ILiFi.SwapData[](1);

            swapData[0] = ILiFi.SwapData(
                address(0), /// callTo (arbitrary)
                address(0), /// callTo (approveTo)
                underlyingToken_,
                underlyingToken_,
                amount_,
                abi.encode(from_, FORKS[toChainId_], underlyingTokenDst_),
                false // arbitrary
            );

            bridgeData = ILiFi.BridgeData(
                bytes32("1"), /// request id
                "",
                "",
                address(0),
                underlyingTokenDst_,
                getContract(toChainId_, "CoreStateRegistry"),
                amount_,
                uint256(toChainId_),
                false,
                true
            );

            txData = abi.encodeWithSelector(LiFiMock.swapAndStartBridgeTokensViaBridge.selector, bridgeData, swapData);
        }
    }

    /// @dev - assumption to only use MultiTxProcessor for destination chain swaps (middleware requests)
    function _processMultiTx(
        uint8 liqBridgeKind_,
        uint64 srcChainId_,
        uint64 targetChainId_,
        address underlyingToken_,
        address underlyingTokenDst_,
        uint256 amount_
    ) internal {
        uint256 initialFork = vm.activeFork();
        vm.selectFork(FORKS[targetChainId_]);

        bytes memory txData = _buildLiqBridgeTxDataMultiTx(
            liqBridgeKind_,
            underlyingToken_,
            underlyingTokenDst_,
            getContract(targetChainId_, "MultiTxProcessor"),
            targetChainId_,
            amount_
        );

        vm.prank(deployer);

        MultiTxProcessor(payable(getContract(targetChainId_, "MultiTxProcessor"))).processTx(
            liqBridgeKind_,
            txData,
            underlyingTokenDst_,
            amount_
        );
        vm.selectFork(initialFork);
    }

    function _batchProcessMultiTx(
        uint8[] memory liqBridgeKinds_,
        uint64 srcChainId_,
        uint64 targetChainId_,
        address[] memory underlyingTokens_,
        address[] memory underlyingTokensDst_,
        uint256[] memory amounts_
    ) internal {
        uint256 initialFork = vm.activeFork();
        vm.selectFork(FORKS[targetChainId_]);

        bytes[] memory txDatas = new bytes[](underlyingTokens_.length);

        for (uint256 i = 0; i < underlyingTokens_.length; i++) {
            txDatas[i] = _buildLiqBridgeTxDataMultiTx(
                liqBridgeKinds_[i],
                underlyingTokens_[i],
                underlyingTokensDst_[i],
                getContract(targetChainId_, "MultiTxProcessor"),
                targetChainId_,
                amounts_[i]
            );
        }
        vm.prank(deployer);

        MultiTxProcessor(payable(getContract(targetChainId_, "MultiTxProcessor"))).batchProcessTx(
            liqBridgeKinds_,
            txDatas,
            underlyingTokensDst_,
            amounts_
        );
        vm.selectFork(initialFork);
    }

    function _payloadDeliveryHelper(uint64 FROM_CHAIN, uint64 TO_CHAIN, Vm.Log[] memory logs) internal {
        for (uint256 i; i < AMBs.length; i++) {
            /// @notice ID: 1 Layerzero
            if (AMBs[i] == 1) {
                LayerZeroHelper(getContract(TO_CHAIN, "LayerZeroHelper")).helpWithEstimates(
                    LZ_ENDPOINTS[FROM_CHAIN],
                    5000000, /// note: using some max limit
                    FORKS[FROM_CHAIN],
                    logs
                );
            }

            /// @notice ID: 2 Hyperlane
            if (AMBs[i] == 2) {
                HyperlaneHelper(getContract(TO_CHAIN, "HyperlaneHelper")).help(
                    address(HyperlaneMailbox),
                    address(HyperlaneMailbox),
                    FORKS[FROM_CHAIN],
                    logs
                );
            }

            /// @notice ID: 3 Celer
            if (AMBs[i] == 3) {
                CelerHelper(getContract(TO_CHAIN, "CelerHelper")).help(
                    CELER_CHAIN_IDS[TO_CHAIN],
                    CELER_BUSSES[TO_CHAIN],
                    CELER_BUSSES[FROM_CHAIN],
                    CELER_CHAIN_IDS[FROM_CHAIN],
                    FORKS[FROM_CHAIN],
                    logs
                );
            }
        }
    }

    function _assertMultiVaultBalance(
        uint256 user,
        uint256[] memory superFormIds,
        uint256[] memory amountsToAssert,
        bool[] memory partialWithdrawVaults
    ) internal {
        address superRegistryAddress = getContract(CHAIN_0, "SuperRegistry");
        vm.selectFork(FORKS[CHAIN_0]);

        address superPositionsAddress = ISuperRegistry(superRegistryAddress).superPositions();

        IERC1155s superPositions = IERC1155s(superPositionsAddress);

        uint256 currentBalanceOfSp;

        bool partialWithdraw = partialWithdrawVaults.length > 0;
        for (uint256 i = 0; i < superFormIds.length; i++) {
            currentBalanceOfSp = superPositions.balanceOf(users[user], superFormIds[i]);
            if (partialWithdrawVaults.length > 0) partialWithdraw = partialWithdrawVaults[i];

            if (!partialWithdraw) {
                assertEq(currentBalanceOfSp, amountsToAssert[i]);
            } else {
                assertGt(currentBalanceOfSp, amountsToAssert[i]);
            }
        }
    }

    function _assertSingleVaultBalance(uint256 user, uint256 superFormId, uint256 amountToAssert) internal {
        address superRegistryAddress = getContract(CHAIN_0, "SuperRegistry");
        vm.selectFork(FORKS[CHAIN_0]);

        address superPositionsAddress = ISuperRegistry(superRegistryAddress).superPositions();

        IERC1155s superPositions = IERC1155s(superPositionsAddress);

        uint256 currentBalanceOfSp = superPositions.balanceOf(users[user], superFormId);

        assertEq(currentBalanceOfSp, amountToAssert);
    }

    function _assertSingleVaultPartialWithdrawBalance(
        uint256 user,
        uint256 superFormId,
        uint256 amountToAssert
    ) internal {
        address superRegistryAddress = getContract(CHAIN_0, "SuperRegistry");
        vm.selectFork(FORKS[CHAIN_0]);

        address superPositionsAddress = ISuperRegistry(superRegistryAddress).superPositions();

        IERC1155s superPositions = IERC1155s(superPositionsAddress);

        uint256 currentBalanceOfSp = superPositions.balanceOf(users[user], superFormId);
        assertGt(currentBalanceOfSp, amountToAssert);
    }

    struct DepositMultiSPCalculationVars {
        uint256 lenSuperforms;
        address[] superForms;
        uint256 finalAmount;
        bool foundRevertingDeposit;
        uint256 i;
        uint256 j;
        uint256 k;
    }

    function _spAmountsMultiBeforeActionOrAfterSuccessDeposit(
        MultiVaultSFData memory multiSuperformsData,
        bool assertWithSlippage,
        int256 slippage,
        bool sameChain,
        uint256 repetitions,
        uint256 lenRevertDeposit,
        uint256 dstIndex
    ) internal returns (uint256[] memory emptyAmount, uint256[] memory spAmountSummed, uint256 totalSpAmount) {
        DepositMultiSPCalculationVars memory v;
        v.lenSuperforms = multiSuperformsData.superFormIds.length;
        emptyAmount = new uint256[](v.lenSuperforms);
        spAmountSummed = new uint256[](v.lenSuperforms);

        // create an array of amounts summing the amounts of the same superform ids
        (v.superForms, , ) = DataLib.getSuperforms(multiSuperformsData.superFormIds);

        for (v.i = 0; v.i < v.lenSuperforms; v.i++) {
            totalSpAmount += multiSuperformsData.amounts[v.i];
            for (v.j = 0; v.j < v.lenSuperforms; v.j++) {
                v.foundRevertingDeposit = false;

                if (lenRevertDeposit > 0) {
                    for (v.k = 0; v.k < lenRevertDeposit; v.k++) {
                        v.foundRevertingDeposit =
                            revertingDepositSFs[dstIndex][v.k] == multiSuperformsData.superFormIds[v.i];
                        if (v.foundRevertingDeposit) break;
                    }
                }
                if (
                    multiSuperformsData.superFormIds[v.i] == multiSuperformsData.superFormIds[v.j] &&
                    !v.foundRevertingDeposit
                ) {
                    v.finalAmount = multiSuperformsData.amounts[v.j];
                    if (assertWithSlippage && slippage != 0 && !sameChain) {
                        v.finalAmount = (multiSuperformsData.amounts[v.j] * (10000 - uint256(slippage))) / 10000;
                    }
                    v.finalAmount = v.finalAmount * repetitions;

                    spAmountSummed[v.i] += v.finalAmount;
                }
            }
            vm.selectFork(FORKS[DST_CHAINS[dstIndex]]);

            spAmountSummed[v.i] = IBaseForm(v.superForms[v.i]).previewDepositTo(spAmountSummed[v.i]);
        }
    }

    function _spAmountsMultiAfterWithdraw(
        MultiVaultSFData memory multiSuperformsData,
        uint256 user,
        uint256[] memory currentSPBeforeWithdaw,
        uint256 lenRevertWithdraw,
        uint256 lenRevertWithdrawTimelocked,
        bool sameDst,
        uint256 dstIndex
    ) internal returns (uint256[] memory spAmountFinal) {
        uint256 lenSuperforms = multiSuperformsData.superFormIds.length;
        spAmountFinal = new uint256[](lenSuperforms);

        if (sameDst && lenRevertWithdraw > 0) {
            spAmountFinal = multiSuperformsData.amounts;
        } else {
            // create an array of amounts summing the amounts of the same superform ids
            (address[] memory superForms, , ) = DataLib.getSuperforms(multiSuperformsData.superFormIds);
            bool foundRevertingWithdraw;
            bool foundRevertingWithdrawTimelocked;
            for (uint256 i = 0; i < lenSuperforms; i++) {
                spAmountFinal[i] = currentSPBeforeWithdaw[i];

                for (uint256 j = 0; j < lenSuperforms; j++) {
                    foundRevertingWithdraw = false;
                    foundRevertingWithdrawTimelocked = false;

                    if (lenRevertWithdraw > 0) {
                        for (uint k = 0; k < lenRevertWithdraw; k++) {
                            foundRevertingWithdraw =
                                revertingWithdrawSFs[dstIndex][k] == multiSuperformsData.superFormIds[i];
                            if (foundRevertingWithdraw) break;
                        }
                    }
                    if (lenRevertWithdrawTimelocked > 0) {
                        for (uint k = 0; k < lenRevertWithdrawTimelocked; k++) {
                            foundRevertingWithdrawTimelocked =
                                revertingWithdrawTimelockedSFs[dstIndex][k] == multiSuperformsData.superFormIds[i];
                            if (foundRevertingWithdrawTimelocked) break;
                        }
                    }

                    if (
                        multiSuperformsData.superFormIds[i] == multiSuperformsData.superFormIds[j] &&
                        !(sameDst && foundRevertingWithdraw)
                    ) {
                        spAmountFinal[i] -= multiSuperformsData.amounts[j];
                    }
                }
            }
        }
    }

    function _spAmountsMultiAfterStage7Withdraw(
        MultiVaultSFData memory multiSuperformsData,
        uint256 user,
        uint256[] memory currentSPBeforeWithdaw,
        uint256 lenRevertWithdraw,
        uint256 lenRevertWithdrawTimelocked,
        bool sameDst,
        uint256 dstIndex
    ) internal returns (uint256[] memory spAmountFinal) {
        uint256 lenSuperforms = multiSuperformsData.superFormIds.length;
        spAmountFinal = new uint256[](lenSuperforms);

        // create an array of amounts summing the amounts of the same superform ids
        (address[] memory superForms, , ) = DataLib.getSuperforms(multiSuperformsData.superFormIds);
        bool foundRevertingWithdraw;
        bool foundRevertingWithdrawTimelocked;

        for (uint256 i = 0; i < lenSuperforms; i++) {
            spAmountFinal[i] = currentSPBeforeWithdaw[i];
            for (uint256 j = 0; j < lenSuperforms; j++) {
                foundRevertingWithdraw = false;
                foundRevertingWithdrawTimelocked = false;

                if (lenRevertWithdraw > 0) {
                    for (uint k = 0; k < lenRevertWithdraw; k++) {
                        foundRevertingWithdraw =
                            revertingWithdrawSFs[dstIndex][k] == multiSuperformsData.superFormIds[i];
                        if (foundRevertingWithdraw) break;
                    }
                }
                if (lenRevertWithdrawTimelocked > 0) {
                    for (uint k = 0; k < lenRevertWithdrawTimelocked; k++) {
                        foundRevertingWithdrawTimelocked =
                            revertingWithdrawTimelockedSFs[dstIndex][k] == multiSuperformsData.superFormIds[i];
                        if (foundRevertingWithdrawTimelocked) break;
                    }
                }

                if (
                    multiSuperformsData.superFormIds[i] == multiSuperformsData.superFormIds[j] &&
                    !((sameDst && (foundRevertingWithdraw || foundRevertingWithdrawTimelocked)) ||
                        (!sameDst && foundRevertingWithdraw))
                ) {
                    spAmountFinal[i] -= multiSuperformsData.amounts[j];
                }
            }
        }
    }

    function _spAmountsMultiAfterFailedWithdraw(
        MultiVaultSFData memory multiSuperformsData,
        uint256 user,
        uint256[] memory currentSPBeforeWithdaw,
        uint256[] memory failedSPAmounts
    ) internal returns (uint256[] memory spAmountFinal) {
        uint256 lenSuperforms = multiSuperformsData.superFormIds.length;
        spAmountFinal = new uint256[](lenSuperforms);

        // create an array of amounts summing the amounts of the same superform ids
        (address[] memory superForms, , ) = DataLib.getSuperforms(multiSuperformsData.superFormIds);

        for (uint256 i = 0; i < lenSuperforms; i++) {
            spAmountFinal[i] = currentSPBeforeWithdaw[i];

            for (uint256 j = 0; j < lenSuperforms; j++) {
                if (
                    multiSuperformsData.superFormIds[i] == multiSuperformsData.superFormIds[j] &&
                    failedSPAmounts[i] == 0
                ) {
                    spAmountFinal[i] -= multiSuperformsData.amounts[j];
                }
            }
        }
    }

    struct AssertBeforeActionVars {
        address token;
        bool partialWithdrawVault;
        bool[] partialWithdrawVaults;
        address superForm;
    }

    function _assertBeforeAction(
        TestAction memory action,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        StagesLocalVars memory vars
    )
        internal
        returns (
            uint256[] memory emptyAmount,
            uint256[][] memory spAmountSummed,
            uint256[] memory spAmountBeforeWithdrawPerDestination,
            uint256 inputBalanceBefore
        )
    {
        /// @dev spAmountSummed likely needs to be a double array
        AssertBeforeActionVars memory v;
        if (action.multiVaults) {
            v.token = multiSuperformsData[0].liqRequests[0].token;
            if (action.action != Actions.Withdraw) {
                inputBalanceBefore = v.token != NATIVE_TOKEN
                    ? IERC20(v.token).balanceOf(users[action.user])
                    : users[action.user].balance;
            }
            uint256[] memory spAmountSummedPerDst;
            spAmountSummed = new uint256[][](vars.nDestinations);
            for (uint256 i = 0; i < vars.nDestinations; i++) {
                v.partialWithdrawVaults = abi.decode(multiSuperformsData[i].extraFormData, (bool[]));
                (emptyAmount, spAmountSummedPerDst, ) = _spAmountsMultiBeforeActionOrAfterSuccessDeposit(
                    multiSuperformsData[i],
                    false,
                    0,
                    false,
                    1,
                    0,
                    i
                );
                _assertMultiVaultBalance(
                    action.user,
                    multiSuperformsData[i].superFormIds,
                    action.action == Actions.Withdraw ? spAmountSummedPerDst : emptyAmount,
                    v.partialWithdrawVaults
                );
                spAmountSummed[i] = spAmountSummedPerDst;
            }
            console.log("Asserted b4 action multi");
        } else {
            v.token = singleSuperformsData[0].liqRequest.token;
            if (action.action != Actions.Withdraw) {
                inputBalanceBefore = v.token != NATIVE_TOKEN
                    ? IERC20(v.token).balanceOf(users[action.user])
                    : users[action.user].balance;
            }
            spAmountBeforeWithdrawPerDestination = new uint256[](vars.nDestinations);
            for (uint256 i = 0; i < vars.nDestinations; i++) {
                (v.superForm, , ) = singleSuperformsData[i].superFormId.getSuperform();
                v.partialWithdrawVault = abi.decode(singleSuperformsData[i].extraFormData, (bool));
                vm.selectFork(FORKS[DST_CHAINS[i]]);

                spAmountBeforeWithdrawPerDestination[i] = IBaseForm(v.superForm).previewDepositTo(
                    singleSuperformsData[i].amount
                );

                if (!v.partialWithdrawVault) {
                    _assertSingleVaultBalance(
                        action.user,
                        singleSuperformsData[i].superFormId,
                        action.action == Actions.Withdraw ? spAmountBeforeWithdrawPerDestination[i] : 0
                    );
                } else {
                    _assertSingleVaultPartialWithdrawBalance(
                        action.user,
                        singleSuperformsData[i].superFormId,
                        spAmountBeforeWithdrawPerDestination[i]
                    );
                }
            }
            console.log("Asserted b4 action");
        }
    }

    function _assertAfterDeposit(
        TestAction memory action,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        StagesLocalVars memory vars,
        uint256 inputBalanceBefore
    ) internal {
        vm.selectFork(FORKS[CHAIN_0]);

        uint256 lenRevertDeposit;
        uint256[] memory spAmountSummed;
        uint256 totalSpAmount;
        uint256 totalSpAmountAllDestinations;
        address token;
        bool foundRevertingDeposit;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            uint256 repetitions = usedDSTs[DST_CHAINS[i]].nRepetitions;
            lenRevertDeposit = 0;
            if (revertingDepositSFs.length > 0) lenRevertDeposit = revertingDepositSFs[i].length;

            if (action.multiVaults) {
                (, spAmountSummed, totalSpAmount) = _spAmountsMultiBeforeActionOrAfterSuccessDeposit(
                    multiSuperformsData[i],
                    true,
                    action.slippage,
                    CHAIN_0 == DST_CHAINS[i],
                    repetitions,
                    lenRevertDeposit,
                    i
                );
                totalSpAmountAllDestinations += totalSpAmount;

                token = multiSuperformsData[0].liqRequests[0].token;

                if (CHAIN_0 == DST_CHAINS[i] && lenRevertDeposit > 0) {
                    /// assert spToken Balance to zero if one of the multi vaults is reverting in same chain
                    _assertMultiVaultBalance(
                        action.user,
                        multiSuperformsData[i].superFormIds,
                        new uint256[](multiSuperformsData[i].superFormIds.length),
                        new bool[](multiSuperformsData[i].superFormIds.length)
                    );
                } else {
                    /// assert spToken Balance
                    _assertMultiVaultBalance(
                        action.user,
                        multiSuperformsData[i].superFormIds,
                        spAmountSummed,
                        new bool[](multiSuperformsData[i].superFormIds.length)
                    );
                }
            } else {
                foundRevertingDeposit = false;

                if (lenRevertDeposit > 0) {
                    foundRevertingDeposit = revertingDepositSFs[i][0] == singleSuperformsData[i].superFormId;
                }

                totalSpAmountAllDestinations += singleSuperformsData[i].amount;

                token = singleSuperformsData[0].liqRequest.token;

                uint256 finalAmount = singleSuperformsData[i].amount;

                if (action.slippage != 0 && CHAIN_0 != DST_CHAINS[i]) {
                    finalAmount = (singleSuperformsData[i].amount * (10000 - uint256(action.slippage))) / 10000;
                }

                finalAmount = repetitions * finalAmount;
                /// assert spToken Balance
                _assertSingleVaultBalance(
                    action.user,
                    singleSuperformsData[i].superFormId,
                    foundRevertingDeposit ? 0 : finalAmount
                );
            }
        }

        if (token == NATIVE_TOKEN) {
            console.log("balance now", users[action.user].balance);
            console.log("balance Before action", inputBalanceBefore);
            console.log("msgValue", msgValue);
            console.log("balance now + msgValue", msgValue + users[action.user].balance);
        }
        /// @dev assert user input token balance

        // assertEq(
        //     token != NATIVE_TOKEN ? IERC20(token).balanceOf(users[action.user]) : users[action.user].balance,
        //     inputBalanceBefore - totalSpAmountAllDestinations - msgValue
        // );
        // console.log("Asserted after deposit");
    }

    struct AssertAfterWithdrawVars {
        uint256[] spAmountFinal;
        uint256 lenRevertWithdraw;
        uint256 lenRevertWithdrawTimelocked;
        bool foundRevertingWithdraw;
        bool foundRevertingWithdrawTimelocked;
        bool sameDst;
        bool partialWithdrawVault;
        bool[] partialWithdrawVaults;
    }

    function _assertAfterStage4Withdraw(
        TestAction memory action,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        StagesLocalVars memory vars,
        uint256[][] memory spAmountsBeforeWithdraw,
        uint256[] memory spAmountBeforeWithdrawPerDst
    ) internal {
        vm.selectFork(FORKS[CHAIN_0]);

        AssertAfterWithdrawVars memory v;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            v.sameDst = CHAIN_0 == DST_CHAINS[i];
            v.lenRevertWithdraw = 0;
            v.lenRevertWithdrawTimelocked = 0;
            if (revertingWithdrawSFs.length > 0)
                /// @ev if doubleArray exists
                v.lenRevertWithdraw = revertingWithdrawSFs[i].length;

            if (revertingWithdrawTimelockedSFs.length > 0)
                v.lenRevertWithdrawTimelocked = revertingWithdrawTimelockedSFs[i].length;

            if (action.multiVaults) {
                v.partialWithdrawVaults = abi.decode(multiSuperformsData[i].extraFormData, (bool[]));

                v.spAmountFinal = _spAmountsMultiAfterWithdraw(
                    multiSuperformsData[i],
                    action.user,
                    spAmountsBeforeWithdraw[i],
                    v.lenRevertWithdraw,
                    v.lenRevertWithdrawTimelocked,
                    v.sameDst,
                    i
                );

                _assertMultiVaultBalance(
                    action.user,
                    multiSuperformsData[i].superFormIds,
                    v.spAmountFinal,
                    v.partialWithdrawVaults
                );
            } else {
                v.foundRevertingWithdraw = false;
                v.foundRevertingWithdrawTimelocked = false;
                v.partialWithdrawVault = abi.decode(singleSuperformsData[i].extraFormData, (bool));

                if (v.lenRevertWithdraw > 0) {
                    v.foundRevertingWithdraw = revertingWithdrawSFs[i][0] == singleSuperformsData[i].superFormId;
                } else if (v.lenRevertWithdrawTimelocked > 0) {
                    v.foundRevertingWithdrawTimelocked =
                        revertingWithdrawTimelockedSFs[i][0] == singleSuperformsData[i].superFormId;
                }

                if (!v.partialWithdrawVault) {
                    /// @dev this assertion assumes the withdraw is happening on the same superformId as the previous deposit
                    _assertSingleVaultBalance(
                        action.user,
                        singleSuperformsData[i].superFormId,
                        v.sameDst && v.foundRevertingWithdraw
                            ? spAmountBeforeWithdrawPerDst[i]
                            : spAmountBeforeWithdrawPerDst[i] - singleSuperformsData[i].amount
                    );
                } else {
                    _assertSingleVaultPartialWithdrawBalance(
                        action.user,
                        singleSuperformsData[i].superFormId,
                        v.sameDst && v.foundRevertingWithdraw
                            ? spAmountBeforeWithdrawPerDst[i]
                            : spAmountBeforeWithdrawPerDst[i] - singleSuperformsData[i].amount
                    );
                }
            }
        }
        console.log("Asserted after withdraw");
    }

    function _assertAfterStage7Withdraw(
        TestAction memory action,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        StagesLocalVars memory vars,
        uint256[][] memory spAmountsBeforeWithdraw,
        uint256[] memory spAmountBeforeWithdrawPerDst
    ) internal {
        vm.selectFork(FORKS[CHAIN_0]);

        AssertAfterWithdrawVars memory v;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            v.sameDst = CHAIN_0 == DST_CHAINS[i];
            v.lenRevertWithdraw = 0;
            v.lenRevertWithdrawTimelocked = 0;
            if (revertingWithdrawSFs.length > 0)
                /// @ev if doubleArray exists
                v.lenRevertWithdraw = revertingWithdrawSFs[i].length;

            if (revertingWithdrawTimelockedSFs.length > 0)
                v.lenRevertWithdrawTimelocked = revertingWithdrawTimelockedSFs[i].length;

            if (action.multiVaults) {
                if (!(v.sameDst && v.lenRevertWithdraw > 0)) {
                    v.partialWithdrawVaults = abi.decode(multiSuperformsData[i].extraFormData, (bool[]));
                    v.spAmountFinal = _spAmountsMultiAfterStage7Withdraw(
                        multiSuperformsData[i],
                        action.user,
                        spAmountsBeforeWithdraw[i],
                        v.lenRevertWithdraw,
                        v.lenRevertWithdrawTimelocked,
                        v.sameDst,
                        i
                    );
                    _assertMultiVaultBalance(
                        action.user,
                        multiSuperformsData[i].superFormIds,
                        v.spAmountFinal,
                        v.partialWithdrawVaults
                    );
                }
            } else {
                v.foundRevertingWithdraw = false;
                v.foundRevertingWithdrawTimelocked = false;
                v.partialWithdrawVault = abi.decode(singleSuperformsData[i].extraFormData, (bool));

                if (v.lenRevertWithdraw > 0) {
                    v.foundRevertingWithdraw = revertingWithdrawSFs[i][0] == singleSuperformsData[i].superFormId;
                }
                if (v.lenRevertWithdrawTimelocked > 0) {
                    v.foundRevertingWithdrawTimelocked =
                        revertingWithdrawTimelockedSFs[i][0] == singleSuperformsData[i].superFormId;
                }

                if (!v.partialWithdrawVault) {
                    /// @dev this assertion assumes the withdraw is happening on the same superformId as the previous deposit
                    _assertSingleVaultBalance(
                        action.user,
                        singleSuperformsData[i].superFormId,
                        ((v.sameDst && (v.foundRevertingWithdraw || v.foundRevertingWithdrawTimelocked)) ||
                            (!v.sameDst && v.foundRevertingWithdraw))
                            ? spAmountBeforeWithdrawPerDst[i]
                            : spAmountBeforeWithdrawPerDst[i] - singleSuperformsData[i].amount
                    );
                } else {
                    _assertSingleVaultPartialWithdrawBalance(
                        action.user,
                        singleSuperformsData[i].superFormId,
                        ((v.sameDst && (v.foundRevertingWithdraw || v.foundRevertingWithdrawTimelocked)) ||
                            (!v.sameDst && v.foundRevertingWithdraw))
                            ? spAmountBeforeWithdrawPerDst[i]
                            : spAmountBeforeWithdrawPerDst[i] - singleSuperformsData[i].amount
                    );
                }
            }
        }
        console.log("Asserted after stage7 timelock withdraw");
    }

    function _assertAfterFailedWithdraw(
        TestAction memory action,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        StagesLocalVars memory vars,
        uint256[][] memory spAmountsBeforeWithdraw,
        uint256[] memory spAmountBeforeWithdrawPerDst,
        bytes[] memory returnMessages
    ) internal {
        vm.selectFork(FORKS[CHAIN_0]);
        uint256[] memory spAmountFinal;
        ReturnMultiData memory returnMultiData;

        bool partialWithdrawVault;
        bool[] memory partialWithdrawVaults;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            /// @dev TODO probably not testing multiDstMultIVault same chain due to no return message for failed cases? - Joao
            if (action.multiVaults && returnMessages[i].length > 0) {
                partialWithdrawVaults = abi.decode(multiSuperformsData[i].extraFormData, (bool[]));

                returnMultiData = abi.decode(abi.decode(returnMessages[i], (AMBMessage)).params, (ReturnMultiData));

                spAmountFinal = _spAmountsMultiAfterFailedWithdraw(
                    multiSuperformsData[i],
                    action.user,
                    spAmountsBeforeWithdraw[i],
                    returnMultiData.amounts
                );

                _assertMultiVaultBalance(
                    action.user,
                    multiSuperformsData[i].superFormIds,
                    spAmountFinal,
                    partialWithdrawVaults
                );
            } else if (!action.multiVaults) {
                partialWithdrawVault = abi.decode(singleSuperformsData[i].extraFormData, (bool));
                if (returnMessages[i].length > 0) {
                    if (!partialWithdrawVault) {
                        /// @dev this assertion assumes the withdraw is happening on the same superformId as the previous deposit
                        _assertSingleVaultBalance(
                            action.user,
                            singleSuperformsData[i].superFormId,
                            spAmountBeforeWithdrawPerDst[i]
                        );
                    } else {
                        _assertSingleVaultPartialWithdrawBalance(
                            action.user,
                            singleSuperformsData[i].superFormId,
                            spAmountBeforeWithdrawPerDst[i]
                        );
                    }
                }
            }
        }
        console.log("Asserted after failed withdraw");
    }

    struct AssertAfterTimelockFailedWithdraw {
        uint256[] spAmountFinal;
        bool partialWithdrawVault;
        bool[] partialWithdrawVaults;
        ReturnMultiData returnMultiData;
        ReturnSingleData returnSingleData;
        uint256[] amountsThatFailed;
    }

    function _assertAfterTimelockFailedWithdraw(
        TestAction memory action,
        MultiVaultSFData[] memory multiSuperformsData,
        SingleVaultSFData[] memory singleSuperformsData,
        StagesLocalVars memory vars,
        uint256[][] memory spAmountsBeforeWithdraw,
        uint256[] memory spAmountBeforeWithdrawPerDst,
        bytes[] memory returnMessagesNormal,
        bytes[] memory returnMessagesTimelocked
    ) internal {
        vm.selectFork(FORKS[CHAIN_0]);

        AssertAfterTimelockFailedWithdraw memory v;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            if (!(CHAIN_0 == DST_CHAINS[i] && revertingWithdrawSFs[i].length > 0)) {
                if (revertingWithdrawTimelockedSFs[i].length > 0) {
                    if (action.multiVaults) {
                        v.partialWithdrawVaults = abi.decode(multiSuperformsData[i].extraFormData, (bool[]));

                        if (returnMessagesNormal.length > 0 && returnMessagesNormal[i].length > 0) {
                            v.returnMultiData = abi.decode(
                                abi.decode(returnMessagesNormal[i], (AMBMessage)).params,
                                (ReturnMultiData)
                            );
                        }

                        if (returnMessagesTimelocked.length > 0 && returnMessagesTimelocked[i].length > 0) {
                            v.returnSingleData = abi.decode(
                                abi.decode(returnMessagesTimelocked[i], (AMBMessage)).params,
                                (ReturnSingleData)
                            );
                        }

                        v.amountsThatFailed = new uint256[](multiSuperformsData[i].superFormIds.length);
                        for (uint256 j = 0; j < multiSuperformsData[i].superFormIds.length; j++) {
                            v.amountsThatFailed[j] = returnMessagesNormal.length > 0 &&
                                returnMessagesNormal[i].length > 0 &&
                                returnMessagesTimelocked.length > 0 &&
                                returnMessagesTimelocked[i].length > 0
                                ? v.returnMultiData.amounts[j]
                                : 0;

                            for (uint256 k = 0; k < revertingWithdrawTimelockedSFs[i].length; k++) {
                                if (multiSuperformsData[i].superFormIds[j] == revertingWithdrawTimelockedSFs[i][k]) {
                                    v.amountsThatFailed[j] = v.returnSingleData.amount;
                                }
                            }
                        }

                        v.spAmountFinal = _spAmountsMultiAfterFailedWithdraw(
                            multiSuperformsData[i],
                            action.user,
                            spAmountsBeforeWithdraw[i],
                            v.amountsThatFailed
                        );

                        _assertMultiVaultBalance(
                            action.user,
                            multiSuperformsData[i].superFormIds,
                            v.spAmountFinal,
                            v.partialWithdrawVaults
                        );
                    } else {
                        v.partialWithdrawVault = abi.decode(singleSuperformsData[i].extraFormData, (bool));
                        if (!v.partialWithdrawVault) {
                            /// @dev this assertion assumes the withdraw is happening on the same superformId as the previous deposit
                            _assertSingleVaultBalance(
                                action.user,
                                singleSuperformsData[i].superFormId,
                                spAmountBeforeWithdrawPerDst[i]
                            );
                        } else {
                            _assertSingleVaultPartialWithdrawBalance(
                                action.user,
                                singleSuperformsData[i].superFormId,
                                spAmountBeforeWithdrawPerDst[i]
                            );
                        }
                    }
                }
            }
        }
        console.log("Asserted after failed timelock withdraw");
    }

    /// @dev Returns the sum of token amounts
    function _sumOfAmounts() internal view returns (uint256 totalAmounts) {
        for (uint256 i; i < DST_CHAINS.length; i++) {
            for (uint256 j; j < actions.length; j++) {
                uint256[] memory amounts = AMOUNTS[DST_CHAINS[i]][j];

                for (uint256 k; k < amounts.length; k++) {
                    totalAmounts += amounts[k];
                }
            }
        }
    }
}
