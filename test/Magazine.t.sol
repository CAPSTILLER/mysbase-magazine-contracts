// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {Test} from "forge-std/Test.sol";
import {MagazineIssue} from "../src/MagazineIssue.sol";
import {RoomPass} from "../src/RoomPass.sol";
import {Mock6, MockKey} from "./Mocks.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MagazineTest is Test {
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant TREASURY = 0xCF1ac98565DA846E8263604b49C1276Ed78A0981;
    address alice = address(0xA11CE); address bob = address(0xB0B); address cap = address(0xCA9);
    Mock6 usdc; MockKey key; MagazineIssue m; RoomPass p;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new Mock6(); key = new MockKey(); key.mint(cap, 1);
        m = new MagazineIssue(LEDGER, address(usdc), TREASURY, 10e6, address(key), 1);
        p = new RoomPass(LEDGER, address(usdc), TREASURY, 1e6, "ipfs://pass/{id}.json");
        address[3] memory us = [alice, bob, cap];
        for (uint256 i; i < 3; i++) { usdc.mint(us[i], 1_000_000e6); vm.startPrank(us[i]); usdc.approve(address(m), type(uint256).max); usdc.approve(address(p), type(uint256).max); vm.stopPrank(); }
    }

    // pool: n entries; rarity = i % 4, trait = 1 + i % 7
    function _load(uint256 issueId, uint256 n, bool lock) internal {
        vm.startPrank(LEDGER);
        m.createIssue(issueId);
        MagazineIssue.Rarity[] memory r = new MagazineIssue.Rarity[](n); uint8[] memory t = new uint8[](n); string[] memory u = new string[](n);
        for (uint256 i; i < n; i++) { r[i] = MagazineIssue.Rarity(i % 4); t[i] = uint8(1 + i % 7); u[i] = string.concat("ipfs://e/", vm.toString(i)); }
        m.addEntries(issueId, r, t, u);
        if (lock) m.lockPool(issueId);
        vm.stopPrank();
    }

    function _mintAs(address a, uint256 issueId) internal returns (uint256 id) { vm.prank(a); id = m.mint(issueId); }

    function test_poolLoadBatchesAndLock() public {
        _load(1, 5, false);
        MagazineIssue.Rarity[] memory r = new MagazineIssue.Rarity[](1); uint8[] memory t = new uint8[](1); string[] memory u = new string[](1);
        r[0] = MagazineIssue.Rarity.Mythic; t[0] = 7; u[0] = "x";
        vm.prank(LEDGER); m.addEntries(1, r, t, u);
        assertEq(m.remaining(1), 6);
        vm.prank(alice); vm.expectRevert(MagazineIssue.PoolNotLocked.selector); m.mint(1);
        vm.prank(alice); vm.expectRevert(); m.addEntries(1, r, t, u); // not owner
        t[0] = 8; vm.prank(LEDGER); vm.expectRevert(MagazineIssue.BadTrait.selector); m.addEntries(1, r, t, u);
        t[0] = 0; vm.prank(LEDGER); vm.expectRevert(MagazineIssue.BadTrait.selector); m.addEntries(1, r, t, u);
        vm.prank(LEDGER); m.lockPool(1);
        t[0] = 7; vm.prank(LEDGER); vm.expectRevert(MagazineIssue.PoolIsLocked.selector); m.addEntries(1, r, t, u);
        vm.prank(LEDGER); vm.expectRevert(MagazineIssue.PoolIsLocked.selector); m.setEntryURI(1, 0, "y");
        vm.prank(LEDGER); m.createIssue(2);
        vm.prank(LEDGER); vm.expectRevert(MagazineIssue.EmptyPool.selector); m.lockPool(2);
        vm.prank(LEDGER); vm.expectRevert(MagazineIssue.IssueExists.selector); m.createIssue(2);
    }

    function test_noDoublePullSoldOutAndPayment() public {
        _load(1, 40, true);
        bool[] memory seen = new bool[](40);
        for (uint256 i; i < 40; i++) {
            vm.prevrandao(bytes32(i * 7919)); vm.roll(block.number + 1);
            uint256 id = _mintAs(alice, 1);
            uint256 e = m.entryOf(id);
            assertFalse(seen[e]); seen[e] = true;
            assertEq(m.tokenURI(id), string.concat("ipfs://e/", vm.toString(e)));
        }
        assertEq(m.totalSupply(), 40); assertEq(m.remaining(1), 0);
        assertEq(usdc.balanceOf(TREASURY), 400e6);
        assertEq(usdc.balanceOf(address(m)), 0);
        vm.prank(alice); vm.expectRevert(MagazineIssue.SoldOut.selector); m.mint(1);
    }

    function test_randomDistributionSanity() public {
        // 400 entries: 100 of each rarity. First 100 pulls should hit every rarity, none dominating.
        _load(1, 400, true);
        uint256[4] memory c;
        for (uint256 i; i < 100; i++) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode(i))))); vm.roll(block.number + 1);
            uint256 id = _mintAs(i % 2 == 0 ? alice : bob, 1);
            (, MagazineIssue.Rarity r,,,) = m.tokenInfo(id);
            c[uint8(r)]++;
        }
        for (uint256 k; k < 4; k++) { assertGt(c[k], 10); assertLt(c[k], 45); }
    }

    function test_multipleIssuesIndependent() public {
        _load(1, 3, true); _load(2, 2, true);
        uint256 a = _mintAs(alice, 2);
        assertEq(m.issueOf(a), 2); assertEq(m.remaining(2), 1); assertEq(m.remaining(1), 3);
    }

    function _find(uint256 issueId, MagazineIssue.Rarity want, uint256 n) internal returns (uint256) {
        for (uint256 i; i < n; i++) {
            vm.prevrandao(bytes32(i + 1)); vm.roll(block.number + 1);
            uint256 id = _mintAs(alice, issueId);
            (, MagazineIssue.Rarity r,,,) = m.tokenInfo(id);
            if (r == want) return id;
        }
        revert("not found");
    }

    function test_durationsAtBoundaries() public {
        _load(1, 40, true);
        uint256[4] memory ids;
        for (uint8 k; k < 4; k++) ids[k] = _find(1, MagazineIssue.Rarity(k), 40);
        assertEq(m.accessEnds(ids[0]), 0); // not started
        (,,,, bool act) = m.tokenInfo(ids[3]); assertFalse(act);
        uint64 st = uint64(block.timestamp + 100);
        vm.prank(LEDGER); m.startIssue(1, st);
        (,,,, act) = m.tokenInfo(ids[0]); assertFalse(act); // before start
        uint256[3] memory d = [uint256(7 days), 14 days, 30 days];
        for (uint256 k; k < 3; k++) {
            assertEq(m.accessEnds(ids[k]), st + d[k]);
            vm.warp(st + d[k] - 1); (,,,, act) = m.tokenInfo(ids[k]); assertTrue(act);
            vm.warp(st + d[k]); (,,,, act) = m.tokenInfo(ids[k]); assertFalse(act);
        }
        assertEq(m.accessEnds(ids[3]), type(uint256).max);
        vm.warp(st + 3650 days); (,,,, act) = m.tokenInfo(ids[3]); assertTrue(act); // mythic forever
        (,,,, act) = m.tokenInfo(ids[2]); assertFalse(act);
    }

    function test_restartTimerAndOperators() public {
        _load(1, 4, true);
        uint256 id = _find(1, MagazineIssue.Rarity.Common, 4);
        vm.prank(bob); vm.expectRevert(MagazineIssue.NotOperator.selector); m.startIssue(1, uint64(block.timestamp));
        vm.prank(cap); m.startIssue(1, uint64(block.timestamp)); // key holder
        vm.warp(block.timestamp + 8 days);
        (,,,, bool act) = m.tokenInfo(id); assertFalse(act);
        vm.prank(cap); m.startIssue(1, uint64(block.timestamp)); // restart
        (,,,, act) = m.tokenInfo(id); assertTrue(act);
        // key moves: old holder loses operator, new holder gains it
        vm.prank(cap); key.transferFrom(cap, bob, 1);
        vm.prank(cap); vm.expectRevert(MagazineIssue.NotOperator.selector); m.startIssue(1, 1);
        vm.prank(bob); m.startIssue(1, 0); // bob can stop (0 = not started)
        assertEq(m.accessEnds(id), 0);
        // owner can re-point key; unset key => only owner
        vm.prank(LEDGER); m.setKey(address(0), 0);
        vm.prank(bob); vm.expectRevert(MagazineIssue.NotOperator.selector); m.startIssue(1, 1);
        vm.prank(LEDGER); m.startIssue(1, 1);
        vm.prank(LEDGER); m.setKey(address(0xdead), 1); // non-contract key → no operator, no revert
        assertFalse(m.isOperator(bob));
        vm.prank(LEDGER); vm.expectRevert(MagazineIssue.BadIssue.selector); m.startIssue(9, 1);
    }

    function test_canEnterTraitMatching() public {
        _load(1, 4, true); // entries: (Common,Grass) (Uncommon,Mountain) (Rare,Tundra) (Mythic,Ocean)
        _load(2, 1, true);
        uint256 id = _find(1, MagazineIssue.Rarity.Rare, 4);
        if (m.ownerOf(id) == alice) { vm.prank(alice); m.transferFrom(alice, bob, id); }
        assertFalse(m.canEnter(bob, 1, 0)); // not started
        vm.prank(LEDGER); m.startIssue(1, uint64(block.timestamp));
        assertTrue(m.canEnter(bob, 1, m.MAIN_ROOM()));
        assertTrue(m.canEnter(bob, 1, m.SNOWY_TUNDRA()));
        assertFalse(m.canEnter(bob, 1, m.OCEAN()));
        assertFalse(m.canEnter(bob, 2, 0)); // other issue
        assertFalse(m.canEnter(cap, 1, 0));
        vm.warp(block.timestamp + 30 days);
        assertFalse(m.canEnter(bob, 1, m.SNOWY_TUNDRA())); // expired
        vm.prank(bob); m.transferFrom(bob, cap, id);
        assertFalse(m.canEnter(bob, 1, 0));
    }

    function test_pauseMint() public {
        _load(1, 2, true);
        vm.prank(alice); vm.expectRevert(); m.pause();
        vm.prank(LEDGER); m.pause();
        vm.prank(alice); vm.expectRevert(Pausable.EnforcedPause.selector); m.mint(1);
        vm.prank(LEDGER); m.unpause();
        vm.prank(LEDGER); m.setMintPrice(20e6);
        _mintAs(alice, 1);
        assertEq(usdc.balanceOf(TREASURY), 20e6);
    }

    // ---------------- RoomPass ----------------
    function test_passBuyUse24h() public {
        vm.prank(alice); p.buy(3);
        assertEq(p.balanceOf(alice, 1), 3); assertEq(usdc.balanceOf(TREASURY), 3e6);
        vm.prank(alice); vm.expectRevert(RoomPass.ZeroAmount.selector); p.buy(0);
        vm.prank(alice); p.use(1, 5);
        assertEq(p.balanceOf(alice, 1), 2);
        uint256 t0 = block.timestamp;
        assertTrue(p.hasPassAccess(alice, 1, 5));
        assertFalse(p.hasPassAccess(alice, 1, 4));
        assertFalse(p.hasPassAccess(bob, 1, 5));
        vm.warp(t0 + 24 hours - 1); assertTrue(p.hasPassAccess(alice, 1, 5));
        vm.warp(t0 + 24 hours); assertFalse(p.hasPassAccess(alice, 1, 5));
        vm.prank(bob); vm.expectRevert(); p.use(1, 5); // no pass
    }

    function test_passPauseAndPrice() public {
        vm.prank(LEDGER); p.pause();
        vm.prank(alice); vm.expectRevert(Pausable.EnforcedPause.selector); p.buy(1);
        vm.prank(LEDGER); p.unpause();
        vm.prank(LEDGER); p.setPrice(2e6);
        vm.prank(alice); p.buy(2);
        assertEq(usdc.balanceOf(TREASURY), 4e6);
        vm.prank(LEDGER); p.pause();
        vm.prank(alice); vm.expectRevert(Pausable.EnforcedPause.selector); p.use(1, 0);
        vm.prank(bob); vm.expectRevert(); p.setPrice(0);
    }
}
