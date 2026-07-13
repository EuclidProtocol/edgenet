#!/usr/bin/env bash
#
# Self-test for anvil-fork.sh. No bats, no network: sources the script
# (main() is guarded behind BASH_SOURCE) and replaces the two RPC accessors
# with a simulated chain whose block N has timestamp
# GENESIS_TS + N * MOCK_ACTUAL_BLOCK_TIME, optionally pruned below a floor.
#
# Run: bash scripts/anvil-fork-test.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=anvil-fork.sh
source "$SCRIPT_DIR/anvil-fork.sh"

# --- mock chain ----------------------------------------------------------------

MOCK_LATEST=1000000
MOCK_GENESIS_TS=1700000000
MOCK_ACTUAL_BLOCK_TIME_MS=2000
MOCK_PRUNE_BELOW=0
MIN_PROBED=""

get_latest_block() { echo "$MOCK_LATEST"; }

# Block N's timestamp in whole seconds: sub-second chains put several blocks
# in the same second, which the resolver must tolerate (it returns the
# greatest such block, matching the real "greatest ts <= target" contract).
mock_block_ts() { echo $(( MOCK_GENESIS_TS + ($1 * MOCK_ACTUAL_BLOCK_TIME_MS) / 1000 )); }

fetch_block_ts() {
  PROBES=$(( PROBES + 1 ))
  if [[ -z "$MIN_PROBED" ]] || (( $1 < MIN_PROBED )); then MIN_PROBED=$1; fi
  if (( $1 < MOCK_PRUNE_BELOW )); then
    BLOCK_TS=""
    return 0
  fi
  BLOCK_TS=$(mock_block_ts "$1")
}

mock_latest_ts() { mock_block_ts "$MOCK_LATEST"; }

reset_mocks() {
  MOCK_LATEST=1000000
  MOCK_GENESIS_TS=1700000000
  MOCK_ACTUAL_BLOCK_TIME_MS=2000
  MOCK_PRUNE_BELOW=0
  MIN_PROBED=""
  PROBES=0
  RESULT_BLOCK=""
  RESULT_TS=""
  SEEDED_LO=""
  BLOCK_TIME_MS=2000
  CHAIN_NAME=testchain
}

# --- harness --------------------------------------------------------------------

PASS=0
FAIL=0

pass() { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$1"; }

assert_eq() { # expected actual desc
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected $1, got $2)"; fi
}

assert_le() { # actual max desc
  if (( $1 <= $2 )); then pass "$3 ($1 <= $2)"; else fail "$3 ($1 > $2)"; fi
}

assert_ge() { # actual min desc
  if (( $1 >= $2 )); then pass "$3 ($1 >= $2)"; else fail "$3 ($1 < $2)"; fi
}

expect_die() { # desc pattern cmd...
  local desc=$1 pattern=$2 out rc=0
  shift 2
  out=$( ( "$@" ) 2>&1 ) || rc=$?
  if (( rc == 0 )); then
    fail "$desc (expected fatal exit, got success)"
  elif [[ "$out" != *"$pattern"* ]]; then
    fail "$desc (message missing '$pattern': $out)"
  else
    pass "$desc"
  fi
}

# Greatest block N whose (second-truncated) timestamp is <= $1, per the mock
# chain. Derived rather than hardcoded so sub-second cases stay checkable.
expected_block() {
  echo $(( ((($1 - MOCK_GENESIS_TS) + 1) * 1000 - 1) / MOCK_ACTUAL_BLOCK_TIME_MS ))
}

# --- tests ------------------------------------------------------------------------

# 1. 6-hour-old snapshot on a 2s chain: exact block, logarithmic probes,
#    and no probe below the seeded lower bound.
reset_mocks
target=$(( $(mock_latest_ts) - 21600 ))
resolve_fork_block "$target"
assert_eq $(( MOCK_LATEST - 10800 )) "$RESULT_BLOCK" "6h/2s: resolves exact block"
assert_eq "$target" "$RESULT_TS" "6h/2s: zero drift on aligned target"
assert_le "$PROBES" 20 "6h/2s: probe count is logarithmic"
assert_ge "$MIN_PROBED" "$SEEDED_LO" "6h/2s: no probe below seeded LO"
echo "     (6h-old snapshot on 2s chain used $PROBES block probes, seeded LO $SEEDED_LO)"

# 2. Target between two blocks: greatest block with ts <= target wins.
reset_mocks
target=$(( $(mock_latest_ts) - 21600 + 1 ))
resolve_fork_block "$target"
assert_eq $(( MOCK_LATEST - 10800 )) "$RESULT_BLOCK" "between-blocks: floors to earlier block"
assert_eq 1 $(( target - RESULT_TS )) "between-blocks: reports 1s drift"
assert_ge "$MIN_PROBED" "$SEEDED_LO" "between-blocks: no probe below seeded LO"

# 3. Target at/after the chain head: fork at head, single probe.
reset_mocks
target=$(( $(mock_latest_ts) + 500 ))
resolve_fork_block "$target"
assert_eq "$MOCK_LATEST" "$RESULT_BLOCK" "future target: forks at chain head"
assert_eq 1 "$PROBES" "future target: only the head is probed"

# 4. Nominal block time wrong (env says 4000ms, chain runs 2000ms): the guard
#    must widen until the invariant holds, then still land on the exact block.
reset_mocks
BLOCK_TIME_MS=4000
target=$(( $(mock_latest_ts) - 21600 ))
resolve_fork_block "$target"
assert_eq $(( MOCK_LATEST - 10800 )) "$RESULT_BLOCK" "widening: correct block despite bad estimate"
assert_le "$PROBES" 30 "widening: probe count stays bounded"

# 4b. Sub-second chain, 1000ms blocks (somnia-class): seed must land in the
#     right neighbourhood and the search stay logarithmic.
reset_mocks
BLOCK_TIME_MS=1000
MOCK_ACTUAL_BLOCK_TIME_MS=1000
target=$(( $(mock_latest_ts) - 21600 ))
resolve_fork_block "$target"
assert_eq "$(expected_block "$target")" "$RESULT_BLOCK" "1000ms: resolves exact block"
assert_eq $(( MOCK_LATEST - 21600 )) "$RESULT_BLOCK" "1000ms: 21600 blocks back over 6h"
assert_le "$PROBES" 22 "1000ms: probe count is logarithmic"
assert_ge "$MIN_PROBED" "$SEEDED_LO" "1000ms: no probe below seeded LO"
echo "     (6h-old snapshot on 1000ms chain used $PROBES block probes, seeded LO $SEEDED_LO)"

# 4c. Sub-second chain, 100ms blocks: ten blocks share each wall-clock second,
#     so the resolver must return the LAST block of the target second.
reset_mocks
BLOCK_TIME_MS=100
MOCK_ACTUAL_BLOCK_TIME_MS=100
target=$(( $(mock_latest_ts) - 21600 ))
resolve_fork_block "$target"
assert_eq "$(expected_block "$target")" "$RESULT_BLOCK" "100ms: resolves last block of target second"
assert_eq 0 $(( target - RESULT_TS )) "100ms: zero drift"
assert_le "$PROBES" 25 "100ms: probe count is logarithmic"
assert_ge "$MIN_PROBED" "$SEEDED_LO" "100ms: no probe below seeded LO"
assert_ge "$SEEDED_LO" 1 "100ms: seeded LO stays >= 1"
assert_le "$SEEDED_LO" "$RESULT_BLOCK" "100ms: seed lands below the answer"
echo "     (6h-old snapshot on 100ms chain used $PROBES block probes, seeded LO $SEEDED_LO)"

# 4d. Non-integer BLOCK_TIME_MS is fatal (the field is milliseconds, not a float).
expect_die "fractional BLOCK_TIME_MS is fatal" "positive integer number of milliseconds" \
  env CHAIN_NAME=x FORK_RPC_URL=http://x BLOCK_TIME_MS=0.5 SNAPSHOT_API_URL=http://x ANVIL_PORT=1 \
  bash "$SCRIPT_DIR/anvil-fork.sh"

# 5. Pruned history: the window the search needs is unservable -> fatal.
reset_mocks
MOCK_PRUNE_BELOW=$(( MOCK_LATEST - 5000 ))
target=$(( $(mock_latest_ts) - 21600 ))
expect_die "pruned history is fatal" "pruned history" resolve_fork_block "$target"

# 6. Chain younger than the snapshot: block 1 already after target -> fatal.
reset_mocks
target=$(( MOCK_GENESIS_TS - 100 ))
expect_die "chain younger than snapshot is fatal" "younger than the snapshot" resolve_fork_block "$target"

# 7. Metadata handling: missing/null/unparseable blockTime are fatal,
#    valid ISO 8601 (with milliseconds) round-trips through epoch.
expect_die "missing blockTime is fatal" "no blockTime" extract_target_ts '{"height": 123}'
expect_die "null blockTime is fatal" "no blockTime" extract_target_ts '{"blockTime": null}'
expect_die "garbage blockTime is fatal" "cannot parse" extract_target_ts '{"blockTime": "not-a-date"}'
expect_die "invalid JSON is fatal" "not valid JSON" extract_target_ts 'no json here'

epoch=$(extract_target_ts '{"blockTime": "2026-07-13T10:00:00.000Z"}')
roundtrip=$(jq -rn --argjson e "$epoch" '$e | todate')
assert_eq "2026-07-13T10:00:00Z" "$roundtrip" "blockTime with millis parses to correct epoch"

# --- summary --------------------------------------------------------------------

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 )) || exit 1
