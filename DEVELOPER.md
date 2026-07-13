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

**The anvil forks (`anvil-base`, `anvil-somnia`).** One service per EVM chain,
all built from the same `Dockerfile.anvil` and all running
`scripts/anvil-fork.sh` as their entrypoint. Each one forks a public EVM chain
at the block that corresponds to the Lumen snapshot's wall clock time. Base
listens on 8545, Somnia on 8546.

The two kinds differ only in role. All anvil services share one image and one
script; they are distinguished purely by environment (`CHAIN_NAME`,
`FORK_RPC_URL`, `BLOCK_TIME_MS`, `SNAPSHOT_API_URL`, `ANVIL_PORT`). There is no
per chain Dockerfile and there should never be one.

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
* The anvil containers do not depend on the node at runtime anyway. They read
  the snapshot metadata over HTTP from `SNAPSHOT_API_URL`, which is a remote
  service, not the local node. So the missing ordering is not currently a bug,
  it is simply unenforced.
* The only backstop is `restart: on-failure`, present on every service. A
  container that dies (for example because its upstream RPC was briefly
  unreachable) is restarted, and `scripts/anvil-fork.sh` re-runs its whole
  resolution from scratch on each restart. Resolution is deterministic given the
  same snapshot metadata and chain head, but it is not idempotent in the sense of
  reusing a previous answer; each restart re-probes and can land on a different
  block if the snapshot has been rotated in the meantime.
* If you ever add a consumer that needs the node's RPC to be live before it
  starts, you must add the ordering yourself. Do not assume it exists.

## 2. The core algorithm: `scripts/anvil-fork.sh`

This is the most subtle part of the repository. Read it before changing anything
in it.

### The problem it solves

The Cosmos node is restored from a snapshot taken at some past moment. The EVM
forks must represent that same moment. If anvil forks Base at the current head
while the Lumen node is replaying a six hour old snapshot, then every cross chain
read is inconsistent: balances, oracle prices and contract state on the EVM side
are from a different point in time than the Cosmos side. The two chains must
agree on a wall clock instant.

Cosmos snapshots carry a wall clock timestamp. EVM chains are addressed by block
number. So the job is a lookup: given a wall clock instant, find the block number
on the target chain that represents it. Formally, find the greatest block whose
timestamp is less than or equal to the target.

### Step by step

**1. Validate the environment.** `main()` calls `require_env` for `CHAIN_NAME`,
`FORK_RPC_URL`, `BLOCK_TIME_MS`, `SNAPSHOT_API_URL`, `ANVIL_PORT`, then asserts
`BLOCK_TIME_MS` matches `^[1-9][0-9]*$`. A fractional value such as `0.5` is
fatal. The field is integer milliseconds, deliberately: sub second chains like
Somnia cannot be expressed in whole seconds, and using milliseconds keeps all the
later arithmetic in Bash integers.

**2. Fetch the snapshot metadata.** `curl -fsS "$SNAPSHOT_API_URL"`. A transport
failure is fatal.

**3. Extract `.blockTime`.** `extract_target_ts()` pulls `.blockTime` out of the
JSON with `jq`. Three separate failures, all fatal:

* the body is not valid JSON,
* `.blockTime` is missing or `null` (this means the snapshot predates
  `blockTime` support, and the fix is to take a fresh snapshot),
* `.blockTime` is not parseable as ISO 8601.

**4. ISO 8601 to epoch seconds.** `iso_to_epoch()` runs
`jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601'`. The `sub`
strips fractional seconds, because `jq`'s `fromdateiso8601` rejects them. So
`2026-07-13T10:00:00.000Z` becomes `2026-07-13T10:00:00Z` and then an epoch
integer. Everything downstream is epoch seconds.

**5. Read the chain head.** `resolve_fork_block()` calls `get_latest_block()`
(`eth_blockNumber`, hex to decimal via `$(( hex ))`) and then `fetch_block_ts()`
on that block. If the RPC cannot serve its own head block, that is fatal.

**6. Short circuit on a future target.** If `target >= latest_ts`, the snapshot
is at or newer than the chain head, so fork at the head. One probe total, no
search.

**7. Seed a lower bound.** This is where `BLOCK_TIME_MS` is used, and it is the
*only* place it is used. It is a search hint, nothing more. It is never passed to
anvil, and anvil is never told to mine at that interval.

```
delta    = latest_ts - target                                 # seconds behind head
est_back = ceil(delta * 1000 / BLOCK_TIME_MS)                 # blocks behind head
         = (delta * 1000 + BLOCK_TIME_MS - 1) / BLOCK_TIME_MS # integer ceiling
est      = max(1, latest - est_back)                          # estimated block
margin   = max(1, est_back / 10)                              # 10 percent, integer division
lo       = max(1, est - margin)
```

Timestamps are seconds and block time is milliseconds, so the gap is scaled by
1000 before dividing. The ceiling is done with the `(a + b - 1) / b` trick to stay
in integer arithmetic. The 10 percent margin exists because the nominal block time
is a nominal average; real chains drift, so the naive estimate `est` is not
guaranteed to sit before the target. Backing off 10 percent makes it very likely
that it does.

**8. Guard the invariant, widening as needed.** The binary search requires
`block(lo).ts <= target`. The guard loop enforces it:

```
loop:
  ts = block(lo).ts
  if ts is unavailable         -> FATAL (pruned history)
  if ts <= target              -> invariant holds, exit loop
  if lo == 1                   -> FATAL (chain younger than snapshot)
  margin = margin * 2
  lo     = max(1, est - margin)
```

Doubling the margin means a badly wrong `BLOCK_TIME_MS` costs a handful of extra
probes, not correctness. The self-test proves this: with the environment claiming
4000ms on a chain that actually runs at 2000ms, the resolver still lands on the
exact right block.

**9. Binary search `[lo, latest]`.** Standard "greatest element satisfying a
monotone predicate" search, with the upper midpoint so that `mid > lo` always
holds:

```
hi = latest
while lo < hi:
  mid = lo + (hi - lo + 1) / 2      # upper midpoint: mid is strictly greater than lo
  ts  = block(mid).ts
  if ts is unavailable -> FATAL (refuse to guess)
  if ts <= target: lo = mid; lo_ts = ts
  else:            hi = mid - 1
RESULT_BLOCK = lo
RESULT_TS    = lo_ts
```

Because the midpoint rounds up, no probe is ever issued below the guarded lower
bound. That property is asserted directly by the self-test (`MIN_PROBED >=
SEEDED_LO`). It matters, and it is the reason the upper midpoint is used rather
than the conventional lower one.

Note that `lo_ts` is seeded by the guard loop, so if the guard's `lo` is already
the answer (the loop body never runs), `RESULT_TS` is still correct.

Timestamps are whole seconds, so on a sub second chain several blocks share one
timestamp. The contract ("greatest block with ts <= target") resolves this
unambiguously: you get the *last* block of that second.

**10. Exec anvil.**

```
exec anvil \
  --fork-url "$FORK_RPC_URL" \
  --fork-block-number "$RESULT_BLOCK" \
  --host 0.0.0.0 \
  --port "$ANVIL_PORT"
```

`exec` replaces the shell, so anvil becomes PID 1 and receives signals directly.
Before exec, the script logs the resolved block, its timestamp, the drift
(`target_ts - RESULT_TS`, always a non negative number of seconds) and the number
of block probes issued.

### The fail fast contract

Every failure mode in this script is a hard exit. There is no fallback path, on
purpose:

* A pruned or otherwise unservable block during the guard loop is fatal.
* A pruned or otherwise unservable block mid search is fatal.
* A chain whose block 1 is already after the target is fatal.
* Missing, null or malformed snapshot metadata is fatal.

The alternative would be to silently fall back to forking at the head, which
produces a stack that looks healthy and is quietly wrong, which is the worst
possible outcome. A container that refuses to start is loud and diagnosable.

Related: the search never probes down from block 1. Public RPC endpoints are not
archival; a deep probe into old history returns `null` or an error. The seeded
lower bound means the script only ever touches a narrow window near the target.
If that window is outside the RPC's retained history, the correct answer is "this
RPC cannot serve this snapshot", not "let me try harder".

### Restating the trap

`BLOCK_TIME_MS` seeds the search and nothing else. It never reaches anvil. If you
get it wrong by a factor of two, the guard loop widens and the search still
returns the exact block. Order of magnitude matters, exactness does not.

## 3. Boot sequence: `scripts/edgenet.sh`

Runs as the entrypoint of the `edgenet` container. `set -e`, so any failing step
aborts the boot. In order:

1. **Wipe the home directory.** `rm -rf $CHAIN_HOME/` where
   `CHAIN_HOME=$HOME/.$BINARY`. Since `HOME` is `/${BINARY}` (set in
   `Dockerfile.edgenet`) and Compose bind mounts
   `./.config/${CHAIN_ID}_edgenet/` onto `/${BINARY}/.${BINARY}/`, this wipes
   the host side state too. Every boot is a clean boot. `make clean` does the
   same thing from the host by removing `.config`.
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
5. **Add the validator key.** `$BINARY keys add $VALIDATOR_MONIKER
   --keyring-backend test --recover` from the same mnemonic, then read the
   address back with `keys show -a` into `VALIDATOR_ADDRESS`.
6. **Download the snapshot, but only if absent.** The cache path is
   `$HOME/cache/snapshot.tar.lz4`, and `./cache/` is bind mounted from the host,
   so the archive survives container rebuilds. The guard is a plain
   `if [ ! -f "$SNAPSHOT_FILE" ]`. Two consequences worth knowing: a *stale*
   cached snapshot is never refreshed, and a *truncated* download is never
   detected. To force a fresh snapshot, delete `cache/snapshot.tar.lz4` on the
   host yourself. Note that `make clean` deliberately does not do this.
7. **Extract.** `lz4 -dc $SNAPSHOT_FILE | tar -C $CHAIN_HOME/ -xf -`. Streamed,
   so the tarball is never materialised on disk. This is why the image needs
   `lz4`.
8. **Launch.**
   ```
   $BINARY in-place-testnet $CHAIN_ID $VALIDATOR_ADDRESS \
       --home $CHAIN_HOME \
       --accounts-to-fund euclid1z328t58xya5hw32a869n6hah33uaehw5zz9rj3 \
       --coins-to-fund 1000000000000$STAKE_DENOM,1000000000000$DENOM
   ```
   `in-place-testnet` takes the restored mainnet state and rewrites it into a
   single validator network owned by `VALIDATOR_ADDRESS`.

### Known limitation: hardcoded funding

The funded account `euclid1z328t58xya5hw32a869n6hah33uaehw5zz9rj3` and the fund
amounts (`1000000000000` of each denomination) are literals in the script. They
are not environment variables, they are not in `.env.example`, and they cannot be
overridden without editing `scripts/edgenet.sh` and rebuilding the image. If you
need a different funded account, that is the edit. Promoting these to environment
variables (something like `ACCOUNTS_TO_FUND` and `COINS_TO_FUND`) is an obvious
improvement and has not been done.

## 4. Testing

`bash scripts/anvil-fork-test.sh` is the only test in the repository.

It is an offline self test. No `bats`, no test framework, no network. It works by
sourcing `scripts/anvil-fork.sh` (whose `main()` is guarded behind
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so sourcing runs no side effects) and
then redefining the two functions that touch the network, `get_latest_block()`
and `fetch_block_ts()`, against a simulated chain. The mock chain gives block `N`
the timestamp `MOCK_GENESIS_TS + N * MOCK_ACTUAL_BLOCK_TIME_MS / 1000` (integer
truncated to whole seconds), with an optional `MOCK_PRUNE_BELOW` floor below
which blocks report as unservable. The mock also records `MIN_PROBED`, the lowest
block number the resolver ever asked for, which is what lets the test assert the
"never probe below the seeded lower bound" property.

The crucial design point is that the mock's *actual* block time
(`MOCK_ACTUAL_BLOCK_TIME_MS`) is separate from the *nominal* block time the
resolver is told (`BLOCK_TIME_MS`). Setting them to different values is how the
widening behaviour gets tested.

What it covers:

* **Exact block resolution.** A six hour old snapshot on a 2s chain resolves to
  exactly `latest - 10800`, with zero drift, in a logarithmic number of probes,
  and with no probe below the seeded lower bound.
* **Flooring between blocks.** A target one second past a block boundary still
  resolves to the earlier block and reports 1s of drift.
* **Future target.** A target beyond the chain head forks at the head and issues
  exactly one probe.
* **Wrong nominal block time.** The environment says 4000ms, the chain runs
  2000ms; the guard loop widens the margin and the resolver still returns the
  exact correct block within a bounded probe count.
* **Sub second chains.** 1000ms blocks (Somnia class) and 100ms blocks. At 100ms
  ten blocks share each wall clock second, and the test asserts the resolver
  returns the *last* block of the target second.
* **Fractional `BLOCK_TIME_MS` is fatal.** Runs the real script as a subprocess
  with `BLOCK_TIME_MS=0.5` and asserts a non zero exit.
* **Pruned history is fatal.** Prunes below `latest - 5000` while the target sits
  much further back, and asserts the resolver dies rather than guessing.
* **Chain younger than the snapshot is fatal.** Target before the mock chain's
  genesis, so block 1 is already after the target.
* **Malformed metadata is fatal.** Missing `blockTime`, null `blockTime`,
  unparseable `blockTime`, and a body that is not JSON at all. Plus one positive
  case: an ISO 8601 timestamp with milliseconds round trips to the correct epoch.

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

`jq` and `curl` are load bearing: the resolver script uses them for every JSON-RPC
call and for parsing the snapshot metadata.

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

`HOME` is set to `/${BINARY}`, which is what makes `$HOME/.$BINARY`,
`$HOME/cache/` and `$HOME/genesis.json` in `edgenet.sh` resolve correctly. If you
change `HOME`, you break the volume mounts in `docker-compose.yml`, which are
written against the same paths.

## 6. Adding an EVM chain

Three edits. Say the chain is called Arbitrum.

**1. `.env.example` (and your own `.env`).** Add two lines:

```
ARBITRUM_FORK_RPC_URL="https://arb1.arbitrum.io/rpc"
ARBITRUM_BLOCK_TIME_MS=250
```

The block time is a nominal average. Order of magnitude is what matters.

**2. `docker-compose.yml`.** Add a service, copying `anvil-base` verbatim and
changing four things: the service name, `CHAIN_NAME`, the two variable names it
reads, and the port. Pick a port not already used (8545 and 8546 are taken).

```yaml
  anvil-arbitrum:
    profiles:
      - edgenet
    image: edgenet-anvil:local
    build:
      context: .
      dockerfile: Dockerfile.anvil
    environment:
      - CHAIN_NAME=arbitrum
      - FORK_RPC_URL=${ARBITRUM_FORK_RPC_URL}
      - BLOCK_TIME_MS=${ARBITRUM_BLOCK_TIME_MS:-250}
      - SNAPSHOT_API_URL=${SNAPSHOT_API_URL}
      - ANVIL_PORT=8547
    ports:
      - 8547:8547
    networks:
      - edgenet-network
    restart: on-failure
```

Note `ANVIL_PORT` and the published port must match, because the port mapping is
`8547:8547`.

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

## 7. Known gaps and cleanup backlog

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
  turn this from a late failure into a corrupted one (see section 8).
* **`.gitignore` has stale entries.** It ignores `logs/` and `*.log`, but nothing
  in the repository writes to either. Logs go to the Docker daemon and are read
  back with `docker compose logs`.
* **`shellcheck` is not wired up.** Both scripts carry
  `# shellcheck disable=` and `# shellcheck source=` directives, so someone ran
  it once, but it is not in a Make target and not in CI.
* **No LICENSE file.**
* **Snapshot cache is never invalidated.** Covered in section 3: `edgenet.sh`
  downloads only when `cache/snapshot.tar.lz4` is absent, so a stale or truncated
  archive persists silently.
* **`SNAPSHOT_API_URL` is worth double checking.** The header comment in
  `scripts/anvil-fork.sh` describes it as the "snapshot metadata endpoint
  (`/snapshots/latest`)", and the script `curl`s the value verbatim and expects
  `.blockTime` in the response body. `.env.example` sets it to the API root
  (`https://snapshot.lumen.euclidprotocol.com/api`) with no path. Either the root
  really does return the latest snapshot's metadata (in which case the comment is
  stale) or the example value is wrong. Confirm against the live API before
  trusting either.

## 8. Troubleshooting

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

**anvil containers (`anvil-base`, `anvil-somnia`):**

```
curl: (3) URL rejected: Port number was not a decimal number between 0 and 65535
```

This means `SNAPSHOT_API_URL` reached the container as a quoted string, and curl
parsed the trailing quote as part of what it expected to be a port number.

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
