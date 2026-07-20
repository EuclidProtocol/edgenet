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

  if [[ -n "${FORK_BLOCK:-}" ]]; then
    [[ "$FORK_BLOCK" =~ ^[1-9][0-9]*$ ]] \
      || die "FORK_BLOCK must be a positive integer block number, got '$FORK_BLOCK'"
    log "forking '$CHAIN_NAME' (chain id $EVM_CHAIN_ID) at pinned block $FORK_BLOCK, mining every ${BLOCK_TIME}s"
    exec anvil \
      --fork-url "$FORK_RPC_URL" \
      --fork-block-number "$FORK_BLOCK" \
      --block-time "$BLOCK_TIME" \
      --chain-id "$EVM_CHAIN_ID" \
      --host 0.0.0.0 \
      --port "$ANVIL_PORT"
  fi

  log "FORK_BLOCK is not set; forking '$CHAIN_NAME' (chain id $EVM_CHAIN_ID) at the chain tip, mining every ${BLOCK_TIME}s"
  exec anvil \
    --fork-url "$FORK_RPC_URL" \
    --block-time "$BLOCK_TIME" \
    --chain-id "$EVM_CHAIN_ID" \
    --host 0.0.0.0 \
    --port "$ANVIL_PORT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
