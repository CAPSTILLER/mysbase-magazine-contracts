// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {Test} from "forge-std/Test.sol";
import {MagazineKey, IRandomSource} from "../src/MagazineKey.sol";
import {RoomPass} from "../src/RoomPass.sol";
import {Mock6, MockKey} from "./Mocks.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract FixedRandom is IRandomSource { uint256 public w; function set(uint256 x) external { w = x; } function randomWord(address, uint256) external view returns (uint256) { return w; } }

contract MagazineKeyTest is Test {
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant TREASURY = 0xCF1ac98565DA846E8263604b49C1276Ed78A0981;
    address alice = address(0xA11CE); address bob = address(0xB0B); address cap = address(0xCA9);
    Mock6 usdc; MockKey key; MagazineKey m; RoomPass p; FixedRandom rnd;
    uint64 T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        usdc = new Mock6(); key = new MockKey(); key.mint(cap, 1); rnd = new FixedRandom();
        m = new MagazineKey("Mysbase Magazine Key", "MYSKEY", LEDGER, address(usdc), TREASURY, 10e6, address(key), 1);
        p = new RoomPass(LEDGER, address(usdc), TREASURY, 1e6, address(m), "ipfs://pass/{id}.json");
        vm.startPrank(LEDGER); m.setRoomPass(address(p)); m.seedDefaultRooms(); vm.stopPrank();
        address[3] memory us = [alice, bob, cap];
        for (uint256 i; i < 3; i++) { usdc.mint(us[i], 1_000_000e6); vm.startPrank(us[i]); usdc.approve(address(m), type(uint256).max); usdc.approve(address(p), type(uint256).max); vm.stopPrank(); }
    }

    function _add(MagazineKey.Rarity rr, uint8 t) internal {
        MagazineKey.Rarity[] memory r = new MagazineKey.Rarity[](1); uint8[] memory tt = new uint8[](1); string[] memory u = new string[](1);
        r[0] = rr; tt[0] = t; u[0] = string.concat("ipfs://e/", vm.toString(m.poolSize()));
        vm.prank(LEDGER); m.addEntries(r, tt, u);
    }
    // n entries: rarity i%4, trait 1+i%7
    function _load(uint256 n, bool lock) internal {
        for (uint256 i; i < n; i++) _add(MagazineKey.Rarity(i % 4), uint8(1 + i % 7));
        if (lock) { vm.prank(LEDGER); m.lockPool(); }
    }
    // single deterministic entry, minted to `to`
    function _one(MagazineKey.Rarity r, uint8 t, address to) internal returns (uint256 id) {
        _add(r, t); vm.prank(LEDGER); m.lockPool(); vm.prank(to); id = m.mint();
    }
    function _start(uint256 room, uint64 t) internal { vm.prank(LEDGER); m.startRoom(room, t); }

    // ---------- pool ----------
    function test_poolLoadEditLock() public {
        _load(3, false);
        vm.prank(LEDGER); m.setEntryURI(0, "fixed");
        assertEq(m.entry(0).uri, "fixed");
        vm.prank(alice); vm.expectRevert(MagazineKey.PoolNotLocked.selector); m.mint();
        vm.prank(LEDGER); m.lockPool();
        vm.startPrank(LEDGER);
        vm.expectRevert(MagazineKey.PoolIsLocked.selector); m.setEntryURI(0, "x");
        MagazineKey.Rarity[] memory r = new MagazineKey.Rarity[](1); uint8[] memory t = new uint8[](1); string[] memory u = new string[](1); t[0] = 1;
        vm.expectRevert(MagazineKey.PoolIsLocked.selector); m.addEntries(r, t, u);
        vm.stopPrank();
    }
    function test_poolRejectsBadInput() public {
        MagazineKey.Rarity[] memory r = new MagazineKey.Rarity[](1); uint8[] memory t = new uint8[](1); string[] memory u = new string[](1);
        vm.startPrank(LEDGER);
        vm.expectRevert(MagazineKey.BadTrait.selector); m.addEntries(r, t, u); // trait 0
        t[0] = 8; vm.expectRevert(MagazineKey.BadTrait.selector); m.addEntries(r, t, u);
        vm.expectRevert(MagazineKey.LengthMismatch.selector); m.addEntries(r, new uint8[](2), u);
        vm.expectRevert(MagazineKey.EmptyPool.selector); m.lockPool();
        vm.stopPrank();
        vm.prank(alice); vm.expectRevert(); m.addEntries(r, t, u);
    }

    function test_randomPullExhaustsPoolExactlyOnce() public {
        uint256 n = 20; _load(n, true);
        bool[] memory seen = new bool[](n);
        for (uint256 i; i < n; i++) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode(i)))));
            vm.prank(alice); uint256 id = m.mint();
            uint256 e = m.entryOf(id); assertFalse(seen[e]); seen[e] = true;
            assertEq(m.tokenURI(id), string.concat("ipfs://e/", vm.toString(e)));
        }
        assertEq(m.remaining(), 0); assertEq(m.balanceOf(alice), n);
        vm.prank(alice); vm.expectRevert(MagazineKey.SoldOut.selector); m.mint();
    }
    function test_swappableRandomSource() public {
        _load(5, true);
        vm.prank(LEDGER); m.setRandomSource(address(rnd));
        rnd.set(3); vm.prank(alice); uint256 id = m.mint(); assertEq(m.entryOf(id), 3);
        vm.prank(alice); vm.expectRevert(); m.setRandomSource(address(0));
    }
    function test_mintPaysTreasury() public {
        _load(2, true);
        uint256 b = usdc.balanceOf(TREASURY);
        vm.prank(alice); m.mint();
        assertEq(usdc.balanceOf(TREASURY) - b, 10e6);
        vm.prank(LEDGER); m.pause();
        vm.prank(alice); vm.expectRevert(Pausable.EnforcedPause.selector); m.mint();
    }

    // ---------- rooms: who can control ----------
    function test_seededRooms() public view {
        for (uint8 i; i <= 7; i++) { (bool ex, uint8 rt,,) = m.rooms(i); assertTrue(ex); assertEq(rt, i); }
    }
    function test_roomControlOwnerAndKeyHolderOnly() public {
        vm.prank(cap); m.createRoom(42, 0);
        vm.prank(cap); m.startRoom(42, T0); assertTrue(m.roomOpen(42));
        vm.prank(cap); m.cancelRoom(42); assertFalse(m.roomOpen(42));
        vm.prank(LEDGER); m.startRoom(42, T0); assertTrue(m.roomOpen(42));
        vm.startPrank(alice);
        vm.expectRevert(MagazineKey.NotOperator.selector); m.createRoom(43, 0);
        vm.expectRevert(MagazineKey.NotOperator.selector); m.startRoom(42, T0);
        vm.expectRevert(MagazineKey.NotOperator.selector); m.cancelRoom(42);
        vm.stopPrank();
        // key moves -> control moves
        vm.prank(cap); key.transferFrom(cap, alice, 1);
        vm.prank(alice); m.cancelRoom(42);
        vm.prank(cap); vm.expectRevert(MagazineKey.NotOperator.selector); m.startRoom(42, T0);
        // setKey retargets token id
        key.mint(bob, 9); vm.prank(LEDGER); m.setKey(address(key), 9);
        vm.prank(bob); m.startRoom(42, T0);
    }
    function test_roomErrors() public {
        vm.startPrank(LEDGER);
        vm.expectRevert(MagazineKey.RoomExists.selector); m.createRoom(0, 0);
        vm.expectRevert(MagazineKey.BadTrait.selector); m.createRoom(50, 8);
        vm.expectRevert(MagazineKey.NoRoom.selector); m.startRoom(99, T0);
        vm.expectRevert(MagazineKey.NoRoom.selector); m.cancelRoom(99);
        vm.expectRevert(MagazineKey.BadStart.selector); m.startRoom(0, 0);
        vm.stopPrank();
    }

    // ---------- windows ----------
    function test_rarityWindows() public {
        _load(4, true); // entries: Common g1, Uncommon g2, Rare g3, Mythic g4
        vm.prank(LEDGER); m.setRandomSource(address(rnd));
        uint256[4] memory ids;
        // remaining list swaps; always pick last so order = 3,2,1,0
        for (uint256 i; i < 4; i++) { rnd.set(3 - i); vm.prank(alice); ids[i] = m.mint(); }
        _start(0, T0);
        uint256[4] memory dur = [uint256(7 days), 14 days, 30 days, type(uint256).max];
        for (uint256 i; i < 4; i++) {
            uint256 id = ids[i]; (MagazineKey.Rarity r,,) = m.tokenInfo(id);
            uint256 d = dur[uint8(r)];
            assertEq(m.accessEnds(id, 0), d == type(uint256).max ? d : T0 + d);
        }
        vm.warp(T0 + 365 days * 5);
        uint256 alive;
        for (uint256 i; i < 4; i++) if (m.keyCanEnter(ids[i], 0)) { alive++; (MagazineKey.Rarity r,,) = m.tokenInfo(ids[i]); assertEq(uint8(r), 3); }
        assertEq(alive, 1);
    }
    function test_commonExpiresThenResetGivesFreshWindow() public {
        uint256 id = _one(MagazineKey.Rarity.Common, 1, alice);
        assertFalse(m.canEnter(alice, 0)); // not started
        _start(0, T0);
        assertTrue(m.canEnter(alice, 0));
        vm.warp(T0 + 7 days - 1); assertTrue(m.canEnter(alice, 0));
        vm.warp(T0 + 7 days); assertFalse(m.canEnter(alice, 0));
        uint64 t2 = uint64(block.timestamp);
        vm.prank(cap); m.startRoom(0, t2); // key holder resets
        assertEq(m.accessEnds(id, 0), t2 + 7 days);
        assertTrue(m.canEnter(alice, 0));
    }
    function test_futureStartNotYetOpen() public {
        _one(MagazineKey.Rarity.Rare, 1, alice);
        _start(0, T0 + 1 days);
        assertFalse(m.canEnter(alice, 0));
        vm.warp(T0 + 1 days); assertTrue(m.canEnter(alice, 0));
        vm.warp(T0 + 31 days); assertFalse(m.canEnter(alice, 0));
    }
    function test_roomsHaveIndependentTimers() public {
        _one(MagazineKey.Rarity.Common, 1, alice); // Grass
        _start(0, T0); _start(1, T0 + 5 days);
        vm.warp(T0 + 8 days);
        assertFalse(m.canEnter(alice, 0)); assertTrue(m.canEnter(alice, 1));
        vm.prank(LEDGER); m.cancelRoom(1);
        assertFalse(m.canEnter(alice, 1));
    }
    function test_mythicForeverButCancelBlocks() public {
        _one(MagazineKey.Rarity.Mythic, 4, alice);
        _start(0, T0); _start(4, T0);
        vm.warp(T0 + 3650 days);
        assertTrue(m.canEnter(alice, 0)); assertTrue(m.canEnter(alice, 4));
        vm.prank(cap); m.cancelRoom(4);
        assertFalse(m.canEnter(alice, 4)); assertTrue(m.canEnter(alice, 0));
        assertEq(m.accessEnds(1, 4), 0);
        _start(4, uint64(block.timestamp)); assertTrue(m.canEnter(alice, 4));
    }

    // ---------- trait gating & transfer ----------
    function test_traitGating() public {
        _one(MagazineKey.Rarity.Rare, 5, alice); // Outer Space
        for (uint8 i; i <= 7; i++) _start(i, T0);
        for (uint8 i; i <= 7; i++) assertEq(m.canEnter(alice, i), i == 0 || i == 5);
        vm.prank(LEDGER); m.createRoom(100, 5); _start(100, T0);
        vm.prank(LEDGER); m.createRoom(101, 0); _start(101, T0);
        vm.prank(LEDGER); m.createRoom(102, 6); _start(102, T0);
        assertTrue(m.canEnter(alice, 100)); assertTrue(m.canEnter(alice, 101)); assertFalse(m.canEnter(alice, 102));
        assertFalse(m.canEnter(bob, 0));
    }
    function test_transferMovesAccess() public {
        uint256 id = _one(MagazineKey.Rarity.Uncommon, 2, alice);
        _start(0, T0);
        assertTrue(m.canEnter(alice, 0));
        vm.prank(alice); m.transferFrom(alice, bob, id);
        assertFalse(m.canEnter(alice, 0)); assertTrue(m.canEnter(bob, 0));
        assertEq(m.accessEnds(id, 0), T0 + 14 days); // window tied to room clock, not owner
    }

    // ---------- RoomPass ----------
    function test_passBuyUseExpire() public {
        uint256 b = usdc.balanceOf(TREASURY);
        vm.prank(bob); p.buy(3);
        assertEq(usdc.balanceOf(TREASURY) - b, 3e6); assertEq(p.balanceOf(bob, 1), 3);
        _start(3, T0);
        assertFalse(m.canEnter(bob, 3));
        vm.prank(bob); p.use(3);
        assertEq(p.balanceOf(bob, 1), 2);
        assertTrue(m.canEnter(bob, 3)); assertFalse(m.canEnter(bob, 0)); // one room only
        vm.warp(T0 + 24 hours - 1); assertTrue(m.canEnter(bob, 3));
        vm.warp(T0 + 24 hours); assertFalse(m.canEnter(bob, 3));
    }
    function test_passRefusedInClosedRooms() public {
        vm.prank(bob); p.buy(2);
        vm.prank(bob); vm.expectRevert(RoomPass.RoomClosed.selector); p.use(0); // never started
        vm.prank(bob); vm.expectRevert(RoomPass.RoomClosed.selector); p.use(77); // no room
        _start(0, T0); vm.prank(LEDGER); m.cancelRoom(0);
        vm.prank(bob); vm.expectRevert(RoomPass.RoomClosed.selector); p.use(0);
        assertEq(p.balanceOf(bob, 1), 2); // nothing burned
    }
    function test_activePassStopsWhenRoomCancelled() public {
        vm.prank(bob); p.buy(1); _start(0, T0);
        vm.prank(bob); p.use(0); assertTrue(m.canEnter(bob, 0));
        vm.prank(cap); m.cancelRoom(0);
        assertFalse(m.canEnter(bob, 0)); assertFalse(p.hasPassAccess(bob, 0));
    }
    function test_passNeedsBalanceAndRespectsPause() public {
        _start(0, T0);
        vm.prank(bob); vm.expectRevert(); p.use(0);
        vm.prank(bob); vm.expectRevert(RoomPass.ZeroAmount.selector); p.buy(0);
        vm.prank(LEDGER); p.pause();
        vm.prank(bob); vm.expectRevert(Pausable.EnforcedPause.selector); p.buy(1);
    }

    // ---------- admin ----------
    function test_ownerSettersAndTwoStep() public {
        _add(MagazineKey.Rarity.Common, 1);
        vm.startPrank(LEDGER);
        m.setMintPrice(5e6); m.setTreasury(bob);
        vm.expectRevert(MagazineKey.ZeroAddress.selector); m.setTreasury(address(0));
        m.transferOwnership(alice);
        vm.stopPrank();
        assertEq(m.owner(), LEDGER);
        vm.prank(alice); m.acceptOwnership(); assertEq(m.owner(), alice);
        vm.prank(alice); m.lockPool();
        uint256 b = usdc.balanceOf(bob);
        vm.prank(cap); m.mint();
        assertEq(usdc.balanceOf(bob) - b, 5e6);
        vm.prank(bob); vm.expectRevert(); m.setMintPrice(1);
        vm.prank(bob); vm.expectRevert(); p.setPrice(1);
    }
    function test_constructorNameConfigurable() public {
        MagazineKey k = new MagazineKey("Other", "OTH", LEDGER, address(usdc), TREASURY, 1, address(key), 1);
        assertEq(k.name(), "Other"); assertEq(m.name(), "Mysbase Magazine Key");
    }
}
