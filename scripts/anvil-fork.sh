#!/usr/bin/env bash
#
# anvil-fork.sh
#
# Resolves the Lumen snapshot's chain timestamp to the matching block number
# on a target EVM chain, then execs anvil forking at that block.
#
# Required environment:
#   CHAIN_NAME        Name of the target chain (logging only)
#   FORK_RPC_URL      JSON-RPC endpoint of the target chain
#   BLOCK_TIME_MS     Nominal block time, integer milliseconds (sub-second
#                     chains like Somnia are why this is not in seconds)
#   SNAPSHOT_API_URL  Lumen snapshot metadata endpoint (/snapshots/latest)
#   ANVIL_PORT        Port for anvil to listen on
#
# Strategy: read the snapshot's blockTime, seed an estimate from the chain
# head and the nominal block time, back off a safety margin, then binary
# search for the greatest block whose timestamp is <= the snapshot time.
# Never probes from block 1: public RPCs are not archival and deep probes
# fail, so an unreachable window is a hard error, not a fallback.

set -euo pipefail

log() { printf '[anvil-fork] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Requires each named variable to be set and free of literal quote characters.
# A quote survives expansion (bash never strips quotes from an expansion
# result), so a quoted .env value silently corrupts every URL and path built
# from it; fail loudly here instead.
require_env() {
  local name value
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "required environment variable $name is not set"
    value=${!name}
    if [[ "$value" == *[\"\']* ]]; then
      die "environment variable $name contains a literal quote character: $value -- this usually means the value is quoted in .env; remove the surrounding quotes"
    fi
  done
}

# --- snapshot metadata -------------------------------------------------------

# $1 = ISO 8601 UTC timestamp; echoes epoch seconds.
# Fractional seconds are stripped because jq's fromdateiso8601 rejects them.
iso_to_epoch() {
  jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601'
}

# $1 = snapshot metadata JSON from the API; echoes the target epoch seconds.
extract_target_ts() {
  local iso
  iso=$(jq -r '.blockTime // empty' <<<"$1" 2>/dev/null) \
    || die "snapshot metadata is not valid JSON"
  if [[ -z "$iso" || "$iso" == "null" ]]; then
    die "snapshot metadata has no blockTime (missing or null); this snapshot predates blockTime support, take a fresh snapshot before forking"
  fi
  iso_to_epoch "$iso" 2>/dev/null \
    || die "cannot parse snapshot blockTime '$iso' as ISO 8601 UTC"
}

# --- JSON-RPC ----------------------------------------------------------------

PROBES=0     # number of eth_getBlockByNumber calls issued
BLOCK_TS=""  # output slot of fetch_block_ts (globals so probes are countable
             # in the parent shell; command substitution would lose the count)

# $1 = method, $2 = params (JSON array); echoes the raw JSON-RPC response.
rpc_call() {
  local payload
  payload=$(jq -cn --arg m "$1" --argjson p "$2" \
    '{jsonrpc: "2.0", id: 1, method: $m, params: $p}')
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$payload" "$FORK_RPC_URL" \
    || die "RPC transport failure calling $1 on $FORK_RPC_URL"
}

# Echoes the latest block number in decimal.
get_latest_block() {
  local resp err hex
  resp=$(rpc_call eth_blockNumber '[]')
  err=$(jq -r '.error.message // empty' <<<"$resp")
  [[ -z "$err" ]] || die "eth_blockNumber failed: $err"
  hex=$(jq -r '.result // empty' <<<"$resp")
  [[ "$hex" == 0x* ]] || die "unexpected eth_blockNumber result: '$hex'"
  echo $(( hex ))
}

# $1 = block number (decimal). Sets BLOCK_TS to the block's timestamp in
# epoch seconds, or to "" when the RPC cannot serve the block (pruned or
# unknown; JSON-RPC errors and null results both count as unavailable).
fetch_block_ts() {
  local number=$1 resp result ts_hex
  resp=$(rpc_call eth_getBlockByNumber "[\"$(printf '0x%x' "$number")\", false]")
  PROBES=$(( PROBES + 1 ))
  result=$(jq -c '.result // null' <<<"$resp")
  if [[ "$result" == "null" ]]; then
    BLOCK_TS=""
    return 0
  fi
  ts_hex=$(jq -r '.timestamp // empty' <<<"$result")
  [[ "$ts_hex" == 0x* ]] || die "block $number has no usable timestamp in RPC response"
  BLOCK_TS=$(( ts_hex ))
}

# --- block resolution --------------------------------------------------------

RESULT_BLOCK=""
RESULT_TS=""
SEEDED_LO="" # consumed by the self-test's probe-floor assertion

# $1 = target epoch seconds. Sets RESULT_BLOCK / RESULT_TS to the greatest
# block whose timestamp is <= target (or the chain head if the target is at
# or beyond it). Dies rather than return a block it could not verify.
resolve_fork_block() {
  local target=$1
  local latest latest_ts
  latest=$(get_latest_block)
  fetch_block_ts "$latest"
  [[ -n "$BLOCK_TS" ]] || die "RPC returned no data for its own latest block $latest"
  latest_ts=$BLOCK_TS
  log "chain head: block $latest (ts $latest_ts); target ts: $target"

  if (( target >= latest_ts )); then
    log "target timestamp is at or beyond the chain head; forking at the head"
    RESULT_BLOCK=$latest
    RESULT_TS=$latest_ts
    # shellcheck disable=SC2034
    SEEDED_LO=$latest
    return 0
  fi

  # Seed the lower bound from the nominal block time, then back off a 10%
  # margin so real block-time drift keeps the estimate below the target.
  # Timestamps are seconds and block time is milliseconds, so scale the gap
  # by 1000 first; the ceiling is done with integer arithmetic only.
  local delta est_back est margin lo
  delta=$(( latest_ts - target ))
  est_back=$(( (delta * 1000 + BLOCK_TIME_MS - 1) / BLOCK_TIME_MS ))
  est=$(( latest - est_back ))
  if (( est < 1 )); then est=1; fi
  margin=$(( est_back / 10 ))
  if (( margin < 1 )); then margin=1; fi
  lo=$(( est - margin ))
  if (( lo < 1 )); then lo=1; fi
  # shellcheck disable=SC2034
  SEEDED_LO=$lo
  log "estimate: block $est, searching from $lo (margin $margin blocks)"

  # The binary search needs block(lo).ts <= target as its invariant; widen
  # the margin until that holds. Unservable blocks mean the window we need
  # is outside the RPC's retained history, which is fatal by design.
  local lo_ts
  while true; do
    fetch_block_ts "$lo"
    if [[ -z "$BLOCK_TS" ]]; then
      die "RPC cannot serve block $lo (pruned history); the snapshot's chain time predates the RPC's retained history, so no matching fork block can be verified. Use an RPC with deeper history or a fresher snapshot."
    fi
    lo_ts=$BLOCK_TS
    if (( lo_ts <= target )); then
      break
    fi
    if (( lo == 1 )); then
      die "block 1 (ts $lo_ts) is already after the target ts $target; chain '$CHAIN_NAME' is younger than the snapshot"
    fi
    log "guard: block $lo ts $lo_ts > target; widening margin to $(( margin * 2 ))"
    margin=$(( margin * 2 ))
    lo=$(( est - margin ))
    if (( lo < 1 )); then lo=1; fi
  done

  # Binary search [lo, latest] for the greatest block with ts <= target.
  # Invariant: block(lo).ts <= target < block(latest+...).ts, and mid > lo,
  # so no probe ever goes below the guarded lower bound.
  local hi=$latest mid
  while (( lo < hi )); do
    mid=$(( lo + (hi - lo + 1) / 2 ))
    fetch_block_ts "$mid"
    [[ -n "$BLOCK_TS" ]] || die "RPC cannot serve block $mid mid-search; refusing to guess a fork block"
    if (( BLOCK_TS <= target )); then
      lo=$mid
      lo_ts=$BLOCK_TS
    else
      hi=$(( mid - 1 ))
    fi
  done

  RESULT_BLOCK=$lo
  RESULT_TS=$lo_ts
}

# --- main ---------------------------------------------------------------------

main() {
  require_env CHAIN_NAME FORK_RPC_URL BLOCK_TIME_MS SNAPSHOT_API_URL ANVIL_PORT
  [[ "$BLOCK_TIME_MS" =~ ^[1-9][0-9]*$ ]] \
    || die "BLOCK_TIME_MS must be a positive integer number of milliseconds, got '$BLOCK_TIME_MS'"

  log "fetching snapshot metadata from $SNAPSHOT_API_URL"
  local meta target_ts
  meta=$(curl -fsS "$SNAPSHOT_API_URL") \
    || die "failed to fetch snapshot metadata from $SNAPSHOT_API_URL"
  target_ts=$(extract_target_ts "$meta")
  log "snapshot chain time: $(jq -r '.blockTime' <<<"$meta") (epoch $target_ts)"

  resolve_fork_block "$target_ts"

  local drift=$(( target_ts - RESULT_TS ))
  log "resolved fork block for '$CHAIN_NAME': $RESULT_BLOCK (ts $RESULT_TS, ${drift}s before snapshot time, $PROBES block probes)"

  exec anvil \
    --fork-url "$FORK_RPC_URL" \
    --fork-block-number "$RESULT_BLOCK" \
    --host 0.0.0.0 \
    --port "$ANVIL_PORT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
