// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRooms { function roomOpen(uint256 roomId) external view returns (bool); }

/// @title Mysbase Room Pass — one-time 24h pass for one room.
/// @notice A pass only works in an OPEN, started room. use() refuses other rooms so nobody burns a pass
///         for nothing; an active pass stops working while the room is ShutDown or Quarantined.
contract RoomPass is ERC1155, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PASS = 1;
    uint256 public constant DURATION = 24 hours;

    IERC20 public immutable usdc;
    address public treasury;
    uint256 public price; // per pass, 6 decimals
    IRooms public rooms;

    /// wallet => roomId => access until
    mapping(address => mapping(uint256 => uint256)) public passUntil;

    event Bought(address indexed buyer, uint256 amount, uint256 paid);
    event Used(address indexed user, uint256 indexed roomId, uint256 until);
    event RoomsSet(address rooms);
    event PriceSet(uint256 price);
    event TreasurySet(address treasury);

    error ZeroAddress(); error ZeroAmount(); error RoomClosed();

    constructor(address owner_, address usdc_, address treasury_, uint256 price_, address rooms_, string memory uri_)
        ERC1155(uri_) Ownable(owner_)
    {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_); treasury = treasury_; price = price_;
        if (rooms_ == address(0)) revert ZeroAddress();
        rooms = IRooms(rooms_);
    }

    function buy(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 cost = amount * price;
        usdc.safeTransferFrom(msg.sender, treasury, cost);
        _mint(msg.sender, PASS, amount, "");
        emit Bought(msg.sender, amount, cost);
    }

    /// @notice Burn one pass for 24h access to one open room. Reverts if the room is not open.
    function use(uint256 roomId) external whenNotPaused nonReentrant {
        if (!rooms.roomOpen(roomId)) revert RoomClosed();
        _burn(msg.sender, PASS, 1);
        uint256 until = block.timestamp + DURATION;
        passUntil[msg.sender][roomId] = until;
        emit Used(msg.sender, roomId, until);
    }

    function hasPassAccess(address wallet, uint256 roomId) external view returns (bool) {
        return block.timestamp < passUntil[wallet][roomId] && rooms.roomOpen(roomId);
    }

    function setRooms(address r) external onlyOwner { if (r == address(0)) revert ZeroAddress(); rooms = IRooms(r); emit RoomsSet(r); }
    function setPrice(uint256 p) external onlyOwner { price = p; emit PriceSet(p); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setURI(string calldata u) external onlyOwner { _setURI(u); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
