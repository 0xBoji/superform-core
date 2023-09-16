///SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title IERC4626Form
/// @author Zeropoint Labs
// FIXME: these variables should be in every form regardless of 4626
interface IERC4626Form is IERC20 {
    function vaultSharesIsERC20() external pure returns (bool);

    function vaultSharesIsERC4626() external pure returns (bool);

    function getVaultAsset() external view returns (address);

    function getVaultName() external view returns (string memory);

    function getVaultSymbol() external view returns (string memory);

    function getVaultDecimals() external view returns (uint256);

    function getPricePerVaultShare() external view returns (uint256);

    function getVaultShareBalance() external view returns (uint256);

    function getTotalAssets() external view returns (uint256);

    function getPreviewPricePerVaultShare() external view returns (uint256);

    function previewDepositTo(uint256 assets_) external view returns (uint256);

    function previewWithdrawFrom(uint256 assets_) external view returns (uint256);
}
