// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;
import "forge-std/Test.sol";
/// Types Imports
import {ISocketRegistry} from "../../vendor/socket/ISocketRegistry.sol";

import "./MockERC20.sol";

/// @title Socket Router Mock
/// @dev eventually replace this by using a fork of the real registry contract
contract SocketRouterMock is ISocketRegistry, Test {
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    receive() external payable {}

    /// @dev FIXME Native case missing
    function outboundTransferTo(ISocketRegistry.UserRequest calldata userRequest_) external payable override {
        ISocketRegistry.BridgeRequest memory bridgeRequest = userRequest_.bridgeRequest;

        ISocketRegistry.MiddlewareRequest memory middlewareRequest = userRequest_.middlewareRequest;

        if (middlewareRequest.id == 0 && bridgeRequest.id != 0) {
            /// @dev just mock bridge
            _bridge(
                userRequest_.amount,
                userRequest_.receiverAddress,
                userRequest_.bridgeRequest.inputToken,
                userRequest_.bridgeRequest.data,
                false
            );
        } else if (middlewareRequest.id != 0 && bridgeRequest.id != 0) {
            /// @dev else, assume according to socket a swap and bridge is involved
            _swap(
                userRequest_.amount,
                userRequest_.middlewareRequest.inputToken,
                userRequest_.bridgeRequest.inputToken,
                userRequest_.middlewareRequest.data
            );

            _bridge(
                userRequest_.amount,
                userRequest_.receiverAddress,
                userRequest_.bridgeRequest.inputToken,
                userRequest_.bridgeRequest.data,
                true
            );
        } else if (middlewareRequest.id != 0 && bridgeRequest.id == 0) {
            /// @dev assume, for mocking purposes that cases with just swap is for the same token
            /// @dev this is for direct actions and multiTx swap of destination
            /// @dev bridge is used here to mint tokens in a new contract, but actually it's just a swap (chain id is the same)
            _bridge(
                userRequest_.amount,
                userRequest_.receiverAddress,
                userRequest_.middlewareRequest.inputToken,
                userRequest_.middlewareRequest.data,
                false
            );
        }
    }

    function routes() external view override returns (RouteData[] memory) {}

    function _bridge(
        uint256 amount_,
        address receiver_,
        address inputToken_,
        bytes memory data_,
        bool prevSwap
    ) internal {
        /// @dev encapsulating from
        (address from, uint256 toForkId) = abi.decode(data_, (address, uint256));
        if (!prevSwap) MockERC20(inputToken_).transferFrom(from, address(this), amount_);
        MockERC20(inputToken_).burn(address(this), amount_);

        uint256 prevForkId = vm.activeFork();
        vm.selectFork(toForkId);
        MockERC20(inputToken_).mint(receiver_, amount_);
        vm.selectFork(prevForkId);
    }

    function _swap(uint256 amount_, address inputToken_, address bridgeToken_, bytes memory data_) internal {
        /// @dev encapsulating from
        address from = abi.decode(data_, (address));
        console.log("msgValue in mock", msg.value);
        if (inputToken_ != NATIVE) {
            MockERC20(inputToken_).transferFrom(from, address(this), amount_);
            MockERC20(inputToken_).burn(address(this), amount_);
        }
        /// @dev assume no swap slippage
        MockERC20(bridgeToken_).mint(address(this), amount_);
    }
}
