/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

/// @dev lib imports
import "./BaseSetup.sol";
import "../../utils/DataPacking.sol";
import {IPermit2} from "../../vendor/dragonfly-xyz/IPermit2.sol";
import {ISocketRegistry} from "../../vendor/socket/ISocketRegistry.sol";
import {ILiFi} from "../../vendor/lifi/ILiFi.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {SocketRouterMock} from "../mocks/SocketRouterMock.sol";
import {LiFiMock} from "../mocks/LiFiMock.sol";
import {ISuperRegistry} from "../../interfaces/ISuperRegistry.sol";
import {ITwoStepsFormStateRegistry} from "../../interfaces/ITwoStepsFormStateRegistry.sol";
import {IERC1155s} from "ERC1155s/interfaces/IERC1155s.sol";

abstract contract ProtocolActions is BaseSetup {
    event FailedXChainDeposits(uint256 indexed payloadId);

    uint8[] public AMBs;

    uint8[][] public MultiDstAMBs;

    uint64 public CHAIN_0;

    uint64[] public DST_CHAINS;

    mapping(uint64 chainId => mapping(uint256 action => uint256[] underlyingTokenIds)) public TARGET_UNDERLYINGS;

    mapping(uint64 chainId => mapping(uint256 action => uint256[] vaultIds)) public TARGET_VAULTS;

    mapping(uint64 chainId => mapping(uint256 action => uint32[] formKinds)) public TARGET_FORM_KINDS;

    mapping(uint64 chainId => mapping(uint256 index => uint256[] action)) public AMOUNTS;

    mapping(uint64 chainId => mapping(uint256 index => uint256[] action)) public MAX_SLIPPAGE;

    /// @dev 1 for socket, 2 for lifi
    mapping(uint64 chainId => mapping(uint256 index => uint8[] liqBridgeId)) public LIQ_BRIDGES;

    /// NOTE: Now that we can pass individual actions, this array is only useful for more extended simulations
    TestAction[] public actions;

    function setUp() public virtual override {
        super.setUp();
    }

    /*///////////////////////////////////////////////////////////////
                            MAIN INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _runMainStages(
        TestAction memory action,
        uint256 act,
        MultiVaultsSFData[] memory multiSuperFormsData,
        SingleVaultSFData[] memory singleSuperFormsData,
        MessagingAssertVars[] memory aV,
        StagesLocalVars memory vars,
        bool success
    ) internal {
        (multiSuperFormsData, singleSuperFormsData, vars) = _stage1_buildReqData(action, act);
        uint256[] memory spAmountSummed;
        uint256 spAmountBeforeWithdraw;
        uint256 inputBalanceBefore;
        (, spAmountSummed, spAmountBeforeWithdraw, inputBalanceBefore) = _assertBeforeAction(
            action,
            multiSuperFormsData,
            singleSuperFormsData,
            vars
        );

        vars = _stage2_run_src_action(action, multiSuperFormsData, singleSuperFormsData, vars);

        aV = _stage3_src_to_dst_amb_delivery(action, vars, multiSuperFormsData, singleSuperFormsData);

        success = _stage4_process_src_dst_payload(action, vars, aV, singleSuperFormsData, act);
        if (!success) {
            console.log("Stage 4 failed");
            return;
        } else if (action.action == Actions.Withdraw && action.testType == TestType.Pass) {
            /// @dev fully successful withdraws finish here
            _assertAfterWithdraw(
                action,
                multiSuperFormsData,
                singleSuperFormsData,
                vars,
                spAmountSummed,
                spAmountBeforeWithdraw
            );
        }
        console.log("balance stage 4", users[action.user].balance);

        if (
            (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) &&
            !(action.testType == TestType.RevertXChainDeposit)
        ) {
            success = _stage5_process_superPositions_mint(action, vars);
            if (!success) {
                console.log("Stage 5 failed");

                return;
            } else {
                _assertAfterDeposit(action, multiSuperFormsData, singleSuperFormsData, vars, inputBalanceBefore);
            }
        }

        /// @dev stage 6 is only required if there is any failed withdraw in the multi vaults
        if (action.action == Actions.Withdraw && action.testType == TestType.RevertXChainWithdraw) {
            bytes memory returnMessage;
            (success, returnMessage) = _stage6_process_superPositions_withdraw(action, vars);
            if (!success) {
                console.log("Stage 6 failed");
                return;
            } else {
                /// @dev TODO check if this is working!
                _assertAfterFailedWithdraw(
                    action,
                    multiSuperFormsData,
                    singleSuperFormsData,
                    vars,
                    spAmountSummed,
                    spAmountBeforeWithdraw,
                    returnMessage
                );
            }
        }

        /// @dev stage 7 and 8 are only required for timelocked forms
        if (action.action == Actions.WithdrawTimelocked) {
            /// @dev Keeper needs to know this value to be able to process unlock
            success = _stage7_process_unlock_withdraw(action, vars, 1);
            if (!success) {
                console.log("Stage 7 failed");
                return;
            } else {
                _assertAfterWithdraw(
                    action,
                    multiSuperFormsData,
                    singleSuperFormsData,
                    vars,
                    spAmountSummed,
                    spAmountBeforeWithdraw
                );
            }
            // if (action.testType == TestType.RevertXChainWithdraw) {
            /// @dev Process payload received on source from destination (withdraw callback)
            /// @dev TODO, THERE IS NO PROCESS PAYLOAD FUNCTION IN TwoStepsFormStateRegistry to re-issue SuperPositions in case of failure!!
            success = _stage8_process_2step_payload(action, vars);
            if (!success) {
                console.log("Stage 8 failed");
                return;
            } else {
                /// @dev TODO to rework (assert SuperPositions are minted back in case of failure)
                //_assertAfterWithdraw(action, multiSuperFormsData, singleSuperFormsData, vars);
            }

            /// @dev TODO what about failed withdraws in timelocked???
        }
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
            MultiVaultsSFData[] memory multiSuperFormsData,
            SingleVaultSFData[] memory singleSuperFormsData,
            StagesLocalVars memory vars
        )
    {
        if (action.revertError != bytes4(0) && action.testType == TestType.Pass) revert MISMATCH_TEST_TYPE();

        /// FIXME: Separate concerns in tests, this revert is for protocol level operation
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
        vars.fromSrc = payable(getContract(CHAIN_0, "SuperFormRouter"));

        vars.nDestinations = DST_CHAINS.length;

        vars.lzEndpoints_1 = new address[](vars.nDestinations);
        vars.toDst = new address[](vars.nDestinations);
        multiSuperFormsData = new MultiVaultsSFData[](vars.nDestinations);
        singleSuperFormsData = new SingleVaultSFData[](vars.nDestinations);
        /// @dev FIXME this probably needs to be tailored for NATIVE DEPOSITS
        /// @dev with multi state requests, the entire msg.value is used. Msg.value in that case should cover
        /// @dev the sum of native assets needed in each state request
        action.msgValue = action.msgValue + (vars.nDestinations + 1) * _getPriceMultiplier(CHAIN_0) * 1e18;
        console.log("action.msgValue", action.msgValue);
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            for (uint256 j = 0; j < chainIds.length; j++) {
                if (DST_CHAINS[i] == chainIds[j]) {
                    vars.chainDstIndex = j;
                    break;
                }
            }

            vars.lzEndpoints_1[i] = LZ_ENDPOINTS[DST_CHAINS[i]];
            (vars.targetSuperFormIds, vars.underlyingSrcToken, vars.vaultMock) = _targetVaults(
                CHAIN_0,
                DST_CHAINS[i],
                actionIndex
            );

            vars.toDst = new address[](vars.targetSuperFormIds.length);

            /// @dev action is sameChain, if there is a liquidity swap it should go to the same form
            /// @dev if action is cross chain withdraw, user can select to receive a different kind of underlying from source

            for (uint256 k = 0; k < vars.targetSuperFormIds.length; k++) {
                if (CHAIN_0 == DST_CHAINS[i] || (action.action == Actions.Withdraw && CHAIN_0 != DST_CHAINS[i])) {
                    (vars.superFormT, , ) = _getSuperForm(vars.targetSuperFormIds[k]);
                    vars.toDst[k] = payable(vars.superFormT);
                } else {
                    vars.toDst[k] = payable(getContract(DST_CHAINS[i], "CoreStateRegistry"));
                }
            }

            vars.amounts = AMOUNTS[DST_CHAINS[i]][actionIndex];

            vars.maxSlippage = MAX_SLIPPAGE[DST_CHAINS[i]][actionIndex];

            vars.liqBridges = LIQ_BRIDGES[DST_CHAINS[i]][actionIndex];

            if (action.multiVaults) {
                multiSuperFormsData[i] = _buildMultiVaultCallData(
                    MultiVaultCallDataArgs(
                        action.user,
                        vars.fromSrc,
                        action.externalToken == 3
                            ? NATIVE_TOKEN
                            : getContract(CHAIN_0, UNDERLYING_TOKENS[action.externalToken]),
                        vars.toDst,
                        vars.underlyingSrcToken,
                        vars.targetSuperFormIds,
                        vars.amounts,
                        vars.liqBridges,
                        vars.maxSlippage,
                        vars.vaultMock,
                        CHAIN_0,
                        DST_CHAINS[i],
                        llChainIds[vars.chain0Index],
                        llChainIds[vars.chainDstIndex],
                        action.multiTx,
                        action.action
                    )
                );
            } else {
                SingleVaultCallDataArgs memory singleVaultCallDataArgs = SingleVaultCallDataArgs(
                    action.user,
                    vars.fromSrc,
                    action.externalToken == 3
                        ? NATIVE_TOKEN
                        : getContract(CHAIN_0, UNDERLYING_TOKENS[action.externalToken]),
                    vars.toDst[0],
                    vars.underlyingSrcToken[0],
                    vars.targetSuperFormIds[0],
                    vars.amounts[0],
                    vars.liqBridges[0],
                    vars.maxSlippage[0],
                    vars.vaultMock[0],
                    CHAIN_0,
                    DST_CHAINS[i],
                    llChainIds[vars.chain0Index],
                    llChainIds[vars.chainDstIndex],
                    action.multiTx
                );

                if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                    singleSuperFormsData[i] = _buildSingleVaultDepositCallData(singleVaultCallDataArgs, action.action);
                } else {
                    singleSuperFormsData[i] = _buildSingleVaultWithdrawCallData(singleVaultCallDataArgs);
                }
            }
        }
    }

    /// @dev STEP 2: Run Source Chain Action
    function _stage2_run_src_action(
        TestAction memory action,
        MultiVaultsSFData[] memory multiSuperFormsData,
        SingleVaultSFData[] memory singleSuperFormsData,
        StagesLocalVars memory vars
    ) internal returns (StagesLocalVars memory) {
        SuperFormRouter superRouter = SuperFormRouter(vars.fromSrc);

        vm.selectFork(FORKS[CHAIN_0]);

        if (action.testType != TestType.RevertMainAction) {
            vm.startPrank(users[action.user]);
            /// @dev see @pigeon for this implementation
            vm.recordLogs();

            if (action.multiVaults) {
                if (vars.nDestinations == 1) {
                    vars.singleDstMultiVaultStateReq = SingleDstMultiVaultsStateReq(
                        AMBs,
                        DST_CHAINS[0],
                        multiSuperFormsData[0],
                        action.ambParams[0]
                    );

                    if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                        superRouter.singleDstMultiVaultDeposit{value: action.msgValue}(
                            vars.singleDstMultiVaultStateReq
                        );
                    } else if (action.action == Actions.Withdraw) {
                        superRouter.singleDstMultiVaultWithdraw{value: action.msgValue}(
                            vars.singleDstMultiVaultStateReq
                        );
                    }
                } else if (vars.nDestinations > 1) {
                    vars.multiDstMultiVaultStateReq = MultiDstMultiVaultsStateReq(
                        MultiDstAMBs,
                        DST_CHAINS,
                        multiSuperFormsData,
                        action.ambParams
                    );

                    if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                        superRouter.multiDstMultiVaultDeposit{value: action.msgValue}(vars.multiDstMultiVaultStateReq);
                    } else if (action.action == Actions.Withdraw) {
                        superRouter.multiDstMultiVaultWithdraw{value: action.msgValue}(vars.multiDstMultiVaultStateReq);
                    }
                }
            } else {
                if (vars.nDestinations == 1) {
                    if (CHAIN_0 != DST_CHAINS[0]) {
                        vars.singleXChainSingleVaultStateReq = SingleXChainSingleVaultStateReq(
                            AMBs,
                            DST_CHAINS[0],
                            singleSuperFormsData[0],
                            action.ambParams[0]
                        );

                        if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                            superRouter.singleXChainSingleVaultDeposit{value: action.msgValue}(
                                vars.singleXChainSingleVaultStateReq
                            );
                        } else if (action.action == Actions.Withdraw) {
                            superRouter.singleXChainSingleVaultWithdraw{value: action.msgValue}(
                                vars.singleXChainSingleVaultStateReq
                            );
                        }
                    } else {
                        vars.singleDirectSingleVaultStateReq = SingleDirectSingleVaultStateReq(
                            DST_CHAINS[0],
                            singleSuperFormsData[0],
                            action.ambParams[0]
                        );

                        if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                            superRouter.singleDirectSingleVaultDeposit{value: action.msgValue}(
                                vars.singleDirectSingleVaultStateReq
                            );
                        } else if (action.action == Actions.Withdraw) {
                            superRouter.singleDirectSingleVaultWithdraw{value: action.msgValue}(
                                vars.singleDirectSingleVaultStateReq
                            );
                        }
                    }
                } else if (vars.nDestinations > 1) {
                    vars.multiDstSingleVaultStateReq = MultiDstSingleVaultStateReq(
                        MultiDstAMBs,
                        DST_CHAINS,
                        singleSuperFormsData,
                        action.ambParams
                    );
                    if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                        superRouter.multiDstSingleVaultDeposit{value: action.msgValue}(
                            vars.multiDstSingleVaultStateReq
                        );
                    } else if (action.action == Actions.Withdraw) {
                        superRouter.multiDstSingleVaultWithdraw{value: action.msgValue}(
                            vars.multiDstSingleVaultStateReq
                        );
                    }
                }
            }
            vm.stopPrank();
        } else {
            /// @dev TODO
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
        MultiVaultsSFData[] memory multiSuperFormsData,
        SingleVaultSFData[] memory singleSuperFormsData
    ) internal returns (MessagingAssertVars[] memory) {
        Stage3InternalVars memory internalVars;
        MessagingAssertVars[] memory aV = new MessagingAssertVars[](vars.nDestinations);

        /// @dev STEP 3 (FOR XCHAIN) Use corresponding AMB helper to get the message data and assert
        internalVars.toMailboxes = new address[](vars.nDestinations);
        internalVars.expDstDomains = new uint32[](vars.nDestinations);

        internalVars.endpoints = new address[](vars.nDestinations);
        internalVars.lzChainIds = new uint16[](vars.nDestinations);

        internalVars.celerBusses = new address[](vars.nDestinations);
        internalVars.celerChainIds = new uint64[](vars.nDestinations);

        internalVars.forkIds = new uint256[](vars.nDestinations);

        internalVars.k = 0;
        for (uint256 i = 0; i < chainIds.length; i++) {
            for (uint256 j = 0; j < vars.nDestinations; j++) {
                if (DST_CHAINS[j] == chainIds[i]) {
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
        vars.logs = vm.getRecordedLogs();

        for (uint256 index; index < AMBs.length; index++) {
            if (AMBs[index] == 1) {
                LayerZeroHelper(getContract(CHAIN_0, "LayerZeroHelper")).help(
                    internalVars.endpoints,
                    internalVars.lzChainIds,
                    1000000, /// (change to 2000000) @dev FIXME: should be calculated automatically - This is the gas value to send - value needs to be tested and probably be lower
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

        CoreStateRegistry stateRegistry;
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            aV[i].initialFork = vm.activeFork();
            aV[i].toChainId = DST_CHAINS[i];
            vm.selectFork(FORKS[aV[i].toChainId]);

            if (CHAIN_0 != aV[i].toChainId) {
                stateRegistry = CoreStateRegistry(payable(getContract(aV[i].toChainId, "CoreStateRegistry")));

                /// @dev NOTE: it's better to assert here inside the loop
                aV[i].receivedPayloadId = stateRegistry.payloadsCount();
                aV[i].data = abi.decode(stateRegistry.payload(aV[i].receivedPayloadId), (AMBMessage));

                /// @dev to assert LzMessage hasn't been tampered with (later we can assert tampers of this message)
                /// @dev - assert the payload reached destination state registry
                if (action.multiVaults) {
                    aV[i].expectedMultiVaultsData = multiSuperFormsData[i];
                    aV[i].receivedMultiVaultData = abi.decode(aV[i].data.params, (InitMultiVaultData));

                    assertEq(aV[i].expectedMultiVaultsData.superFormIds, aV[i].receivedMultiVaultData.superFormIds);

                    assertEq(aV[i].expectedMultiVaultsData.amounts, aV[i].receivedMultiVaultData.amounts);
                } else {
                    aV[i].expectedSingleVaultData = singleSuperFormsData[i];

                    aV[i].receivedSingleVaultData = abi.decode(aV[i].data.params, (InitSingleVaultData));

                    assertEq(aV[i].expectedSingleVaultData.superFormId, aV[i].receivedSingleVaultData.superFormId);

                    assertEq(aV[i].expectedSingleVaultData.amount, aV[i].receivedSingleVaultData.amount);
                }
            }
            //vm.selectFork(aV.initialFork);
        }
        return aV;
    }

    /// @dev STEP 4 Update state and process src to dst payload
    function _stage4_process_src_dst_payload(
        TestAction memory action,
        StagesLocalVars memory vars,
        MessagingAssertVars[] memory aV,
        SingleVaultSFData[] memory singleSuperFormsData,
        uint256 actionIndex
    ) internal returns (bool success) {
        /// assume it will pass by default
        success = true;
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            aV[i].toChainId = DST_CHAINS[i];
            if (CHAIN_0 != aV[i].toChainId) {
                if (action.action == Actions.Deposit || action.action == Actions.DepositPermit2) {
                    unchecked {
                        PAYLOAD_ID[aV[i].toChainId]++;
                    }

                    vars.multiVaultsPayloadArg = UpdateMultiVaultPayloadArgs(
                        PAYLOAD_ID[aV[i].toChainId],
                        aV[i].receivedMultiVaultData.amounts,
                        action.slippage,
                        aV[i].toChainId,
                        action.testType,
                        action.revertError,
                        action.revertRole
                    );

                    vars.singleVaultsPayloadArg = UpdateSingleVaultPayloadArgs(
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
                            (, vars.underlyingSrcToken, ) = _targetVaults(CHAIN_0, DST_CHAINS[i], actionIndex);
                            if (action.multiVaults) {
                                vars.amounts = AMOUNTS[DST_CHAINS[i]][actionIndex];
                                _batchProcessMultiTx(
                                    vars.liqBridges,
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    llChainIds[vars.chainDstIndex],
                                    vars.underlyingSrcToken,
                                    vars.amounts
                                );
                            } else {
                                _processMultiTx(
                                    vars.liqBridges[0],
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    llChainIds[vars.chainDstIndex],
                                    vars.underlyingSrcToken[0],
                                    singleSuperFormsData[i].amount
                                );
                            }
                        }

                        if (action.multiVaults) {
                            _updateMultiVaultPayload(vars.multiVaultsPayloadArg);
                        } else if (singleSuperFormsData.length > 0) {
                            _updateSingleVaultPayload(vars.singleVaultsPayloadArg);
                        }

                        vm.recordLogs();
                        (success, ) = _processPayload(
                            PAYLOAD_ID[aV[i].toChainId],
                            aV[i].toChainId,
                            action.testType,
                            action.revertError
                        );

                        vars.logs = vm.getRecordedLogs();

                        _payloadDeliveryHelper(CHAIN_0, aV[i].toChainId, vars.logs);
                    } else if (action.testType == TestType.RevertProcessPayload) {
                        /// @dev FIXME brute copied this here, likely the whole if else can be optimized (we are trying to detect reverts at processPayload stage)
                        if (action.multiTx) {
                            (, vars.underlyingSrcToken, ) = _targetVaults(CHAIN_0, DST_CHAINS[i], actionIndex);
                            if (action.multiVaults) {
                                vars.amounts = AMOUNTS[DST_CHAINS[i]][actionIndex];
                                _batchProcessMultiTx(
                                    vars.liqBridges,
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    llChainIds[vars.chainDstIndex],
                                    vars.underlyingSrcToken,
                                    vars.amounts
                                );
                            } else {
                                _processMultiTx(
                                    vars.liqBridges[0],
                                    CHAIN_0,
                                    aV[i].toChainId,
                                    llChainIds[vars.chainDstIndex],
                                    vars.underlyingSrcToken[0],
                                    singleSuperFormsData[i].amount
                                );
                            }
                        }
                        if (action.multiVaults) {
                            _updateMultiVaultPayload(vars.multiVaultsPayloadArg);
                        } else if (singleSuperFormsData.length > 0) {
                            _updateSingleVaultPayload(vars.singleVaultsPayloadArg);
                        }
                        (success, ) = _processPayload(
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
                            success = _updateMultiVaultPayload(vars.multiVaultsPayloadArg);
                        } else {
                            success = _updateSingleVaultPayload(vars.singleVaultsPayloadArg);
                        }

                        if (!success) {
                            return success;
                        }
                    }
                } else {
                    unchecked {
                        PAYLOAD_ID[aV[i].toChainId]++;
                    }

                    vm.recordLogs();
                    /// note: this is high-lvl processPayload function, even if this happens outside of the user view
                    /// we need to manually process payloads by invoking sending actual messages
                    (success, ) = _processPayload(
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
        StagesLocalVars memory vars
    ) internal returns (bool success) {
        /// assume it will pass by default
        success = true;
        uint256 toChainId;
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            toChainId = DST_CHAINS[i];

            if (CHAIN_0 != toChainId) {
                if (action.testType == TestType.Pass) {
                    unchecked {
                        PAYLOAD_ID[CHAIN_0]++;
                    }

                    (success, ) = _processPayload(PAYLOAD_ID[CHAIN_0], CHAIN_0, action.testType, action.revertError);
                }
            }
        }
    }

    /// NOTE: For 2-way comms we need to now process payload on Source again
    function _stage6_process_superPositions_withdraw(
        TestAction memory action,
        StagesLocalVars memory vars
    ) internal returns (bool success, bytes memory returnMessage) {
        /// assume it will pass by default
        success = true;

        unchecked {
            PAYLOAD_ID[CHAIN_0]++;
        }

        (success, returnMessage) = _processPayload(PAYLOAD_ID[CHAIN_0], CHAIN_0, action.testType, action.revertError);
    }

    function _stage7_process_unlock_withdraw(
        TestAction memory action,
        StagesLocalVars memory vars,
        uint256 unlockId_
    ) internal returns (bool success) {
        vm.prank(deployer);
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            vm.recordLogs();
            vm.selectFork(FORKS[DST_CHAINS[i]]);
            ITwoStepsFormStateRegistry twoStepsFormStateRegistry = ITwoStepsFormStateRegistry(
                contracts[DST_CHAINS[i]][bytes32(bytes("TwoStepsFormStateRegistry"))]
            );
            vm.rollFork(block.number + 20000);
            //twoStepsFormStateRegistry.finalizePayload(unlockId_, generateAckParams(AMBs));
        }

        return true;
    }

    /// NOTE: to process failed messages from 2 step forms registry
    /// @dev implemented due to payload id collision
    function _stage8_process_2step_payload(
        TestAction memory action,
        StagesLocalVars memory vars
    ) internal returns (bool success) {
        /// assume it will pass by default
        success = true;

        unchecked {
            TWO_STEP_PAYLOAD_ID[CHAIN_0]++;
        }

        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[CHAIN_0]);

        _processTwoStepPayload(TWO_STEP_PAYLOAD_ID[CHAIN_0], CHAIN_0, action.testType, action.revertError);

        vm.selectFork(initialFork);

        return true;
    }

    function _buildMultiVaultCallData(
        MultiVaultCallDataArgs memory args
    ) internal returns (MultiVaultsSFData memory superFormsData) {
        SingleVaultSFData memory superFormData;
        uint256 len = args.superFormIds.length;
        LiqRequest[] memory liqRequests = new LiqRequest[](len);
        SingleVaultCallDataArgs memory callDataArgs;

        if (len == 0) revert LEN_MISMATCH();

        for (uint i = 0; i < len; i++) {
            callDataArgs = SingleVaultCallDataArgs(
                args.user,
                args.fromSrc,
                args.externalToken,
                args.toDst[i],
                args.underlyingTokens[i],
                args.superFormIds[i],
                args.amounts[i],
                args.liqBridges[i],
                args.maxSlippage[i],
                args.vaultMock[i],
                args.srcChainId,
                args.toChainId,
                args.liquidityBridgeSrcChainId,
                args.liquidityBridgeToChainId,
                args.multiTx
            );
            if (args.action == Actions.Deposit || args.action == Actions.DepositPermit2) {
                superFormData = _buildSingleVaultDepositCallData(callDataArgs, args.action);
            } else if (args.action == Actions.Withdraw) {
                superFormData = _buildSingleVaultWithdrawCallData(callDataArgs);
            }
            liqRequests[i] = superFormData.liqRequest;
        }

        superFormsData = MultiVaultsSFData(args.superFormIds, args.amounts, args.maxSlippage, liqRequests, "");
    }

    function _buildLiqBridgeTxData(
        uint8 liqBridgeKind_,
        address externalToken_,
        address underlyingToken_,
        address from_,
        uint64 toChainId_,
        bool multiTx_,
        address toDst_,
        uint256 liqBridgeToChainId_,
        uint256 amount_
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
                    0, /// FIXME optional native amount
                    externalToken_,
                    abi.encode(from_)
                );

                bridgeRequest = ISocketRegistry.BridgeRequest(
                    1, /// request id
                    0, /// FIXME optional native amount
                    underlyingToken_,
                    abi.encode(from_, FORKS[toChainId_])
                );
            } else {
                bridgeRequest = ISocketRegistry.BridgeRequest(
                    1, /// request id
                    0, /// FIXME optional native amount
                    underlyingToken_,
                    abi.encode(from_, FORKS[toChainId_])
                );
            }

            userRequest = ISocketRegistry.UserRequest(
                multiTx_ ? getContract(toChainId_, "MultiTxProcessor") : toDst_,
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
                underlyingToken_,
                amount_,
                abi.encode(from_, FORKS[toChainId_]),
                false // arbitrary
            );

            if (externalToken_ != underlyingToken_) {
                bridgeData = ILiFi.BridgeData(
                    bytes32("1"), /// request id
                    "",
                    "", /// FIXME optional native amount
                    address(0),
                    underlyingToken_,
                    multiTx_ ? getContract(toChainId_, "MultiTxProcessor") : toDst_,
                    amount_,
                    liqBridgeToChainId_,
                    true,
                    false
                );
            } else {
                bridgeData = ILiFi.BridgeData(
                    bytes32("1"), /// request id
                    "",
                    "", /// FIXME optional native amount
                    address(0),
                    underlyingToken_,
                    multiTx_ ? getContract(toChainId_, "MultiTxProcessor") : toDst_,
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
            v.from,
            args.toChainId,
            args.multiTx,
            args.toDst,
            args.liquidityBridgeToChainId,
            args.amount
        );

        address liqRequestToken = args.externalToken != args.underlyingToken
            ? args.externalToken
            : args.underlyingToken;

        /// @dev permit2 calldata
        if (action == Actions.DepositPermit2) {
            v.permit = IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: IERC20(address(liqRequestToken)), amount: args.amount}),
                nonce: _randomUint256(),
                deadline: block.timestamp
            });
            v.sig = _signPermit(v.permit, v.from, userKeys[args.user], args.srcChainId); /// @dev from is either SuperFormRouter (xchain) or the form (direct deposit)

            v.permit2Calldata = abi.encode(v.permit.nonce, v.permit.deadline, v.sig);
        }

        /// @dev FIXME: currently only producing liqRequests for non-permit2 ERC20 transfers!!!
        /// @dev TODO: need to test native requests and permit2 requests
        v.liqReq = LiqRequest(
            args.liqBridge, /// @dev FIXME: hardcoded for now - but this should be a different bridge per type of transaction
            v.txData,
            liqRequestToken,
            args.amount,
            liqRequestToken == NATIVE_TOKEN ? args.amount : 0,
            v.permit2Calldata /// @dev will be empty if action == Actions.Deposit
        );

        vm.selectFork(FORKS[args.srcChainId]);

        if (liqRequestToken != NATIVE_TOKEN) {
            /// @dev - APPROVE transfer to SuperFormRouter (because of Socket)
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

        superFormData = SingleVaultSFData(args.superFormId, args.amount, args.maxSlippage, v.liqReq, "");
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

        vars.superRouter = contracts[CHAIN_0][bytes32(bytes("SuperFormRouter"))];
        vars.stateRegistry = contracts[CHAIN_0][bytes32(bytes("SuperRegistry"))];
        vars.superPositions = IERC1155s(ISuperRegistry(vars.stateRegistry).superPositions());
        vm.prank(users[args.user]);
        vars.superPositions.setApprovalForOne(vars.superRouter, args.superFormId, args.amount);

        vars.txData = _buildLiqBridgeTxData(
            args.liqBridge,
            args.underlyingToken,
            args.externalToken,
            args.toDst,
            args.srcChainId,
            false,
            users[args.user],
            args.liquidityBridgeSrcChainId,
            args.amount
        );

        vars.liqReq = LiqRequest(
            args.liqBridge, /// @dev FIXME: hardcoded for now
            vars.txData,
            args.underlyingToken,
            args.amount,
            0,
            ""
        );

        superFormData = SingleVaultSFData(args.superFormId, args.amount, args.maxSlippage, vars.liqReq, "");
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
        uint256 action
    )
        internal
        view
        returns (
            uint256[] memory targetSuperFormsMem,
            address[] memory underlyingSrcTokensMem,
            address[] memory vaultMocksMem
        )
    {
        TargetVaultsVars memory vars;
        vars.underlyingTokens = TARGET_UNDERLYINGS[chain1][action];
        vars.vaultIds = TARGET_VAULTS[chain1][action];
        vars.formKinds = TARGET_FORM_KINDS[chain1][action];

        vars.superFormIdsTemp = _superFormIds(vars.underlyingTokens, vars.vaultIds, vars.formKinds, chain1);

        vars.len = vars.superFormIdsTemp.length;

        if (vars.len == 0) revert LEN_VAULTS_ZERO();

        targetSuperFormsMem = new uint256[](vars.len);
        underlyingSrcTokensMem = new address[](vars.len);
        vaultMocksMem = new address[](vars.len);

        for (uint256 i = 0; i < vars.len; i++) {
            vars.underlyingToken = UNDERLYING_TOKENS[
                vars.underlyingTokens[i] // 1
            ];

            targetSuperFormsMem[i] = vars.superFormIdsTemp[i];
            underlyingSrcTokensMem[i] = getContract(chain0, vars.underlyingToken);
            vaultMocksMem[i] = getContract(chain1, VAULT_NAMES[vars.vaultIds[i]][vars.underlyingTokens[i]]);
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
            /// NOTE/FIXME: This should be allowed to revert (or not) at the core level.
            /// Can produce false positive. (What if we revert here, but not in the core)
            if (underlyingTokens_[i] > UNDERLYING_TOKENS.length) revert WRONG_UNDERLYING_ID();
            if (vaultIds_[i] > VAULT_KINDS.length) revert WRONG_UNDERLYING_ID();
            if (formKinds_[i] > FORM_BEACON_IDS.length) revert WRONG_FORMBEACON_ID();

            address superForm = getContract(
                chainId_,
                string.concat(
                    UNDERLYING_TOKENS[underlyingTokens_[i]],
                    VAULT_KINDS[vaultIds_[i]],
                    "SuperForm",
                    Strings.toString(FORM_BEACON_IDS[formKinds_[i]])
                )
            );

            superFormIds_[i] = _packSuperForm(superForm, FORM_BEACON_IDS[formKinds_[i]], chainId_);
        }

        return superFormIds_;
    }

    function _updateMultiVaultPayload(UpdateMultiVaultPayloadArgs memory args) internal returns (bool) {
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

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry"))).updateMultiVaultPayload(
                args.payloadId,
                finalAmounts
            );
        } else if (args.testType == TestType.RevertUpdateStateSlippage) {
            vm.prank(deployer);

            vm.expectRevert(args.revertError); /// @dev removed string here: come to this later

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry"))).updateMultiVaultPayload(
                args.payloadId,
                finalAmounts
            );

            return false;
        } else if (args.testType == TestType.RevertUpdateStateRBAC) {
            vm.prank(users[2]);
            bytes memory errorMsg = getAccessControlErrorMsg(users[2], args.revertRole);
            vm.expectRevert(errorMsg);

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry"))).updateMultiVaultPayload(
                args.payloadId,
                finalAmounts
            );

            return false;
        }

        vm.selectFork(initialFork);

        return true;
    }

    function _updateSingleVaultPayload(UpdateSingleVaultPayloadArgs memory args) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[args.targetChainId]);
        uint256 finalAmount;

        finalAmount = args.amount;
        if (args.slippage > 0) {
            finalAmount = (args.amount * (10000 - uint256(args.slippage))) / 10000;
        }

        if (args.testType == TestType.Pass || args.testType == TestType.RevertProcessPayload) {
            vm.prank(deployer);

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry"))).updateSingleVaultPayload(
                args.payloadId,
                finalAmount
            );
        } else if (args.testType == TestType.RevertUpdateStateSlippage) {
            vm.prank(deployer);

            vm.expectRevert(args.revertError); /// @dev removed string here: come to this later

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry"))).updateSingleVaultPayload(
                args.payloadId,
                finalAmount
            );

            return false;
        } else if (args.testType == TestType.RevertUpdateStateRBAC) {
            vm.prank(users[2]);
            bytes memory errorMsg = getAccessControlErrorMsg(users[2], args.revertRole);
            vm.expectRevert(errorMsg);

            CoreStateRegistry(payable(getContract(args.targetChainId, "CoreStateRegistry"))).updateSingleVaultPayload(
                args.payloadId,
                finalAmount
            );

            return false;
        }

        vm.selectFork(initialFork);

        return true;
    }

    function _processPayload(
        uint256 payloadId_,
        uint64 targetChainId_,
        TestType testType,
        bytes4 revertError
    ) internal returns (bool, bytes memory returnMessage) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[targetChainId_]);
        uint256 msgValue = 240 * 1e18; /// @FIXME: try more accurate estimations

        vm.prank(deployer);
        if (testType == TestType.Pass) {
            CoreStateRegistry(payable(getContract(targetChainId_, "CoreStateRegistry"))).processPayload{
                value: msgValue
            }(payloadId_, generateAckParams(AMBs));
        } else if (testType == TestType.RevertProcessPayload) {
            /// @dev WARNING the try catch silences the revert, therefore the only way to assert is via emit
            vm.expectEmit();
            // We emit the event we expect to see.
            emit FailedXChainDeposits(payloadId_);

            returnMessage = CoreStateRegistry(payable(getContract(targetChainId_, "CoreStateRegistry"))).processPayload{
                value: msgValue
            }(payloadId_, generateAckParams(AMBs));
            return (false, returnMessage);
        }

        vm.selectFork(initialFork);
        return (true, "");
    }

    function _processTwoStepPayload(
        uint256 payloadId_,
        uint64 targetChainId_,
        TestType testType,
        bytes4
    ) internal returns (bool) {
        uint256 initialFork = vm.activeFork();

        vm.selectFork(FORKS[targetChainId_]);
        uint256 msgValue = 240 * 1e18; /// @FIXME: try more accurate estimations

        // vm.prank(deployer);
        if (testType == TestType.Pass) {
            TwoStepsFormStateRegistry(payable(getContract(targetChainId_, "TwoStepsFormStateRegistry"))).processPayload{
                value: msgValue
            }(payloadId_, generateAckParams(AMBs));
        } else if (testType == TestType.RevertProcessPayload) {
            vm.expectRevert();

            TwoStepsFormStateRegistry(payable(getContract(targetChainId_, "TwoStepsFormStateRegistry"))).processPayload{
                value: msgValue
            }(payloadId_, generateAckParams(AMBs));

            return false;
        }

        vm.selectFork(initialFork);
        return true;
    }

    function _buildLiqBridgeTxDataMultiTx(
        uint8 liqBridgeKind_,
        address underlyingToken_,
        address from_,
        uint64 toChainId_,
        uint256 liqBridgeToChainId_,
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
                0, /// FIXME optional native amount
                underlyingToken_,
                abi.encode(getContract(toChainId_, "MultiTxProcessor"), FORKS[toChainId_])
            );

            /// @dev empty bridge request
            bridgeRequest = ISocketRegistry.BridgeRequest(
                0, /// id
                0, /// FIXME optional native amount
                address(0),
                abi.encode(getContract(toChainId_, "MultiTxProcessor"), FORKS[toChainId_])
            );

            userRequest = ISocketRegistry.UserRequest(
                getContract(toChainId_, "CoreStateRegistry"),
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
                underlyingToken_,
                underlyingToken_,
                amount_,
                abi.encode(from_, FORKS[toChainId_]),
                false // arbitrary
            );

            bridgeData = ILiFi.BridgeData(
                bytes32("1"), /// request id
                "",
                "", /// FIXME optional native amount
                address(0),
                underlyingToken_,
                getContract(toChainId_, "CoreStateRegistry"),
                amount_,
                liqBridgeToChainId_,
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
        uint256 liquidityBridgeDstChainId_,
        address underlyingToken_,
        uint256 amount_
    ) internal {
        uint256 initialFork = vm.activeFork();
        vm.selectFork(FORKS[targetChainId_]);

        bytes memory txData = _buildLiqBridgeTxDataMultiTx(
            liqBridgeKind_,
            underlyingToken_,
            getContract(targetChainId_, "MultiTxProcessor"),
            targetChainId_,
            liquidityBridgeDstChainId_,
            amount_
        );

        vm.prank(deployer);

        MultiTxProcessor(payable(getContract(targetChainId_, "MultiTxProcessor"))).processTx(
            bridgeIds[0],
            txData,
            underlyingToken_,
            amount_
        );
        vm.selectFork(initialFork);
    }

    function _batchProcessMultiTx(
        uint8[] memory liqBridgeKinds_,
        uint64 srcChainId_,
        uint64 targetChainId_,
        uint256 liquidityBridgeDstChainId_,
        address[] memory underlyingTokens_,
        uint256[] memory amounts_
    ) internal {
        uint256 initialFork = vm.activeFork();
        vm.selectFork(FORKS[targetChainId_]);

        bytes[] memory txDatas = new bytes[](underlyingTokens_.length);

        for (uint256 i = 0; i < underlyingTokens_.length; i++) {
            txDatas[i] = _buildLiqBridgeTxDataMultiTx(
                liqBridgeKinds_[i],
                underlyingTokens_[i],
                getContract(targetChainId_, "MultiTxProcessor"),
                targetChainId_,
                liquidityBridgeDstChainId_,
                amounts_[i]
            );
        }
        vm.prank(deployer);

        MultiTxProcessor(payable(getContract(targetChainId_, "MultiTxProcessor"))).batchProcessTx(
            bridgeIds[0],
            txDatas,
            underlyingTokens_,
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
                    1000000, /// (change to 2000000) @dev This is the gas value to send - value needs to be tested and probably be lower
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
        uint256[] memory amountsToAssert
    ) internal {
        address superRegistryAddress = getContract(CHAIN_0, "SuperRegistry");

        address superPositionsAddress = ISuperRegistry(superRegistryAddress).superPositions();

        IERC1155s superPositions = IERC1155s(superPositionsAddress);

        uint256 currentBalanceOfSp;

        for (uint256 i = 0; i < superFormIds.length; i++) {
            currentBalanceOfSp = superPositions.balanceOf(users[user], superFormIds[i]);

            assertEq(currentBalanceOfSp, amountsToAssert[i]);
        }
    }

    function _assertSingleVaultBalance(uint256 user, uint256 superFormId, uint256 amountToAssert) internal {
        address superRegistryAddress = getContract(CHAIN_0, "SuperRegistry");

        address superPositionsAddress = ISuperRegistry(superRegistryAddress).superPositions();

        IERC1155s superPositions = IERC1155s(superPositionsAddress);

        uint256 currentBalanceOfSp = superPositions.balanceOf(users[user], superFormId);
        console.log("currentBalanceOfSp", currentBalanceOfSp);
        console.log("amountToAssert", amountToAssert);

        assertEq(currentBalanceOfSp, amountToAssert);
    }

    function _spAmountsMultiBeforeActionOrAfterSuccessDeposit(
        MultiVaultsSFData memory multiSuperFormsData,
        bool assertWithSlippage,
        int256 slippage
    ) internal returns (uint256[] memory emptyAmount, uint256[] memory spAmountSummed, uint256 totalSpAmount) {
        uint256 lenSuperforms = multiSuperFormsData.superFormIds.length;
        emptyAmount = new uint256[](lenSuperforms);
        spAmountSummed = new uint256[](lenSuperforms);

        // create an array of amounts summing the amounts of the same superform ids
        (address[] memory superForms, , ) = _getSuperForms(multiSuperFormsData.superFormIds);
        uint256 finalAmount;

        for (uint256 i = 0; i < lenSuperforms; i++) {
            totalSpAmount += multiSuperFormsData.amounts[i];
            for (uint256 j = 0; j < lenSuperforms; j++) {
                if (multiSuperFormsData.superFormIds[i] == multiSuperFormsData.superFormIds[j]) {
                    finalAmount = multiSuperFormsData.amounts[j];
                    if (assertWithSlippage && slippage != 0) {
                        finalAmount = (multiSuperFormsData.amounts[j] * (10000 - uint256(slippage))) / 10000;
                    }
                    spAmountSummed[i] += finalAmount;
                }
            }
            spAmountSummed[i] = IBaseForm(superForms[i]).previewDepositTo(spAmountSummed[i]);
        }
    }

    function _spAmountsMultiAfterWithdraw(
        MultiVaultsSFData memory multiSuperFormsData,
        uint256 user,
        uint256[] memory currentSPBeforeWithdaw
    ) internal returns (uint256[] memory spAmountFinal) {
        uint256 lenSuperforms = multiSuperFormsData.superFormIds.length;
        spAmountFinal = new uint256[](lenSuperforms);

        // create an array of amounts summing the amounts of the same superform ids
        (address[] memory superForms, , ) = _getSuperForms(multiSuperFormsData.superFormIds);

        for (uint256 i = 0; i < lenSuperforms; i++) {
            spAmountFinal[i] = currentSPBeforeWithdaw[i];
            for (uint256 j = 0; j < lenSuperforms; j++) {
                if (multiSuperFormsData.superFormIds[i] == multiSuperFormsData.superFormIds[j]) {
                    spAmountFinal[i] -= multiSuperFormsData.amounts[j];
                }
            }
        }
    }

    function _spAmountsMultiAfterFailedWithdraw(
        MultiVaultsSFData memory multiSuperFormsData,
        uint256 user,
        uint256[] memory currentSPBeforeWithdaw,
        uint256[] memory failedSPAmounts
    ) internal returns (uint256[] memory spAmountFinal) {
        uint256 lenSuperforms = multiSuperFormsData.superFormIds.length;
        spAmountFinal = new uint256[](lenSuperforms);

        // create an array of amounts summing the amounts of the same superform ids
        (address[] memory superForms, , ) = _getSuperForms(multiSuperFormsData.superFormIds);

        for (uint256 i = 0; i < lenSuperforms; i++) {
            spAmountFinal[i] = currentSPBeforeWithdaw[i];
            for (uint256 j = 0; j < lenSuperforms; j++) {
                if (
                    multiSuperFormsData.superFormIds[i] == multiSuperFormsData.superFormIds[j] &&
                    failedSPAmounts[i] == 0
                ) {
                    spAmountFinal[i] -= multiSuperFormsData.amounts[j];
                }
            }
        }
    }

    function _assertBeforeAction(
        TestAction memory action,
        MultiVaultsSFData[] memory multiSuperFormsData,
        SingleVaultSFData[] memory singleSuperFormsData,
        StagesLocalVars memory vars
    )
        internal
        returns (
            uint256[] memory emptyAmount,
            uint256[] memory spAmountSummed,
            uint256 spAmountBeforeWithdraw,
            uint256 inputBalanceBefore
        )
    {
        address token;
        if (action.multiVaults) {
            token = multiSuperFormsData[0].liqRequests[0].token;
            inputBalanceBefore = token != NATIVE_TOKEN
                ? IERC20(token).balanceOf(users[action.user])
                : users[action.user].balance;

            for (uint256 i = 0; i < vars.nDestinations; i++) {
                (emptyAmount, spAmountSummed, ) = _spAmountsMultiBeforeActionOrAfterSuccessDeposit(
                    multiSuperFormsData[i],
                    false,
                    0
                );
                _assertMultiVaultBalance(
                    action.user,
                    multiSuperFormsData[i].superFormIds,
                    action.action == Actions.Withdraw ? spAmountSummed : emptyAmount
                );
            }
            console.log("Asserted b4 action multi");
        } else {
            token = singleSuperFormsData[0].liqRequest.token;

            inputBalanceBefore = token != NATIVE_TOKEN
                ? IERC20(token).balanceOf(users[action.user])
                : users[action.user].balance;

            for (uint256 i = 0; i < vars.nDestinations; i++) {
                (address superForm, , ) = _getSuperForm(singleSuperFormsData[i].superFormId);
                spAmountBeforeWithdraw = IBaseForm(superForm).previewDepositTo(singleSuperFormsData[i].amount);
                _assertSingleVaultBalance(
                    action.user,
                    singleSuperFormsData[i].superFormId,
                    action.action == Actions.Withdraw ? spAmountBeforeWithdraw : 0
                );
            }
            console.log("Asserted b4 action");
        }
    }

    function _assertAfterDeposit(
        TestAction memory action,
        MultiVaultsSFData[] memory multiSuperFormsData,
        SingleVaultSFData[] memory singleSuperFormsData,
        StagesLocalVars memory vars,
        uint256 inputBalanceBefore
    ) internal {
        vm.selectFork(FORKS[CHAIN_0]);

        uint256[] memory spAmountSummed;
        uint256 totalSpAmount;
        uint256 totalSpAmountAllDestinations;
        address token;
        for (uint256 i = 0; i < vars.nDestinations; i++) {
            if (action.multiVaults) {
                (, spAmountSummed, totalSpAmount) = _spAmountsMultiBeforeActionOrAfterSuccessDeposit(
                    multiSuperFormsData[i],
                    true,
                    action.slippage
                );
                totalSpAmountAllDestinations += totalSpAmount;

                token = multiSuperFormsData[0].liqRequests[0].token;

                /// assert spToken Balance
                _assertMultiVaultBalance(action.user, multiSuperFormsData[i].superFormIds, spAmountSummed);
            } else {
                totalSpAmountAllDestinations += singleSuperFormsData[i].amount;

                token = singleSuperFormsData[0].liqRequest.token;

                uint256 finalAmount = (singleSuperFormsData[i].amount * (10000 - uint256(action.slippage))) / 10000;

                /// assert spToken Balance
                _assertSingleVaultBalance(action.user, singleSuperFormsData[i].superFormId, finalAmount);
            }
        }
        uint256 msgValue = token != NATIVE_TOKEN ? 0 : action.msgValue;
        /*
        if (token == NATIVE_TOKEN) {
            console.log("balance now", users[action.user].balance);
            console.log("balance Before action", inputBalanceBefore);
            console.log("totalSpAmountAllDestinations", totalSpAmountAllDestinations);
            console.log("msgValue", msgValue);
            console.log("balance Before action - now", inputBalanceBefore - users[action.user].balance);
            console.log("msg.value - remainder", msgValue - (inputBalanceBefore - users[action.user].balance));
        }
        /// @dev assert user input token balance
        /// @notice TODO commented for now until we have precise gas estimation, otherwise it is not possible to assert conclusively


        assertEq(
            token != NATIVE_TOKEN ? IERC20(token).balanceOf(users[action.user]) : users[action.user].balance,
            inputBalanceBefore - totalSpAmountAllDestinations - msgValue
        );
        */
        console.log("Asserted after deposit");
    }

    function _assertAfterWithdraw(
        TestAction memory action,
        MultiVaultsSFData[] memory multiSuperFormsData,
        SingleVaultSFData[] memory singleSuperFormsData,
        StagesLocalVars memory vars,
        uint256[] memory spAmountsBeforeWithdraw,
        uint256 spAmountBeforeWithdraw
    ) internal {
        vm.selectFork(FORKS[CHAIN_0]);
        uint256[] memory spAmountFinal;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            if (action.multiVaults) {
                spAmountFinal = _spAmountsMultiAfterWithdraw(
                    multiSuperFormsData[i],
                    action.user,
                    spAmountsBeforeWithdraw
                );

                _assertMultiVaultBalance(action.user, multiSuperFormsData[i].superFormIds, spAmountFinal);
            } else {
                /// @dev this assertion assumes the withdraw is happening on the same superformId as the previous deposit
                _assertSingleVaultBalance(
                    action.user,
                    singleSuperFormsData[i].superFormId,
                    spAmountBeforeWithdraw - singleSuperFormsData[i].amount
                );
            }
        }
        console.log("Asserted after withdraw");
    }

    function _assertAfterFailedWithdraw(
        TestAction memory action,
        MultiVaultsSFData[] memory multiSuperFormsData,
        SingleVaultSFData[] memory singleSuperFormsData,
        StagesLocalVars memory vars,
        uint256[] memory spAmountsBeforeWithdraw,
        uint256 spAmountBeforeWithdraw,
        bytes memory returnMessage
    ) internal {
        AMBMessage memory message = abi.decode(returnMessage, (AMBMessage));
        ReturnMultiData memory returnMultiData;
        if (action.multiVaults) {
            returnMultiData = abi.decode(message.params, (ReturnMultiData));
        }

        vm.selectFork(FORKS[CHAIN_0]);
        uint256[] memory spAmountFinal;

        for (uint256 i = 0; i < vars.nDestinations; i++) {
            if (action.multiVaults) {
                spAmountFinal = _spAmountsMultiAfterFailedWithdraw(
                    multiSuperFormsData[i],
                    action.user,
                    spAmountsBeforeWithdraw,
                    returnMultiData.amounts
                );

                _assertMultiVaultBalance(action.user, multiSuperFormsData[i].superFormIds, spAmountFinal);
            } else {
                /// @dev this assertion assumes the withdraw is happening on the same superformId as the previous deposit
                _assertSingleVaultBalance(action.user, singleSuperFormsData[i].superFormId, spAmountBeforeWithdraw);
            }
        }
        console.log("Asserted after withdraw");
    }
}
