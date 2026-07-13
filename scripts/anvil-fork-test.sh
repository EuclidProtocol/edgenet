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

# 8. Quoted env values. A quote-preserving .env parse ships SNAPSHOT_API_URL as
#    the literal string "https://.../api" (quotes included), which bash never
#    strips, so curl sees a URL it cannot parse. require_env must reject it.
QUOTED_URL='"https://snapshots.example/api"'
QUOTED_DENOM="'usync'"
PLAIN_URL='https://snapshots.example/api'

expect_die "double-quoted value is rejected" "literal quote character" \
  require_env QUOTED_URL
expect_die "double-quoted value names the offending var" "QUOTED_URL" \
  require_env QUOTED_URL
expect_die "double-quoted value shows the value" "$QUOTED_URL" \
  require_env QUOTED_URL
expect_die "error blames a quoted value in .env" "quoted in .env" \
  require_env QUOTED_URL
expect_die "single-quoted value is rejected" "literal quote character" \
  require_env QUOTED_DENOM

if ( require_env PLAIN_URL ) 2>/dev/null; then
  pass "unquoted value is accepted"
else
  fail "unquoted value is accepted (require_env rejected a clean value)"
fi

# The whole point is to fail before the network: stub curl so any invocation
# announces itself, then assert the run died without one.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
printf '#!/bin/sh\necho CURL_WAS_INVOKED\nexit 0\n' >"$stub_dir/curl"
chmod +x "$stub_dir/curl"

rc=0
out=$(PATH="$stub_dir:$PATH" \
  CHAIN_NAME=base FORK_RPC_URL=http://rpc.example BLOCK_TIME_MS=2000 \
  SNAPSHOT_API_URL='"https://snapshots.example/api"' ANVIL_PORT=8545 \
  bash "$SCRIPT_DIR/anvil-fork.sh" 2>&1) || rc=$?

if (( rc != 0 )); then
  pass "quoted SNAPSHOT_API_URL: entrypoint exits non-zero"
else
  fail "quoted SNAPSHOT_API_URL: entrypoint exits non-zero (exited 0)"
fi
if [[ "$out" == *"literal quote character"* && "$out" == *SNAPSHOT_API_URL* ]]; then
  pass "quoted SNAPSHOT_API_URL: error names the variable and the cause"
else
  fail "quoted SNAPSHOT_API_URL: error names the variable and the cause (got: $out)"
fi
if [[ "$out" != *CURL_WAS_INVOKED* ]]; then
  pass "quoted SNAPSHOT_API_URL: dies before any curl runs"
else
  fail "quoted SNAPSHOT_API_URL: dies before any curl runs (curl was invoked)"
fi

# 9. edgenet.sh guards the same failure mode on its own vars. HOME is a throwaway
#    dir so a regression that reaches the `rm -rf $CHAIN_HOME/` cannot touch
#    anything real.
fake_home=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$fake_home"' EXIT

rc=0
out=$(HOME="$fake_home" BINARY='"lumend"' CHAIN_ID=edgenet-1 \
  SNAPSHOT_URL=https://snapshots.example/s.tar.lz4 \
  bash "$SCRIPT_DIR/edgenet.sh" 2>&1) || rc=$?

if (( rc != 0 )) && [[ "$out" == *"literal quote character"* && "$out" == *BINARY* ]]; then
  pass "edgenet.sh: quoted BINARY is rejected before any teardown"
else
  fail "edgenet.sh: quoted BINARY is rejected before any teardown (rc=$rc, got: $out)"
fi

# 10. Stale image: HOME is baked into the layer as `ENV HOME /${BINARY}`, so an
#     image built while BINARY was quoted carries HOME=/"lumend" even after .env
#     is cleaned up. Every var below is clean, so the .env loop passes and only
#     the HOME check stands between this run and `rm -rf $CHAIN_HOME/`.
#     CHAIN_HOME lands inside the temp dir; a sentinel there proves the teardown
#     never ran, rather than merely trusting the exit code.
stale_home="$fake_home/\"lumend\""
mkdir -p "$stale_home/.lumend"
: >"$stale_home/.lumend/sentinel"

rc=0
out=$(HOME="$stale_home" BINARY=lumend CHAIN_ID=edgenet-1 DENOM=ualpha STAKE_DENOM=usync \
  SNAPSHOT_URL=https://snapshots.example/s.tar.lz4 \
  bash "$SCRIPT_DIR/edgenet.sh" 2>&1) || rc=$?

if (( rc != 0 )); then
  pass "stale image: quoted HOME exits non-zero despite a clean .env"
else
  fail "stale image: quoted HOME exits non-zero despite a clean .env (exited 0)"
fi
if [[ -f "$stale_home/.lumend/sentinel" ]]; then
  pass "stale image: quoted HOME dies before the rm -rf teardown"
else
  fail "stale image: quoted HOME dies before the rm -rf teardown (CHAIN_HOME was wiped)"
fi
if [[ "$out" == *HOME* && "$out" == *"Rebuild the image"* ]]; then
  pass "stale image: error points at rebuilding the image"
else
  fail "stale image: error points at rebuilding the image (got: $out)"
fi
if [[ "$out" != *"remove the surrounding quotes"* ]]; then
  pass "stale image: error does not misdirect to .env"
else
  fail "stale image: error does not misdirect to .env (blamed .env instead)"
fi

# --- summary --------------------------------------------------------------------

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 )) || exit 1
