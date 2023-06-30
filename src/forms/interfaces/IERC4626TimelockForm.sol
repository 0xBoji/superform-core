///SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import {IERC4626Form} from "../../test/interfaces/IERC4626Form.sol";
import {InitSingleVaultData} from "../../types/DataTypes.sol";

/// @title IERC4626TimelockForm
/// @notice Interface used by ERC4626TimelockForm. Required by TwostepsFormStateRegistry to call processUnlock() function
interface IERC4626TimelockForm is IERC4626Form {
    /// @notice Process unlock request
    function withdrawAfterCoolDown(uint256 amount_) external;
}
