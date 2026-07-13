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
either at the current chain tip or at a block height pinned in `.env`. Base
listens on 8545, Somnia on 8546.

The two kinds differ only in role. All anvil services share one image and one
script; they are distinguished purely by environment (`CHAIN_NAME`,
`FORK_RPC_URL`, `FORK_BLOCK`, `ANVIL_PORT`). There is no
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
`FORK_RPC_URL`, `ANVIL_PORT`. `require_env` also rejects any of these values if
it contains a literal quote character (see section 8), which matters because a
quote surviving expansion silently corrupts a URL built from it rather than
failing loudly on its own.

**2. Branch on `FORK_BLOCK`.**

```
if FORK_BLOCK is set and non-empty:
  assert FORK_BLOCK matches ^[1-9][0-9]*$, else FATAL
  exec anvil --fork-url "$FORK_RPC_URL" --fork-block-number "$FORK_BLOCK" \
             --host 0.0.0.0 --port "$ANVIL_PORT"
else:
  exec anvil --fork-url "$FORK_RPC_URL" \
             --host 0.0.0.0 --port "$ANVIL_PORT"
```

An empty or unset `FORK_BLOCK` forks the upstream chain's current tip, because
omitting `--fork-block-number` is anvil's own default behaviour. A `FORK_BLOCK`
that is not a positive integer (a decimal, a negative number, `0`, a hex
literal, non numeric text) is fatal before anvil ever starts.

**3. `exec` replaces the shell**, so anvil becomes PID 1 and receives signals
directly, same as before.

### Consequence: no automatic time alignment

Because there is no metadata fetch and no search, `scripts/anvil-fork.sh` has no
way to know what wall clock time the Lumen snapshot represents, and does not try
to find out. `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` and the Lumen snapshot
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
stated anywhere in the repository, and it is not this document's place to guess. See section 7.

## 3. Boot sequence: `scripts/edgenet.sh`

Runs as the entrypoint of the `edgenet` container. `set -e`, so any failing step
aborts the boot. In order:

1. **Clear the home directory's contents.** `CHAIN_HOME=$HOME/.$BINARY`. Since
   `HOME` is `/${BINARY}` (set in `Dockerfile.edgenet`) and Compose bind mounts
   `./.config/${CHAIN_ID}_edgenet/` onto `/${BINARY}/.${BINARY}/`, `CHAIN_HOME`
   is a live mountpoint from inside the container. It cannot be unlinked from
   inside the container that holds it, so `rm -rf $CHAIN_HOME/` used to fail
   with `rm: can't remove '/lumend/.lumend': Resource busy` and, because the
   script runs under `set -e`, that killed the entrypoint on every boot (see
   section 8 for the recovery steps if you hit this). The script now runs
   `mkdir -p "$CHAIN_HOME"` followed by
   `find "$CHAIN_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +`, which clears
   everything under the mountpoint without touching the mountpoint itself.
   `-mindepth 1` also picks up dotfiles and is a no-op on an already empty
   directory. Every boot is still a clean boot from the chain's perspective.
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
5. **Add the validator key.** `$BINARY keys add $VALIDATOR_MONIKER
   --keyring-backend test --recover` from the same mnemonic, then read the
   address back with `keys show -a` into `VALIDATOR_ADDRESS`.
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
* **Malformed `FORK_BLOCK` is fatal before anvil starts.** Covers
  `not-a-number`, `-5`, `1.5`, `0`, and `0x10`; each must exit non zero with
  `positive integer block number` in the output, and the anvil stub must never
  have been invoked.
* **Missing required environment is fatal and names the variable**, e.g. an
  absent `FORK_RPC_URL`.
* **Quoted environment values are rejected**, both at the `require_env` unit
  level and end to end through the entrypoint with a quoted `FORK_RPC_URL`;
  the entrypoint must die before anvil is invoked, naming the offending
  variable and the literal quote character.
* **`edgenet.sh` rejects a quoted `BINARY`** before any teardown of the chain
  home runs.
* **`edgenet.sh` also fails safely when `HOME` itself is quoted** (the stale
  image case, see section 8): it asserts the script exits non zero, that a
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
not used by it; see section 2 and the note in section 7. They may be there for
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
      - FORK_BLOCK=${ARBITRUM_FORK_BLOCK}
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
  ties `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` to the snapshot selected by
  `SNAPSHOT_URL`; see section 2. There is no validation, warning, or check of
  any kind if an operator changes one without the other.

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
