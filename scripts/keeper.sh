#!/usr/bin/env bash
# Opens sealed Mysbase keys. Run server-side every ~30s (cron / worker).
# Needs env: BASE_RPC_URL, MAGAZINE_KEY (contract address), KEEPER_PRIVATE_KEY (small funded HOT wallet,
# keep in server env only - never commit). The keeper has no special rights: reveal is permissionless.
set -euo pipefail
ids=$(cast call "$MAGAZINE_KEY" "pendingReveals(uint256,uint256)(uint256[])" 0 200 --rpc-url "$BASE_RPC_URL")
ready=()
for id in $(echo "$ids" | tr -d '[],'); do
  [ "$(cast call "$MAGAZINE_KEY" "revealReady(uint256)(bool)" "$id" --rpc-url "$BASE_RPC_URL")" = "true" ] && ready+=("$id")
done
[ ${#ready[@]} -eq 0 ] && exit 0
list="[$(IFS=,; echo "${ready[*]}")]"
cast send "$MAGAZINE_KEY" "revealBatch(uint256[])" "$list" --rpc-url "$BASE_RPC_URL" --private-key "$KEEPER_PRIVATE_KEY"
