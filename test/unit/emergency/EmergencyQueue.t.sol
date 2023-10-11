// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.19;

import "test/utils/ProtocolActions.sol";

contract EmergencyQueueTest is ProtocolActions {
    /// our intended user who is a nice person
    address mrperfect;

    /// our users who is a friend of nice person that wants the refunds
    address mrimperfect;

    function setUp() public override {
        super.setUp();

        mrperfect = vm.addr(421);
        mrimperfect = vm.addr(420);
    }

    function test_emergencyQueueAddition() public {
        /// user deposits successfully to a form
        _successfulDeposit();

        /// pause the form
        _pauseForm();

        /// try to withdraw after pause (mrperfect panicks)
        _withdrawAfterPause();
    }

    function test_emergencyQueueProcessing() public {
        /// user deposits successfully to a form
        _successfulDeposit();

        /// now pause the form and try to withdraw
        _pauseForm();

        /// try to withdraw after pause (mrperfect panicks)
        _withdrawAfterPause();

        /// processing the queued withdrawal and assert
        vm.selectFork(FORKS[ETH]);

        /// @dev deployer has emergency admin role
        address emergencyQueue = getContract(ETH, "EmergencyQueue");

        address superform = getContract(
            ETH, string.concat("DAI", "VaultMock", "Superform", Strings.toString(FORM_IMPLEMENTATION_IDS[0]))
        );

        uint256 balanceBefore = MockERC20(IBaseForm(superform).getVaultAddress()).balanceOf(mrperfect);

        assertFalse(EmergencyQueue(emergencyQueue).queuedWithdrawalStatus(1));
        vm.prank(deployer);
        EmergencyQueue(emergencyQueue).executeQueuedWithdrawal(1);
        assertTrue(EmergencyQueue(emergencyQueue).queuedWithdrawalStatus(1));

        uint256 balanceAfter = MockERC20(IBaseForm(superform).getVaultAddress()).balanceOf(mrperfect);
        assertEq(balanceBefore + 1e18, balanceAfter);
    }

    function test_emergencyQueueProcessingXChain() public {
        /// user deposits successfully to a form
        _successfulDepositXChain();

        /// now pause the form and try to withdraw
        _pauseFormXChain();

        /// try to withdraw after pause (mrperfect panicks)
        _withdrawAfterPauseXChain();

        /// processing the queued withdrawal and assert
        vm.selectFork(FORKS[ARBI]);

        /// @dev deployer has emergency admin role
        address emergencyQueue = getContract(ARBI, "EmergencyQueue");

        address superform = getContract(
            ARBI, string.concat("DAI", "VaultMock", "Superform", Strings.toString(FORM_IMPLEMENTATION_IDS[0]))
        );

        uint256 balanceBefore = MockERC20(IBaseForm(superform).getVaultAddress()).balanceOf(mrimperfect);

        assertFalse(EmergencyQueue(emergencyQueue).queuedWithdrawalStatus(1));
        vm.prank(deployer);
        EmergencyQueue(emergencyQueue).executeQueuedWithdrawal(1);
        assertTrue(EmergencyQueue(emergencyQueue).queuedWithdrawalStatus(1));

        uint256 balanceAfter = MockERC20(IBaseForm(superform).getVaultAddress()).balanceOf(mrimperfect);
        assertEq(balanceBefore + 1e18, balanceAfter);
    }

    function _withdrawAfterPause() internal {
        vm.selectFork(FORKS[ETH]);
        address payable router = payable(getContract(ETH, "SuperformRouter"));
        address superPositions = getContract(ETH, "SuperPositions");

        SingleVaultSFData memory data = SingleVaultSFData(
            _getTestSuperformId(),
            1e18,
            100,
            false,
            LiqRequest(1, "", getContract(ETH, "DAI"), ETH, 0),
            "",
            mrperfect,
            ""
        );

        SingleDirectSingleVaultStateReq memory req = SingleDirectSingleVaultStateReq(data);

        vm.prank(mrperfect);
        SuperPositions(superPositions).increaseAllowance(router, _getTestSuperformId(), 100e18);

        vm.prank(mrperfect);
        SuperformRouter(router).singleDirectSingleVaultWithdraw(req);

        assertEq(EmergencyQueue(getContract(ETH, "EmergencyQueue")).queueCounter(), 1);
    }

    function _withdrawAfterPauseXChain() internal {
        /// scenario: user deposits with his own collateral and has approved enough tokens
        vm.selectFork(FORKS[ETH]);

        address superformRouter = getContract(ETH, "SuperformRouter");

        address superform = getContract(
            ARBI, string.concat("DAI", "VaultMock", "Superform", Strings.toString(FORM_IMPLEMENTATION_IDS[0]))
        );

        uint256 superformId = DataLib.packSuperform(superform, FORM_IMPLEMENTATION_IDS[0], ARBI);

        SingleVaultSFData memory data = SingleVaultSFData(
            superformId, 1e18, 1000, false, LiqRequest(1, "", address(0), ETH, 0), "", mrimperfect, ""
        );

        uint8[] memory ambIds = new uint8[](2);
        ambIds[0] = 1;
        ambIds[1] = 2;

        SingleXChainSingleVaultStateReq memory req = SingleXChainSingleVaultStateReq(ambIds, ARBI, data);

        /// @dev approves before call
        vm.prank(mrperfect);
        SuperPositions(getContract(ETH, "SuperPositions")).increaseAllowance(superformRouter, superformId, 2e18);
        vm.recordLogs();

        vm.prank(mrperfect);
        vm.deal(mrperfect, 2 ether);
        SuperformRouter(payable(superformRouter)).singleXChainSingleVaultWithdraw{ value: 2 ether }(req);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        /// @dev simulate cross-chain payload delivery
        LayerZeroHelper(getContract(ETH, "LayerZeroHelper")).helpWithEstimates(
            LZ_ENDPOINTS[ARBI],
            500_000,
            /// note: using some max limit
            FORKS[ARBI],
            logs
        );

        HyperlaneHelper(getContract(ETH, "HyperlaneHelper")).help(
            address(HyperlaneMailbox), address(HyperlaneMailbox), FORKS[ARBI], logs
        );

        /// @dev update and process the payload on ARBI
        vm.selectFork(FORKS[ARBI]);

        vm.prank(deployer);
        CoreStateRegistry(payable(getContract(ARBI, "CoreStateRegistry"))).processPayload(2);

        /// @dev assert emergency withdrawal added to queue on ARBI
        assertEq(EmergencyQueue(getContract(ARBI, "EmergencyQueue")).queueCounter(), 1);
    }

    function _pauseForm() internal {
        vm.prank(deployer);
        SuperformFactory(getContract(ETH, "SuperformFactory")).changeFormImplementationPauseStatus(
            FORM_IMPLEMENTATION_IDS[0], true, bytes("")
        );
    }

    function _pauseFormXChain() internal {
        vm.selectFork(FORKS[ARBI]);
        vm.prank(deployer);
        SuperformFactory(getContract(ARBI, "SuperformFactory")).changeFormImplementationPauseStatus(
            FORM_IMPLEMENTATION_IDS[0], true, bytes("")
        );
    }

    function _successfulDeposit() internal {
        vm.selectFork(FORKS[ETH]);
        address dai = getContract(ETH, "DAI");

        vm.prank(deployer);
        MockERC20(dai).transfer(mrperfect, 2e18);

        vm.startPrank(mrperfect);

        address superformRouter = getContract(ETH, "SuperformRouter");
        uint256 superformId = _getTestSuperformId();

        SingleVaultSFData memory data =
            SingleVaultSFData(superformId, 2e18, 100, false, LiqRequest(1, "", dai, 1, 0), "", mrperfect, "");

        SingleDirectSingleVaultStateReq memory req = SingleDirectSingleVaultStateReq(data);

        /// @dev approves before call
        MockERC20(dai).approve(address(superformRouter), 2e18);

        SuperformRouter(payable(superformRouter)).singleDirectSingleVaultDeposit(req);
        vm.stopPrank();
    }

    function _successfulDepositXChain() internal {
        /// scenario: user deposits with his own collateral and has approved enough tokens
        vm.selectFork(FORKS[ETH]);

        vm.prank(deployer);
        MockERC20(getContract(ETH, "DAI")).transfer(mrperfect, 2e18);

        address superformRouter = getContract(ETH, "SuperformRouter");

        address superform = getContract(
            ARBI, string.concat("DAI", "VaultMock", "Superform", Strings.toString(FORM_IMPLEMENTATION_IDS[0]))
        );

        uint256 superformId = DataLib.packSuperform(superform, FORM_IMPLEMENTATION_IDS[0], ARBI);

        LiqBridgeTxDataArgs memory liqBridgeTxDataArgs = LiqBridgeTxDataArgs(
            1,
            getContract(ETH, "DAI"),
            getContract(ETH, "DAI"),
            getContract(ARBI, "DAI"),
            superformRouter,
            ETH,
            ARBI,
            ARBI,
            false,
            getContract(ARBI, "CoreStateRegistry"),
            uint256(ARBI),
            2e18,
            2e18,
            false,
            /// @dev placeholder value, not used
            0
        );

        SingleVaultSFData memory data = SingleVaultSFData(
            superformId,
            2e18,
            1000,
            false,
            LiqRequest(1, _buildLiqBridgeTxData(liqBridgeTxDataArgs, false), getContract(ETH, "DAI"), ARBI, 0),
            "",
            mrimperfect,
            ""
        );

        uint8[] memory ambIds = new uint8[](2);
        ambIds[0] = 1;
        ambIds[1] = 2;

        SingleXChainSingleVaultStateReq memory req = SingleXChainSingleVaultStateReq(ambIds, ARBI, data);

        /// @dev approves before call
        vm.prank(mrperfect);
        MockERC20(getContract(ETH, "DAI")).approve(superformRouter, 2e18);
        vm.recordLogs();

        vm.prank(mrperfect);
        vm.deal(mrperfect, 2 ether);
        SuperformRouter(payable(superformRouter)).singleXChainSingleVaultDeposit{ value: 2 ether }(req);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        /// @dev simulate cross-chain payload delivery
        LayerZeroHelper(getContract(ETH, "LayerZeroHelper")).helpWithEstimates(
            LZ_ENDPOINTS[ARBI],
            500_000,
            /// note: using some max limit
            FORKS[ARBI],
            logs
        );

        HyperlaneHelper(getContract(ETH, "HyperlaneHelper")).help(
            address(HyperlaneMailbox), address(HyperlaneMailbox), FORKS[ARBI], logs
        );

        /// @dev update and process the payload on ARBI
        vm.selectFork(FORKS[ARBI]);
        vm.prank(deployer);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2e18;

        CoreStateRegistry(payable(getContract(ARBI, "CoreStateRegistry"))).updateDepositPayload(1, amounts);

        vm.recordLogs();
        vm.prank(deployer);
        CoreStateRegistry(payable(getContract(ARBI, "CoreStateRegistry"))).processPayload{ value: 1 ether }(1);

        logs = vm.getRecordedLogs();

        /// @dev simulate cross-chain payload delivery
        LayerZeroHelper(getContract(ARBI, "LayerZeroHelper")).helpWithEstimates(
            LZ_ENDPOINTS[ETH],
            500_000,
            /// note: using some max limit
            FORKS[ETH],
            logs
        );

        HyperlaneHelper(getContract(ARBI, "HyperlaneHelper")).help(
            address(HyperlaneMailbox), address(HyperlaneMailbox), FORKS[ETH], logs
        );

        /// @dev mint super positions on source chain
        vm.selectFork(FORKS[ETH]);
        vm.prank(deployer);
        CoreStateRegistry(payable(getContract(ETH, "CoreStateRegistry"))).processPayload(1);
    }

    function _getTestSuperformId() internal view returns (uint256) {
        address superform = getContract(
            ETH, string.concat("DAI", "VaultMock", "Superform", Strings.toString(FORM_IMPLEMENTATION_IDS[0]))
        );

        return DataLib.packSuperform(superform, FORM_IMPLEMENTATION_IDS[0], ETH);
    }

    function _getTestSuperformIdXChain() internal view returns (uint256) {
        address superform = getContract(
            ARBI, string.concat("DAI", "VaultMock", "Superform", Strings.toString(FORM_IMPLEMENTATION_IDS[0]))
        );

        return DataLib.packSuperform(superform, FORM_IMPLEMENTATION_IDS[0], ARBI);
    }
}
