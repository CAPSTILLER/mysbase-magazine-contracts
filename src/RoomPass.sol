// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRooms {
    function roomOpen(uint256 roomId) external view returns (bool);
    function closeEpoch(uint256 roomId) external view returns (uint64);
    function closedAt(uint256 roomId, uint64 epoch) external view returns (uint64);
}

/// @title Mysbase Room Pass — 1 USDC throwaway pass for 24h in one room.
/// @notice use(roomId) (room must be Open) moves one pass from the caller into this contract (escrow)
///         and starts a 24h timer. One active escrowed pass per user per room.
///         - Room shut down / quarantined before the 24h ends: access stops at once and the pass can be
///           reclaimed (reclaim(user, roomId), callable by anyone) — returned like new.
///         - 24h ends without a close: the escrowed pass is burned (burnExpired, callable by anyone, or
///           automatically on the user's next use()). Expired passes never grant access or refunds.
contract RoomPass is ERC1155, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PASS = 1;
    uint256 public constant DURATION = 24 hours;

    IERC20 public immutable usdc;
    address public treasury;
    uint256 public price; // per pass, 6 decimals
    IRooms public rooms;

    struct Deposit { uint64 until; uint64 epoch; }
    /// wallet => roomId => escrowed pass (until 0 = none)
    mapping(address => mapping(uint256 => Deposit)) public deposits;

    event Bought(address indexed buyer, uint256 amount, uint256 paid);
    event Used(address indexed user, uint256 indexed roomId, uint256 until);
    event RoomsSet(address rooms);
    event Reclaimed(address indexed user, uint256 indexed roomId);
    event BurnedExpired(address indexed user, uint256 indexed roomId);
    event PriceSet(uint256 price);
    event TreasurySet(address treasury);

    error ZeroAddress(); error ZeroAmount(); error RoomClosed(); error PassActive(); error NotReclaimable(); error NotExpired();

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

    /// @notice Escrow one pass for 24h in an Open room. Settles any old deposit for this room first.
    function use(uint256 roomId) external whenNotPaused nonReentrant {
        if (!rooms.roomOpen(roomId)) revert RoomClosed();
        Deposit memory d = deposits[msg.sender][roomId];
        if (d.until != 0) {
            if (_reclaimable(d, roomId)) _reclaim(msg.sender, roomId);
            else if (block.timestamp >= d.until) _burnExpired(msg.sender, roomId);
            else revert PassActive();
        }
        _move(msg.sender, address(this));
        uint64 until = uint64(block.timestamp + DURATION);
        deposits[msg.sender][roomId] = Deposit(until, rooms.closeEpoch(roomId));
        emit Used(msg.sender, roomId, until);
    }

    /// @notice Return an escrowed pass whose room was closed before its 24h ended. Anyone may call.
    function reclaim(address user, uint256 roomId) external nonReentrant {
        if (!_reclaimable(deposits[user][roomId], roomId)) revert NotReclaimable();
        _reclaim(user, roomId);
    }

    /// @notice Burn an escrowed pass whose 24h ran out without a close. Anyone may call.
    function burnExpired(address user, uint256 roomId) external {
        Deposit memory d = deposits[user][roomId];
        if (d.until == 0 || _reclaimable(d, roomId) || block.timestamp < d.until) revert NotExpired();
        _burnExpired(user, roomId);
    }

    function reclaimable(address user, uint256 roomId) external view returns (bool) {
        return _reclaimable(deposits[user][roomId], roomId);
    }

    function burnable(address user, uint256 roomId) external view returns (bool) {
        Deposit memory d = deposits[user][roomId];
        return d.until != 0 && !_reclaimable(d, roomId) && block.timestamp >= d.until;
    }

    function hasPassAccess(address wallet, uint256 roomId) external view returns (bool) {
        Deposit memory d = deposits[wallet][roomId];
        return block.timestamp < d.until && rooms.closeEpoch(roomId) == d.epoch && rooms.roomOpen(roomId);
    }

    /// closed (first close after use) strictly before expiry
    function _reclaimable(Deposit memory d, uint256 roomId) internal view returns (bool) {
        if (d.until == 0 || rooms.closeEpoch(roomId) == d.epoch) return false;
        return rooms.closedAt(roomId, d.epoch + 1) < d.until;
    }

    function _reclaim(address user, uint256 roomId) internal {
        delete deposits[user][roomId];
        _move(address(this), user);
        emit Reclaimed(user, roomId);
    }

    function _burnExpired(address user, uint256 roomId) internal {
        delete deposits[user][roomId];
        _burn(address(this), PASS, 1);
        emit BurnedExpired(user, roomId);
    }

    /// internal move (no receiver hook needed; the user authorises by calling use()).
    function _move(address from, address to) internal {
        uint256[] memory ids = new uint256[](1); uint256[] memory v = new uint256[](1);
        ids[0] = PASS; v[0] = 1;
        _update(from, to, ids, v);
    }

    function setRooms(address r) external onlyOwner { if (r == address(0)) revert ZeroAddress(); rooms = IRooms(r); emit RoomsSet(r); }
    function setPrice(uint256 p) external onlyOwner { price = p; emit PriceSet(p); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setURI(string calldata u) external onlyOwner { _setURI(u); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
