// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Mysbase Room Pass — one-time 24h pass for any room.
contract RoomPass is ERC1155, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PASS = 1;
    uint256 public constant DURATION = 24 hours;

    IERC20 public immutable usdc;
    address public treasury;
    uint256 public price; // per pass, 6 decimals

    /// wallet => issueId => room => access until
    mapping(address => mapping(uint256 => mapping(uint8 => uint256))) public passUntil;

    event Bought(address indexed buyer, uint256 amount, uint256 paid);
    event Used(address indexed user, uint256 indexed issueId, uint8 room, uint256 until);
    event PriceSet(uint256 price);
    event TreasurySet(address treasury);

    error ZeroAddress(); error ZeroAmount();

    constructor(address owner_, address usdc_, address treasury_, uint256 price_, string memory uri_)
        ERC1155(uri_) Ownable(owner_)
    {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_); treasury = treasury_; price = price_;
    }

    function buy(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 cost = amount * price;
        usdc.safeTransferFrom(msg.sender, treasury, cost);
        _mint(msg.sender, PASS, amount, "");
        emit Bought(msg.sender, amount, cost);
    }

    /// @notice Burn one pass for 24h access to one room (issueId + room id; room 0 = issue main room).
    function use(uint256 issueId, uint8 room) external whenNotPaused {
        _burn(msg.sender, PASS, 1);
        uint256 until = block.timestamp + DURATION;
        passUntil[msg.sender][issueId][room] = until;
        emit Used(msg.sender, issueId, room, until);
    }

    function hasPassAccess(address wallet, uint256 issueId, uint8 room) external view returns (bool) {
        return block.timestamp < passUntil[wallet][issueId][room];
    }

    function setPrice(uint256 p) external onlyOwner { price = p; emit PriceSet(p); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setURI(string calldata u) external onlyOwner { _setURI(u); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
