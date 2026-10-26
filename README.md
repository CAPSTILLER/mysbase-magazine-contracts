# Mysbase Magazine contracts

Foundry, Solidity 0.8.24, OpenZeppelin v5.1. Built for Base. **Nothing is deployed yet.**

## MagazineKey (ERC-721, `src/MagazineKey.sol`)
Genesis collection ("Mysbase Genesis Key" / MYSGEN in the deploy script): permanent gate keys for the magazine rooms, with a hard cap of **MAX_SUPPLY = 10,000**. `addEntries` reverts with `MaxSupply` past that, so minting can never exceed it. More keys later would need a new contract. RoomPass is unlimited.
- **Pool:** Cap loads entries with `addEntries(rarities[], traits[], uris[])`. Rarity: 0 Common, 1 Uncommon, 2 Rare, 3 Mythic. Trait: 1 Grass, 2 Mountain, 3 Snowy Tundra, 4 Ocean, 5 Outer Space, 6 Desert, 7 Forest. Fix typos with `setEntryURI(idx, uri)`, then `lockPool()` freezes the pool and opens minting.
- **Mint (two-step, no rerolls, every wallet type):**
  1. `mint()` pays `mintPrice` (10 USDC) to the treasury (0xCF1ac98565DA846E8263604b49C1276Ed78A0981) and mints a **sealed** key at once, with `targetBlock = block.number + REVEAL_DELAY (2)`. Emits `Sealed(tokenId, minter, targetBlock)`. Payment is final. Total mints (sealed + revealed) can never exceed the pool (`SoldOut`). EOAs, Coinbase Smart Wallet / Base app, Safe and 7702 wallets all work (receiver must accept ERC-721, as all of those do).
  2. `reveal(tokenId)` or `revealBatch(ids)`: anyone (our keeper, the holder, anyone) after the target block. Picks a random remaining entry from `keccak(hash(targetBlock), seed, tokenId)`. The hash does not exist during the mint tx, so a contract cannot see the result and revert. Once the target block exists the outcome is fixed: who reveals or when does not change it. Emits `Revealed(tokenId, entryIndex, rarity, trait)`. `revealBatch` skips ids that are not ready.
  - **Hash expiry:** `blockhash` covers 256 blocks; after that the EIP-2935 history contract (0x0000F90827F1C53a10cb7A02335B175320002935, live on Base, checked on a mainnet fork) covers 8191 blocks (~4.5h on Base). Past that, `reveal` reverts `HashUnavailable` and only the operator (owner / CAPs Mind key holder) can `retarget(ids)` to a new future block. The holder can never retarget.
  - **Sealed keys:** `tokenURI` = `sealedURI` (owner `setSealedURI`), `keyInfo`/`tokenInfo` return trait 0 + sealedURI, `accessEnds` 0, no room entry. Views: `isRevealed`, `revealReady`, `sealedCount`, `pendingReveals(offset, limit)`, `tickets(id)`.
  - `setRandomSource` can plug in a VRF adapter; when set, its word replaces the block-hash word at reveal.
- **Keeper:** `scripts/keeper.sh` (cast) lists `pendingReveals`, filters `revealReady`, calls `revealBatch`. Run every ~30s server-side with env `BASE_RPC_URL`, `MAGAZINE_KEY`, `KEEPER_PRIVATE_KEY` (a small funded hot wallet in server env only, never committed; it has no special rights).
- **Residual risks:** the Base sequencer produces block hashes and could in theory bias a target block (fine for 10 USDC pulls; use a VRF source for high stakes). If the keeper is down >4.5h, a holder who computed a bad result offchain might hope for the operator to retarget; the operator should only retarget truly stuck tickets.
- **Rooms:** `createRoom(roomId, requiredTrait)` (0 = any key holder, 1..7 = that trait only). `seedDefaultRooms()` creates room 0 (main) and rooms 1..7 (trait rooms). The owner or the current CAPs Mind key holder can create rooms.
- **Room states** (changed by the owner or current CAPs Mind key holder; key = 0x00635ca44339c7c194ef5bc87bf2cd6df04a666d, token id set with `setKey`):
  - **Quarantined** is the default for every new room, and `quarantineRoom(roomId)` can quarantine from any state. Only Cap gets in; Mythic is locked out.
  - `startRoom(roomId, startTime)` (0 = now) → **Open**. The timer starts fresh: Common 7d, Uncommon 14d, Rare 30d from startTime. Trait gating and passes apply.
  - `shutDownRoom(roomId)` → **ShutDown**, only allowed from Open. Only Mythic holders and Cap get in, and the timer stops. Reopening resets it fresh.
  - Every shutdown or quarantine bumps the room's `closeEpoch` and records `closedAt`, which RoomPass uses for refunds.
- **Mythic:** free reign in any Open (started) or ShutDown room. Mythic ignores trait gating and has no time limit.
- **Cap** (owner or current CAPs Mind key holder): `canEnter` is always true, in every room and every state.
- **Views for apps and future contracts:** `canEnter(wallet, roomId)` (sealed keys never count), `roomState(roomId)`, `keyInfo(tokenId)`, `accessEnds(tokenId, roomId)`, `roomOpen(roomId)`.
- Includes Ownable2Step, Pausable (mint), ReentrancyGuard and SafeERC20, and emits an event for every change.

## RoomPass (ERC-1155, `src/RoomPass.sol`)
- `buy(n)` costs 1 USDC per pass, paid to the treasury. Passes are cheap throwaway tokens.
- `use(roomId)` only works while the room is Open. It moves one pass into the RoomPass contract (escrow) and starts 24h of access to that room. Each user can have one active pass per room.
- If the room is shut down or quarantined before the 24h ends, access stops at once, and `reclaim(user, roomId)` (anyone can call it) returns the pass like new. The view `reclaimable(user, roomId)` tells the site when to show or trigger this.
- If the 24h end without a close, the pass is burned by `burnExpired(user, roomId)` (anyone; view `burnable`), or automatically on the user's next `use()` of that room. An expired pass never grants access and is never refunded.
- On `use()`, an old deposit for that room is settled first: a reclaimable one is returned, an expired one is burned.

## Setup after deploy (owner = Ledger)
`setRoomPass(pass)` → `seedDefaultRooms()` → `setSealedURI(uri)` → `addEntries(...)` batches → `lockPool()` → `startRoom(id, time)`. Then start the keeper.

Deploy from the commit that adds the two-step mint (see git log), not 538f0a9.

## Future
A separate "custom rooms" contract (user-built rooms, Cap approval to go public, private rooms with friend-access NFTs mintable by MagazineKey holders) can read `keyInfo` / `canEnter` / `roomState`. It is not built yet.

## Test
`forge test`
