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
    function randomWord(address minter, uint256 issueId, uint256 nonce) external returns (uint256);
}

interface IKeyNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title Mysbase Magazine Issue — rarity-gated room access NFTs.
/// @dev Randomness: by default uses block.prevrandao + blockhash + nonce + minter. On Base the
///      sequencer produces blocks and could in theory bias/choose outcomes, and a contract caller
///      can simulate and revert unwanted pulls. Acceptable for a fun pull, not for high-value odds.
///      Owner can plug in an IRandomSource (VRF adapter) later via setRandomSource.
contract MagazineIssue is ERC721Enumerable, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Rarity { Common, Uncommon, Rare, Mythic }

    /// Room ids: 0 = the issue's main room (any holder of the issue), 1..7 = trait rooms.
    uint8 public constant MAIN_ROOM = 0;
    uint8 public constant GRASS = 1;
    uint8 public constant MOUNTAIN = 2;
    uint8 public constant SNOWY_TUNDRA = 3;
    uint8 public constant OCEAN = 4;
    uint8 public constant OUTER_SPACE = 5;
    uint8 public constant DESERT = 6;
    uint8 public constant FOREST = 7;

    struct Entry { Rarity rarity; uint8 trait; string uri; }
    struct Issue { bool exists; bool locked; uint64 startTime; uint32 size; uint32 minted; }

    IERC20 public immutable usdc;
    address public treasury;
    uint256 public mintPrice; // 6 decimals
    IKeyNFT public keyContract;
    uint256 public keyTokenId;
    IRandomSource public randomSource;

    uint256 public nextTokenId = 1;
    uint256 private _nonce;

    mapping(uint256 => Issue) public issues;
    mapping(uint256 => Entry[]) private _entries;      // issueId => all entries
    mapping(uint256 => uint32[]) private _remaining;   // issueId => unminted entry indexes
    mapping(uint256 => uint256) public issueOf;        // tokenId => issueId
    mapping(uint256 => uint32) public entryOf;         // tokenId => entry index

    event IssueCreated(uint256 indexed issueId);
    event EntriesAdded(uint256 indexed issueId, uint256 from, uint256 count);
    event PoolLocked(uint256 indexed issueId, uint256 size);
    event IssueStarted(uint256 indexed issueId, uint256 startTime, address by);
    event Minted(address indexed to, uint256 indexed tokenId, uint256 indexed issueId, uint256 entry, Rarity rarity, uint8 trait);
    event MintPriceSet(uint256 price);
    event TreasurySet(address treasury);
    event KeySet(address key, uint256 tokenId);
    event RandomSourceSet(address source);

    error ZeroAddress(); error BadIssue(); error IssueExists(); error PoolIsLocked(); error PoolNotLocked();
    error SoldOut(); error BadTrait(); error LengthMismatch(); error NotOperator(); error EmptyPool();

    constructor(address owner_, address usdc_, address treasury_, uint256 price_, address key_, uint256 keyTokenId_)
        ERC721("Mysbase Magazine", "MYSMAG") Ownable(owner_)
    {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_); treasury = treasury_; mintPrice = price_;
        keyContract = IKeyNFT(key_); keyTokenId = keyTokenId_;
    }

    // ---------------- pool setup (owner) ----------------
    function createIssue(uint256 issueId) external onlyOwner {
        if (issues[issueId].exists) revert IssueExists();
        issues[issueId].exists = true;
        emit IssueCreated(issueId);
    }

    function addEntries(uint256 issueId, Rarity[] calldata rarities, uint8[] calldata traits, string[] calldata uris) external onlyOwner {
        Issue storage s = issues[issueId];
        if (!s.exists) revert BadIssue();
        if (s.locked) revert PoolIsLocked();
        if (rarities.length != traits.length || traits.length != uris.length) revert LengthMismatch();
        uint256 from = _entries[issueId].length;
        for (uint256 i; i < traits.length; i++) {
            if (traits[i] < GRASS || traits[i] > FOREST) revert BadTrait();
            _entries[issueId].push(Entry(rarities[i], traits[i], uris[i]));
            _remaining[issueId].push(uint32(from + i));
        }
        s.size = uint32(_entries[issueId].length);
        emit EntriesAdded(issueId, from, traits.length);
    }

    /// @notice Fix a mistaken entry URI before locking.
    function setEntryURI(uint256 issueId, uint256 idx, string calldata uri) external onlyOwner {
        if (issues[issueId].locked) revert PoolIsLocked();
        _entries[issueId][idx].uri = uri;
    }

    function lockPool(uint256 issueId) external onlyOwner {
        Issue storage s = issues[issueId];
        if (!s.exists) revert BadIssue();
        if (s.size == 0) revert EmptyPool();
        s.locked = true;
        emit PoolLocked(issueId, s.size);
    }

    // ---------------- access clock ----------------
    function isOperator(address a) public view returns (bool) {
        if (a == owner()) return true;
        if (address(keyContract).code.length == 0) return false;
        try keyContract.ownerOf(keyTokenId) returns (address h) { return h == a; } catch { return false; }
    }

    /// @notice Start or restart/adjust an issue's access clock. Owner or current CAPs Mind key holder.
    function startIssue(uint256 issueId, uint64 startTime) external {
        if (!isOperator(msg.sender)) revert NotOperator();
        if (!issues[issueId].exists) revert BadIssue();
        issues[issueId].startTime = startTime;
        emit IssueStarted(issueId, startTime, msg.sender);
    }

    // ---------------- mint ----------------
    function mint(uint256 issueId) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        Issue storage s = issues[issueId];
        if (!s.locked) revert PoolNotLocked();
        uint32[] storage rem = _remaining[issueId];
        uint256 n = rem.length;
        if (n == 0) revert SoldOut();
        usdc.safeTransferFrom(msg.sender, treasury, mintPrice);
        uint256 r = _random(issueId);
        uint256 pick = r % n;
        uint32 picked = rem[pick];
        rem[pick] = rem[n - 1];
        rem.pop();
        s.minted++;
        tokenId = nextTokenId++;
        issueOf[tokenId] = issueId;
        entryOf[tokenId] = picked;
        _safeMint(msg.sender, tokenId);
        Entry storage e = _entries[issueId][picked];
        emit Minted(msg.sender, tokenId, issueId, picked, e.rarity, e.trait);
    }

    function _random(uint256 issueId) internal returns (uint256) {
        uint256 nonce = ++_nonce;
        if (address(randomSource) != address(0)) return randomSource.randomWord(msg.sender, issueId, nonce);
        return uint256(keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), nonce, msg.sender, issueId)));
    }

    // ---------------- views ----------------
    function durationOf(Rarity r) public pure returns (uint256) {
        if (r == Rarity.Common) return 7 days;
        if (r == Rarity.Uncommon) return 14 days;
        if (r == Rarity.Rare) return 30 days;
        return type(uint256).max;
    }

    function entry(uint256 issueId, uint256 idx) external view returns (Entry memory) { return _entries[issueId][idx]; }
    function remaining(uint256 issueId) external view returns (uint256) { return _remaining[issueId].length; }

    function tokenInfo(uint256 tokenId) public view returns (uint256 issueId, Rarity rarity, uint8 trait, uint256 ends, bool active) {
        _requireOwned(tokenId);
        issueId = issueOf[tokenId];
        Entry storage e = _entries[issueId][entryOf[tokenId]];
        rarity = e.rarity; trait = e.trait;
        ends = accessEnds(tokenId);
        uint64 st = issues[issueId].startTime;
        active = st != 0 && block.timestamp >= st && block.timestamp < ends;
    }

    /// @notice 0 = issue not started; type(uint256).max = forever (Mythic). Access is active while start <= now < ends.
    function accessEnds(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        uint256 issueId = issueOf[tokenId];
        uint64 st = issues[issueId].startTime;
        if (st == 0) return 0;
        uint256 d = durationOf(_entries[issueId][entryOf[tokenId]].rarity);
        return d == type(uint256).max ? d : st + d;
    }

    function canEnter(address wallet, uint256 issueId, uint8 room) external view returns (bool) {
        uint256 n = balanceOf(wallet);
        for (uint256 i; i < n; i++) {
            uint256 id = tokenOfOwnerByIndex(wallet, i);
            if (issueOf[id] != issueId) continue;
            (, , uint8 trait, , bool active) = tokenInfo(id);
            if (active && (room == MAIN_ROOM || room == trait)) return true;
        }
        return false;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _entries[issueOf[tokenId]][entryOf[tokenId]].uri;
    }

    // ---------------- owner ----------------
    function setMintPrice(uint256 p) external onlyOwner { mintPrice = p; emit MintPriceSet(p); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setKey(address key, uint256 tokenId) external onlyOwner { keyContract = IKeyNFT(key); keyTokenId = tokenId; emit KeySet(key, tokenId); }
    function setRandomSource(address s) external onlyOwner { randomSource = IRandomSource(s); emit RandomSourceSet(s); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
