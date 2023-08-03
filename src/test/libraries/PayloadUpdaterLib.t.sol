// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import "forge-std/Test.sol";

import {Error} from "../../utils/Error.sol";
import {DataLib} from "../../libraries/DataLib.sol";
import {PayloadUpdaterLib} from "../../libraries/PayloadUpdaterLib.sol";
import "../../types/DataTypes.sol";

contract PayloadUpdaterLibUser {
    function validateSlippage(uint256 a, uint256 b, uint256 c) external pure {
        PayloadUpdaterLib.validateSlippage(a, b, c);
    }

    function validatePayloadUpdate(uint256 a, PayloadState b, uint8 c) external pure {
        PayloadUpdaterLib.validatePayloadUpdate(a, b, c);
    }
}

contract PayloadUpdaterLibTest is Test {
    PayloadUpdaterLibUser payloadUpdateLib;

    function setUp() public {
        payloadUpdateLib = new PayloadUpdaterLibUser();
    }

    function test_validateSlippage() public {
        /// @dev payload updater goes rogue and tries to update new amount > max amount
        uint256 newAmount = 100;
        uint256 newAmountBeyondSlippage = 97;

        uint256 maxAmount = 99;
        uint256 slippage = 100; /// 1%

        vm.expectRevert(Error.NEGATIVE_SLIPPAGE.selector);
        payloadUpdateLib.validateSlippage(newAmount, maxAmount, slippage);

        /// @dev payload updater goes rogue and tries to update new amount beyond slippage limit
        vm.expectRevert(Error.SLIPPAGE_OUT_OF_BOUNDS.selector);
        payloadUpdateLib.validateSlippage(newAmountBeyondSlippage, maxAmount, slippage);
    }

    function test_validatePayloadUpdate() public {
        /// @dev payload updater goes rogue and tries to update amounts for withdraw transaction
        uint256 txInfo = DataLib.packTxInfo(
            uint8(TransactionType.WITHDRAW),
            uint8(CallbackType.INIT),
            1,
            1,
            address(420),
            1
        );

        vm.expectRevert(Error.INVALID_PAYLOAD_UPDATE_REQUEST.selector);
        payloadUpdateLib.validatePayloadUpdate(txInfo, PayloadState.STORED, 1);

        /// @dev payload updater goes rogue and tries to update amounts for deposit return transaction
        uint256 txInfo2 = DataLib.packTxInfo(
            uint8(TransactionType.DEPOSIT),
            uint8(CallbackType.RETURN),
            1,
            1,
            address(420),
            1
        );

        vm.expectRevert(Error.INVALID_PAYLOAD_UPDATE_REQUEST.selector);
        payloadUpdateLib.validatePayloadUpdate(txInfo2, PayloadState.STORED, 1);

        /// @dev payload updater goes rogue and tries to update amounts for failed withdraw transaction
        uint256 txInfo3 = DataLib.packTxInfo(
            uint8(TransactionType.WITHDRAW),
            uint8(CallbackType.FAIL),
            1,
            1,
            address(420),
            1
        );

        vm.expectRevert(Error.INVALID_PAYLOAD_UPDATE_REQUEST.selector);
        payloadUpdateLib.validatePayloadUpdate(txInfo3, PayloadState.STORED, 1);

        /// @dev payload updater goes rogue and tries to update amounts for crafted type
        uint256 txInfo4 = DataLib.packTxInfo(
            uint8(TransactionType.DEPOSIT),
            uint8(CallbackType.FAIL),
            1,
            1,
            address(420),
            1
        );

        vm.expectRevert(Error.INVALID_PAYLOAD_UPDATE_REQUEST.selector);
        payloadUpdateLib.validatePayloadUpdate(txInfo4, PayloadState.STORED, 1);
    }

    function test_validatePayloadUpdateForAlreadyUpdatedPayload() public {
        /// @dev payload updater goes rogue and tries to update already updated payload
        uint256 txInfo = DataLib.packTxInfo(
            uint8(TransactionType.DEPOSIT),
            uint8(CallbackType.INIT),
            1,
            1,
            address(420),
            1
        );

        vm.expectRevert(Error.INVALID_PAYLOAD_STATE.selector);
        payloadUpdateLib.validatePayloadUpdate(txInfo, PayloadState.UPDATED, 1);
    }

    function test_validatePayloadUpdateForIsMultiMismatch() public {
        /// @dev payload updater goes rogue and tries to update already updated payload
        uint256 txInfo = DataLib.packTxInfo(
            uint8(TransactionType.DEPOSIT),
            uint8(CallbackType.INIT),
            0, /// 0 - not multi
            1,
            address(420),
            1
        );

        vm.expectRevert(Error.INVALID_PAYLOAD_UPDATE_REQUEST.selector);
        payloadUpdateLib.validatePayloadUpdate(txInfo, PayloadState.STORED, 1);
    }
}
