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

# 9. Restart behaviour. edgenet.sh writes $CHAIN_HOME/initialized before handing off
#    to in-place-testnet; a home carrying that sentinel must skip setup entirely and
#    just start the node. Stubs stand in for everything the script shells out to, so
#    the setup path can run to completion without a network or a real chain binary.
edgenet_stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$fake_home" "$edgenet_stub_dir"' EXIT

# The chain binary logs its argv to $EDGENET_LOG. `init` creates the config dir the
# real one would; `keys show` prints an address; `in-place-testnet` additionally
# records whether the sentinel already existed when it was invoked.
cat >"$edgenet_stub_dir/lumend" <<'STUB'
#!/bin/sh
echo "BINARY_INVOKED:$*" >>"$EDGENET_LOG"
case "$1" in
  init)
    cat >/dev/null
    mkdir -p "$HOME/.lumend/config"
    ;;
  keys)
    # Only `keys add` is fed a mnemonic on stdin; `keys show` must not read at all
    # (it runs in a command substitution and would block on the caller's stdin).
    [ "$2" = "add" ] && cat >/dev/null
    [ "$2" = "show" ] && echo euclid1validatoraddressstub
    ;;
  in-place-testnet)
    if [ -f "$HOME/.lumend/initialized" ]; then
      echo "SENTINEL_PRESENT_AT_CONVERT" >>"$EDGENET_LOG"
    else
      echo "SENTINEL_MISSING_AT_CONVERT" >>"$EDGENET_LOG"
    fi
    ;;
esac
exit 0
STUB
chmod +x "$edgenet_stub_dir/lumend"

# curl logs every call. A restart must not make one at all, so the log doubles as
# the network-silence assertion. Serves snapshot metadata, and writes a file for the
# archive download so the `mv` of the .part file succeeds.
cat >"$edgenet_stub_dir/curl" <<'STUB'
#!/bin/sh
echo "CURL_INVOKED:$*" >>"$EDGENET_LOG"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
  esac
  shift
done
if [ -n "$out" ]; then
  echo snapshot-bytes >"$out"
else
  echo '{"height":25667070,"url":"https://snapshots.example/lumen-1_25667070.tar.lz4"}'
fi
exit 0
STUB
chmod +x "$edgenet_stub_dir/curl"

# dasel and lz4 are not installed on a dev machine, and real tar would reject the fake
# archive. lz4 writes nothing, so the tar stub sees EOF on the pipe immediately; neither
# reads the caller's stdin.
printf '#!/bin/sh\nexit 0\n' >"$edgenet_stub_dir/dasel"
printf '#!/bin/sh\nexit 0\n' >"$edgenet_stub_dir/lz4"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$edgenet_stub_dir/tar"
chmod +x "$edgenet_stub_dir/dasel" "$edgenet_stub_dir/lz4" "$edgenet_stub_dir/tar"

# desc -- runs edgenet.sh against a fresh fake HOME; sets EDGENET_RC/EDGENET_OUT/EDGENET_LOG.
EDGENET_RC=0
EDGENET_OUT=""
EDGENET_HOME=""
EDGENET_LOG=""
run_edgenet() {
  EDGENET_HOME=$(mktemp -d "$fake_home/run.XXXXXX")
  EDGENET_LOG="$EDGENET_HOME/calls.log"
  : >"$EDGENET_LOG"
  echo '{}' >"$EDGENET_HOME/genesis.json"
  mkdir -p "$EDGENET_HOME/.lumend"
  "$@" # caller may seed CHAIN_HOME (e.g. drop the sentinel in) before the run
  EDGENET_RC=0
  EDGENET_OUT=$(env HOME="$EDGENET_HOME" EDGENET_LOG="$EDGENET_LOG" \
    PATH="$edgenet_stub_dir:$PATH" \
    BINARY=lumend CHAIN_ID=edgenet-1 DENOM=ualpha STAKE_DENOM=usync \
    VALIDATOR_MONIKER=validator VALIDATOR_MNEMONIC='test test test' \
    SNAPSHOT_URL=https://snapshots.example/meta.json \
    bash "$SCRIPT_DIR/edgenet.sh" </dev/null 2>&1) || EDGENET_RC=$?
}

seed_sentinel() { : >"$EDGENET_HOME/.lumend/initialized"; }

# 9a. Sentinel absent: the setup path runs, and the sentinel is on disk by the time
#     in-place-testnet is invoked (it never returns, so there is no later chance).
run_edgenet true
log=$(cat "$EDGENET_LOG")
assert_eq 0 "$EDGENET_RC" "first boot: setup path exits cleanly"
if [[ "$log" == *"BINARY_INVOKED:in-place-testnet edgenet-1 euclid1validatoraddressstub"* ]]; then
  pass "first boot: in-place-testnet is invoked with the chain id and validator address"
else
  fail "first boot: in-place-testnet is invoked (got: $log)"
fi
if [[ "$log" == *SENTINEL_PRESENT_AT_CONVERT* ]]; then
  pass "first boot: sentinel exists by the time in-place-testnet is invoked"
else
  fail "first boot: sentinel exists by the time in-place-testnet is invoked (got: $log)"
fi
if [[ -f "$EDGENET_HOME/.lumend/initialized" ]]; then
  pass "first boot: sentinel is left behind in CHAIN_HOME"
else
  fail "first boot: sentinel is left behind in CHAIN_HOME"
fi
if [[ "$log" == *BINARY_INVOKED:init* && "$log" == *CURL_INVOKED* ]]; then
  pass "first boot: runs init and fetches the snapshot"
else
  fail "first boot: runs init and fetches the snapshot (got: $log)"
fi
if [[ "$EDGENET_OUT" == *"No existing chain"* ]]; then
  pass "first boot: log announces the setup path"
else
  fail "first boot: log announces the setup path (got: $EDGENET_OUT)"
fi

# 9b. Sentinel present: `start` with the exact serving flags, and no in-place-testnet.
run_edgenet seed_sentinel
log=$(cat "$EDGENET_LOG")
assert_eq 0 "$EDGENET_RC" "restart: exits cleanly"
if [[ "$log" == *"BINARY_INVOKED:start --home $EDGENET_HOME/.lumend --rpc.laddr tcp://0.0.0.0:26657 --api.enable true --api.swagger true --api.enabled-unsafe-cors true"* ]]; then
  pass "restart: start is invoked with the exact serving flags"
else
  fail "restart: start is invoked with the exact serving flags (got: $log)"
fi
if [[ "$log" != *in-place-testnet* ]]; then
  pass "restart: in-place-testnet is NOT invoked"
else
  fail "restart: in-place-testnet is NOT invoked (it was: $log)"
fi
if [[ "$log" != *CURL_INVOKED* ]]; then
  pass "restart: makes no curl call to the snapshot endpoint"
else
  fail "restart: makes no curl call to the snapshot endpoint (got: $log)"
fi
if [[ "$log" != *BINARY_INVOKED:init* && "$log" != *BINARY_INVOKED:keys* ]]; then
  pass "restart: skips init and key add"
else
  fail "restart: skips init and key add (got: $log)"
fi
if [[ "$EDGENET_OUT" == *"Existing chain found"* ]]; then
  pass "restart: log announces the restart path"
else
  fail "restart: log announces the restart path (got: $EDGENET_OUT)"
fi

# 9c. The sentinel does not buy a pass on the quote guards: they validate values the
#     restart path uses too ($BINARY and $CHAIN_HOME both feed `start`).
EDGENET_RC=0
seeded=$(mktemp -d "$fake_home/run.XXXXXX")
mkdir -p "$seeded/.lumend"
: >"$seeded/.lumend/initialized"
out=$(env HOME="$seeded" EDGENET_LOG=/dev/null PATH="$edgenet_stub_dir:$PATH" \
  BINARY='"lumend"' CHAIN_ID=edgenet-1 DENOM=ualpha STAKE_DENOM=usync \
  SNAPSHOT_URL=https://snapshots.example/meta.json \
  bash "$SCRIPT_DIR/edgenet.sh" 2>&1) || EDGENET_RC=$?
if (( EDGENET_RC != 0 )) && [[ "$out" == *"literal quote character"* ]]; then
  pass "restart: quote guards still run on the sentinel path"
else
  fail "restart: quote guards still run on the sentinel path (rc=$EDGENET_RC, got: $out)"
fi

# --- summary --------------------------------------------------------------------

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 )) || exit 1
