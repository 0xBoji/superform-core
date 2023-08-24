// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.19;

import { Error } from "src/utils/Error.sol";
import "test/utils/ProtocolActions.sol";

contract CoreStateRegistryTest is ProtocolActions {
    uint64 internal chainId = ETH;

    function setUp() public override {
        super.setUp();
    }

    /// @dev test processPayload reverts with insufficient collateral
    function test_processPayloadRevertingWithoutCollateral() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulSingleDeposit(ambIds);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        vm.prank(deployer);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18 - 1;
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateDepositPayload(1, amounts);

        uint256[] memory gasPerAMB = new uint256[](1);
        gasPerAMB[0] = 5 ether;

        vm.prank(getContract(AVAX, "CoreStateRegistry"));
        MockERC20(getContract(AVAX, "USDT")).transfer(deployer, 1e18);

        vm.prank(deployer);
        vm.expectRevert(Error.BRIDGE_TOKENS_PENDING.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).processPayload{ value: 5 ether }(1);
    }

    /// @dev test processPayload reverts with insufficient collateral for multi vault case
    function test_processPayloadRevertingWithoutCollateralMultiVault() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulMultiDeposit(ambIds);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        uint256[] memory finalAmounts = new uint256[](2);
        finalAmounts[0] = 419;
        finalAmounts[1] = 419;

        vm.prank(deployer);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateDepositPayload(1, finalAmounts);

        uint256[] memory gasPerAMB = new uint256[](1);
        gasPerAMB[0] = 5 ether;

        vm.prank(getContract(AVAX, "CoreStateRegistry"));
        MockERC20(getContract(AVAX, "USDT")).transfer(deployer, 840);

        vm.prank(deployer);
        vm.expectRevert(Error.BRIDGE_TOKENS_PENDING.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).processPayload{ value: 5 ether }(1);
    }

    /// @dev test processPayload with just 1 AMB
    function test_processPayloadWithoutReachingQuorum() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulSingleDeposit(ambIds);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        vm.expectRevert(Error.QUORUM_NOT_REACHED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).processPayload(1);
    }

    /// @dev test processPayload without updating deposit payload
    function test_processPayloadWithoutUpdating() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulSingleDeposit(ambIds);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        vm.prank(deployer);
        vm.expectRevert(Error.PAYLOAD_NOT_UPDATED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).processPayload(1);
    }

    /// @dev test processPayload without updating deposit payload
    function test_processPayloadForAlreadyProcessedPayload() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulSingleDeposit(ambIds);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        vm.prank(deployer);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18 - 1;
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateDepositPayload(1, amounts);

        uint256[] memory gasPerAMB = new uint256[](1);
        gasPerAMB[0] = 5 ether;

        vm.prank(deployer);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).processPayload{ value: 5 ether }(1);

        vm.prank(deployer);
        vm.expectRevert(Error.PAYLOAD_ALREADY_PROCESSED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).processPayload{ value: 5 ether }(1);
    }

    /// @dev test processPayload without updating multi vault deposit payload
    function test_processPayloadWithoutUpdatingMultiVaultDeposit() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulMultiDeposit(ambIds);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        vm.prank(deployer);
        vm.expectRevert(Error.PAYLOAD_NOT_UPDATED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).processPayload(1);
    }

    /// @dev test all revert cases with single vault deposit payload update
    function test_updatePayloadSingleVaultDepositRevertCases() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulSingleDeposit(ambIds);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18 - 1;

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        vm.expectRevert(Error.QUORUM_NOT_REACHED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateDepositPayload(1, amounts);
    }

    /// @dev test all revert cases with single vault withdraw payload update
    function test_updatePayloadSingleVaultWithdrawQuorumCheck() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulSingleWithdrawal(ambIds, 0);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);

        bytes[] memory txData = new bytes[](1);
        txData[0] = bytes("");
        vm.expectRevert(Error.QUORUM_NOT_REACHED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateWithdrawPayload(1, txData);
    }

    function test_updatePayloadSingleVaultWithdrawUpdateValidator() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        /// beacon id 1 shouldn't be upgradeable.
        _successfulSingleWithdrawal(ambIds, 1);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        vm.prank(deployer);
        bytes[] memory txData = new bytes[](1);
        txData[0] = bytes("");
        vm.expectRevert(Error.INVALID_PAYLOAD_UPDATE_REQUEST.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateWithdrawPayload(1, txData);
    }

    /// @dev test all revert cases with multi vault withdraw payload update
    function test_updatePayloadMultiVaultWithdrawRevertCases() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulMultiWithdrawal(ambIds);

        bytes[] memory txData = new bytes[](1);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        vm.expectRevert(Error.QUORUM_NOT_REACHED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateWithdrawPayload(1, txData);

        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        vm.prank(deployer);
        vm.expectRevert(Error.DIFFERENT_PAYLOAD_UPDATE_TX_DATA_LENGTH.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateWithdrawPayload(1, txData);
    }

    /// @dev test all revert cases with multi vault deposit payload update
    function test_updatePayloadMultiVaultDepositRevertCases() public {
        uint8[] memory ambIds = new uint8[](1);
        ambIds[0] = 1;

        _successfulMultiDeposit(ambIds);

        uint256[] memory finalAmounts = new uint256[](1);

        vm.selectFork(FORKS[AVAX]);
        vm.prank(deployer);
        vm.expectRevert(Error.QUORUM_NOT_REACHED.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateDepositPayload(1, finalAmounts);

        vm.prank(deployer);
        SuperRegistry(getContract(AVAX, "SuperRegistry")).setRequiredMessagingQuorum(ETH, 0);

        vm.prank(deployer);
        vm.expectRevert(Error.DIFFERENT_PAYLOAD_UPDATE_AMOUNTS_LENGTH.selector);
        CoreStateRegistry(payable(getContract(AVAX, "CoreStateRegistry"))).updateDepositPayload(1, finalAmounts);
    }

    /*///////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _successfulSingleDeposit(uint8[] memory ambIds) internal {
        /// scenario: user deposits with his own collateral and has approved enough tokens
        vm.selectFork(FORKS[ETH]);
        vm.startPrank(deployer);

        address superform =
            getContract(AVAX, string.concat("USDT", "VaultMock", "Superform", Strings.toString(FORM_BEACON_IDS[0])));

        uint256 superformId = DataLib.packSuperform(superform, FORM_BEACON_IDS[0], AVAX);

        address superformRouter = getContract(ETH, "SuperformRouter");

        SingleVaultSFData memory data = SingleVaultSFData(
            superformId,
            1e18,
            100,
            LiqRequest(
                1,
                _buildLiqBridgeTxData(
                    1,
                    getContract(ETH, "USDT"),
                    getContract(ETH, "USDT"),
                    getContract(AVAX, "USDT"),
                    superformRouter,
                    AVAX,
                    false,
                    getContract(AVAX, "CoreStateRegistry"),
                    uint256(AVAX),
                    1e18,
                    false
                ),
                getContract(ETH, "USDT"),
                1e18,
                0,
                bytes("")
            ),
            bytes("")
        );
        /// @dev approves before call
        MockERC20(getContract(ETH, "USDT")).approve(superformRouter, 1e18);

        vm.recordLogs();
        SuperformRouter(payable(superformRouter)).singleXChainSingleVaultDeposit{ value: 2 ether }(
            SingleXChainSingleVaultStateReq(ambIds, AVAX, data)
        );
        vm.stopPrank();

        /// @dev mocks the cross-chain payload delivery
        LayerZeroHelper(getContract(ETH, "LayerZeroHelper")).helpWithEstimates(
            LZ_ENDPOINTS[AVAX],
            5_000_000,
            /// note: using some max limit
            FORKS[AVAX],
            vm.getRecordedLogs()
        );
    }

    function _successfulSingleWithdrawal(uint8[] memory ambIds, uint256 beaconId) internal {
        vm.selectFork(FORKS[ETH]);

        address superform = beaconId == 1
            ? getContract(
                AVAX, string.concat("USDT", "ERC4626TimelockMock", "Superform", Strings.toString(FORM_BEACON_IDS[beaconId]))
            )
            : getContract(
                AVAX, string.concat("USDT", "VaultMock", "Superform", Strings.toString(FORM_BEACON_IDS[beaconId]))
            );

        uint256 superformId = DataLib.packSuperform(superform, FORM_BEACON_IDS[beaconId], AVAX);
        address superformRouter = getContract(ETH, "SuperformRouter");

        vm.prank(superformRouter);
        SuperPositions(getContract(ETH, "SuperPositions")).mintSingleSP(deployer, superformId, 1e18);

        SingleVaultSFData memory data = SingleVaultSFData(
            superformId, 1e18, 100, LiqRequest(1, bytes(""), getContract(ETH, "USDT"), 1e18, 0, bytes("")), bytes("")
        );

        vm.recordLogs();

        vm.prank(deployer);
        SuperformRouter(payable(superformRouter)).singleXChainSingleVaultWithdraw{ value: 2 ether }(
            SingleXChainSingleVaultStateReq(ambIds, AVAX, data)
        );

        /// @dev mocks the cross-chain payload delivery
        LayerZeroHelper(getContract(ETH, "LayerZeroHelper")).helpWithEstimates(
            LZ_ENDPOINTS[AVAX],
            5_000_000,
            /// note: using some max limit
            FORKS[AVAX],
            vm.getRecordedLogs()
        );
    }

    function _successfulMultiDeposit(uint8[] memory ambIds) internal {
        /// scenario: user deposits with his own collateral and has approved enough tokens
        vm.selectFork(FORKS[ETH]);
        vm.startPrank(deployer);

        address superform =
            getContract(AVAX, string.concat("USDT", "VaultMock", "Superform", Strings.toString(FORM_BEACON_IDS[0])));

        uint256 superformId = DataLib.packSuperform(superform, FORM_BEACON_IDS[0], AVAX);

        address superformRouter = getContract(ETH, "SuperformRouter");

        uint256[] memory superformIds = new uint256[](2);
        superformIds[0] = superformId;
        superformIds[1] = superformId;

        uint256[] memory uint256MemArr = new uint256[](2);
        uint256MemArr[0] = 420;
        uint256MemArr[1] = 420;

        LiqRequest[] memory liqReqArr = new LiqRequest[](2);
        liqReqArr[0] = LiqRequest(
            1,
            _buildLiqBridgeTxData(
                1,
                getContract(ETH, "USDT"),
                getContract(ETH, "USDT"),
                getContract(AVAX, "USDT"),
                superformRouter,
                AVAX,
                false,
                getContract(AVAX, "CoreStateRegistry"),
                uint256(AVAX),
                420,
                false
            ),
            getContract(ETH, "USDT"),
            420,
            0,
            bytes("")
        );
        liqReqArr[1] = liqReqArr[0];

        MultiVaultSFData memory data =
            MultiVaultSFData(superformIds, uint256MemArr, uint256MemArr, liqReqArr, bytes(""));
        /// @dev approves before call
        MockERC20(getContract(ETH, "USDT")).approve(superformRouter, 1e18);

        vm.recordLogs();
        SuperformRouter(payable(superformRouter)).singleXChainMultiVaultDeposit{ value: 2 ether }(
            SingleXChainMultiVaultStateReq(ambIds, AVAX, data)
        );
        vm.stopPrank();

        /// @dev mocks the cross-chain payload delivery
        LayerZeroHelper(getContract(ETH, "LayerZeroHelper")).helpWithEstimates(
            LZ_ENDPOINTS[AVAX],
            5_000_000,
            /// note: using some max limit
            FORKS[AVAX],
            vm.getRecordedLogs()
        );
    }

    function _successfulMultiWithdrawal(uint8[] memory ambIds) internal {
        vm.selectFork(FORKS[ETH]);

        address superform = getContract(
            AVAX, string.concat("USDT", "ERC4626TimelockMock", "Superform", Strings.toString(FORM_BEACON_IDS[0]))
        );

        uint256 superformId = DataLib.packSuperform(superform, FORM_BEACON_IDS[0], AVAX);
        address superformRouter = getContract(ETH, "SuperformRouter");

        vm.prank(superformRouter);
        SuperPositions(getContract(ETH, "SuperPositions")).mintSingleSP(deployer, superformId, 2e18);

        uint256[] memory superformIds = new uint256[](2);
        superformIds[0] = superformId;
        superformIds[1] = superformId;

        uint256[] memory amountArr = new uint256[](2);
        amountArr[0] = 1e18;
        amountArr[1] = 1e18;

        LiqRequest[] memory liqReqArr = new LiqRequest[](2);
        liqReqArr[0] = LiqRequest(1, bytes(""), getContract(AVAX, "USDT"), 1e18, 0, bytes(""));
        liqReqArr[1] = liqReqArr[0];

        MultiVaultSFData memory data = MultiVaultSFData(superformIds, amountArr, new uint256[](2), liqReqArr, bytes(""));

        vm.recordLogs();
        vm.prank(deployer);
        SuperformRouter(payable(superformRouter)).singleXChainMultiVaultWithdraw{ value: 2 ether }(
            SingleXChainMultiVaultStateReq(ambIds, AVAX, data)
        );

        /// @dev mocks the cross-chain payload delivery
        LayerZeroHelper(getContract(ETH, "LayerZeroHelper")).helpWithEstimates(
            LZ_ENDPOINTS[AVAX],
            50_000_000,
            /// note: using some max limit
            FORKS[AVAX],
            vm.getRecordedLogs()
        );
    }
}
