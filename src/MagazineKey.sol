// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Optional future randomness source (e.g. a VRF adapter). Must return a fresh random word.
interface IRandomSource {
    function randomWord(address minter, uint256 nonce) external returns (uint256);
}

interface IKeyNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IRoomPassView {
    function hasPassAccess(address wallet, uint256 roomId) external view returns (bool);
}

/// @title Mysbase Magazine Key — permanent gate-key NFTs for the magazine rooms.
/// @notice One collection, one pool. Keys never change. Each room has its OWN clock:
///         when a room is started/reset, every eligible holder gets a fresh window from that
///         room's startTime: Common 7d, Uncommon 14d, Rare 30d, Mythic forever
///         Room states: Quarantined (default for every new room), Open, ShutDown.
///         - Open: rarity windows from startTime + trait gating + RoomPasses.
///         - ShutDown (only from Open; stops the timer, reopening resets it): only Mythic holders and Cap.
///         - Quarantined (default; allowed from any state): only Cap. Mythic locked out.
///         Every shutdown/quarantine bumps the room's closeEpoch and records closedAt, so RoomPass can
///         refund passes used before the close (pull model, no loops here).
///         Mythic holders ignore trait gating and time limits in any Open (started) or ShutDown room.
///         Cap (owner or current CAPs Mind key holder) can always enter every room.
///         canEnter / roomState / keyInfo are stable external views for a future custom-rooms contract.
/// @dev Randomness: by default uses block.prevrandao + blockhash + nonce + minter. On Base the
///      sequencer produces blocks and could in theory bias outcomes, and a contract caller can
///      simulate and revert unwanted pulls. Fine for a fun pull, not for high-value odds.
///      Owner can plug in an IRandomSource (VRF adapter) later via setRandomSource.
contract MagazineKey is ERC721Enumerable, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Rarity { Common, Uncommon, Rare, Mythic }

    /// Traits: 1 Grass, 2 Mountain, 3 Snowy Tundra, 4 Ocean, 5 Outer Space, 6 Desert, 7 Forest.
    /// @notice Hard cap: the pool (and so total mints) can never exceed 10,000 keys.
    uint256 public constant MAX_SUPPLY = 10_000;
    uint8 public constant ANY = 0;
    uint8 public constant GRASS = 1;
    uint8 public constant MOUNTAIN = 2;
    uint8 public constant SNOWY_TUNDRA = 3;
    uint8 public constant OCEAN = 4;
    uint8 public constant OUTER_SPACE = 5;
    uint8 public constant DESERT = 6;
    uint8 public constant FOREST = 7;

    enum RoomState { Quarantined, Open, ShutDown }

    struct Entry { Rarity rarity; uint8 trait; string uri; }
    /// requiredTrait 0 = any key holder; 1..7 = only holders of that trait.
    struct Room { bool exists; uint8 requiredTrait; RoomState state; uint64 startTime; }

    IERC20 public immutable usdc;
    address public treasury;
    uint256 public mintPrice; // 6 decimals
    IKeyNFT public keyContract;
    uint256 public keyTokenId;
    IRandomSource public randomSource;
    IRoomPassView public roomPass;

    bool public poolLocked;
    uint256 public nextTokenId = 1;
    uint256 private _nonce;

    Entry[] private _entries;
    uint32[] private _remaining;
    mapping(uint256 => uint32) public entryOf; // tokenId => entry index
    mapping(uint256 => Room) public rooms;
    mapping(uint256 => uint64) public closeEpoch;                       // roomId => number of closes
    mapping(uint256 => mapping(uint64 => uint64)) public closedAt;      // roomId => epoch => close time

    event EntriesAdded(uint256 from, uint256 count);
    event EntryURISet(uint256 indexed idx, string uri);
    event PoolLocked(uint256 size);
    event RoomCreated(uint256 indexed roomId, uint8 requiredTrait);
    event RoomStarted(uint256 indexed roomId, uint64 startTime, address by);
    event RoomShutDown(uint256 indexed roomId, address by);
    event RoomQuarantined(uint256 indexed roomId, address by);
    event Minted(address indexed to, uint256 indexed tokenId, uint256 entry, Rarity rarity, uint8 trait);
    event MintPriceSet(uint256 price);
    event TreasurySet(address treasury);
    event KeySet(address key, uint256 tokenId);
    event RandomSourceSet(address source);
    event RoomPassSet(address pass);

    error ZeroAddress(); error PoolIsLocked(); error PoolNotLocked(); error SoldOut(); error BadTrait();
    error LengthMismatch(); error NotOperator(); error EmptyPool(); error MaxSupply(); error RoomExists(); error NoRoom(); error NotOpen();

    constructor(string memory name_, string memory symbol_, address owner_, address usdc_, address treasury_,
        uint256 price_, address key_, uint256 keyTokenId_)
        ERC721(name_, symbol_) Ownable(owner_)
    {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_); treasury = treasury_; mintPrice = price_;
        keyContract = IKeyNFT(key_); keyTokenId = keyTokenId_;
    }

    // ---------------- pool (owner, before lock) ----------------
    function addEntries(Rarity[] calldata rarities, uint8[] calldata traits, string[] calldata uris) external onlyOwner {
        if (poolLocked) revert PoolIsLocked();
        if (rarities.length != traits.length || traits.length != uris.length) revert LengthMismatch();
        uint256 from = _entries.length;
        if (from + traits.length > MAX_SUPPLY) revert MaxSupply();
        for (uint256 i; i < traits.length; i++) {
            if (traits[i] < GRASS || traits[i] > FOREST) revert BadTrait();
            _entries.push(Entry(rarities[i], traits[i], uris[i]));
            _remaining.push(uint32(from + i));
        }
        emit EntriesAdded(from, traits.length);
    }

    /// @notice Fix a mistaken entry URI before locking.
    function setEntryURI(uint256 idx, string calldata uri) external onlyOwner {
        if (poolLocked) revert PoolIsLocked();
        _entries[idx].uri = uri;
        emit EntryURISet(idx, uri);
    }

    /// @notice Freeze the pool forever and open minting.
    function lockPool() external onlyOwner {
        if (poolLocked) revert PoolIsLocked();
        if (_entries.length == 0) revert EmptyPool();
        poolLocked = true;
        emit PoolLocked(_entries.length);
    }

    // ---------------- rooms ----------------
    function isOperator(address a) public view returns (bool) {
        if (a == owner()) return true;
        if (address(keyContract).code.length == 0) return false;
        try keyContract.ownerOf(keyTokenId) returns (address h) { return h == a; } catch { return false; }
    }

    modifier onlyOperator() { if (!isOperator(msg.sender)) revert NotOperator(); _; }

    /// @notice Create a room. requiredTrait 0 = any key holder, 1..7 = that trait only.
    function createRoom(uint256 roomId, uint8 requiredTrait) public onlyOperator {
        if (rooms[roomId].exists) revert RoomExists();
        if (requiredTrait > FOREST) revert BadTrait();
        rooms[roomId] = Room(true, requiredTrait, RoomState.Quarantined, 0);
        emit RoomCreated(roomId, requiredTrait);
    }

    /// @notice Seed room 0 = main (any holder) and rooms 1..7 = trait rooms. Skips rooms that exist.
    function seedDefaultRooms() external onlyOperator {
        for (uint8 i; i <= FOREST; i++) if (!rooms[i].exists) createRoom(i, i);
    }

    /// @notice Open/reopen a room; its timer starts fresh at startTime (0 = now). Every eligible
    ///         holder gets a fresh window. Owner or current CAPs Mind key holder.
    function startRoom(uint256 roomId, uint64 startTime) external onlyOperator {
        Room storage r = _room(roomId);
        if (startTime == 0) startTime = uint64(block.timestamp);
        r.startTime = startTime; r.state = RoomState.Open;
        emit RoomStarted(roomId, startTime, msg.sender);
    }

    /// @notice Shut down an OPEN room: only Mythic holders and Cap can enter; timer stops; passes in use become reclaimable.
    function shutDownRoom(uint256 roomId) external onlyOperator {
        Room storage r = _room(roomId);
        if (r.state != RoomState.Open) revert NotOpen();
        r.state = RoomState.ShutDown;
        _close(roomId);
        emit RoomShutDown(roomId, msg.sender);
    }

    /// @notice Quarantine a room (any state): only Cap can enter; passes in use become reclaimable.
    function quarantineRoom(uint256 roomId) external onlyOperator {
        _room(roomId).state = RoomState.Quarantined;
        _close(roomId);
        emit RoomQuarantined(roomId, msg.sender);
    }

    function _close(uint256 roomId) internal {
        uint64 e = ++closeEpoch[roomId];
        closedAt[roomId][e] = uint64(block.timestamp);
    }

    function _room(uint256 roomId) internal view returns (Room storage r) {
        r = rooms[roomId];
        if (!r.exists) revert NoRoom();
    }

    /// @notice Room is Open and its start time has been reached (normal rules + passes apply).
    function roomOpen(uint256 roomId) public view returns (bool) {
        Room storage r = rooms[roomId];
        return r.exists && r.state == RoomState.Open && block.timestamp >= r.startTime;
    }

    /// @notice Clean view for other contracts/apps.
    function roomState(uint256 roomId) external view returns (bool exists, RoomState state, uint8 requiredTrait, uint64 startTime, bool open) {
        Room storage r = rooms[roomId];
        return (r.exists, r.state, r.requiredTrait, r.startTime, roomOpen(roomId));
    }

    // ---------------- mint ----------------
    /// @notice Pay mintPrice USDC to treasury, get a random key from the remaining pool.
    function mint() external whenNotPaused nonReentrant returns (uint256 tokenId) {
        if (!poolLocked) revert PoolNotLocked();
        uint256 n = _remaining.length;
        if (n == 0) revert SoldOut();
        usdc.safeTransferFrom(msg.sender, treasury, mintPrice);
        uint256 pick = _random() % n;
        uint32 picked = _remaining[pick];
        _remaining[pick] = _remaining[n - 1];
        _remaining.pop();
        tokenId = nextTokenId++;
        entryOf[tokenId] = picked;
        _safeMint(msg.sender, tokenId);
        Entry storage e = _entries[picked];
        emit Minted(msg.sender, tokenId, picked, e.rarity, e.trait);
    }

    function _random() internal returns (uint256) {
        uint256 nonce = ++_nonce;
        if (address(randomSource) != address(0)) return randomSource.randomWord(msg.sender, nonce);
        return uint256(keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), nonce, msg.sender)));
    }

    // ---------------- views ----------------
    function durationOf(Rarity r) public pure returns (uint256) {
        if (r == Rarity.Common) return 7 days;
        if (r == Rarity.Uncommon) return 14 days;
        if (r == Rarity.Rare) return 30 days;
        return type(uint256).max;
    }

    function poolSize() external view returns (uint256) { return _entries.length; }
    function remaining() external view returns (uint256) { return _remaining.length; }
    function entry(uint256 idx) external view returns (Entry memory) { return _entries[idx]; }

    /// @notice Clean view for other contracts/apps: a key's permanent rarity, trait, uri and current owner.
    function keyInfo(uint256 tokenId) external view returns (address holder, Rarity rarity, uint8 trait, string memory uri) {
        holder = _requireOwned(tokenId);
        Entry storage e = _entries[entryOf[tokenId]];
        return (holder, e.rarity, e.trait, e.uri);
    }

    function tokenInfo(uint256 tokenId) external view returns (Rarity rarity, uint8 trait, string memory uri) {
        _requireOwned(tokenId);
        Entry storage e = _entries[entryOf[tokenId]];
        return (e.rarity, e.trait, e.uri);
    }

    /// @notice When this key's access to a room ends. 0 = no access now;
    ///         type(uint256).max = no time limit (Mythic in an Open or ShutDown room).
    function accessEnds(uint256 tokenId, uint256 roomId) public view returns (uint256) {
        _requireOwned(tokenId);
        Room storage r = rooms[roomId];
        if (!r.exists) return 0;
        Entry storage e = _entries[entryOf[tokenId]];
        if (e.rarity == Rarity.Mythic) {
            if (r.state == RoomState.ShutDown || roomOpen(roomId)) return type(uint256).max;
            return 0;
        }
        if (!roomOpen(roomId)) return 0;
        if (r.requiredTrait != ANY && r.requiredTrait != e.trait) return 0;
        return r.startTime + durationOf(e.rarity);
    }

    function keyCanEnter(uint256 tokenId, uint256 roomId) public view returns (bool) {
        return block.timestamp < accessEnds(tokenId, roomId);
    }

    /// @notice True if wallet is Cap (owner / current CAPs Mind key holder, any room, any state),
    ///         holds a key with access now, or has an active RoomPass for this (Open) room.
    function canEnter(address wallet, uint256 roomId) external view returns (bool) {
        if (isOperator(wallet)) return true;
        if (!rooms[roomId].exists) return false;
        uint256 n = balanceOf(wallet);
        for (uint256 i; i < n; i++) if (keyCanEnter(tokenOfOwnerByIndex(wallet, i), roomId)) return true;
        if (address(roomPass) != address(0) && roomOpen(roomId)) return roomPass.hasPassAccess(wallet, roomId);
        return false;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _entries[entryOf[tokenId]].uri;
    }

    // ---------------- owner ----------------
    function setMintPrice(uint256 p) external onlyOwner { mintPrice = p; emit MintPriceSet(p); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setKey(address key, uint256 tokenId) external onlyOwner { keyContract = IKeyNFT(key); keyTokenId = tokenId; emit KeySet(key, tokenId); }
    function setRandomSource(address s) external onlyOwner { randomSource = IRandomSource(s); emit RandomSourceSet(s); }
    function setRoomPass(address p) external onlyOwner { roomPass = IRoomPassView(p); emit RoomPassSet(p); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
