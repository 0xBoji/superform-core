/// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "../utils/ProtocolActions.sol";
import "./handlers/VaultSharesHandler.sol";
import "forge-std/Test.sol";

contract VaultSharesInvariantTest is Test {
    VaultSharesHandler public handler;

    function setUp() public {
        // super.setUp();

        handler = new VaultSharesHandler();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = VaultSharesHandler.singleDirectSingleVaultDeposit.selector;
        selectors[1] = VaultSharesHandler.singleDirectSingleVaultWithdraw.selector;
        selectors[2] = VaultSharesHandler.singleXChainRescueFailedDeposit.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_vaultShares() public {
        // /// @dev target superform: (underlying, vault, formKind, chain) = (1, 0, 0, 1)
        // uint256 superPositionsSum;
        // /// @dev sum up superpositions owned by user for the superform on ETH, on all chains
        // for (uint256 i = 0; i < chainIds.length; i++) {
        //     uint256[] memory superPositions = _getSuperpositionsForDstChainFromSrcChain(
        //         0, TARGET_UNDERLYINGS[ETH][0], TARGET_VAULTS[ETH][0], TARGET_FORM_KINDS[ETH][0], chainIds[i], ETH
        //     );

        //     if (superPositions.length > 0) {
        //         superPositionsSum += superPositions[0];
        //     }
        // }

        // address superform = getContract(
        //     ETH, string.concat(UNDERLYING_TOKENS[2], VAULT_KINDS[0], "Superform",
        // Strings.toString(FORM_BEACON_IDS[0]))
        // );

        // vm.selectFork(ETH);
        // console.log("superPositionsSum:", superPositionsSum);
        // console.log("vaultShares:", IBaseForm(superform).getVaultShareBalance());
        // assertEq(superPositionsSum, IBaseForm(superform).getVaultShareBalance());

        assertEq(handler.getSuperpositionsSum(), handler.getVaultShares());
    }
}

/// define getters in handler that return addresses of target superform and target superposition
