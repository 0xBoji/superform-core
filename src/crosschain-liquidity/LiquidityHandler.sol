// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Error } from "src/libraries/Error.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidityHandler
/// @dev Executes an action with tokens to either bridge from Chain A -> Chain B or swap on same chain
/// @dev To be inherited by contracts that move liquidity
/// @author ZeroPoint Labs
abstract contract LiquidityHandler {
    
    using SafeERC20 for IERC20;

    //////////////////////////////////////////////////////////////
    //                         CONSTANTS                        //
    //////////////////////////////////////////////////////////////

    address immutable NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //////////////////////////////////////////////////////////////
    //                  INTERNAL FUNCTIONS                      //
    //////////////////////////////////////////////////////////////

    /// @dev dispatches tokens via a liquidity bridge or exchange
    /// @param bridge_ Bridge address to pass tokens to
    /// @param txData_ liquidity bridge data
    /// @param token_ Token caller deposits into superform
    /// @param amount_ Amount of tokens to deposit
    /// @param nativeAmount_ msg.value or msg.value + native tokens
    function _dispatchTokens(
        address bridge_,
        bytes memory txData_,
        address token_,
        uint256 amount_,
        uint256 nativeAmount_
    )
        internal
        virtual
    {
        if (amount_ == 0) {
            revert Error.ZERO_AMOUNT();
        }

        if (bridge_ == address(0)) {
            revert Error.ZERO_ADDRESS();
        }

        if (token_ != NATIVE) {
            IERC20(token_).safeIncreaseAllowance(bridge_, amount_);
        } else {
            if (nativeAmount_ < amount_) revert Error.INSUFFICIENT_NATIVE_AMOUNT();
            if (nativeAmount_ > address(this).balance) revert Error.INSUFFICIENT_BALANCE();
        }

        (bool success,) = payable(bridge_).call{ value: nativeAmount_ }(txData_);
        if (!success) revert Error.FAILED_TO_EXECUTE_TXDATA(token_);

        if (token_ != NATIVE) {
            IERC20 token = IERC20(token_);
            if (token.allowance(address(this), bridge_) > 0) token.forceApprove(bridge_, 0);
        }
    }
}
