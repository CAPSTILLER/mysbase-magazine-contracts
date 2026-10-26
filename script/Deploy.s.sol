// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {Script} from "forge-std/Script.sol";
import {MagazineIssue} from "../src/MagazineIssue.sol";
import {RoomPass} from "../src/RoomPass.sol";

/// Deploys both contracts owned by Cap's Ledger. No keys in repo: run with --ledger or --account.
contract Deploy is Script {
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant TREASURY = 0xCF1ac98565DA846E8263604b49C1276Ed78A0981;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CAPS_MIND_KEY = 0x00635cA44339C7C194eF5bC87bF2cD6Df04A666D; // from caps-mind-prophecies README
    uint256 constant KEY_TOKEN_ID = 1; // ASSUMPTION: Cap's key is token #1, owner can change with setKey

    function run() external {
        vm.startBroadcast();
        new MagazineIssue(LEDGER, USDC, TREASURY, 10e6, CAPS_MIND_KEY, KEY_TOKEN_ID);
        new RoomPass(LEDGER, USDC, TREASURY, 1e6, "");
        vm.stopBroadcast();
    }
}
