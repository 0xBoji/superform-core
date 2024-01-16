// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

/// @title LiFi Validator Interface
/// @author Zeropoint Labs
interface ILiFiValidator {
    //////////////////////////////////////////////////////////////
    //              EXTERNAL  FUNCTIONS                         //
    //////////////////////////////////////////////////////////////

    /// @dev Adds a selector to the blacklist
    /// @param selector_ the selector to add
    function addToBlacklist(bytes4 selector_) external;

    /// @dev Removes a selector from the blacklist
    /// @param selector_ the selector to remove
    function removeFromBlacklist(bytes4 selector_) external;
    //////////////////////////////////////////////////////////////
    //              EXTERNAL VIEW FUNCTIONS                     //
    //////////////////////////////////////////////////////////////

    /// @dev Checks if given selector is blacklisted
    /// @param selector_ the selector to check
    /// @return blacklisted if selector is blacklisted
    function isSelectorBlacklisted(bytes4 selector_) external view returns (bool blacklisted);
}
