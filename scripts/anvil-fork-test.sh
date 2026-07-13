#!/usr/bin/env bash
#
# Self-test for anvil-fork.sh. No bats, no network: sources the script
# (main() is guarded behind BASH_SOURCE) for unit-level checks, and runs
# the entrypoint end to end with a stubbed anvil that prints its argv.
#
# Run: bash scripts/anvil-fork-test.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=anvil-fork.sh
source "$SCRIPT_DIR/anvil-fork.sh"

# --- harness --------------------------------------------------------------------

PASS=0
FAIL=0

pass() { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$1"; }

assert_eq() { # expected actual desc
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected $1, got $2)"; fi
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

# Stub anvil: `exec anvil ...` in the entrypoint hits this instead, printing
# its argv one per line so tests can assert on the exact command produced.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
printf '#!/bin/sh\necho ANVIL_WAS_INVOKED\nfor a in "$@"; do echo "arg:$a"; done\nexit 0\n' >"$stub_dir/anvil"
chmod +x "$stub_dir/anvil"

# desc env... -- runs the entrypoint with the anvil stub; sets RUN_RC / RUN_OUT.
RUN_RC=0
RUN_OUT=""
run_entrypoint() {
  RUN_RC=0
  RUN_OUT=$(env "$@" PATH="$stub_dir:$PATH" bash "$SCRIPT_DIR/anvil-fork.sh" 2>&1) || RUN_RC=$?
}

# --- tests ------------------------------------------------------------------------

# 1. FORK_BLOCK unset: anvil forks at the chain tip, no --fork-block-number.
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545
assert_eq 0 "$RUN_RC" "tip mode: entrypoint execs anvil successfully"
if [[ "$RUN_OUT" != *"arg:--fork-block-number"* ]]; then
  pass "tip mode: no --fork-block-number flag"
else
  fail "tip mode: no --fork-block-number flag (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"arg:--fork-url"* && "$RUN_OUT" == *"arg:http://rpc.example"* ]]; then
  pass "tip mode: --fork-url is passed through"
else
  fail "tip mode: --fork-url is passed through (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"arg:--port"* && "$RUN_OUT" == *"arg:8545"* ]]; then
  pass "tip mode: --port is passed through"
else
  fail "tip mode: --port is passed through (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"chain tip"* ]]; then
  pass "tip mode: log announces chain-tip mode"
else
  fail "tip mode: log announces chain-tip mode (got: $RUN_OUT)"
fi

# 2. FORK_BLOCK set but empty: same as unset (compose passes empty strings
#    for undefined .env vars, so empty must mean tip, not an error).
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 FORK_BLOCK=
assert_eq 0 "$RUN_RC" "empty FORK_BLOCK: entrypoint execs anvil successfully"
if [[ "$RUN_OUT" != *"arg:--fork-block-number"* && "$RUN_OUT" == *"chain tip"* ]]; then
  pass "empty FORK_BLOCK: treated as chain tip"
else
  fail "empty FORK_BLOCK: treated as chain tip (got: $RUN_OUT)"
fi

# 3. FORK_BLOCK set: the flag is passed with exactly that value.
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 FORK_BLOCK=12345678
assert_eq 0 "$RUN_RC" "pinned mode: entrypoint execs anvil successfully"
if [[ "$RUN_OUT" == *"arg:--fork-block-number
arg:12345678"* ]]; then
  pass "pinned mode: --fork-block-number 12345678 is passed"
else
  fail "pinned mode: --fork-block-number 12345678 is passed (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"pinned block 12345678"* ]]; then
  pass "pinned mode: log announces the pinned height"
else
  fail "pinned mode: log announces the pinned height (got: $RUN_OUT)"
fi

# 4. Malformed FORK_BLOCK is fatal before anvil starts.
for bad in not-a-number -5 1.5 0 0x10; do
  run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 FORK_BLOCK="$bad"
  if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *"positive integer block number"* ]]; then
    pass "FORK_BLOCK=$bad is fatal"
  else
    fail "FORK_BLOCK=$bad is fatal (rc=$RUN_RC, got: $RUN_OUT)"
  fi
  if [[ "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
    pass "FORK_BLOCK=$bad dies before anvil starts"
  else
    fail "FORK_BLOCK=$bad dies before anvil starts (anvil was invoked)"
  fi
done

# 5. Missing required env is fatal.
run_entrypoint CHAIN_NAME=base ANVIL_PORT=8545
if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *FORK_RPC_URL* && "$RUN_OUT" == *"is not set"* ]]; then
  pass "missing FORK_RPC_URL is fatal and names the variable"
else
  fail "missing FORK_RPC_URL is fatal and names the variable (rc=$RUN_RC, got: $RUN_OUT)"
fi

# 6. Quoted env values. A quote-preserving .env parse ships FORK_RPC_URL as
#    the literal string "http://rpc.example" (quotes included), which bash
#    never strips, so anvil would dial a URL that cannot parse. require_env
#    must reject it.
QUOTED_URL='"https://rpc.example"'
QUOTED_DENOM="'usync'"
PLAIN_URL='https://rpc.example'

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

# The whole point is to fail before anvil dials out: a quoted FORK_RPC_URL
# through the real entrypoint must die without invoking anvil.
run_entrypoint CHAIN_NAME=base FORK_RPC_URL='"http://rpc.example"' ANVIL_PORT=8545
if (( RUN_RC != 0 )); then
  pass "quoted FORK_RPC_URL: entrypoint exits non-zero"
else
  fail "quoted FORK_RPC_URL: entrypoint exits non-zero (exited 0)"
fi
if [[ "$RUN_OUT" == *"literal quote character"* && "$RUN_OUT" == *FORK_RPC_URL* ]]; then
  pass "quoted FORK_RPC_URL: error names the variable and the cause"
else
  fail "quoted FORK_RPC_URL: error names the variable and the cause (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
  pass "quoted FORK_RPC_URL: dies before anvil starts"
else
  fail "quoted FORK_RPC_URL: dies before anvil starts (anvil was invoked)"
fi

# 7. edgenet.sh guards the same failure mode on its own vars. HOME is a throwaway
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

# 8. Stale image: HOME is baked into the layer as `ENV HOME /${BINARY}`, so an
#    image built while BINARY was quoted carries HOME=/"lumend" even after .env
#    is cleaned up. Every var below is clean, so the .env loop passes and only
#    the HOME check stands between this run and `rm -rf $CHAIN_HOME/`.
#    CHAIN_HOME lands inside the temp dir; a sentinel there proves the teardown
#    never ran, rather than merely trusting the exit code.
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
