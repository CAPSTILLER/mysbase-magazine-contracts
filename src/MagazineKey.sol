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
/// @dev Two-step commit-reveal mint (no rerolls, works for every wallet type):
///      1. mint(): pays USDC, mints a SEALED key and fixes targetBlock = block.number + REVEAL_DELAY.
///         The outcome depends on blockhash(targetBlock), which does not exist yet, so nothing in the
///         mint tx can compute (and revert on) the result.
///      2. reveal(id) / revealBatch(ids): permissionless after targetBlock. Hash comes from BLOCKHASH
///         (<=256 blocks) or the EIP-2935 history contract (<=8191 blocks, live on Base). Once the target
///         block exists the outcome is fixed; nobody chooses it. If a ticket is somehow left >8191 blocks
///         unrevealed, only the operator (owner / CAPs Mind key) can retarget it - never the holder.
///      Optional IRandomSource (setRandomSource) replaces the hash word at reveal.
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
    uint256 public constant REVEAL_DELAY = 2;
    address public constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935; // EIP-2935
    string public sealedURI;

    struct Ticket { uint64 targetBlock; bool revealed; bytes32 seed; }
    mapping(uint256 => Ticket) public tickets;
    uint256[] private _sealed;
    mapping(uint256 => uint256) private _sealedPos; // tokenId => index+1

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
    event Sealed(uint256 indexed tokenId, address indexed minter, uint256 targetBlock);
    event Revealed(uint256 indexed tokenId, uint256 entryIndex, Rarity rarity, uint8 trait);
    event Retargeted(uint256 indexed tokenId, uint256 targetBlock);
    event SealedURISet(string uri);
    event MintPriceSet(uint256 price);
    event TreasurySet(address treasury);
    event KeySet(address key, uint256 tokenId);
    event RandomSourceSet(address source);
    event RoomPassSet(address pass);

    error ZeroAddress(); error PoolIsLocked(); error PoolNotLocked(); error SoldOut(); error BadTrait();
    error LengthMismatch(); error NotOperator(); error EmptyPool(); error MaxSupply(); error RoomExists(); error NotSealed(); error RevealNotReady(); error HashUnavailable(); error StillRecoverable(); error NoRoom(); error NotOpen();

    constructor(string memory name_, string memory symbol_, address owner_, address usdc_, address treasury_,
        uint256 price_, address key_, uint256 keyTokenId_)
        ERC721(name_, symbol_) Ownable(owner_)
    {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_); treasury = treasury_; mintPrice = price_;
        keyContract = IKeyNFT(key_); keyTokenId = keyTokenId_;
        _pause(); // launches paused; owner calls unpause() when ready
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

    // ---------------- mint (commit) ----------------
    /// @notice Pay mintPrice USDC to treasury and get a SEALED key. Opened by reveal() a few blocks later.
    function mint() external whenNotPaused nonReentrant returns (uint256 tokenId) {
        if (!poolLocked) revert PoolNotLocked();
        if (nextTokenId > _entries.length) revert SoldOut(); // sealed + revealed never exceed pool
        usdc.safeTransferFrom(msg.sender, treasury, mintPrice);
        tokenId = nextTokenId++;
        uint64 target = uint64(block.number + REVEAL_DELAY);
        tickets[tokenId] = Ticket(target, false, keccak256(abi.encode(tokenId, msg.sender, ++_nonce, block.prevrandao)));
        _sealed.push(tokenId); _sealedPos[tokenId] = _sealed.length;
        _safeMint(msg.sender, tokenId);
        emit Sealed(tokenId, msg.sender, target);
    }

    // ---------------- reveal (permissionless) ----------------
    function reveal(uint256 tokenId) public nonReentrant { _reveal(tokenId); }

    /// @notice Reveal many; skips ids that are already revealed or not ready (keeper friendly).
    function revealBatch(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; i++) if (revealReady(ids[i])) _reveal(ids[i]);
    }

    function _reveal(uint256 tokenId) internal {
        Ticket storage t = tickets[tokenId];
        if (t.targetBlock == 0 || t.revealed) revert NotSealed();
        if (block.number <= t.targetBlock) revert RevealNotReady();
        bytes32 h = _hashOf(t.targetBlock);
        if (h == bytes32(0)) revert HashUnavailable();
        // Optional external source (e.g. VRF adapter) replaces the block-hash word when set.
        uint256 r = address(randomSource) != address(0)
            ? randomSource.randomWord(_ownerOf(tokenId), tokenId)
            : uint256(keccak256(abi.encode(h, t.seed, tokenId)));
        uint256 n = _remaining.length;
        uint256 pick = r % n;
        uint32 picked = _remaining[pick];
        _remaining[pick] = _remaining[n - 1];
        _remaining.pop();
        entryOf[tokenId] = picked;
        t.revealed = true;
        uint256 pos = _sealedPos[tokenId]; uint256 last = _sealed[_sealed.length - 1];
        _sealed[pos - 1] = last; _sealedPos[last] = pos; _sealed.pop(); delete _sealedPos[tokenId];
        Entry storage e = _entries[picked];
        emit Revealed(tokenId, picked, e.rarity, e.trait);
    }

    /// @dev blockhash for <=256 back, EIP-2935 history for <=8191 back, else 0.
    function _hashOf(uint256 b) internal view returns (bytes32 h) {
        h = blockhash(b);
        if (h != bytes32(0) || HISTORY.code.length == 0) return h;
        (bool ok, bytes memory ret) = HISTORY.staticcall(abi.encode(b));
        if (ok && ret.length == 32) h = abi.decode(ret, (bytes32));
    }

    /// @notice Only if a ticket's target hash is truly gone (>8191 blocks, keeper was down): operator
    ///         gives it a new future target. Holder can never trigger this, so no reroll choice.
    function retarget(uint256[] calldata ids) external onlyOperator {
        for (uint256 i; i < ids.length; i++) {
            Ticket storage t = tickets[ids[i]];
            if (t.targetBlock == 0 || t.revealed) revert NotSealed();
            if (block.number <= t.targetBlock || _hashOf(t.targetBlock) != bytes32(0)) revert StillRecoverable();
            t.targetBlock = uint64(block.number + REVEAL_DELAY);
            emit Retargeted(ids[i], t.targetBlock);
        }
    }

    function isRevealed(uint256 tokenId) public view returns (bool) { return tickets[tokenId].revealed; }
    function revealReady(uint256 tokenId) public view returns (bool) {
        Ticket storage t = tickets[tokenId];
        return t.targetBlock != 0 && !t.revealed && block.number > t.targetBlock && _hashOf(t.targetBlock) != bytes32(0);
    }
    function sealedCount() external view returns (uint256) { return _sealed.length; }
    /// @notice Page through sealed (unrevealed) token ids for the keeper.
    function pendingReveals(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _sealed.length; if (offset >= n) return ids;
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) ids[i - offset] = _sealed[i];
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
    ///         Sealed keys return trait 0 (ANY), Common and sealedURI. Check isRevealed().
    function keyInfo(uint256 tokenId) external view returns (address holder, Rarity rarity, uint8 trait, string memory uri) {
        holder = _requireOwned(tokenId);
        if (!isRevealed(tokenId)) return (holder, Rarity.Common, 0, sealedURI);
        Entry storage e = _entries[entryOf[tokenId]];
        return (holder, e.rarity, e.trait, e.uri);
    }

    function tokenInfo(uint256 tokenId) external view returns (Rarity rarity, uint8 trait, string memory uri) {
        _requireOwned(tokenId);
        if (!isRevealed(tokenId)) return (Rarity.Common, 0, sealedURI);
        Entry storage e = _entries[entryOf[tokenId]];
        return (e.rarity, e.trait, e.uri);
    }

    /// @notice When this key's access to a room ends. 0 = no access now;
    ///         type(uint256).max = no time limit (Mythic in an Open or ShutDown room).
    function accessEnds(uint256 tokenId, uint256 roomId) public view returns (uint256) {
        _requireOwned(tokenId);
        Room storage r = rooms[roomId];
        if (!r.exists || !isRevealed(tokenId)) return 0; // sealed keys open nothing
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
        if (!isRevealed(tokenId)) return sealedURI;
        return _entries[entryOf[tokenId]].uri;
    }

    // ---------------- owner ----------------
    function setMintPrice(uint256 p) external onlyOwner { mintPrice = p; emit MintPriceSet(p); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setKey(address key, uint256 tokenId) external onlyOwner { keyContract = IKeyNFT(key); keyTokenId = tokenId; emit KeySet(key, tokenId); }
    function setRandomSource(address s) external onlyOwner { randomSource = IRandomSource(s); emit RandomSourceSet(s); }
    function setRoomPass(address p) external onlyOwner { roomPass = IRoomPassView(p); emit RoomPassSet(p); }
    function setSealedURI(string calldata u) external onlyOwner { sealedURI = u; emit SealedURISet(u); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
