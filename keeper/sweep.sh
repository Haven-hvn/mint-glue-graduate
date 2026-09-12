#!/usr/bin/env bash
# Minimal keeper: sweep every router whose pending royalties clear its MIN_CLAIM.
# Run from cron, e.g. every 10 minutes:  */10 * * * * RPC=... PK=... /path/keeper/sweep.sh 0xRouter1 0xRouter2
#
# Env:  RPC   JSON-RPC url
#       PK    keeper private key (any funded EOA; it receives the bounty in the reserve token)
#       MIN_OUT  optional swap floor for swapper routes (default 0 — fine on swap-free routes)
# Args: router addresses
set -euo pipefail
: "${RPC:?}" "${PK:?}"
MIN_OUT="${MIN_OUT:-0}"

for R in "$@"; do
  pending=$(cast call "$R" 'pending()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
  min=$(cast call "$R" 'MIN_CLAIM()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
  if (( $(echo "$pending >= $min && $pending > 0" | bc) )); then
    # Simulate first so a revert (BelowMinimum, slippage) costs nothing.
    if cast call "$R" 'sweep(uint256)' "$MIN_OUT" --rpc-url "$RPC" --from "$(cast wallet address --private-key "$PK")" >/dev/null 2>&1; then
      tx=$(cast send "$R" 'sweep(uint256)' "$MIN_OUT" --rpc-url "$RPC" --private-key "$PK" --json | jq -r .transactionHash)
      echo "$(date -u +%FT%TZ) $R swept pending=$pending tx=$tx"
    else
      echo "$(date -u +%FT%TZ) $R simulation reverted, skipped"
    fi
  else
    # Not worth a sweep: stamp activity if the token traded on the pool, so a live token never looks stale.
    if cast call "$R" 'heartbeat()(bool)' --rpc-url "$RPC" 2>/dev/null | grep -q true; then
      cast send "$R" 'heartbeat()' --rpc-url "$RPC" --private-key "$PK" >/dev/null && echo "$(date -u +%FT%TZ) $R heartbeat stamped"
    else
      echo "$(date -u +%FT%TZ) $R pending=$pending < min=$min, quiet"
    fi
  fi
done
