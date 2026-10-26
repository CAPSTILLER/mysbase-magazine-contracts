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
        _add(r, t); vm.prank(LEDGER); m.lockPool(); vm.prank(to, to); id = m.mint();
    }
    function _start(uint256 room, uint64 t) internal { vm.prank(LEDGER); m.startRoom(room, t); }

    // ---------- pool ----------
    function test_poolLoadEditLock() public {
        _load(3, false);
        vm.prank(LEDGER); m.setEntryURI(0, "fixed");
        assertEq(m.entry(0).uri, "fixed");
        vm.prank(alice, alice); vm.expectRevert(MagazineKey.PoolNotLocked.selector); m.mint();
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
            vm.prank(alice, alice); uint256 id = m.mint();
            uint256 e = m.entryOf(id); assertFalse(seen[e]); seen[e] = true;
            assertEq(m.tokenURI(id), string.concat("ipfs://e/", vm.toString(e)));
        }
        assertEq(m.remaining(), 0); assertEq(m.balanceOf(alice), n);
        vm.prank(alice, alice); vm.expectRevert(MagazineKey.SoldOut.selector); m.mint();
    }
    function test_swappableRandomSource() public {
        _load(5, true);
        vm.prank(LEDGER); m.setRandomSource(address(rnd));
        rnd.set(3); vm.prank(alice, alice); uint256 id = m.mint(); assertEq(m.entryOf(id), 3);
        vm.prank(alice); vm.expectRevert(); m.setRandomSource(address(0));
    }
    function test_mintPaysTreasury() public {
        _load(2, true);
        uint256 b = usdc.balanceOf(TREASURY);
        vm.prank(alice, alice); m.mint();
        assertEq(usdc.balanceOf(TREASURY) - b, 10e6);
        vm.prank(LEDGER); m.pause();
        vm.prank(alice, alice); vm.expectRevert(Pausable.EnforcedPause.selector); m.mint();
    }

    // ---------- rooms: who can control ----------
    function test_seededRooms() public view {
        for (uint8 i; i <= 7; i++) { (bool ex, uint8 rt,,) = m.rooms(i); assertTrue(ex); assertEq(rt, i); }
    }
    function test_roomControlOwnerAndKeyHolderOnly() public {
        vm.prank(cap); m.createRoom(42, 0);
        vm.prank(cap); m.startRoom(42, T0); assertTrue(m.roomOpen(42));
        vm.prank(cap); m.shutDownRoom(42); assertFalse(m.roomOpen(42));
        vm.prank(LEDGER); m.startRoom(42, T0); assertTrue(m.roomOpen(42));
        vm.startPrank(alice);
        vm.expectRevert(MagazineKey.NotOperator.selector); m.createRoom(43, 0);
        vm.expectRevert(MagazineKey.NotOperator.selector); m.startRoom(42, T0);
        vm.expectRevert(MagazineKey.NotOperator.selector); m.shutDownRoom(42);
        vm.expectRevert(MagazineKey.NotOperator.selector); m.quarantineRoom(42);
        vm.stopPrank();
        // key moves -> control moves
        vm.prank(cap); key.transferFrom(cap, alice, 1);
        vm.prank(alice); m.shutDownRoom(42);
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
        vm.expectRevert(MagazineKey.NoRoom.selector); m.shutDownRoom(99);
        vm.expectRevert(MagazineKey.NoRoom.selector); m.quarantineRoom(99);
        vm.expectRevert(MagazineKey.NotOpen.selector); m.shutDownRoom(0); // never opened
        vm.stopPrank();
    }

    // ---------- windows ----------
    function test_rarityWindows() public {
        _load(4, true); // entries: Common g1, Uncommon g2, Rare g3, Mythic g4
        vm.prank(LEDGER); m.setRandomSource(address(rnd));
        uint256[4] memory ids;
        // remaining list swaps; always pick last so order = 3,2,1,0
        for (uint256 i; i < 4; i++) { rnd.set(3 - i); vm.prank(alice, alice); ids[i] = m.mint(); }
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
        vm.prank(LEDGER); m.shutDownRoom(1);
        assertFalse(m.canEnter(alice, 1));
    }
    function test_mythicFreeReign() public {
        uint256 id = _one(MagazineKey.Rarity.Mythic, 4, alice); // Ocean
        _start(0, T0); _start(4, T0); _start(6, T0); // 6 = Desert, other trait
        vm.warp(T0 + 3650 days);
        assertTrue(m.canEnter(alice, 0)); assertTrue(m.canEnter(alice, 4)); assertTrue(m.canEnter(alice, 6));
        assertEq(m.accessEnds(id, 6), type(uint256).max);
        assertFalse(m.canEnter(alice, 5)); // never started
        vm.prank(cap); m.shutDownRoom(6);
        assertTrue(m.canEnter(alice, 6)); // Mythic in shut-down room
        vm.prank(LEDGER); m.quarantineRoom(6);
        assertFalse(m.canEnter(alice, 6)); assertEq(m.accessEnds(id, 6), 0);
        _start(6, uint64(block.timestamp)); assertTrue(m.canEnter(alice, 6));
    }
    function test_shutDownBlocksNonMythic() public {
        _one(MagazineKey.Rarity.Rare, 1, alice);
        _start(1, T0); assertTrue(m.canEnter(alice, 1));
        vm.prank(LEDGER); m.shutDownRoom(1); assertFalse(m.canEnter(alice, 1));
        vm.prank(LEDGER); m.quarantineRoom(1); assertFalse(m.canEnter(alice, 1));
        _start(1, T0 + 1); vm.warp(T0 + 1); assertTrue(m.canEnter(alice, 1));
    }
    function test_capAlwaysIn() public {
        vm.prank(LEDGER); m.createRoom(55, 3);
        for (uint256 r; r < 3; r++) {
            if (r == 1) _start(55, T0);
            if (r == 2) { vm.prank(LEDGER); m.quarantineRoom(55); }
            assertTrue(m.canEnter(LEDGER, 55)); assertTrue(m.canEnter(cap, 55));
            assertTrue(m.canEnter(cap, 0)); assertFalse(m.canEnter(bob, 55));
        }
        _start(55, T0); vm.prank(LEDGER); m.shutDownRoom(55); assertTrue(m.canEnter(cap, 55));
        vm.prank(cap); key.transferFrom(cap, bob, 1);
        assertFalse(m.canEnter(cap, 55)); assertTrue(m.canEnter(bob, 55));
    }
    function test_viewsForOtherContracts() public {
        uint256 id = _one(MagazineKey.Rarity.Uncommon, 7, alice);
        (address h, MagazineKey.Rarity r, uint8 t, string memory u) = m.keyInfo(id);
        assertEq(h, alice); assertEq(uint8(r), 1); assertEq(t, 7); assertEq(u, "ipfs://e/0");
        (bool ex, MagazineKey.RoomState st, uint8 rt, uint64 s0, bool open) = m.roomState(7);
        assertTrue(ex); assertEq(uint8(st), 0); assertEq(rt, 7); assertEq(s0, 0); assertFalse(open); // Quarantined by default
        _start(7, T0);
        (, st,,, open) = m.roomState(7); assertEq(uint8(st), 1); assertTrue(open);
        vm.prank(LEDGER); m.quarantineRoom(7);
        (, st,,, open) = m.roomState(7); assertEq(uint8(st), 0); assertFalse(open);
    }
    function test_passRefusedWhenNotOpen() public {
        vm.prank(bob); p.buy(3); _start(0, T0);
        vm.prank(LEDGER); m.quarantineRoom(0);
        vm.prank(bob); vm.expectRevert(RoomPass.RoomClosed.selector); p.use(0);
        _start(0, T0 + 1 days); // open but start not reached
        vm.prank(bob); vm.expectRevert(RoomPass.RoomClosed.selector); p.use(0);
        vm.warp(T0 + 1 days); vm.prank(bob); p.use(0); assertTrue(m.canEnter(bob, 0));
        vm.prank(LEDGER); m.quarantineRoom(0); assertFalse(m.canEnter(bob, 0));
        assertEq(p.balanceOf(bob, 1), 2);
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
        _start(0, T0); vm.prank(LEDGER); m.shutDownRoom(0);
        vm.prank(bob); vm.expectRevert(RoomPass.RoomClosed.selector); p.use(0);
        assertEq(p.balanceOf(bob, 1), 2); // nothing burned
    }
    function test_activePassStopsWhenRoomCancelled() public {
        vm.prank(bob); p.buy(1); _start(0, T0);
        vm.prank(bob); p.use(0); assertTrue(m.canEnter(bob, 0));
        vm.prank(cap); m.shutDownRoom(0);
        assertFalse(m.canEnter(bob, 0)); assertFalse(p.hasPassAccess(bob, 0));
    }
    function test_passNeedsBalanceAndRespectsPause() public {
        _start(0, T0);
        vm.prank(bob); vm.expectRevert(); p.use(0);
        vm.prank(bob); vm.expectRevert(RoomPass.ZeroAmount.selector); p.buy(0);
        vm.prank(LEDGER); p.pause();
        vm.prank(bob); vm.expectRevert(Pausable.EnforcedPause.selector); p.buy(1);
    }

    // ---------- round: quarantine default + pass escrow ----------
    function test_quarantinedByDefault() public {
        _one(MagazineKey.Rarity.Mythic, 1, alice);
        vm.prank(bob); p.buy(1);
        for (uint8 i; i <= 7; i++) { (, MagazineKey.RoomState st,,,) = m.roomState(i); assertEq(uint8(st), 0); assertFalse(m.canEnter(alice, i)); assertTrue(m.canEnter(cap, i)); }
        vm.prank(bob); vm.expectRevert(RoomPass.RoomClosed.selector); p.use(0);
    }
    function test_startZeroMeansNow() public {
        vm.warp(T0 + 5); vm.prank(LEDGER); m.startRoom(2, 0);
        (,,, uint64 s0, bool open) = m.roomState(2); assertEq(s0, T0 + 5); assertTrue(open);
    }
    function test_shutdownThenReopenResetsWindows() public {
        uint256 id = _one(MagazineKey.Rarity.Common, 1, alice);
        _start(1, T0);
        vm.warp(T0 + 6 days); vm.prank(LEDGER); m.shutDownRoom(1);
        assertFalse(m.canEnter(alice, 1));
        vm.prank(LEDGER); vm.expectRevert(MagazineKey.NotOpen.selector); m.shutDownRoom(1); // already shut
        vm.warp(T0 + 20 days); _start(1, uint64(block.timestamp));
        assertEq(m.accessEnds(id, 1), T0 + 27 days); assertTrue(m.canEnter(alice, 1));
    }
    function _usePass(uint256 room) internal { vm.prank(bob); p.use(room); }
    function test_passEscrowOnUse() public {
        vm.prank(bob); p.buy(2); _start(0, T0); _start(1, T0);
        _usePass(0);
        assertEq(p.balanceOf(bob, 1), 1); assertEq(p.balanceOf(address(p), 1), 1);
        assertTrue(m.canEnter(bob, 0));
        vm.prank(bob); vm.expectRevert(RoomPass.PassActive.selector); p.use(0); // one active per room
        _usePass(1); assertTrue(m.canEnter(bob, 1)); // other room ok
        assertEq(p.balanceOf(address(p), 1), 2);
    }
    function test_reclaimAfterShutdown() public {
        vm.prank(bob); p.buy(1); _start(0, T0); _usePass(0);
        vm.warp(T0 + 10 hours); vm.prank(cap); m.shutDownRoom(0);
        assertFalse(m.canEnter(bob, 0)); // access off immediately
        assertTrue(p.reclaimable(bob, 0)); assertFalse(p.burnable(bob, 0));
        vm.warp(T0 + 30 days); // still reclaimable later
        vm.prank(alice); p.reclaim(bob, 0); // anyone on bob's behalf
        assertEq(p.balanceOf(bob, 1), 1); assertEq(p.balanceOf(address(p), 1), 0);
        vm.expectRevert(RoomPass.NotReclaimable.selector); p.reclaim(bob, 0); // no double
        _start(0, uint64(block.timestamp)); _usePass(0); assertTrue(m.canEnter(bob, 0)); // usable again
    }
    function test_reclaimAfterQuarantine() public {
        vm.prank(bob); p.buy(1); _start(3, T0); _usePass(3);
        vm.prank(LEDGER); m.quarantineRoom(3);
        assertFalse(m.canEnter(bob, 3));
        p.reclaim(bob, 3); assertEq(p.balanceOf(bob, 1), 1);
        _start(3, T0); _usePass(3); assertTrue(m.canEnter(bob, 3));
    }
    function test_noReclaimAfterExpiryThenBurn() public {
        vm.prank(bob); p.buy(1); _start(0, T0); _usePass(0);
        vm.warp(T0 + 24 hours); assertFalse(m.canEnter(bob, 0));
        vm.prank(LEDGER); m.shutDownRoom(0); // close after expiry
        assertFalse(p.reclaimable(bob, 0)); assertTrue(p.burnable(bob, 0));
        vm.expectRevert(RoomPass.NotReclaimable.selector); p.reclaim(bob, 0);
        vm.prank(alice); p.burnExpired(bob, 0);
        assertEq(p.balanceOf(address(p), 1), 0); assertEq(p.balanceOf(bob, 1), 0);
        vm.expectRevert(RoomPass.NotExpired.selector); p.burnExpired(bob, 0);
    }
    function test_burnExpiredRefusedWhileActive() public {
        vm.prank(bob); p.buy(1); _start(0, T0); _usePass(0);
        vm.expectRevert(RoomPass.NotExpired.selector); p.burnExpired(bob, 0);
    }
    function test_useAutoBurnsExpired() public {
        vm.prank(bob); p.buy(2); _start(0, T0); _usePass(0);
        vm.warp(T0 + 25 hours); _usePass(0);
        assertEq(p.balanceOf(address(p), 1), 1); assertEq(p.balanceOf(bob, 1), 0);
        assertTrue(m.canEnter(bob, 0));
    }
    function test_useAutoReclaimsClosedDeposit() public {
        vm.prank(bob); p.buy(1); _start(0, T0); _usePass(0);
        vm.prank(LEDGER); m.quarantineRoom(0); _start(0, T0);
        _usePass(0); // old pass returned then re-escrowed
        assertEq(p.balanceOf(address(p), 1), 1); assertTrue(m.canEnter(bob, 0));
    }

    function test_maxSupply10000() public {
        assertEq(m.MAX_SUPPLY(), 10_000);
        uint256 b = 1000;
        MagazineKey.Rarity[] memory r = new MagazineKey.Rarity[](b); uint8[] memory t = new uint8[](b); string[] memory u = new string[](b);
        for (uint256 i; i < b; i++) t[i] = 1;
        vm.startPrank(LEDGER);
        for (uint256 k; k < 10; k++) m.addEntries(r, t, u);
        assertEq(m.poolSize(), 10_000);
        MagazineKey.Rarity[] memory r1 = new MagazineKey.Rarity[](1); uint8[] memory t1 = new uint8[](1); string[] memory u1 = new string[](1); t1[0] = 1;
        vm.expectRevert(MagazineKey.MaxSupply.selector); m.addEntries(r1, t1, u1);
        vm.stopPrank();
    }
    function test_maxSupplySingleBatchOver() public {
        uint256 b = 10_001;
        MagazineKey.Rarity[] memory r = new MagazineKey.Rarity[](b); uint8[] memory t = new uint8[](b); string[] memory u = new string[](b);
        vm.prank(LEDGER); vm.expectRevert(MagazineKey.MaxSupply.selector); m.addEntries(r, t, u);
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
        vm.prank(cap, cap); m.mint();
        assertEq(usdc.balanceOf(bob) - b, 5e6);
        vm.prank(bob); vm.expectRevert(); m.setMintPrice(1);
        vm.prank(bob); vm.expectRevert(); p.setPrice(1);
    }
    function test_constructorNameConfigurable() public {
        MagazineKey k = new MagazineKey("Other", "OTH", LEDGER, address(usdc), TREASURY, 1, address(key), 1);
        assertEq(k.name(), "Other"); assertEq(m.name(), "Mysbase Magazine Key") /* test instance name */;
    }

    // ---------- anti-reroll ----------
    function test_mint_rejectsContractCaller() public {
        _add(MagazineKey.Rarity.Common, 1); vm.prank(LEDGER); m.lockPool();
        Reroller c = new Reroller(m);
        usdc.mint(address(c), 100e6);
        vm.prank(alice, alice); vm.expectRevert(MagazineKey.ContractCallerNotAllowed.selector); c.go();
    }
    function test_mint_eoaSucceeds() public {
        _add(MagazineKey.Rarity.Common, 1); vm.prank(LEDGER); m.lockPool();
        vm.prank(alice, alice); uint256 id = m.mint(); assertEq(m.ownerOf(id), alice);
    }
    function test_mint_rejects7702DelegatedEoa() public {
        _add(MagazineKey.Rarity.Common, 1); vm.prank(LEDGER); m.lockPool();
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(0xBEEF))); // 7702-style delegation designator
        vm.prank(alice, alice); vm.expectRevert(MagazineKey.ContractCallerNotAllowed.selector); m.mint();
    }
    function test_mint_rejectsSpoofedOriginMismatch() public {
        _add(MagazineKey.Rarity.Common, 1); vm.prank(LEDGER); m.lockPool();
        vm.prank(alice, bob); vm.expectRevert(MagazineKey.ContractCallerNotAllowed.selector); m.mint();
    }
}

contract Reroller {
    MagazineKey m;
    constructor(MagazineKey _m) { m = _m; }
    function go() external { Mock6(address(m.usdc())).approve(address(m), type(uint256).max); m.mint(); }
}
