// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
contract Mock6 is ERC20 { constructor() ERC20("USDC", "USDC") {} function decimals() public pure override returns (uint8) { return 6; } function mint(address t, uint256 a) external { _mint(t, a); } }
contract MockKey is ERC721 { constructor() ERC721("Key", "KEY") {} function mint(address t, uint256 id) external { _mint(t, id); } }
