// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { IBaseRouter } from "src/interfaces/IBaseRouter.sol";
import { ISuperRegistry } from "src/interfaces/ISuperRegistry.sol";
import { Error } from "src/libraries/Error.sol";
import "src/types/DataTypes.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BaseRouter
/// @dev Routes users funds and action information to a remote execution chain.
/// @dev abstract implementation that allows inheriting contract to implement the logic
/// @author Zeropoint Labs
abstract contract BaseRouter is IBaseRouter {

    using SafeERC20 for IERC20;

    //////////////////////////////////////////////////////////////
    //                         CONSTANTS                        //
    //////////////////////////////////////////////////////////////

    ISuperRegistry public immutable superRegistry;
    uint64 public immutable CHAIN_ID;
    uint8 internal constant STATE_REGISTRY_TYPE = 1;

    //////////////////////////////////////////////////////////////
    //                      CONSTRUCTOR                         //
    //////////////////////////////////////////////////////////////

    /// @param superRegistry_ the superform registry contract
    constructor(address superRegistry_) {
        if (superRegistry_ == address(0)) {
            revert Error.ZERO_ADDRESS();
        }
        
        if (block.chainid > type(uint64).max) {
            revert Error.BLOCK_CHAIN_ID_OUT_OF_BOUNDS();
        }

        CHAIN_ID = uint64(block.chainid);
        superRegistry = ISuperRegistry(superRegistry_);
    }

    //////////////////////////////////////////////////////////////
    //              EXTERNAL WRITE FUNCTIONS                    //
    //////////////////////////////////////////////////////////////

    /// @notice receive enables processing native token transfers into the smart contract.
    /// @notice liquidity bridge fails without a native receive function.
    receive() external payable { }

    /// @inheritdoc IBaseRouter
    function singleDirectSingleVaultDeposit(SingleDirectSingleVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function singleXChainSingleVaultDeposit(SingleXChainSingleVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function singleDirectMultiVaultDeposit(SingleDirectMultiVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function singleXChainMultiVaultDeposit(SingleXChainMultiVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function multiDstSingleVaultDeposit(MultiDstSingleVaultStateReq calldata req_) external payable virtual override;

    /// @inheritdoc IBaseRouter
    function multiDstMultiVaultDeposit(MultiDstMultiVaultStateReq calldata req_) external payable virtual override;

    /// @inheritdoc IBaseRouter
    function singleDirectSingleVaultWithdraw(SingleDirectSingleVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function singleXChainSingleVaultWithdraw(SingleXChainSingleVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function singleDirectMultiVaultWithdraw(SingleDirectMultiVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function singleXChainMultiVaultWithdraw(SingleXChainMultiVaultStateReq memory req_)
        external
        payable
        virtual
        override;

    /// @inheritdoc IBaseRouter
    function multiDstSingleVaultWithdraw(MultiDstSingleVaultStateReq calldata req_) external payable virtual override;

    /// @inheritdoc IBaseRouter
    function multiDstMultiVaultWithdraw(MultiDstMultiVaultStateReq calldata req_) external payable virtual override;

    /// @inheritdoc IBaseRouter
    function forwardDustToPaymaster(address token_) external virtual override;
}
