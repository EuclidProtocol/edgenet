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
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
  BLOCK_TIME=2 EVM_CHAIN_ID=84539
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
# Without --block-time anvil mines only on transactions and never produces an
# empty block, so the flag has to reach anvil on this branch too, not just the
# pinned one.
if [[ "$RUN_OUT" == *"arg:--block-time
arg:2"* ]]; then
  pass "tip mode: --block-time 2 is passed"
else
  fail "tip mode: --block-time 2 is passed (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"arg:--chain-id
arg:84539"* ]]; then
  pass "tip mode: --chain-id 84539 is passed"
else
  fail "tip mode: --chain-id 84539 is passed (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"chain id 84539"* && "$RUN_OUT" == *"every 2s"* ]]; then
  pass "tip mode: log announces the chain id and the block time"
else
  fail "tip mode: log announces the chain id and the block time (got: $RUN_OUT)"
fi

# 2. FORK_BLOCK set but empty: same as unset (compose passes empty strings
#    for undefined .env vars, so empty must mean tip, not an error).
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
  BLOCK_TIME=2 EVM_CHAIN_ID=84539 FORK_BLOCK=
assert_eq 0 "$RUN_RC" "empty FORK_BLOCK: entrypoint execs anvil successfully"
if [[ "$RUN_OUT" != *"arg:--fork-block-number"* && "$RUN_OUT" == *"chain tip"* ]]; then
  pass "empty FORK_BLOCK: treated as chain tip"
else
  fail "empty FORK_BLOCK: treated as chain tip (got: $RUN_OUT)"
fi

# 3. FORK_BLOCK set: the flag is passed with exactly that value.
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
  BLOCK_TIME=2 EVM_CHAIN_ID=84539 FORK_BLOCK=12345678
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
# The two branches are separate `exec anvil` lines, so both need asserting.
if [[ "$RUN_OUT" == *"arg:--block-time
arg:2"* ]]; then
  pass "pinned mode: --block-time 2 is passed"
else
  fail "pinned mode: --block-time 2 is passed (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"arg:--chain-id
arg:84539"* ]]; then
  pass "pinned mode: --chain-id 84539 is passed"
else
  fail "pinned mode: --chain-id 84539 is passed (got: $RUN_OUT)"
fi
if [[ "$RUN_OUT" == *"chain id 84539"* && "$RUN_OUT" == *"every 2s"* ]]; then
  pass "pinned mode: log announces the chain id and the block time"
else
  fail "pinned mode: log announces the chain id and the block time (got: $RUN_OUT)"
fi

# 3b. The values are read from the environment, not hard coded: a second chain
#     (Somnia) gets its own chain id and block time.
run_entrypoint CHAIN_NAME=somnia FORK_RPC_URL=http://rpc.example ANVIL_PORT=8546 \
  BLOCK_TIME=1 EVM_CHAIN_ID=50319
assert_eq 0 "$RUN_RC" "somnia: entrypoint execs anvil successfully"
if [[ "$RUN_OUT" == *"arg:--block-time
arg:1"* && "$RUN_OUT" == *"arg:--chain-id
arg:50319"* ]]; then
  pass "somnia: --block-time 1 and --chain-id 50319 are passed"
else
  fail "somnia: --block-time 1 and --chain-id 50319 are passed (got: $RUN_OUT)"
fi

# 3c. A third chain (Polygon) gets its own chain id and block time too.
run_entrypoint CHAIN_NAME=polygon FORK_RPC_URL=http://rpc.example ANVIL_PORT=8547 \
  BLOCK_TIME=2 EVM_CHAIN_ID=1379
assert_eq 0 "$RUN_RC" "polygon: entrypoint execs anvil successfully"
if [[ "$RUN_OUT" == *"arg:--block-time
arg:2"* && "$RUN_OUT" == *"arg:--chain-id
arg:1379"* ]]; then
  pass "polygon: --block-time 2 and --chain-id 1379 are passed"
else
  fail "polygon: --block-time 2 and --chain-id 1379 are passed (got: $RUN_OUT)"
fi

# 4. Malformed FORK_BLOCK is fatal before anvil starts.
for bad in not-a-number -5 1.5 0 0x10; do
  run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
    BLOCK_TIME=2 EVM_CHAIN_ID=84539 FORK_BLOCK="$bad"
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

# 4b. Malformed BLOCK_TIME / EVM_CHAIN_ID are fatal before anvil starts, on the
#     same terms as FORK_BLOCK. A hex chain id is the interesting one: it is how
#     eth_chainId reports the value, and anvil would reject it.
for bad in not-a-number -5 1.5 0 0x10; do
  run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
    BLOCK_TIME="$bad" EVM_CHAIN_ID=84539
  if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *"positive integer number of seconds"* ]]; then
    pass "BLOCK_TIME=$bad is fatal"
  else
    fail "BLOCK_TIME=$bad is fatal (rc=$RUN_RC, got: $RUN_OUT)"
  fi
  if [[ "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
    pass "BLOCK_TIME=$bad dies before anvil starts"
  else
    fail "BLOCK_TIME=$bad dies before anvil starts (anvil was invoked)"
  fi

  run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
    BLOCK_TIME=2 EVM_CHAIN_ID="$bad"
  if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *"positive integer chain id"* ]]; then
    pass "EVM_CHAIN_ID=$bad is fatal"
  else
    fail "EVM_CHAIN_ID=$bad is fatal (rc=$RUN_RC, got: $RUN_OUT)"
  fi
  if [[ "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
    pass "EVM_CHAIN_ID=$bad dies before anvil starts"
  else
    fail "EVM_CHAIN_ID=$bad dies before anvil starts (anvil was invoked)"
  fi
done

# 5. Missing required env is fatal.
run_entrypoint CHAIN_NAME=base ANVIL_PORT=8545 BLOCK_TIME=2 EVM_CHAIN_ID=84539
if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *FORK_RPC_URL* && "$RUN_OUT" == *"is not set"* ]]; then
  pass "missing FORK_RPC_URL is fatal and names the variable"
else
  fail "missing FORK_RPC_URL is fatal and names the variable (rc=$RUN_RC, got: $RUN_OUT)"
fi

# 5b. BLOCK_TIME and EVM_CHAIN_ID are required, not defaulted: an unset one must
#     stop the boot rather than let anvil fall back to instant-mining or its own
#     chain id. Compose ships an undefined .env var as an empty string, so empty
#     has to be fatal too.
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 EVM_CHAIN_ID=84539
if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *BLOCK_TIME* && "$RUN_OUT" == *"is not set"* \
  && "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
  pass "missing BLOCK_TIME is fatal before anvil starts and names the variable"
else
  fail "missing BLOCK_TIME is fatal before anvil starts and names the variable (rc=$RUN_RC, got: $RUN_OUT)"
fi

run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 BLOCK_TIME=2
if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *EVM_CHAIN_ID* && "$RUN_OUT" == *"is not set"* \
  && "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
  pass "missing EVM_CHAIN_ID is fatal before anvil starts and names the variable"
else
  fail "missing EVM_CHAIN_ID is fatal before anvil starts and names the variable (rc=$RUN_RC, got: $RUN_OUT)"
fi

run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
  BLOCK_TIME= EVM_CHAIN_ID=
if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *"is not set"* && "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
  pass "empty BLOCK_TIME/EVM_CHAIN_ID are fatal before anvil starts"
else
  fail "empty BLOCK_TIME/EVM_CHAIN_ID are fatal before anvil starts (rc=$RUN_RC, got: $RUN_OUT)"
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
run_entrypoint CHAIN_NAME=base FORK_RPC_URL='"http://rpc.example"' ANVIL_PORT=8545 \
  BLOCK_TIME=2 EVM_CHAIN_ID=84539
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

# BLOCK_TIME and EVM_CHAIN_ID are in require_env, so the same quote guard covers
# them: a quoted "2" would otherwise reach anvil as a literal-quoted argument.
run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
  BLOCK_TIME='"2"' EVM_CHAIN_ID=84539
if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *"literal quote character"* && "$RUN_OUT" == *BLOCK_TIME* \
  && "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
  pass "quoted BLOCK_TIME: rejected by the quote guard before anvil starts"
else
  fail "quoted BLOCK_TIME: rejected by the quote guard before anvil starts (rc=$RUN_RC, got: $RUN_OUT)"
fi

run_entrypoint CHAIN_NAME=base FORK_RPC_URL=http://rpc.example ANVIL_PORT=8545 \
  BLOCK_TIME=2 EVM_CHAIN_ID="'84539'"
if (( RUN_RC != 0 )) && [[ "$RUN_OUT" == *"literal quote character"* && "$RUN_OUT" == *EVM_CHAIN_ID* \
  && "$RUN_OUT" != *ANVIL_WAS_INVOKED* ]]; then
  pass "quoted EVM_CHAIN_ID: rejected by the quote guard before anvil starts"
else
  fail "quoted EVM_CHAIN_ID: rejected by the quote guard before anvil starts (rc=$RUN_RC, got: $RUN_OUT)"
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
# real one would, along with the priv_validator_key.json it would generate (the INIT_*
# values below stand for the key a fresh `init` mints, which the snapshot may later
# overwrite). `keys show` prints an address, in the operator bech32 prefix when asked
# with --bech val. `in-place-testnet` additionally records whether the sentinel already
# existed when it was invoked.
cat >"$edgenet_stub_dir/lumend" <<'STUB'
#!/bin/sh
echo "BINARY_INVOKED:$*" >>"$EDGENET_LOG"
case "$1" in
  init)
    cat >/dev/null
    mkdir -p "$HOME/.lumend/config"
    printf '%s' '{"address":"INITADDR","pub_key":{"type":"tendermint/PubKeyEd25519","value":"INIT_PUBKEY_FROM_INIT"},"priv_key":{"type":"tendermint/PrivKeyEd25519","value":"INIT_PRIVKEY_FROM_INIT"}}' \
      >"$HOME/.lumend/config/priv_validator_key.json"
    ;;
  keys)
    # Only `keys add` is fed a mnemonic on stdin; `keys show` must not read at all
    # (it runs in a command substitution and would block on the caller's stdin).
    [ "$2" = "add" ] && cat >/dev/null
    if [ "$2" = "show" ]; then
      case " $* " in
        *" --bech val "*) echo euclidvaloper1validatoroperatorstub ;;
        *)                echo euclid1validatoraddressstub ;;
      esac
    fi
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

# A real mainnet snapshot tarball can carry its own config/, so extracting it clobbers
# the priv_validator_key.json that `init` just generated. That is exactly why edgenet.sh
# must read the consensus key AFTER extraction. This stub reproduces it: SNAPSHOT_KEY
# is what the "archive" drops at config/priv_validator_key.json on top of init's file.
#   unset      -> archive carries no config/, init's key survives
#   __DELETE__ -> archive's config/ has no key file at all (deletes it)
#   __EMPTY__  -> archive carries a truncated/empty key file
#   anything   -> that literal JSON is written
cat >"$edgenet_stub_dir/tar" <<'STUB'
#!/bin/sh
cat >/dev/null
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir=$2; shift ;;
  esac
  shift
done
echo "TAR_INVOKED:extracted-to:$dir" >>"$EDGENET_LOG"
key=$dir/config/priv_validator_key.json
case "${SNAPSHOT_KEY:-}" in
  "")         ;;
  __DELETE__) rm -f "$key" ;;
  __EMPTY__)  mkdir -p "$dir/config"; : >"$key" ;;
  *)          mkdir -p "$dir/config"; printf '%s' "$SNAPSHOT_KEY" >"$key" ;;
esac
exit 0
STUB
chmod +x "$edgenet_stub_dir/dasel" "$edgenet_stub_dir/lz4" "$edgenet_stub_dir/tar"

# run_edgenet <seed-cmd...> -- runs edgenet.sh against a fresh fake HOME; sets
# EDGENET_RC/EDGENET_OUT/EDGENET_LOG. Callers add per-run environment (FUNDED_ACCOUNTS,
# SNAPSHOT_KEY) by filling EDGENET_ENV before the call; it is reset after every run so
# one test's environment cannot leak into the next.
EDGENET_RC=0
EDGENET_OUT=""
EDGENET_HOME=""
EDGENET_LOG=""
EDGENET_ENV=()
run_edgenet() {
  EDGENET_HOME=$(mktemp -d "$fake_home/run.XXXXXX")
  EDGENET_LOG="$EDGENET_HOME/calls.log"
  : >"$EDGENET_LOG"
  # Dockerfile.edgenet bakes both of these into $HOME; edgenet.sh copies them into
  # CONFIG_FOLDER, so a fake HOME missing either one fails the setup path at the cp.
  echo '{}' >"$EDGENET_HOME/genesis.json"
  : >"$EDGENET_HOME/config.toml"
  mkdir -p "$EDGENET_HOME/.lumend"
  "$@" # caller may seed CHAIN_HOME (e.g. drop the sentinel in) before the run
  EDGENET_RC=0
  # ${arr[@]+"${arr[@]}"} because bash 3.2 (the macOS system bash this suite runs under)
  # treats an empty array as unset under `set -u`.
  EDGENET_OUT=$(env HOME="$EDGENET_HOME" EDGENET_LOG="$EDGENET_LOG" \
    PATH="$edgenet_stub_dir:$PATH" \
    BINARY=lumend CHAIN_ID=edgenet-1 DENOM=ualpha STAKE_DENOM=usync \
    VALIDATOR_MONIKER=validator VALIDATOR_MNEMONIC='test test test' \
    SNAPSHOT_URL=https://snapshots.example/meta.json \
    ${EDGENET_ENV[@]+"${EDGENET_ENV[@]}"} \
    bash "$SCRIPT_DIR/edgenet.sh" </dev/null 2>&1) || EDGENET_RC=$?
  EDGENET_ENV=()
}

seed_sentinel() { : >"$EDGENET_HOME/.lumend/initialized"; }

# 9a. Sentinel absent: the setup path runs, and the sentinel is on disk by the time
#     in-place-testnet is invoked (it never returns, so there is no later chance).
run_edgenet true
log=$(cat "$EDGENET_LOG")
assert_eq 0 "$EDGENET_RC" "first boot: setup path exits cleanly"
if [[ "$log" == *"BINARY_INVOKED:in-place-testnet edgenet-1 --validator-operator=euclidvaloper1validatoroperatorstub"* ]]; then
  pass "first boot: in-place-testnet is invoked with the chain id and the validator operator"
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

# 10. in-place-testnet arguments. Everything it is handed is derived from the node's
#     own keys at runtime: the operator address from the keyring, the consensus key pair
#     from config/priv_validator_key.json.
SNAP_PUB='SNAPSHOT_PUBKEY_Zm9vYmFy'
SNAP_PRIV='SNAPSHOT_PRIVKEY_c2VjcmV0'
SNAP_KEY_JSON="{\"address\":\"SNAPADDR\",\"pub_key\":{\"type\":\"tendermint/PubKeyEd25519\",\"value\":\"$SNAP_PUB\"},\"priv_key\":{\"type\":\"tendermint/PrivKeyEd25519\",\"value\":\"$SNAP_PRIV\"}}"

# 10a. The full command line, with FUNDED_ACCOUNTS unset.
EDGENET_ENV=("SNAPSHOT_KEY=$SNAP_KEY_JSON")
run_edgenet true
log=$(cat "$EDGENET_LOG")
assert_eq 0 "$EDGENET_RC" "in-place-testnet: setup path exits cleanly"

expected_cmd="BINARY_INVOKED:in-place-testnet edgenet-1 \
--validator-operator=euclidvaloper1validatoroperatorstub \
--validator-pubkey=$SNAP_PUB \
--validator-privkey=$SNAP_PRIV \
--accounts-to-fund=euclid1validatoraddressstub \
--cosmwasm-admin=euclid1validatoraddressstub \
--home $EDGENET_HOME/.lumend \
--coins-to-fund 1000000000000ualpha,1000000000000usync"
if [[ "$log" == *"$expected_cmd"* ]]; then
  pass "in-place-testnet: exact command line (operator, pubkey, privkey, accounts, admin, coins)"
else
  fail "in-place-testnet: exact command line
  expected: $expected_cmd
  got:      $log"
fi

# The consensus key is the node's block-signing key. It is passed on the command line
# because in-place-testnet takes it there, but edgenet.sh must never print it.
if [[ "$EDGENET_OUT" != *"$SNAP_PRIV"* ]]; then
  pass "in-place-testnet: the private key never appears on stdout/stderr"
else
  fail "in-place-testnet: the private key never appears on stdout/stderr (it was printed: $EDGENET_OUT)"
fi
if [[ "$EDGENET_OUT" != *"priv_key"* ]]; then
  pass "in-place-testnet: the key file's contents are never dumped"
else
  fail "in-place-testnet: the key file's contents are never dumped (got: $EDGENET_OUT)"
fi

# ORDERING. The tar stub overwrote priv_validator_key.json with the snapshot's own copy,
# exactly as a real snapshot carrying config/ does. Reading the key after `init` instead
# of after extraction would hand in-place-testnet the (now stale) INIT_* key, so seeing
# the snapshot's key here is the proof that the read happens post-extraction.
if [[ "$log" == *"$SNAP_PUB"* && "$log" != *INIT_PUBKEY_FROM_INIT* && "$log" != *INIT_PRIVKEY_FROM_INIT* ]]; then
  pass "in-place-testnet: consensus key is read AFTER snapshot extraction, not after init"
else
  fail "in-place-testnet: consensus key is read AFTER snapshot extraction, not after init (got: $log)"
fi
if [[ "$log" == *TAR_INVOKED* ]]; then
  pass "in-place-testnet: the snapshot really was extracted in this run"
else
  fail "in-place-testnet: the snapshot really was extracted in this run (got: $log)"
fi

# 10b. FUNDED_ACCOUNTS unset: only the validator account, and no trailing comma (which
#      in-place-testnet would parse as an empty address).
if [[ "$log" == *"--accounts-to-fund=euclid1validatoraddressstub --cosmwasm-admin"* ]]; then
  pass "FUNDED_ACCOUNTS unset: accounts-to-fund is just the validator, no trailing comma"
else
  fail "FUNDED_ACCOUNTS unset: accounts-to-fund is just the validator, no trailing comma (got: $log)"
fi

# 10c. FUNDED_ACCOUNTS empty (compose passes an empty string for an undefined .env var,
#      so empty must behave exactly like unset).
EDGENET_ENV=("SNAPSHOT_KEY=$SNAP_KEY_JSON" "FUNDED_ACCOUNTS=")
run_edgenet true
log=$(cat "$EDGENET_LOG")
assert_eq 0 "$EDGENET_RC" "FUNDED_ACCOUNTS empty: setup path exits cleanly"
if [[ "$log" == *"--accounts-to-fund=euclid1validatoraddressstub --cosmwasm-admin"* ]]; then
  pass "FUNDED_ACCOUNTS empty: accounts-to-fund is just the validator, no trailing comma"
else
  fail "FUNDED_ACCOUNTS empty: accounts-to-fund is just the validator, no trailing comma (got: $log)"
fi
# FUNDED_ACCOUNTS is in the quote-guard loop, but unlike every other var in that loop it
# is legitimately empty. The guard only looks for quote characters, so empty must sail
# through it rather than being read as "unset, therefore broken".
if [[ "$EDGENET_OUT" != *"literal quote character"* ]]; then
  pass "FUNDED_ACCOUNTS empty: passes the quote guard and boots"
else
  fail "FUNDED_ACCOUNTS empty: passes the quote guard and boots (guard rejected it: $EDGENET_OUT)"
fi

# 10d. FUNDED_ACCOUNTS set: appended to the validator account, comma joined.
EDGENET_ENV=("SNAPSHOT_KEY=$SNAP_KEY_JSON" "FUNDED_ACCOUNTS=euclid1aaaaaaaaaa,euclid1bbbbbbbbbb")
run_edgenet true
log=$(cat "$EDGENET_LOG")
assert_eq 0 "$EDGENET_RC" "FUNDED_ACCOUNTS set: setup path exits cleanly"
if [[ "$log" == *"--accounts-to-fund=euclid1validatoraddressstub,euclid1aaaaaaaaaa,euclid1bbbbbbbbbb --cosmwasm-admin"* ]]; then
  pass "FUNDED_ACCOUNTS set: validator account plus the configured accounts, comma joined"
else
  fail "FUNDED_ACCOUNTS set: validator account plus the configured accounts, comma joined (got: $log)"
fi
if [[ "$log" == *"--cosmwasm-admin=euclid1validatoraddressstub"* ]]; then
  pass "FUNDED_ACCOUNTS set: cosmwasm-admin stays the validator account"
else
  fail "FUNDED_ACCOUNTS set: cosmwasm-admin stays the validator account (got: $log)"
fi

# 10e. A quoted FUNDED_ACCOUNTS is the same bug class the quote guard exists for: bash
#      never strips the quotes, so `--accounts-to-fund="euclid1..."` would reach the
#      chain as a literal-quoted bech32 address. The guard runs first, so this dies
#      before any teardown, let alone before in-place-testnet.
EDGENET_ENV=("SNAPSHOT_KEY=$SNAP_KEY_JSON" 'FUNDED_ACCOUNTS="euclid1aaaaaaaaaa"')
run_edgenet true
log=$(cat "$EDGENET_LOG")
if (( EDGENET_RC != 0 )) && [[ "$EDGENET_OUT" == *"literal quote character"* && "$EDGENET_OUT" == *FUNDED_ACCOUNTS* ]]; then
  pass "quoted FUNDED_ACCOUNTS: rejected by the quote guard, which names the variable"
else
  fail "quoted FUNDED_ACCOUNTS: rejected by the quote guard, which names the variable (rc=$EDGENET_RC, got: $EDGENET_OUT)"
fi
if [[ "$EDGENET_OUT" == *"remove the surrounding quotes"* ]]; then
  pass "quoted FUNDED_ACCOUNTS: error keeps the loop's .env wording"
else
  fail "quoted FUNDED_ACCOUNTS: error keeps the loop's .env wording (got: $EDGENET_OUT)"
fi
if [[ "$log" != *in-place-testnet* ]]; then
  pass "quoted FUNDED_ACCOUNTS: dies before in-place-testnet runs"
else
  fail "quoted FUNDED_ACCOUNTS: dies before in-place-testnet runs (it ran: $log)"
fi

# Single quotes too, since a .env parse that preserves them is the same defect.
EDGENET_ENV=("SNAPSHOT_KEY=$SNAP_KEY_JSON" "FUNDED_ACCOUNTS='euclid1aaaaaaaaaa'")
run_edgenet true
log=$(cat "$EDGENET_LOG")
if (( EDGENET_RC != 0 )) && [[ "$EDGENET_OUT" == *"literal quote character"* && "$log" != *in-place-testnet* ]]; then
  pass "single-quoted FUNDED_ACCOUNTS: fatal before in-place-testnet runs"
else
  fail "single-quoted FUNDED_ACCOUNTS: fatal before in-place-testnet runs (rc=$EDGENET_RC, got: $EDGENET_OUT)"
fi

# 10f. An unusable priv_validator_key.json is fatal, and fatal BEFORE in-place-testnet:
#      handing it an empty --validator-privkey would produce a chain that cannot sign.
#      One case per way the file can be unusable after extraction.
EMPTY_FIELDS_JSON='{"address":"X","pub_key":{"type":"tendermint/PubKeyEd25519","value":""},"priv_key":{"type":"tendermint/PrivKeyEd25519","value":""}}'
NO_PRIV_JSON="{\"pub_key\":{\"type\":\"tendermint/PubKeyEd25519\",\"value\":\"$SNAP_PUB\"}}"

for bad_case in "__DELETE__:missing file" "__EMPTY__:empty file" "$EMPTY_FIELDS_JSON:empty key fields" "$NO_PRIV_JSON:no priv_key"; do
  bad_key=${bad_case%:*}
  bad_desc=${bad_case##*:}
  EDGENET_ENV=("SNAPSHOT_KEY=$bad_key")
  run_edgenet true
  log=$(cat "$EDGENET_LOG")
  if (( EDGENET_RC != 0 )) && [[ "$EDGENET_OUT" == *priv_validator_key.json* ]]; then
    pass "bad consensus key ($bad_desc): fatal, and the error names the key file"
  else
    fail "bad consensus key ($bad_desc): fatal, and the error names the key file (rc=$EDGENET_RC, got: $EDGENET_OUT)"
  fi
  if [[ "$log" != *in-place-testnet* ]]; then
    pass "bad consensus key ($bad_desc): dies before in-place-testnet runs"
  else
    fail "bad consensus key ($bad_desc): dies before in-place-testnet runs (it ran: $log)"
  fi
done

# --- summary --------------------------------------------------------------------

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 )) || exit 1
