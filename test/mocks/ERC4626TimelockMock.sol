// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.21;

import { ERC4626 } from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

/// @notice Mock ERC4626Timelock contract
/// @dev Requires two separate calls to perform ERC4626.withdraw() or redeem()
/// @dev First call is to requestUnlock() and second call is to withdraw() or redeem()
/// @dev Allows canceling unlock request
/// @dev Designed to mimick behavior of timelock vaults covering most of the use cases abstracted
contract ERC4626TimelockMock is ERC4626 {
    uint256 public lockPeriod = 1 hours;
    uint256 public requestId;

    struct UnlockRequest {
        /// Unique id of the request
        uint256 id;
        // The timestamp at which the `shareAmount` was requested to be unlocked
        uint256 startedAt;
        // The amount of shares to burn
        uint256 shareAmount;
    }

    mapping(address owner => UnlockRequest) public requests;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) { }

    function userUnlockRequests(address owner) external view returns (UnlockRequest memory) {
        return requests[owner];
    }

    function getLockPeriod() external view returns (uint256) {
        return lockPeriod;
    }

    /// @notice Mock Timelock-like behavior (a need for two separate calls to withdraw)
    function requestUnlock(uint256 sharesAmount, address owner) external {
        require(requests[owner].shareAmount == 0, "ALREADY_REQUESTED");

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) approve(msg.sender, allowed - sharesAmount);
        }

        /// @dev Internal tracking of withdraw/redeem requests routed through this vault
        requestId++;
        requests[owner] = (UnlockRequest({ id: requestId, startedAt: block.timestamp, shareAmount: sharesAmount }));
    }

    function cancelUnlock(address owner) external {
        UnlockRequest storage request = requests[owner];
        require(request.startedAt + lockPeriod > block.timestamp, "NOT_UNLOCKED");

        /// @dev Mint shares back
        /// NOTE: This method needs to be tested for re-basing shares
        _mint(owner, request.shareAmount);

        delete requests[owner];
    }
}
