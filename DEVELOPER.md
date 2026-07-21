# Developer guide

This document explains how the edgenet stack is put together so you can change it
with confidence. It assumes you have already read `README.md` and can start the
stack. Nothing here repeats the quick start or the environment variable table.

## 1. Architecture

The stack is two kinds of container on one shared Docker network.

**The Cosmos node (`edgenet`).** One service, built from `Dockerfile.edgenet`,
running `scripts/edgenet.sh` as its entrypoint. It restores a snapshot of the
Lumen chain and relaunches it as a single validator local network via the
`in-place-testnet` subcommand. It publishes 26657 (RPC), 1317 (LCD) and 9090
(gRPC).

**The anvil forks (`anvil-base`, `anvil-somnia`, `anvil-polygon`).** One
service per EVM chain, all built from the same `Dockerfile.anvil` and all
running `scripts/anvil-fork.sh` as their entrypoint. Each one forks a public
EVM chain either at the current chain tip or at a block height pinned in
`.env`. Base listens on host port 8545, Somnia on 8546, Polygon on 8547;
every container listens on 8545 internally.

**The faucet (`faucet`).** One service, built from `faucet/Dockerfile`. It is
a Vite/React frontend built to `faucet/dist/` and an Express server
(`faucet/server/index.mjs`) that serves that static build and answers
`POST /api/faucet`, funding whichever address and chain the request names. It
publishes host port 3000, both internally and externally, since unlike the
anvil services it is not multiplied across chains. See section 7 for how it
works.

The three kinds differ only in role. All anvil services share one image and one
script; they are distinguished purely by environment (`CHAIN_NAME`,
`FORK_RPC_URL`, `FORK_BLOCK`, `BLOCK_TIME`, `EVM_CHAIN_ID`, `ANVIL_PORT`).
There is no per chain Dockerfile and there should never be one. The faucet is
the only service that talks to every other service: it dials the Lumen node's
RPC and every anvil fork's RPC, all by Compose service name over
`edgenet-network`, exactly the way an external client would.

Everything sits on the `edgenet-network` bridge network declared at the top of
`docker-compose.yml`, so containers can reach each other by service name. All
services are gated behind the `edgenet` Compose profile, which is why the
`Makefile` always passes `--profile edgenet`.

### No ordering, by omission

`docker-compose.yml` has no `depends_on` and no `healthcheck` on any service.
Nothing enforces start order, and nothing enforces readiness. The practical
implications:

* The anvil containers and the Cosmos node start concurrently. An anvil
  container does not wait for the node, and the node does not wait for anvil.
* The anvil containers do not depend on the node at runtime anyway, and they
  do not depend on the Lumen snapshot either. Each one only dials its own
  `FORK_RPC_URL`, an upstream chain RPC, to fork from. So the missing ordering
  is not currently a bug, it is simply unenforced.
* The only backstop is `restart: on-failure`, present on every service. A
  container that dies (for example because its upstream RPC was briefly
  unreachable) is restarted, and `scripts/anvil-fork.sh` re-execs anvil with
  the same `FORK_BLOCK` (or the same tip-forking behaviour, if `FORK_BLOCK` is
  empty) on each restart. A pinned `FORK_BLOCK` reproduces the same fork every
  time; an empty `FORK_BLOCK` forks whatever the chain tip is at restart time,
  which can differ from the tip at the previous start.
* If you ever add a consumer that needs the node's RPC to be live before it
  starts, you must add the ordering yourself. Do not assume it exists.
* The `faucet` container is exactly such a consumer, and it has no ordering
  guarantee either. It can start, and start serving `http://localhost:3000`,
  before the Lumen node or any anvil fork is ready. Nothing prevents this; a
  request that arrives too early simply fails against whichever upstream RPC
  is not yet reachable, the same failure mode a request would hit against a
  fork whose upstream RPC briefly drops, and there is no retry or queueing on
  the faucet side to smooth it over.

## 2. `scripts/anvil-fork.sh`

This script used to resolve a fork block from the Lumen snapshot's wall clock
time by bisecting the upstream chain for the matching block, seeded by a
nominal per chain interval and a snapshot metadata endpoint URL, both supplied
through dedicated environment variables. That resolver, and the environment
variables it used, have been removed entirely. There is no lookup and no
search left in this script. If you are looking for time based fork alignment,
it does not exist anymore; see the note on manual alignment in `README.md`
under "Anvil forks".

### What it does now

**1. Validate the environment.** `main()` calls `require_env` for `CHAIN_NAME`,
`FORK_RPC_URL`, `ANVIL_PORT`, `BLOCK_TIME` and `EVM_CHAIN_ID`. `require_env`
also rejects any of these values if it contains a literal quote character (see
section 9), which matters because a quote surviving expansion silently
corrupts a URL built from it rather than failing loudly on its own.
`BLOCK_TIME` and `EVM_CHAIN_ID` are then each checked against
`^[1-9][0-9]*$`, the same positive integer regex `FORK_BLOCK` is held to
below; a non-positive-integer value in either one is fatal before anvil ever
starts, same as a malformed `FORK_BLOCK`.

**2. Branch on `FORK_BLOCK`.**

```
if FORK_BLOCK is set and non-empty:
  assert FORK_BLOCK matches ^[1-9][0-9]*$, else FATAL
  exec anvil --fork-url "$FORK_RPC_URL" --fork-block-number "$FORK_BLOCK" \
             --block-time "$BLOCK_TIME" --chain-id "$EVM_CHAIN_ID" \
             --host 0.0.0.0 --port "$ANVIL_PORT"
else:
  exec anvil --fork-url "$FORK_RPC_URL" \
             --block-time "$BLOCK_TIME" --chain-id "$EVM_CHAIN_ID" \
             --host 0.0.0.0 --port "$ANVIL_PORT"
```

An empty or unset `FORK_BLOCK` forks the upstream chain's current tip, because
omitting `--fork-block-number` is anvil's own default behaviour. A `FORK_BLOCK`
that is not a positive integer (a decimal, a negative number, `0`, a hex
literal, non numeric text) is fatal before anvil ever starts. `--block-time`
and `--chain-id` are passed identically on both branches, since which block
the fork starts at has no bearing on how it should mine or what chain id it
should report.

**3. `exec` replaces the shell**, so anvil becomes PID 1 and receives signals
directly, same as before.

### Why `--block-time` matters

Without `--block-time`, anvil auto-mines a block on every transaction it
receives and produces no empty blocks in between, so a fork sitting idle
never advances: no new block appears until someone sends it a transaction.
No real chain behaves that way. `BLOCK_TIME` (whole seconds, anvil's `-b`
flag) makes the fork tick on a fixed interval regardless of transaction
activity, the same way the upstream chain does. This was the single biggest
realism gap in the fork and closing it is the point of this change.
`BLOCK_TIME` is hardcoded per service in `docker-compose.yml`, 2 for
`anvil-base`, 1 for `anvil-somnia` and 2 for `anvil-polygon`, rather than
living in `.env`, because it
is a property of how closely the fork should track the upstream chain's own
cadence, not something a deployment should tune.

### `--chain-id` overrides the fork's reported chain id, on purpose

Anvil does not have to inherit the chain id from the chain it forks. Run
`ghcr.io/foundry-rs/foundry:stable` forking `https://mainnet.base.org` with
no `--chain-id` flag at all and query `eth_chainId`, and it answers `0x2105`,
which is 8453, Base's real mainnet chain id. Pass `--chain-id 84539` instead,
and the fork answers `84539`. The flag is not decorative: it changes what
every client of the fork, including a wallet, sees over `eth_chainId`.

That override is the whole reason `EVM_CHAIN_ID` is passed at all. Each fork
answers with its real mainnet chain id plus one inserted digit (Base 8453
becomes 84539, Somnia 5031 becomes 50319, Polygon 137 becomes 1379), never
the real id itself. A wallet or browser extension keys its network list and
cached state off chain id. If a local fork answered the real mainnet id, a
wallet already configured for Base (or Somnia, or Polygon) mainnet would
treat the fork as that same network: same cached balances, same transaction
history, same trust assumptions, wrong chain underneath. The offset id keeps
the fork mechanically distinct from the network it mirrors, so no wallet
already pointed at the real chain can mistake one for the other.

Two smaller benefits fall out of passing the flag explicitly rather than
picking the offset id some other way:

* It makes the value **explicit and reviewable in `docker-compose.yml`**
  rather than implicit in whatever the upstream RPC happens to answer. A
  reader of the compose file can see what chain id each service reports
  without going and asking an RPC endpoint.
* It **pins the fork's identity** if `FORK_RPC_URL` is ever repointed at a
  proxy, a testnet, or any endpoint that answers `eth_chainId` differently
  from the chain the service is named after. The fork keeps reporting the id
  it is configured with instead of quietly adopting whatever the new endpoint
  says.

### Why the variable is `EVM_CHAIN_ID` and not `CHAIN_ID`

The real mainnet values (Base 8453, Somnia 5031, Polygon 137) were queried
live from the respective RPC endpoints via `eth_chainId` rather than copied
from memory, then each offset by one inserted digit (84539, 50319, 1379) for
the id actually configured, so the fork never reports the real chain's id.
The variable carrying them is named `EVM_CHAIN_ID` rather than
`CHAIN_ID` because `CHAIN_ID` already names something else in this stack: the
Cosmos chain id (`lumen-1`) consumed by the `edgenet` service. Reusing
`CHAIN_ID` for anvil would put two unrelated identifiers, one Cosmos, one EVM,
behind the same name across services, so the anvil variable gets its own name
instead. That is a naming choice, not an inconsistency.

### What was deliberately not overridden

Forking already gives anvil a realistic gas limit, base fee, hardfork and
code size limit, inherited from the upstream chain at the fork point.
Anvil's own defaults for `--order` (transaction ordering by fees) and
`--slots-in-an-epoch` (32) are also already realistic and match mainnet
behaviour. None of these were added as flags or environment variables.
Overriding any of them would make the fork less faithful to the chain it is
forking, not more, so if you are tempted to "complete" this list, do not; the
one real gap being closed here is the mining interval, not everything anvil
could be told to override.

### Known limitation: whole-second block time cannot match Somnia's real cadence

Anvil's `-b` / `--block-time` flag only accepts whole seconds. Somnia's real
block time is well under a second, so `anvil-somnia` is configured with
`BLOCK_TIME=1`, the smallest value anvil supports, and still ticks slower
than the real chain. There is no anvil flag that accepts sub-second
intervals, so this gap cannot be closed from this script; it is listed again
as a known gap in section 8.

### Consequence: no automatic time alignment

Because there is no metadata fetch and no search, `scripts/anvil-fork.sh` has no
way to know what wall clock time the Lumen snapshot represents, and does not try
to find out. `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` / `POLYGON_FORK_BLOCK` and the Lumen snapshot
chosen via `SNAPSHOT_URL` are configured completely independently. Keeping them
consistent (so that the Cosmos side and the EVM side represent roughly the same
moment) is now something the operator has to do by hand, by picking the fork
block that corresponds to their snapshot's timeframe themselves, for example
using a block explorer.

### What the script no longer needs

`curl` and `jq` were load bearing for the deleted resolver: JSON-RPC calls to
look up when candidate blocks occurred, and parsing the snapshot metadata
response. The current
script makes no HTTP calls and does not invoke `jq` at all; it only does a bash
regex check and execs anvil. `Dockerfile.anvil` still installs `curl` and `jq`
in the image (see section 5); whether that is intentional (kept for interactive
debugging, e.g. via `docker exec`) or leftover from the removed resolver is not
stated anywhere in the repository, and it is not this document's place to guess. See section 8.

## 3. Boot sequence: `scripts/edgenet.sh`

Runs as the entrypoint of the `edgenet` container. `set -e`, so any failing step
aborts the boot. `CHAIN_HOME=$HOME/.$BINARY`, and the very first thing the
script does is check whether `$CHAIN_HOME/initialized` exists. That check
branches the boot into one of two paths, replacing the old behaviour where
every boot unconditionally wiped and rebuilt the chain.

### Resume path: the sentinel exists

The chain was already built in this `CHAIN_HOME` by a previous boot. The
script skips every setup step below, clears nothing, fetches no snapshot
metadata, downloads nothing, and execs directly into:

```
$BINARY start --home $CHAIN_HOME \
    --rpc.laddr tcp://0.0.0.0:26657 \
    --api.enable true \
    --api.swagger true \
    --api.enabled-unsafe-cors true
```

Because `docker-compose.yml` bind mounts `./.config/${CHAIN_ID}_edgenet/` onto
`CHAIN_HOME`, the sentinel and the rest of the chain state outlive the
container, so this is the path an ordinary restart, whether triggered by
`docker compose restart`, a host reboot, or Compose's `restart: on-failure`,
takes. `make clean` removes `.config`, and with it the sentinel, which is the
only way to force the next boot back onto the build path below. Deleting just
`$CHAIN_HOME/initialized` by hand has the same effect without discarding the
rest of the chain home.

### Build path: the sentinel is absent

1. **Clear the home directory's contents.** Since
   `HOME` is `/${BINARY}` (set in `Dockerfile.edgenet`) and Compose bind mounts
   `./.config/${CHAIN_ID}_edgenet/` onto `/${BINARY}/.${BINARY}/`, `CHAIN_HOME`
   is a live mountpoint from inside the container. It cannot be unlinked from
   inside the container that holds it, so `rm -rf $CHAIN_HOME/` used to fail
   with `rm: can't remove '/lumend/.lumend': Resource busy` and, because the
   script runs under `set -e`, that killed the entrypoint on every boot (see
   section 9 for the recovery steps if you hit this). The script now runs
   `mkdir -p "$CHAIN_HOME"` followed by
   `find "$CHAIN_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +`, which clears
   everything under the mountpoint without touching the mountpoint itself.
   `-mindepth 1` also picks up dotfiles and is a no-op on an already empty
   directory. This step only runs on the build path now, not on every boot;
   `make clean` does the equivalent from the host by removing `.config`.
2. **Init with the recovered mnemonic.**
   `echo $VALIDATOR_MNEMONIC | $BINARY init $VALIDATOR_MONIKER --chain-id
   $CHAIN_ID --home $CHAIN_HOME --default-denom $DENOM --recover`. Recovering
   rather than generating means the node's key is deterministic across boots.
3. **Install the genesis file.** `cp $HOME/genesis.json
   $CONFIG_FOLDER/genesis.json`. That genesis is baked into the image at build
   time (see section 5), not fetched at runtime.
4. **Edit `client.toml` with `dasel`.** Two `dasel put` calls set
   `.keyring-backend` to `test` and `.chain-id` to `$CHAIN_ID`. This is why the
   image needs `dasel`.
5. **Add the validator key, then derive both address forms.** `$BINARY keys
   add $VALIDATOR_MONIKER --keyring-backend test --recover` from the same
   mnemonic, then read it back twice: `keys show -a` into `VAL_ACCOUNT` (the
   `euclid1...` account address) and `keys show --bech val -a` into
   `VAL_OPERATOR` (the `euclidvaloper1...` operator address). Both are the
   same key in two bech32 prefixes; `in-place-testnet` wants the operator
   form for `--validator-operator` and the account form for
   `--accounts-to-fund` / `--cosmwasm-admin`.
6. **Resolve snapshot metadata, then download the snapshot, but only if
   absent.** `SNAPSHOT_URL` is a metadata endpoint, not the archive. The script
   `curl`s it, requires the body to be non empty and valid JSON, then reads
   `.url` (the archive location) and `.height` (the cache key) out of it with
   `jq`; a missing `.url` or `.height` is fatal. The cache path is
   `$HOME/cache/snapshot-$SNAPSHOT_HEIGHT.tar.lz4`, and `./cache/` is bind
   mounted from the host, so the archive survives container rebuilds. The
   download guard is a plain `if [ ! -f "$SNAPSHOT_FILE" ]`, and the download
   itself goes to a `.part` suffixed temp name that is renamed into place only
   on success, so an interrupted download is never mistaken for a complete
   cache entry. Two consequences still worth knowing: a *stale* metadata
   response naming a height that is already cached is served the cached
   archive without re-checking it, and there is no cross height pruning, so
   `cache/` accumulates one archive per distinct height you have ever pointed
   `SNAPSHOT_URL` at. To force a fresh download for a given height, delete that
   height's `cache/snapshot-<height>.tar.lz4` on the host yourself. Note that
   `make clean` deliberately does not do this. Older checkouts may still have a
   leftover `cache/snapshot.tar.lz4` from before the cache key included the
   height; it is orphaned and safe to delete.
7. **Extract.** `lz4 -dc $SNAPSHOT_FILE | tar -C $CHAIN_HOME/ -xf -`. Streamed,
   so the tarball is never materialised on disk. This is why the image needs
   `lz4`.
8. **Read the consensus key, only now, after extraction.** This ordering is a
   constraint, not a detail: it must happen after step 7, never right after
   `init` in step 2. The snapshot tarball can carry its own `config/` and
   overwrite the `priv_validator_key.json` that `init` generated in step 2,
   so reading the key any earlier would hand `in-place-testnet` a consensus
   key that no longer matches what ends up on disk, and the converted chain
   would refuse to sign blocks. The script reads
   `$CHAIN_HOME/config/priv_validator_key.json` with `jq` into
   `CONSENSUS_PUBKEY` (`.pub_key.value`) and `CONSENSUS_PRIVKEY`
   (`.priv_key.value`), and dies before reaching `in-place-testnet` in any of
   three cases: the file does not exist, the file is not valid JSON, or
   either field is empty. None of the error paths print the file's contents;
   it holds the node's consensus signing key.
9. **Assemble the accounts to fund.** `ACCOUNTS_TO_FUND` starts as
   `VAL_ACCOUNT`, the validator's own account, which is always funded. If
   `FUNDED_ACCOUNTS` (a comma separated list of extra bech32 addresses, from
   `.env`) is non empty, it is appended with a comma. Left empty,
   `FUNDED_ACCOUNTS` funds only the validator; the script is careful not to
   emit a trailing comma in that case, which `in-place-testnet` would read as
   an empty address and reject.
10. **Fund the faucet account, if configured.** `FAUCET_PRIVATE_KEY` (a raw
    hex private key, no `0x` prefix, no quotes) is optional. If set, the
    script imports it into a throwaway test keyring in a temp dir, purely to
    derive its `euclid1...` address with `keys show`, then deletes that
    keyring immediately, so the private key itself never lands anywhere in
    `CHAIN_HOME`. The derived address is appended to `ACCOUNTS_TO_FUND`, the
    same way `FUNDED_ACCOUNTS` was in step 9, so the faucet account ends up
    funded like any other. A key that fails to import, or that somehow
    derives no address, is fatal before `in-place-testnet` runs. Left empty,
    this step is skipped entirely and `ACCOUNTS_TO_FUND` is unchanged; this
    is the input the faucet's `server/index.mjs` reads back as
    `FAUCET_PRIVATE_KEY` at request time to sign Lumen sends, see section 7.
    `COSMWASM_ADMIN` is resolved right after, falling back to `$VAL_ACCOUNT`
    if unset, so a bare `.env` still yields a usable testnet.
11. **Write the sentinel, then launch.** `touch "$CHAIN_HOME/initialized"` runs
    immediately before `in-place-testnet`, not after, because there is no
    "after": `in-place-testnet` never returns, it converts the restored state
    and then runs the node itself. This is a deliberate, accepted tradeoff, not
    an oversight, and it is listed as a known gap in section 8: a conversion
    that dies partway through leaves the sentinel written over a
    half-converted home, and the next boot takes the resume path above and
    runs `start` against it. Recovery is `make clean` (or deleting the
    sentinel by hand).
    ```
    $BINARY in-place-testnet $CHAIN_ID \
        --validator-operator=$VAL_OPERATOR \
        --validator-pubkey=$CONSENSUS_PUBKEY \
        --validator-privkey=$CONSENSUS_PRIVKEY \
        --accounts-to-fund=$ACCOUNTS_TO_FUND \
        --cosmwasm-admin=$COSMWASM_ADMIN \
        --home $CHAIN_HOME \
        --coins-to-fund 1000000000000$DENOM,1000000000000$STAKE_DENOM
    ```
    `in-place-testnet` takes the restored mainnet state and rewrites it into a
    single validator network, owned by `VAL_OPERATOR`/`VAL_ACCOUNT`, with
    `ACCOUNTS_TO_FUND` funded. This is the flag form `EuclidProtocol/vsld`
    uses to drive the same subcommand; the older positional
    `in-place-testnet $CHAIN_ID $VALIDATOR_ADDRESS` form is gone.

    **Security note.** `--validator-privkey` places the consensus private
    key on the command line, which makes it visible to anything that can run
    `ps` inside the container. That is inherent to the `in-place-testnet`
    interface, not something this script can avoid while using it; the
    script itself never logs or echoes the key. This is a local testnet
    validator key with no mainnet value, which is what makes that acceptable
    here.

### Consequence: `SNAPSHOT_URL` changes are ignored once initialized

The resume path never reaches step 6 above, so editing `SNAPSHOT_URL` in
`.env` has no effect on a `CHAIN_HOME` that already has a sentinel. The new
value is only read the next time the script takes the build path, which means
after `make clean` or after deleting `$CHAIN_HOME/initialized` by hand.

### Known limitation: hardcoded fund amounts

Which accounts get funded is now configurable: the validator's own account is
always funded, and `FUNDED_ACCOUNTS` in `.env` adds any number of extra
addresses on top (see step 9 above). What is still hardcoded is how much each
funded account receives: `1000000000000` of `DENOM` and of `STAKE_DENOM` are
literals in the `--coins-to-fund` argument in `scripts/edgenet.sh`. They are
not environment variables, they are not in `.env.example`, and they cannot be
overridden without editing the script and rebuilding the image. Promoting
them to an environment variable (something like `COINS_TO_FUND`) is an
obvious improvement and has not been done.

## 4. Testing

`bash scripts/anvil-fork-test.sh` is the only test in the repository.

It is an offline self test. No `bats`, no test framework, no network. It works by
sourcing `scripts/anvil-fork.sh` (whose `main()` is guarded behind
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so sourcing runs no side effects) for
unit level checks against `require_env`, and by running the entrypoint end to
end as a subprocess against a stubbed `anvil` binary (a shell script placed
first on `PATH` that just echoes its own argv) so the tests can assert on the
exact command line the script would have execed.

What it covers:

* **`FORK_BLOCK` unset forks the tip.** No `--fork-block-number` flag is
  emitted, `--fork-url` and `--port` are passed through, and the log announces
  chain tip mode.
* **`FORK_BLOCK` set but empty behaves the same as unset.** This matters
  because Compose passes an empty string, not an absent variable, for an
  unset `.env` entry, so empty has to mean tip, not an error.
* **`FORK_BLOCK` set to a valid height** produces
  `--fork-block-number <that height>` exactly, and the log announces the
  pinned height.
* **`--block-time` and `--chain-id` are passed on both branches**, tip and
  pinned, with the exact values from `BLOCK_TIME` and `EVM_CHAIN_ID`, and the
  log line announces both (`chain id <id>`, `mining every <n>s`). A second
  case runs the entrypoint as Somnia (`BLOCK_TIME=1`, `EVM_CHAIN_ID=50319`),
  and a third as Polygon (`BLOCK_TIME=2`, `EVM_CHAIN_ID=1379`), to confirm the
  values are read from the environment per chain, not hardcoded to Base's.
* **Malformed `FORK_BLOCK` is fatal before anvil starts.** Covers
  `not-a-number`, `-5`, `1.5`, `0`, and `0x10`; each must exit non zero with
  `positive integer block number` in the output, and the anvil stub must never
  have been invoked.
* **Malformed `BLOCK_TIME` or `EVM_CHAIN_ID` is fatal before anvil starts**,
  on the same terms and against the same bad values as `FORK_BLOCK`, including
  a hex value (`0x10`), the form `eth_chainId` itself would report a chain id
  in, which anvil would otherwise reject on its own terms rather than this
  script's.
* **Missing required environment is fatal and names the variable**, e.g. an
  absent `FORK_RPC_URL`, or an absent or empty `BLOCK_TIME` / `EVM_CHAIN_ID`;
  the anvil stub must never have been invoked.
* **Quoted environment values are rejected**, both at the `require_env` unit
  level and end to end through the entrypoint with a quoted `FORK_RPC_URL` or
  a quoted `BLOCK_TIME`; the entrypoint must die before anvil is invoked,
  naming the offending variable and the literal quote character.
* **`edgenet.sh` rejects a quoted `BINARY`** before any teardown of the chain
  home runs.
* **`edgenet.sh` also fails safely when `HOME` itself is quoted** (the stale
  image case, see section 9): it asserts the script exits non zero, that a
  sentinel file placed inside the chain home survives (proving the
  entrypoint died before touching it), and that the error message points at
  rebuilding the image rather than editing `.env`.

None of this exercises `SNAPSHOT_URL` resolution, snapshot download, or the
`edgenet` container's boot sequence; the self test is scoped to
`scripts/anvil-fork.sh` and the environment guard shared with
`scripts/edgenet.sh`.

It exits non zero if any assertion fails and prints a `passed: N failed: M`
summary.

**It is not wired into anything.** There is no `make test` target, and there is
no CI. You have to remember to run it. If you touch `resolve_fork_block()` and do
not run this file, nothing will stop you.

## 5. Image build details

### `Dockerfile.anvil`

Two stages. The first pulls `ghcr.io/foundry-rs/foundry:stable` purely as a
source of binaries. The final stage is `ubuntu:24.04` with `bash`,
`ca-certificates`, `curl` and `jq` installed via apt, then `anvil` and `cast`
copied across from the foundry stage. `scripts/anvil-fork.sh` is copied to
`/usr/local/bin/` and set as the `ENTRYPOINT`.

`jq` and `curl` are installed but, as of the current `scripts/anvil-fork.sh`,
not used by it; see section 2 and the note in section 8. They may be there for
interactive debugging via `docker exec`, or simply left over from the removed
resolver; the repository does not say which.

This is one image for every chain. `docker-compose.yml` tags it
`edgenet-anvil:local` and both anvil services reference the same tag and the same
build context. Services differ only by environment variables. Keep it that way; a
per chain Dockerfile would be a regression.

### `Dockerfile.edgenet`

Single stage, `alpine:3.20`. Installs `bash`, `curl`, `dasel` (`>2.0.0`), `jq`
and `lz4` via `apk`. Two of those are direct requirements of `edgenet.sh`:
`dasel` for the `client.toml` edits, `lz4` for snapshot extraction. Alpine's
default shell is not bash, and the script has a bash shebang, hence `bash`.

Both the chain binary and `genesis.json` are downloaded **at image build time**
from a Vercel blob storage URL:

```
https://so7hoepmu4vbb7pi.public.blob.vercel-storage.com/${BINARY}/${BINARY}_edgenet_${PLATFORM}
https://so7hoepmu4vbb7pi.public.blob.vercel-storage.com/${BINARY}/genesis.json
```

`BINARY` and `PLATFORM` are build args, passed through from `.env` by
`docker-compose.yml`. Two consequences: the build is not hermetic (it depends on
that blob store being up), and a new binary or genesis requires an image rebuild,
not just a restart. That is why nearly every Make target passes `--build`.

Both downloads use `curl -fL` with retries, and both are validated afterwards.
This is not decoration. Neither one used `-f` originally, and without it curl
exits 0 on an HTTP error and writes the error body to disk as though it were the
artifact. The blob store answers a missing object with a 404 and a 15 byte
`text/plain` body reading `Blob not found`, so the build wrote those 15 bytes to
`/bin/${BINARY}`, marked them executable, and succeeded. The container then died
at runtime for reasons that pointed nowhere near the real cause. The binary is
now checked for ELF magic bytes and `genesis.json` is checked with `jq empty`, so
an endpoint that answers 200 with the wrong body is caught too, and the build
fails naming the URL it could not fetch.

Note that a `RUN curl ...` layer is cached on the command text, not on the
response body. If an artifact is re-uploaded to the blob store under the same
URL, a plain `make build` reuses the stale layer and never re-fetches. Use
`make build-force`, which passes `--no-cache --pull`.

`HOME` is set to `/${BINARY}`, which is what makes `$HOME/.$BINARY`,
`$HOME/cache/` and `$HOME/genesis.json` in `edgenet.sh` resolve correctly. If you
change `HOME`, you break the volume mounts in `docker-compose.yml`, which are
written against the same paths.

## 6. Adding an EVM chain

Three edits. Say the chain is called Arbitrum.

**1. `.env.example` (and your own `.env`).** Add two lines:

```
ARBITRUM_FORK_RPC_URL=https://arb1.arbitrum.io/rpc
ARBITRUM_FORK_BLOCK=
```

Leave the fork block empty to fork the chain tip, or set a pinned block number.
There is no per chain timing variable to add anymore.

**2. `docker-compose.yml`.** Add a service, starting from `anvil-base` as a
template. The service name, `CHAIN_NAME`, the two `.env` backed variable
names, and the host port all change the same way they did before. Two more
values now need to be set as literals, `BLOCK_TIME` and `EVM_CHAIN_ID`: these
are not copied from `anvil-base`, they are facts about Arbitrum itself (its
own block time in whole seconds, and its own EVM chain id, queried live via
`eth_chainId`), the same way Base carries `2`/`84539` (Base's real mainnet id
8453, offset by one inserted digit), Somnia carries `1`/`50319` (Somnia's
real mainnet id 5031, offset the same way) and Polygon carries `2`/`1379`
(Polygon's real mainnet id 137, offset the same way). Pick a free host port (8545,
8546 and 8547 are taken); `ANVIL_PORT` itself stays `8545`, the same as
every other anvil service.

```yaml
  anvil-arbitrum:
    profiles:
      - edgenet
    image: edgenet-anvil:local
    build:
      context: .
      dockerfile: Dockerfile.anvil
    # BLOCK_TIME is whole seconds (anvil's -b flag). EVM_CHAIN_ID is
    # Arbitrum One's real chain id, not an arbitrary value.
    environment:
      - CHAIN_NAME=arbitrum
      - FORK_RPC_URL=${ARBITRUM_FORK_RPC_URL}
      - FORK_BLOCK=${ARBITRUM_FORK_BLOCK}
      - BLOCK_TIME=1
      - EVM_CHAIN_ID=42161
      - ANVIL_PORT=8545
    ports:
      - 8548:8545
    networks:
      - edgenet-network
    restart: on-failure
```

`ANVIL_PORT` does not need to match the published port; every anvil container
listens on `8545` internally regardless of which chain it forks, and only the
host side of the mapping, `8548` here, has to be free and distinct per
service. `BLOCK_TIME` and `EVM_CHAIN_ID` are both required by
`scripts/anvil-fork.sh`; a missing, non-positive-integer, or quote-containing
value is fatal before anvil starts, see section 2.

**3. `Makefile`.** Add the three convenience targets and register them in
`.PHONY`:

```make
anvil-arbitrum-start:
	@$(COMPOSE) up -d --build anvil-arbitrum

anvil-arbitrum-stop:
	@$(COMPOSE) stop anvil-arbitrum

anvil-arbitrum-logs:
	@$(COMPOSE) logs -f anvil-arbitrum --since 10s
```

No Dockerfile change, no script change. If you find yourself editing
`Dockerfile.anvil` or `scripts/anvil-fork.sh` to add a chain, stop and reconsider.

## 7. Faucet

`faucet/` is a small, separate npm project. `faucet/src/` (`App.tsx`,
`main.tsx`, `index.css`) is a Vite/React single page frontend: pick a chain,
enter an address, submit. `faucet/server/index.mjs` is the Express server;
it is the only piece with any actual logic, and the only file this section
documents in depth.

### Build: two stage `faucet/Dockerfile`

The build stage runs `npm ci` and `npm run build` (`tsc --noEmit && vite
build`), producing `faucet/dist/`. The run stage installs only production
dependencies (`npm ci --omit=dev`), copies `server/` and the built `dist/`
across, and runs `node server/index.mjs`. The frontend is compiled once at
image build time, not served by Vite's dev server at runtime; there is no
`vite dev` in the running container.

### What the server does

`index.mjs` reads three sets of upstream RPC URLs from the environment:
`LUMEN_RPC_URL` (default `http://edgenet:26657`) and `BASE_RPC_URL`,
`SOMNIA_RPC_URL`, `POLYGON_RPC_URL` (defaulting to
`http://anvil-base:8545`, `http://anvil-somnia:8545`,
`http://anvil-polygon:8545`), the same Compose service names every other
service already reaches its neighbours by. `docker-compose.yml` sets all
four explicitly anyway; the defaults exist so the server also runs stand
alone against a differently named stack.

It serves the built frontend as static files from `dist/`, and answers one
route, `POST /api/faucet`, with a JSON body of `{ chain, address }`.
Behaviour branches on `chain`:

* **`chain === "lumen"`.** The address must satisfy `fromBech32(address)`
  with prefix `euclid`, or the request is rejected with 400. On success,
  `fundLumen()` loads the faucet keypair from `FAUCET_PRIVATE_KEY` with
  `DirectSecp256k1Wallet.fromKey(fromHex(pk), "euclid")`, opens a
  `SigningStargateClient` against `LUMEN_RPC_URL`, and calls `sendTokens()`
  for `1000000000ualpha` and `1000000000usync` (1,000 of each denom, at 6
  decimals) to the requested address, gas priced at `0.015ualpha`. The
  response is the real `transactionHash`. If `FAUCET_PRIVATE_KEY` is unset,
  `fundLumen()` throws `FAUCET_PRIVATE_KEY not set` before it ever tries to
  build a wallet, and the route answers 500 with that message.
* **`chain === "base" | "somnia" | "polygon"`.** The address must match
  `/^0x[0-9a-fA-F]{40}$/`, or the request is rejected with 400. On success,
  `fundEvm()` reads the address's current balance with `eth_getBalance`,
  adds `1000` ether (`1000n * 10n ** 18n`, matching the 18 decimal native
  token every anvil fork uses), and writes the new balance back with
  `anvil_setBalance`. This is a state cheat the anvil JSON-RPC exposes for
  exactly this purpose, not a signed transaction, so there is no sender, no
  gas, and no real transaction hash; the route returns the hash of the
  latest block instead, purely as an acknowledgement that the call reached
  the fork.
* **Any other `chain` value.** Rejected with 400, `unknown chain`.

There is no authentication and no rate limiting anywhere in this route: any
caller, on any chain, can request any address be funded any number of times.
This is deliberate for a local development faucet behind no public ingress,
not an oversight; if the stack is ever exposed beyond a developer's own
machine, this is the first thing to add.

### Where the Lumen faucet account gets its initial balance

The faucet server never funds its own account; it only spends from it. The
account is funded once, at the Lumen node's first boot, by
`scripts/edgenet.sh`, not by anything in `faucet/`. See section 3, the
`FAUCET_PRIVATE_KEY` step: the script imports the raw hex key into a
throwaway keyring purely to derive the `euclid1...` address, appends that
address to `--accounts-to-fund`, and the account receives
`1000000000000ualpha` and `1000000000000usync` (1,000,000 of each denom)
from `in-place-testnet`, the same funding every other funded account gets.
If `FAUCET_PRIVATE_KEY` is empty, no faucet account is created or funded,
and the `lumen` tab has nothing to sign from until it is set and the node is
rebuilt from scratch (the account is only created on the build path, see
section 3; an already initialized chain home ignores a newly set
`FAUCET_PRIVATE_KEY` exactly the way it ignores a changed `SNAPSHOT_URL`).

## 8. Known gaps and cleanup backlog

None of these are blocking. All of them are real.

* **`scripts/anvil-fork-test.sh` is orphaned.** It is not referenced by any Make
  target and there is no CI, so the only test in the repository runs only when a
  human remembers. A `make test` target is a one line fix.
* **No CI at all.** No GitHub Actions workflow, nothing that builds the images or
  runs the self test on a push.
* **`cast` is installed but never used.** `Dockerfile.anvil` copies
  `/usr/local/bin/cast` out of the foundry stage. Nothing in `scripts/` invokes
  it. Either it is there for interactive `docker exec` debugging, in which case
  say so, or it should be dropped.
* **`EXPOSE 26656` is never published.** `Dockerfile.edgenet` exposes the P2P
  port, but `docker-compose.yml` publishes only 26657, 1317 and 9090. The P2P
  port is unreachable from the host. Since this is a single validator in place
  testnet with no peers, that is probably intentional, but the `EXPOSE` line is
  then misleading.
* **`VALIDATOR_MONIKER` is hardcoded.** `docker-compose.yml` sets
  `VALIDATOR_MONIKER=validator` as a literal, and it does not appear in
  `.env.example` at all, even though `scripts/edgenet.sh` reads it from the
  environment like every other setting. It should either be a `.env` variable
  like the rest, or the script should default it.
* **A missing `.env` still fails late rather than loudly.** Compose loads
  `./.env` natively and does not treat an absent file as an error. Every
  variable interpolates to an empty string, Compose warns once per variable,
  and the build fails much later with a confusing message (an empty `BINARY`
  turns the binary download URL into nonsense). A guard target that checks for
  the file and errors with a useful message would be a real improvement. The
  `Makefile` no longer parses or exports `.env` itself, which is what used to
  turn this from a late failure into a corrupted one (see section 9).
* **`.gitignore` has stale entries.** It ignores `logs/` and `*.log`, but nothing
  in the repository writes to either. Logs go to the Docker daemon and are read
  back with `docker compose logs`.
* **`shellcheck` is not wired up.** Both scripts carry
  `# shellcheck disable=` and `# shellcheck source=` directives, so someone ran
  it once, but it is not in a Make target and not in CI.
* **No LICENSE file.**
* **Snapshot cache is never invalidated, and never pruned.** Covered in
  section 3: `edgenet.sh` downloads only when
  `cache/snapshot-<height>.tar.lz4` is absent for that height, so a stale or
  truncated archive persists silently, and `cache/` accumulates one archive
  per distinct height ever requested with no cleanup.
* **`Dockerfile.anvil` installs `curl` and `jq` that `scripts/anvil-fork.sh` no
  longer uses.** The current script only validates `FORK_BLOCK` with a bash
  regex and execs anvil; it makes no HTTP calls and never invokes `jq`. This is
  a leftover from the removed metadata driven fork block resolver. Either drop
  both packages from the image, or, if they are kept deliberately for
  interactive `docker exec` debugging, say so next to the `RUN apt-get install`
  line.
* **Anvil forks and the Lumen snapshot can silently drift apart.** Nothing
  ties `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` / `POLYGON_FORK_BLOCK` to the
  snapshot selected by `SNAPSHOT_URL`; see section 2. There is no validation,
  warning, or check of any kind if an operator changes one without the
  others.
* **`anvil-somnia` cannot tick as fast as the real Somnia chain.** Anvil's
  `--block-time` only accepts whole seconds, so `anvil-somnia` runs at the
  smallest value anvil supports, `BLOCK_TIME=1`, while Somnia's real block
  time is well under a second. The fork therefore mines slower than the chain
  it forks. No anvil flag fixes this; see section 2.
* **An unrelated crash can now loop instead of self-healing.** Persisting the
  chain across restarts (section 3) means Compose's `restart: on-failure` on
  the `edgenet` service restarts the container straight back into
  `$BINARY start` against the same chain home. If the crash was caused by
  something in that home, for example a corrupted database after a hard
  kill, rather than by a bad snapshot or a bad config, the container can
  crash-loop. Before this change, every restart rebuilt the chain from
  scratch, which incidentally self-healed this class of failure. There is no
  automatic detection of a broken home; the recovery is manual, `make clean`.

## 9. Troubleshooting

### Recovering from quote poisoned `.env` values

Grep for either of these two error strings if a deployment looks broken in a way
that does not match its configuration.

**`edgenet` container:**

```
rm: can't remove '/"lumend"/."lumend"': Resource busy
```

This means `BINARY` reached the container as `"lumend"`, quotes included, rather
than `lumend`. The quoted value was baked into `ENV HOME` at image build time
(section 5), and Compose mounts a host volume at that same quote laden path
(section 3, step 1), so the entrypoint's own cleanup step collides with the
mount instead of removing it cleanly.

**anvil containers (`anvil-base`, `anvil-somnia`, `anvil-polygon`):**

```
FATAL: environment variable FORK_RPC_URL contains a literal quote character
```

This means `FORK_RPC_URL` (or another anvil variable) reached the container as
a quoted string. `scripts/anvil-fork.sh`'s `require_env` catches this before
anvil is ever execed. At the time this bug was first found, the script still
fetched a since removed metadata endpoint variable with `curl`, and a quoted
value there surfaced as a curl argument parsing error instead of this
`require_env` message; that code path no longer exists (see section 2), but
the underlying cause, a quoted `.env` value, is the same regardless of which
anvil variable carries it, and `require_env` now catches it earlier and more
clearly than curl's own error ever did.

Both symptoms share one root cause. The `Makefile` used to begin with `-include
.env` plus a bare `export`. GNU Make parses `.env` as makefile syntax, not as a
dotenv file, so a double quoted value such as `BINARY="lumend"` kept its literal
quotes when Make read it. The `export` then pushed that quoted value into the
process environment that `docker compose` inherits, and an inherited environment
variable outranks Compose's own `.env` parsing, which strips quotes correctly on
its own. Compose was never the problem. Make was. The `Makefile` no longer reads
or exports `.env` at all, `.env.example` values are unquoted, and both
entrypoints now reject any value containing a quote character.

A deployment that last built while that combination was in place carries a
poisoned image layer as well as a poisoned environment, because the quoted
`BINARY` was baked into `ENV HOME` at build time. Fixing `.env` alone is not
enough. The image has to be rebuilt too. Recover in this order.

1. `make edgenet-down` to stop the poisoned containers.
2. Remove the quote named host directory under `.config/`. Because `CHAIN_ID`
   was also quoted, the directory is literally named `"lumen-1"_edgenet`,
   quotes included in the filename, not the expected `lumen-1_edgenet`.
3. Edit the existing `.env` and remove the quotes from every value.
4. Rebuild with `make edgenet` (or any target that passes `--build`). The bad
   `BINARY` value was baked into the image layer at `ENV HOME`, so a plain
   restart without a rebuild reuses that layer and reproduces the same
   failure.

### `Resource busy` on a clean, unquoted path

This looks similar to the quote poisoning case above but has a different cause
and a different fix. Do not confuse the two: check whether the path in the
error message contains literal quote characters. If it does not, this section
applies instead.

```
rm: can't remove '/lumend/.lumend': Resource busy
```

No quotes anywhere in that path. This was a bug in `scripts/edgenet.sh` itself,
independent of any `.env` value: the old boot sequence ran `rm -rf
$CHAIN_HOME/` to wipe the chain home on every start, but `docker-compose.yml`
bind mounts `./.config/${CHAIN_ID}_edgenet/` onto exactly that path
(`CHAIN_HOME`). A bind mountpoint cannot be unlinked from inside the container
that holds it, so the `rm -rf` failed with `EBUSY`, `set -e` treated that as a
fatal error, and the entrypoint died on every single boot, quoted values or
not.

The fix (see section 3, step 1) was to stop trying to remove `CHAIN_HOME`
itself and instead clear only its contents with `find "$CHAIN_HOME" -mindepth
1 -maxdepth 1 -exec rm -rf {} +`, after `mkdir -p "$CHAIN_HOME"`. If you are
running an older image that predates this fix, rebuild with `make edgenet` (or
any target that passes `--build`); no `.env` edit is needed, since nothing
here was ever a quoting problem.
