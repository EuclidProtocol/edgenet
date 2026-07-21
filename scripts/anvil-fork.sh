#!/usr/bin/env bash
#
# anvil-fork.sh
#
# Execs anvil forking a target EVM chain, either at a hand-pinned block
# height or at the chain tip.
#
# Required environment:
#   CHAIN_NAME    Name of the target chain (logging only)
#   FORK_RPC_URL  JSON-RPC endpoint of the target chain
#   ANVIL_PORT    Port for anvil to listen on
#   BLOCK_TIME    Seconds between blocks. Without it anvil auto-mines a block
#                 per transaction and never produces an empty block, which no
#                 real chain does.
#   EVM_CHAIN_ID  EVM chain id anvil reports over eth_chainId. Not inherited
#                 from the fork, so it must be given explicitly. These are
#                 mainnet-offset fork ids, not the real mainnet chain ids
#                 (Base 84539, Somnia 50319, Polygon 1379).
#
# Optional environment:
#   FORK_BLOCK    Block number to fork at. When empty or unset, anvil
#                 forks at the chain tip.
#
# anvil is always started with --timestamp set to the current wall-clock
# unix time, so the forked chain's clock starts at "now" rather than at the
# forked block's original timestamp. On a restart that reloads persisted
# /data/state, this flag is a no-op: anvil resumes the state's own clock,
# it does not rewind to a fresh --timestamp.
#
# History is bounded. Unpruned, every mined block keeps an in-memory state
# snapshot and memory grows without limit; instead anvil keeps one hour of
# blocks in memory, at most 16 states on disk, and dumps state to /data
# every 300 seconds.

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

# --- main ---------------------------------------------------------------------

main() {
  require_env CHAIN_NAME FORK_RPC_URL ANVIL_PORT BLOCK_TIME EVM_CHAIN_ID

  [[ "$BLOCK_TIME" =~ ^[1-9][0-9]*$ ]] \
    || die "BLOCK_TIME must be a positive integer number of seconds, got '$BLOCK_TIME'"
  [[ "$EVM_CHAIN_ID" =~ ^[1-9][0-9]*$ ]] \
    || die "EVM_CHAIN_ID must be a positive integer chain id, got '$EVM_CHAIN_ID'"

  # Persist chain state under the bind-mounted /data so it survives container
  # restarts. anvil loads /data/state on boot if present, dumps to it every
  # 300s and on exit. Memory previously grew unbounded because every mined
  # block kept an in-memory state snapshot; --max-persisted-states caps on-disk
  # states at 16, and --transaction-block-keeper prunes mined transactions on a
  # one-hour horizon. --prune-history is intentionally omitted: anvil rejects it
  # alongside --max-persisted-states.
  local HISTORY_BLOCKS=$((3600 / BLOCK_TIME))
  local STATE_FLAGS=(
    --state /data/state
    --state-interval 300
    --max-persisted-states 16
    --transaction-block-keeper "$HISTORY_BLOCKS"
  )

  # Wall-clock unix time, not the forked chain's own timestamp: a fork of an
  # old block should still tick from "now" so relative-time assumptions in
  # anything talking to this chain hold. Only has effect on the first boot;
  # a restart that reloads /data/state resumes the state's clock instead.
  local TIMESTAMP
  TIMESTAMP=$(date +%s)

  if [[ -n "${FORK_BLOCK:-}" ]]; then
    [[ "$FORK_BLOCK" =~ ^[1-9][0-9]*$ ]] \
      || die "FORK_BLOCK must be a positive integer block number, got '$FORK_BLOCK'"
    log "forking '$CHAIN_NAME' (chain id $EVM_CHAIN_ID) at pinned block $FORK_BLOCK, mining every ${BLOCK_TIME}s, clock starting at $TIMESTAMP"
    exec anvil \
      --fork-url "$FORK_RPC_URL" \
      --fork-block-number "$FORK_BLOCK" \
      --block-time "$BLOCK_TIME" \
      --chain-id "$EVM_CHAIN_ID" \
      --timestamp "$TIMESTAMP" \
      --host 0.0.0.0 \
      --port "$ANVIL_PORT" \
      "${STATE_FLAGS[@]}"
  fi

  log "FORK_BLOCK is not set; forking '$CHAIN_NAME' (chain id $EVM_CHAIN_ID) at the chain tip, mining every ${BLOCK_TIME}s, clock starting at $TIMESTAMP"
  exec anvil \
    --fork-url "$FORK_RPC_URL" \
    --block-time "$BLOCK_TIME" \
    --chain-id "$EVM_CHAIN_ID" \
    --timestamp "$TIMESTAMP" \
    --host 0.0.0.0 \
    --port "$ANVIL_PORT" \
    "${STATE_FLAGS[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
