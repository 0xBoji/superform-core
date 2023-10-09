// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

/// Types Imports
import { ILiFi } from "src/vendor/lifi/ILiFi.sol";
import { LibSwap } from "src/vendor/lifi/LibSwap.sol";
import "./MockERC20.sol";

/// @title Socket Router Mock
/// @dev eventually replace this by using a fork of the real registry contract

contract LiFiMock is Test {
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    receive() external payable { }

    function swapAndStartBridgeTokensViaBridge(
        ILiFi.BridgeData calldata bridgeData,
        LibSwap.SwapData[] calldata swapData
    )
        external
        payable
    {
        if (!bridgeData.hasSourceSwaps) {
            _bridge(bridgeData.minAmount, bridgeData.receiver, bridgeData.sendingAssetId, swapData[0].callData, false);
        } else {
            uint256 amount = _swap(
                swapData[0].fromAmount,
                swapData[0].sendingAssetId,
                swapData[0].receivingAssetId,
                swapData[0].callData,
                address(this)
            );

            _bridge(amount, bridgeData.receiver, bridgeData.sendingAssetId, swapData[0].callData, true);
        }
    }

    function swapTokensGeneric(
        bytes32, /*_transactionId*/
        string calldata, /*_integrator*/
        string calldata, /*_referrer*/
        address payable _receiver,
        uint256, /*_minAmount*/
        LibSwap.SwapData[] calldata _swapData
    )
        external
        payable
    {
        _swap(
            _swapData[0].fromAmount,
            _swapData[0].sendingAssetId,
            _swapData[0].receivingAssetId,
            _swapData[0].callData,
            _receiver
        );
    }

    struct BridgeLocalVars {
        address from;
        uint256 toForkId;
        address outputToken;
        int256 slippage;
        bool isMultiTx;
        uint256 multiTxSlippageShare;
        uint256 amount;
        bool isDirect;
    }

    function _bridge(
        uint256 amount_,
        address receiver_,
        address inputToken_,
        bytes memory data_,
        bool prevSwap
    )
        internal
    {
        BridgeLocalVars memory v;
        /// @dev encapsulating from
        (v.from, v.toForkId, v.outputToken, v.slippage, v.isMultiTx, v.multiTxSlippageShare, v.isDirect) =
            abi.decode(data_, (address, uint256, address, int256, bool, uint256, bool));

        uint256 decimal1 = inputToken_ == NATIVE ? 18 : MockERC20(inputToken_).decimals();
        // if underlyingTokenn
        if (inputToken_ != NATIVE) {
            if (!prevSwap) MockERC20(inputToken_).transferFrom(v.from, address(this), amount_);
        } else {
            require(msg.value == amount_);
        }

        uint256 prevForkId = vm.activeFork();
        vm.selectFork(v.toForkId);

        uint256 decimal2 = v.outputToken == NATIVE ? 18 : MockERC20(v.outputToken).decimals();
        uint256 amountOut;

        if (v.isDirect) v.slippage = 0;
        else if (v.isMultiTx) v.slippage = (v.slippage * int256(v.multiTxSlippageShare)) / 100;
        else v.slippage = (v.slippage * int256(100 - v.multiTxSlippageShare)) / 100;

        amountOut = (amount_ * uint256(10_000 - v.slippage)) / 10_000;

        /// input token decimals are greater than output
        if (decimal1 > decimal2) {
            v.amount = amountOut / 10 ** (decimal1 - decimal2);
        } else {
            v.amount = amountOut * 10 ** (decimal2 - decimal1);
        }

        console.log("--LiFi Mock Logs");

        console.log("amountOut", amountOut);
        console.log("decimal1", decimal1);
        console.log("decimal2", decimal2);
        console.log("v.amount", v.amount);

        if (v.outputToken != NATIVE) {
            console.log("balance b4", MockERC20(v.outputToken).balanceOf(receiver_));
            //MockERC20(v.outputToken).approve(receiver_, v.amount);
            //MockERC20(v.outputToken).transferFrom(address(this), receiver_, v.amount);
            deal(v.outputToken, receiver_, MockERC20(v.outputToken).balanceOf(receiver_) + v.amount);

            console.log("receiver", receiver_);
            console.log("balance after", MockERC20(v.outputToken).balanceOf(receiver_));
        } else {
            if (prevForkId != v.toForkId) vm.deal(address(this), v.amount);

            (bool success,) = payable(receiver_).call{ value: v.amount }("");

            require(success);
        }
        vm.selectFork(prevForkId);
    }

    function _swap(
        uint256 amount_,
        address inputToken_,
        address outputToken_,
        bytes memory data_,
        address receiver_
    )
        internal
        returns (uint256)
    {
        /// @dev encapsulating from
        address from = abi.decode(data_, (address));
        if (inputToken_ != NATIVE) {
            MockERC20(inputToken_).transferFrom(from, address(this), amount_);
        }

        uint256 decimal1 = inputToken_ == NATIVE ? 18 : MockERC20(inputToken_).decimals();
        uint256 decimal2 = outputToken_ == NATIVE ? 18 : MockERC20(outputToken_).decimals();

        /// input token decimals are greater than output
        if (decimal1 > decimal2) {
            amount_ = amount_ / 10 ** (decimal1 - decimal2);
        } else {
            amount_ = amount_ * 10 ** (decimal2 - decimal1);
        }
        console.log("amount swapped", amount_);
        /// @dev assume no swap slippage
        deal(outputToken_, receiver_, MockERC20(outputToken_).balanceOf(receiver_) + amount_);
        return amount_;
    }
}
