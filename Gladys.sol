
// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.5.0
pragma solidity ^0.8.27;

import {ERC1363} from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Gladys is ERC20, ERC20Burnable, ERC20Pausable, Ownable, ERC1363, ERC20Permit, ERC20Votes {
    // Tracks the last block in which an address used the public mint
    mapping(address => uint256) public lastPublicMintBlock;

    // Exactly 1 token (1 * 10^decimals)
    uint256 public immutable PUBLIC_MINT_AMOUNT;

    constructor(address recipient, address initialOwner)
        ERC20("Gladys", "GLAD")
        Ownable(initialOwner)
        ERC20Permit("Gladys")
    {
        PUBLIC_MINT_AMOUNT = 1 * 10 ** decimals();

        _mint(recipient, 90000000000000 * 10 ** decimals());
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /// @notice Owner mint (unchanged)
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /// @notice Anyone can mint exactly 1 token, at most once per block per address
    function publicMintOne() external whenNotPaused {
        require(lastPublicMintBlock[msg.sender] < block.number, "Already minted this block");
        lastPublicMintBlock[msg.sender] = block.number;

        _mint(msg.sender, PUBLIC_MINT_AMOUNT);
    }

    // The following functions are overrides required by Solidity.

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
