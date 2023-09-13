/// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC721 } from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract KYCDaoNFTMock is ERC721 {
    uint256 private tokenId;

    constructor() ERC721("KYCDaoNFT", "KYCDaoNFT") { }

    function mint(address owner) public returns (uint256) {
        unchecked {
            ++tokenId;
        }

        _mint(owner, tokenId);

        return tokenId;
    }

    function hasValidToken(address _addr) public view returns (bool) {
        uint256 numTokens = balanceOf(_addr);
        if (numTokens > 0) return true;

        return false;
    }
}
