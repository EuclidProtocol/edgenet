# Edgenet

A local Euclid development stack. One command starts a Lumen edgenet node (an in place testnet restored from a live network snapshot) together with one anvil fork per configured EVM chain, plus a faucet web app for funding addresses on any of them, see [Faucet](#faucet) below.

Each anvil fork's block height is set independently, either pinned to a specific block via `.env` or left to follow the upstream chain tip. Anvil forks are **not** automatically time aligned with the Lumen snapshot. If you need the Cosmos side and the EVM side to represent a consistent point in time, that alignment is a manual step you own, see [Configuration](#anvil-forks) below.

For internals (the fork boot sequence, the snapshot metadata contract, the self-test), see [DEVELOPER.md](DEVELOPER.md).

## Prerequisites

* **Docker** with **Compose v2** (`docker compose`, not `docker-compose`) and **BuildKit**. The Makefile sets `DOCKER_BUILDKIT=1` for you.
* **make**.
* **Free host ports**: `26657`, `1317`, `9090`, `8545`, `8546`, `8547`, `3000`.
* **Network egress**. The build downloads the Lumen binary and genesis file, and at runtime the node fetches snapshot metadata and downloads a compressed chain snapshot while each anvil service dials its upstream EVM RPC to fork from.
* **A validator mnemonic**. `VALIDATOR_MNEMONIC` is the only variable in `.env.example` with no working default. Nothing starts without it.
* **The right `PLATFORM`**. `.env.example` ships `x86_64`. On Apple Silicon you must change it to `arm64`, otherwise the build pulls a binary that will not run.

## Quick start

```sh
git clone <this repo> && cd edgenet
cp .env.example .env       # do this first, see the warning below
# edit .env: set VALIDATOR_MNEMONIC, and set PLATFORM=arm64 on Apple Silicon
make edgenet
```

`make edgenet` is the single entrypoint. It builds all images and starts the Lumen node plus every anvil fork in the background, then returns.

Watch it come up with `make edgenet-logs`. The first run is slow because it downloads the snapshot into `cache/`. Later runs reuse the cached archive.

> **Copy `.env.example` to `.env` before anything else.** Compose loads `./.env` on its own, so a missing `.env` is not a hard error. Every variable comes through as an empty string instead, Compose prints a warning like `The "BINARY" variable is not set. Defaulting to a blank string.` for each one, and the build fails much later with a confusing message (an empty `BINARY` turns the binary download URL into nonsense). If a first build fails in a way that makes no sense, check that `.env` exists.

Once the stack is up:

| What | Where |
| --- | --- |
| Lumen RPC | `http://localhost:26657` |
| Lumen LCD (REST) | `http://localhost:1317` |
| Lumen gRPC | `localhost:9090` |
| Base fork | `http://localhost:8545` |
| Somnia fork | `http://localhost:8546` |
| Polygon fork | `http://localhost:8547` |
| Faucet | `http://localhost:3000` |

## Services

| Service | Built from | Published ports |
| --- | --- | --- |
| `edgenet` | `Dockerfile.edgenet` | 26657 (RPC), 1317 (LCD), 9090 (gRPC) |
| `anvil-base` | `Dockerfile.anvil` | 8545 |
| `anvil-somnia` | `Dockerfile.anvil` | 8546 |
| `anvil-polygon` | `Dockerfile.anvil` | 8547 |
| `faucet` | `faucet/Dockerfile` | 3000 |

All five share the `edgenet-network` Docker network and the `edgenet` compose profile, which is why one `make edgenet` starts all of them. All five restart `on-failure`.

Every anvil service runs the same image (`edgenet-anvil:local`, built once from `Dockerfile.anvil`, containing foundry, curl and jq). Services differ only by environment variables, never by Dockerfile. Each one starts through `scripts/anvil-fork.sh`.

The node container also declares P2P port 26656, but compose does not publish it to the host.

`Dockerfile.edgenet` downloads two artifacts from Vercel blob storage at image build time, the chain binary and `genesis.json`. Both downloads use `curl -fL` with retries, so an HTTP error (a 404, for example) fails the build immediately instead of writing the error response to disk as if it were the artifact. The build then validates what it downloaded: the binary must start with the ELF magic bytes, and `genesis.json` must pass `jq empty`. Either a failed download or a failed check aborts the build with an error naming the exact URL it could not fetch or validate. See [Troubleshooting](#troubleshooting) below for the specific 404 you will currently hit.

### Host directories

| Path | Contents | Cleared by |
| --- | --- | --- |
| `cache/` | `snapshot-<height>.tar.lz4`, one downloaded snapshot archive per distinct height | nothing, delete it by hand to force a re-download |
| `.config/${CHAIN_ID}_edgenet/` | the node's chain home (keys, config, state, plus an `initialized` sentinel once the chain has been built) | `make clean` |

Both are git ignored. The `initialized` sentinel is what makes the chain persist across restarts instead of being rebuilt from the snapshot every time; removing it, whether via `make clean` or by hand, is what forces a rebuild. See [How the Lumen node boots](#how-the-lumen-node-boots). Because the cache file is now named after the snapshot height, `cache/` grows by one archive every time you point `SNAPSHOT_URL` at a different height, and it is never pruned automatically. If you upgraded from an older checkout, `cache/` may still hold a leftover `snapshot.tar.lz4` from the previous single file naming scheme; it is orphaned and safe to delete by hand.

## Make targets

**Whole stack** (all services in the `edgenet` profile):

```sh
make edgenet         # build and start everything, detached
make edgenet-up      # same, but in the foreground
make edgenet-stop    # stop containers, keep them
make edgenet-down    # stop and remove containers and the network
make edgenet-logs    # tail logs for everything
make build           # build all images, start nothing
make build-force     # build all images, no cache, base images refreshed, start nothing
make rebuild         # build-force, then bring the stack up detached
```

Reach for `make build-force` when a cached layer is serving something stale and `make build` will not fix it. Docker keys a `RUN curl ...` layer on the command text, not on the response body, so if an artifact such as the chain binary or `genesis.json` is re-uploaded to the blob store under the same URL, a plain `make build` still reuses the old cached layer. `--pull` additionally refreshes the base images, which matters because `foundry:stable` (the image `Dockerfile.anvil` builds from) is a moving tag; `--no-cache` on its own still reuses whatever `alpine` and `foundry:stable` images already sit on disk. `make rebuild` is `build-force` followed by bringing the stack up detached, the forced rebuild equivalent of `make edgenet`.

**Lumen node only:**

```sh
make node-start      # build and start, foreground
make node-startd     # build and start, detached
make node-stop
make node-logs
```

**Base fork only:**

```sh
make anvil-base-start    # build and start, detached
make anvil-base-stop
make anvil-base-logs
```

**Somnia fork only:**

```sh
make anvil-somnia-start  # build and start, detached
make anvil-somnia-stop
make anvil-somnia-logs
```

**Polygon fork only:**

```sh
make anvil-polygon-start  # build and start, detached
make anvil-polygon-stop
make anvil-polygon-logs
```

**Faucet only:**

```sh
make faucet-start    # build and start, detached
make faucet-stop
make faucet-logs
```

**Housekeeping:**

```sh
make clean           # remove .config/ (chain data). The snapshot cache in cache/ is kept.
```

## Configuration

All configuration lives in `.env`, copied from `.env.example`. Compose loads it natively; the Makefile does not touch it.

### Lumen node

| Variable | Default | What it does |
| --- | --- | --- |
| `BINARY` | `lumend` | Name of the chain binary. `lumend` for a mainnet derived edgenet, `lumentestd` for a testnet derived one. Used as a build arg to pick which prebuilt binary to download, and as the in-container home directory name. |
| `CHAIN_ID` | `lumen-1` | Chain id of the network the edgenet is derived from. Passed to `init`, written into `client.toml`, passed to `in-place-testnet`, and used in the host path `.config/${CHAIN_ID}_edgenet/`. |
| `DENOM` | `ualpha` | Default denomination. Used as `--default-denom` and in the funded account balances. |
| `STAKE_DENOM` | `usync` | Staking denomination. Used in the funded account balances. |
| `PLATFORM` | `x86_64` | Architecture of the prebuilt binary to download. Valid values are `x86_64` and `arm64`. **Set this to `arm64` on Apple Silicon.** |
| `VALIDATOR_MNEMONIC` | *(empty)* | Mnemonic of the edgenet validator account. Recovers the validator key that `scripts/edgenet.sh` then reads back with `keys show` to get the operator and account addresses `in-place-testnet` is handed. **Required. There is no default that works.** |
| `SNAPSHOT_URL` | `https://snapshot.lumen.euclidprotocol.com/api/snapshots/latest` | URL of the snapshot **metadata** endpoint, not the archive. `scripts/edgenet.sh` fetches this URL, reads `.url` (the archive location) and `.height` from the returned JSON, then downloads the archive from `.url` and caches it at `cache/snapshot-<height>.tar.lz4`. Both a `latest` endpoint and a pinned `.../api/snapshots/<height>` endpoint are valid values. **Breaking change:** older configurations pointed `SNAPSHOT_URL` directly at a `/download` archive URL; that form is now rejected. If you have an existing `.env`, update it to a metadata endpoint. |
| `FUNDED_ACCOUNTS` | `euclid1z328t58xya5hw32a869n6hah33uaehw5zz9rj3` | Comma separated list of extra bech32 addresses to fund on the testnet, in addition to the validator's own account, which is always funded regardless of this setting. Passed to `in-place-testnet` via `--accounts-to-fund`. Leave it empty to fund only the validator. |
| `FAUCET_PRIVATE_KEY` | *(empty)* | Raw hex private key (no `0x` prefix, no quotes) of the faucet account the [faucet](#faucet) web app signs Lumen transactions with. `scripts/edgenet.sh` derives its `euclid1...` address and funds it `1000000000000ualpha` and `1000000000000usync` (1,000,000 of each denom) at first boot, same as any other funded account. Leave it empty to skip funding a faucet account; the faucet app's Lumen tab will then fail every request with `FAUCET_PRIVATE_KEY not set`. |

The validator moniker is hard coded to `validator` in `docker-compose.yml` and is not configurable from `.env`.

### Anvil forks

| Variable | Default | What it does |
| --- | --- | --- |
| `BASE_FORK_RPC_URL` | `https://mainnet.base.org` | Upstream JSON-RPC endpoint that `anvil-base` forks. |
| `SOMNIA_FORK_RPC_URL` | `https://api.infra.mainnet.somnia.network` | Upstream JSON-RPC endpoint that `anvil-somnia` forks. |
| `POLYGON_FORK_RPC_URL` | `https://polygon-bor-rpc.publicnode.com` | Upstream JSON-RPC endpoint that `anvil-polygon` forks. |
| `BASE_FORK_BLOCK` | *(empty)* | Block height `anvil-base` forks at. Empty (the default) means anvil forks the upstream chain's current tip. Set it to a positive integer to pin a specific block. A non-integer value is fatal. |
| `SOMNIA_FORK_BLOCK` | *(empty)* | Block height `anvil-somnia` forks at. Same rules as `BASE_FORK_BLOCK`. |
| `POLYGON_FORK_BLOCK` | *(empty)* | Block height `anvil-polygon` forks at. Same rules as `BASE_FORK_BLOCK`. |

**Anvil forks are not automatically aligned with the Lumen snapshot.** Pinning `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` / `POLYGON_FORK_BLOCK` and choosing which Lumen snapshot to restore (via `SNAPSHOT_URL`) are two independent settings; nothing in the stack keeps them in sync. If your workflow needs the Cosmos and EVM sides to reflect a consistent point in time, you have to work out the corresponding block height on each upstream chain yourself (for example from a block explorer, by matching timestamps) and set `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` / `POLYGON_FORK_BLOCK` accordingly. Leaving all empty is the simplest option when that alignment does not matter to you, at the cost of the forks drifting from whatever moment the snapshot represents.

### Variables passed to each anvil container

`docker-compose.yml` maps the per chain `.env` variables onto a fixed set of variables that `scripts/anvil-fork.sh` reads. All of these except `FORK_BLOCK` are required by the script.

| Variable | Meaning |
| --- | --- |
| `CHAIN_NAME` | Label for the chain. **Logging only.** Nothing is looked up or resolved by it. Set literally in `docker-compose.yml`, not in `.env`. |
| `FORK_RPC_URL` | Upstream RPC endpoint to fork. |
| `FORK_BLOCK` | Block height to fork at, sourced from `<NAME>_FORK_BLOCK`. Empty or unset means fork the chain tip. |
| `BLOCK_TIME` | Seconds between blocks, passed to anvil as `--block-time`. A fact about the upstream chain (Base 2, Somnia 1, Polygon 2), set literally in `docker-compose.yml`, not in `.env`. Required; must be a positive integer. |
| `EVM_CHAIN_ID` | EVM chain id anvil reports over `eth_chainId`, passed as `--chain-id`, which overrides whatever the fork would otherwise inherit from the upstream chain. Set literally in `docker-compose.yml`: Base 84539, Somnia 50319, Polygon 1379, each the real mainnet chain id (8453, 5031, 137) with a digit inserted, not the real id itself. The offset is deliberate: a wallet or browser extension keys its network list off chain id, and a fork reporting the real mainnet id could be mistaken by an already configured wallet for that same network. Named `EVM_CHAIN_ID` rather than `CHAIN_ID` because `CHAIN_ID` already names the Cosmos chain id on the `edgenet` service. Required by the script; must be a positive integer. |
| `ANVIL_PORT` | Port anvil listens on **inside the container**. Every anvil service sets this to `8545`; all three containers listen on the same internal port. The host port comes from the compose `ports:` mapping, a separate setting, and is what actually tells the forks apart from the host side: `8545` for `anvil-base`, `8546` for `anvil-somnia`, `8547` for `anvil-polygon`. Host and container port no longer need to match, and today they only do for `anvil-base`. |

## Adding an EVM chain

One `<NAME>_FORK_RPC_URL` line and one `<NAME>_FORK_BLOCK` line in `.env`, plus one service block in `docker-compose.yml` carrying `CHAIN_NAME`, `BLOCK_TIME`, `EVM_CHAIN_ID` and `ANVIL_PORT` as literals. No new Dockerfile.

1. Add the upstream RPC URL and the fork block height to `.env` (and to `.env.example`):

   ```sh
   ARBITRUM_FORK_RPC_URL=https://arb1.arbitrum.io/rpc
   ARBITRUM_FORK_BLOCK=
   ```

   Leave `ARBITRUM_FORK_BLOCK` empty to fork the chain tip, or set it to a pinned block number. `BLOCK_TIME` and `EVM_CHAIN_ID` do not go in `.env`; see the next step.

2. Add a service block to `docker-compose.yml`, picking a free host port. `BLOCK_TIME` (whole seconds) and `EVM_CHAIN_ID` are facts about the chain being forked, not deployment configuration, so they are set as literals here, the same way `CHAIN_NAME` already is; look up the chain's real block time and query its real chain id via `eth_chainId` rather than guessing:

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

   `ANVIL_PORT` stays `8545`, matching every other anvil service; only the host side of `ports:` needs to be free, and it no longer needs to match `ANVIL_PORT`. `BLOCK_TIME` and `EVM_CHAIN_ID` are both required by `scripts/anvil-fork.sh`; a missing, non positive integer, or quote containing value is fatal before anvil starts.

3. Optionally add `anvil-arbitrum-start`, `anvil-arbitrum-stop` and `anvil-arbitrum-logs` targets to the `Makefile`, mirroring the existing ones.

The next `make edgenet` picks the service up automatically, because everything in the `edgenet` profile starts together.

## How the Lumen node boots

`scripts/edgenet.sh` is the container entrypoint. It checks for a sentinel file, `$CHAIN_HOME/initialized`, before doing anything else, and that check decides which of two paths the boot takes.

**If the sentinel is present, the chain resumes.** The script skips setup entirely, clearing nothing, downloading nothing, and execs straight into `$BINARY start` against the existing chain home, with the RPC and API flags. This is the path an ordinary restart takes.

**If the sentinel is absent, the chain is built from the snapshot:**

1. Clears the contents of the chain home directory (not the directory itself, since it is a live bind mount, see the note below), then initialises a fresh one and recovers the validator key from `VALIDATOR_MNEMONIC`.
2. Copies in the genesis file that was baked into the image at build time.
3. Sets the keyring backend to `test` and the chain id in `client.toml`.
4. Fetches the snapshot metadata JSON from `SNAPSHOT_URL`, reads `.url` (the archive location) and `.height` from it, then downloads the archive from `.url` into `cache/snapshot-<height>.tar.lz4`, but only if that file is not already there.
5. Decompresses it with `lz4` and unpacks it into the chain home.
6. Reads the consensus public and private key out of `$CHAIN_HOME/config/priv_validator_key.json`. This happens only after the snapshot has been extracted, not right after `init`, because the snapshot's own `config/` can overwrite the key `init` generated. Reading it any earlier would hand `in-place-testnet` a consensus key that no longer matches what is on disk. The script exits before starting the chain if that file is missing, is not valid JSON, or has an empty key field.
7. Writes the sentinel file, then starts the chain with `in-place-testnet`, passing the validator's operator and account addresses (derived from the recovered mnemonic with `keys show`), the consensus pubkey and privkey just read, and the accounts to fund: the validator's own account plus any addresses listed in `FUNDED_ACCOUNTS`. This rewrites the snapshot state so the recovered validator is the sole validator and gives each funded account a large balance of `DENOM` and `STAKE_DENOM`. The sentinel is written before `in-place-testnet` runs, not after, because that command never returns: it converts the state and then runs the node itself.

Because `CHAIN_HOME` is a bind mount (`./.config/${CHAIN_ID}_edgenet/`), the sentinel and the rest of the chain data survive container restarts, which is what makes the node's state persistent instead of being rebuilt from the snapshot every time it starts. Three things follow from this, and each has a Troubleshooting entry below:

* **Changing `SNAPSHOT_URL` has no effect on an already-initialized container.** The resume path never reaches the snapshot code. To move to a different snapshot, run `make clean` (or delete `$CHAIN_HOME/initialized` by hand) first, then start the stack again so it rebuilds.
* **A conversion that dies partway leaves the sentinel over a half-converted home.** The sentinel is written just before `in-place-testnet`, which is the only point available since that command never returns. If it dies partway through, the next restart takes the resume path and runs `start` against a home that was never fully converted. Recovery is `make clean`.
* **A crash from an unrelated cause can now loop instead of self-healing.** `docker-compose.yml` sets `restart: on-failure` on the `edgenet` service. Previously every restart wiped and rebuilt the chain, so a corrupted database after a hard kill, for example, silently fixed itself. Now the container restarts straight back into `start` against the same broken home and can crash-loop. `make clean` is the recovery path.

`docker-compose.yml` bind mounts `./.config/${CHAIN_ID}_edgenet/` onto the chain home inside the container, so step 1 of the build path cannot simply `rm -rf` that path (a live mountpoint cannot be unlinked from inside the container that holds it). The script instead removes everything under the directory while leaving the directory itself in place.

## How each anvil fork boots

`scripts/anvil-fork.sh` is the entrypoint of every anvil container. If `FORK_BLOCK` is set to a positive integer, it execs anvil with `--fork-url` and `--fork-block-number` pinned to that value. If `FORK_BLOCK` is empty or unset, it execs anvil with `--fork-url` only, so anvil forks the upstream chain's current tip. A non-integer `FORK_BLOCK` is fatal before anvil starts.

Both branches also pass `--block-time "$BLOCK_TIME"` and `--chain-id "$EVM_CHAIN_ID"`. Both are required: a missing, non-positive-integer, or quote-containing value is fatal before anvil starts, same as a malformed `FORK_BLOCK`. Without `--block-time`, anvil auto-mines a block on every transaction and produces no empty blocks, so an idle fork never advances; with it, the fork ticks on a fixed interval like a real chain. `--chain-id` is not a no-op: anvil does not have to inherit the chain id from the chain it forks, and the flag overrides whatever it would otherwise report. A fork of Base with no `--chain-id` flag reports 8453 over `eth_chainId`; passed as `--chain-id 84539`, it reports 84539 instead. That override is the reason `EVM_CHAIN_ID` is passed at all: each fork's real mainnet chain id (Base 8453, Somnia 5031, Polygon 137) is offset by one inserted digit (84539, 50319, 1379) rather than reported as is, so a wallet or browser extension already configured for the real chain cannot mistake the fork for it. Both values are hardcoded per service in `docker-compose.yml` (`anvil-base`: 2 seconds and chain id 84539; `anvil-somnia`: 1 second and chain id 50319; `anvil-polygon`: 2 seconds and chain id 1379), not sourced from `.env`, because they are facts about the upstream chain rather than deployment configuration; the real chain ids were queried live from each RPC endpoint via `eth_chainId` before being offset. Deliberately not overridden: anvil already inherits gas limit, base fee, hardfork and code size limit from the forked chain, and its own defaults for transaction ordering and epoch length are already realistic, so none of those were touched. One caveat: anvil's block time only accepts whole seconds, so `anvil-somnia`, whose real block time is well under a second, still ticks slower than the real chain; see [DEVELOPER.md](DEVELOPER.md#8-known-gaps-and-cleanup-backlog) for this and other known gaps.

There is no lookup against the Lumen snapshot: the fork height and the snapshot are configured independently, see [Anvil forks](#anvil-forks) above for what that means for keeping them consistent.

There is an offline self-test that exercises the entrypoint's argument handling and its environment validation, with no network access and no extra tooling:

```sh
bash scripts/anvil-fork-test.sh
```

See DEVELOPER.md for what it covers.

## Faucet

The `faucet` service is a small web app, a Vite/React frontend backed by an Express server, that funds a given address on any of the four chains on request. Open `http://localhost:3000` once the stack is up, pick a chain and an address, and submit.

Funding works differently depending on the chain:

| Chain | What happens per request |
| --- | --- |
| `lumen` | The server signs and broadcasts a real bank send of `1000000000ualpha` and `1000000000usync` (1,000 of each denom) from the faucet account (the one derived from `FAUCET_PRIVATE_KEY`) to the requested `euclid1...` address, via `SigningStargateClient`. The response is a real transaction hash. |
| `base`, `somnia`, `polygon` | The server calls `anvil_setBalance` on the corresponding anvil fork, adding 1,000 of the chain's native token to whatever balance the address already has. This is a state cheat, not a transaction, so there is no transaction hash; the response returns the latest block hash instead. |

There is no rate limiting anywhere in the server. Any address can be funded any number of times.

The faucet account on Lumen only exists if `FAUCET_PRIVATE_KEY` is set (see [Configuration](#lumen-node) above); it is funded `1000000000000ualpha` and `1000000000000usync` (1,000,000 of each denom) once, at the Lumen node's first boot, the same way every other funded account is. If `FAUCET_PRIVATE_KEY` is empty, the `lumen` tab fails every request with `FAUCET_PRIVATE_KEY not set`, since there is no faucet account to sign from. The EVM tabs (`base`, `somnia`, `polygon`) do not depend on `FAUCET_PRIVATE_KEY` at all; `anvil_setBalance` needs no funded account, only a reachable anvil fork.

```sh
make faucet-start
make faucet-logs
```

## Troubleshooting

**The build fails with a strange URL error, or `BINARY` looks empty.**
You probably have no `.env`. Compose loads `./.env` on its own and does not treat a missing file as an error, it just interpolates every variable as an empty string and warns about each one (`The "BINARY" variable is not set. Defaulting to a blank string.`). Run `cp .env.example .env` and fill it in. See [DEVELOPER.md](DEVELOPER.md#9-troubleshooting) if the failure looks like a quoted value instead of an empty one.

**`exec format error`, or the binary download 404s.**
`PLATFORM` does not match your machine. Use `arm64` on Apple Silicon, `x86_64` on Intel and on most Linux hosts. Then rebuild with `make build`.

**The binary download 404s no matter what `PLATFORM` is set to, and the build error names a URL under `.../lumend/lumend_edgenet_...` (or `lumentestd`).**
This is expected right now, not a bug in this repo: the `_edgenet` build has not been uploaded to the blob store yet, so the image build will fail until that artifact is published there. Check that the blob actually exists at the URL the build printed before assuming `.env` or `PLATFORM` is wrong.

**The node fails while recovering the key.**
`VALIDATOR_MNEMONIC` is empty or invalid. It has no default.

**A port is already allocated.**
Free 26657, 1317, 9090, 8545, 8546, 8547 or 3000, or change the host side of the `ports:` mapping in `docker-compose.yml` (for an anvil service the container side stays `8545`, matching `ANVIL_PORT`).

**The faucet's `lumen` tab returns `FAUCET_PRIVATE_KEY not set`.**
`FAUCET_PRIVATE_KEY` is empty in `.env`. Set it to a raw hex private key (no `0x` prefix, no quotes), then rebuild the `edgenet` node so the derived faucet account gets funded at boot (`make node-startd --build` or `make edgenet`, since the node only funds the account on a fresh, uninitialized chain home, see [How the Lumen node boots](#how-the-lumen-node-boots)). The `base`, `somnia` and `polygon` tabs do not need this variable at all.

**The edgenet node fails to boot with `could not import FAUCET_PRIVATE_KEY as a hex key`.**
`FAUCET_PRIVATE_KEY` is not a valid raw hex private key. Check it has no `0x` prefix and no surrounding quotes.

**Anvil exits with `FORK_BLOCK must be a positive integer block number`.**
`BASE_FORK_BLOCK`, `SOMNIA_FORK_BLOCK` or `POLYGON_FORK_BLOCK` is set to something other than a positive integer. Leave it empty to fork the chain tip, or set it to a plain block number.

**Anvil exits with `BLOCK_TIME must be a positive integer` or `EVM_CHAIN_ID must be a positive integer`.**
`BLOCK_TIME` and `EVM_CHAIN_ID` are literals in `docker-compose.yml`, not `.env` values, so this points at an edit made there (or at a new service added while [adding an EVM chain](#adding-an-evm-chain)) rather than at anything in `.env`. Both must be plain positive integers.

**The node fails to fetch snapshot metadata, or complains the response is not JSON.**
`SNAPSHOT_URL` must point at a snapshot metadata endpoint (one that returns JSON with `.url` and `.height`), not at an archive file directly. If your `.env` predates this change, it may still hold the old `/download` archive URL; that form is rejected. Point it at a metadata endpoint instead, for example `https://snapshot.lumen.euclidprotocol.com/api/snapshots/latest` or a pinned `https://snapshot.lumen.euclidprotocol.com/api/snapshots/<height>`.

**The `edgenet` container fails with `Resource busy` on a path that is not quoted.**
See [DEVELOPER.md](DEVELOPER.md#9-troubleshooting), this is a different failure from the quote poisoning case below and has its own entry there.

**The stack starts from stale chain data.**
Run `make clean` to drop `.config/`, and delete the relevant `cache/snapshot-<height>.tar.lz4` if you also want a fresh snapshot download. `make clean` alone keeps the cached archive.

**I changed `SNAPSHOT_URL` but the node is still running the old snapshot.**
Once `.config/${CHAIN_ID}_edgenet/initialized` exists, the node resumes its existing chain on every restart instead of rebuilding it, and the resume path never reaches the snapshot code, so a new `SNAPSHOT_URL` is not picked up. Run `make clean` (or delete that `initialized` file by hand) and start the stack again so it rebuilds from the new snapshot.

**The node is crash-looping.**
The chain now persists across restarts, and `docker-compose.yml` sets `restart: on-failure` on the `edgenet` service, so a crash caused by something in the chain home itself (a corrupted database after a hard kill, for example, rather than a bad snapshot or config) restarts straight back into the same broken home and can loop. Run `make clean` to drop `.config/` and force a rebuild.
