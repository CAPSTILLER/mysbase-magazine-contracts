# Mysbase Magazine Contracts (Base)

Two contracts, both owned by Cap's Ledger `0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca` (Ownable2Step). USDC (`0x8335…2913`) goes straight to the treasury `0xCF1ac98565DA846E8263604b49C1276Ed78A0981`. Nothing is held in the contracts.

## MagazineIssue (ERC-721 "MYSMAG")
1. **Issues:** the owner creates any number of issues (`createIssue(issueId)`).
2. **Pool:** per issue, the owner preloads entries in batches with `addEntries(issueId, rarities, traits, uris)`. Each entry has a rarity (0 Common, 1 Uncommon, 2 Rare, 3 Mythic), a room trait (1 Grass, 2 Mountain, 3 Snowy Tundra, 4 Ocean, 5 Outer Space, 6 Desert, 7 Forest) and its own metadata URI. URIs can be fixed with `setEntryURI` until `lockPool`. After locking, the pool can't change. Supply = pool size.
3. **Mint:** `mint(issueId)` costs 10 USDC (owner can change with `setMintPrice`) and gives a random unminted entry from that issue. Picked entries are removed (swap-and-pop), so every remaining entry has an equal chance, and rare ones are still in there as the pool shrinks. When the pool is empty, mint reverts `SoldOut`. Owner can pause mint.
4. **Randomness:** by default it's a hash of `block.prevrandao`, the previous blockhash, a nonce, the minter and the issue. **Risk:** Base's sequencer makes the blocks and could in theory bias pulls, and a bot contract can simulate a mint and revert if it doesn't like the result. Fine for a fun pull, not for high-value odds. The owner can plug in a VRF adapter later with `setRandomSource` (interface `IRandomSource`), with no redeploy.
5. **Access clock:** each issue has a start time. Access for a token runs from start to start + 7 days (Common), 14 days (Uncommon), 30 days (Rare); Mythic is forever. Before the issue is started (start = 0) nobody has access. `startIssue(issueId, startTime)` can be called by the owner **or whoever currently holds the CAPs Mind key** (`keyContract`, `keyTokenId`, both owner-settable with `setKey`). It can be called again any time to restart or adjust the clock (0 stops it).
6. **Rooms:** room 0 is the issue's main room (any active holder of that issue). Rooms 1–7 are trait rooms (only active holders whose token has that trait).

Views for Mysbase: `canEnter(wallet, issueId, room)`, `tokenInfo(tokenId)` → (issueId, rarity, trait, accessEnds, active), `accessEnds(tokenId)` (0 = not started, max uint = forever), `tokenURI`, `remaining(issueId)`, `entry(issueId, idx)`, `issues(issueId)`, `isOperator(addr)`.

## RoomPass (ERC-1155, id 1)
1. `buy(amount)`: 1 USDC per pass (owner `setPrice`) to the treasury.
2. `use(issueId, room)`: burns 1 pass, gives the caller 24 hours of access to that one room (any issue, any room, 0 = main).
3. View `hasPassAccess(wallet, issueId, room)`. Mysbase should allow entry if `canEnter || hasPassAccess`.
4. Owner can pause buy and use, and set the treasury and URI.

## Deploy (Ledger, nothing deployed yet)
1. `forge install --no-git foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0` then `forge test`.
2. `forge script script/Deploy.s.sol --rpc-url https://mainnet.base.org --ledger --broadcast --verify`. The script uses CAPs Mind key `0x00635ca44339c7c194ef5bc87bf2cd6df04a666d` with token id 1 (check this; change with `setKey`).
3. From the Ledger: `createIssue(1)`, `addEntries` in batches (about 100 per tx), check with `entry()`, then `lockPool(1)`.
4. Test mint (approve 10 USDC first), check the treasury got it, then sign `startIssue` from the Ledger or the CAPs Mind key wallet when the issue goes live.
