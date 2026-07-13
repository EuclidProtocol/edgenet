# Edgenet

A local Euclid development stack. One command starts a Lumen edgenet node (an in place testnet restored from a live network snapshot) together with one anvil fork per configured EVM chain.

Each anvil fork's block height is set independently, either pinned to a specific block via `.env` or left to follow the upstream chain tip. Anvil forks are **not** automatically time aligned with the Lumen snapshot. If you need the Cosmos side and the EVM side to represent a consistent point in time, that alignment is a manual step you own, see [Configuration](#anvil-forks) below.

For internals (the fork boot sequence, the snapshot metadata contract, the self-test), see [DEVELOPER.md](DEVELOPER.md).

## Prerequisites

* **Docker** with **Compose v2** (`docker compose`, not `docker-compose`) and **BuildKit**. The Makefile sets `DOCKER_BUILDKIT=1` for you.
* **make**.
* **Free host ports**: `26657`, `1317`, `9090`, `8545`, `8546`.
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

## Services

| Service | Built from | Published ports |
| --- | --- | --- |
| `edgenet` | `Dockerfile.edgenet` | 26657 (RPC), 1317 (LCD), 9090 (gRPC) |
| `anvil-base` | `Dockerfile.anvil` | 8545 |
| `anvil-somnia` | `Dockerfile.anvil` | 8546 |

All three share the `edgenet-network` Docker network and the `edgenet` compose profile, which is why one `make edgenet` starts all of them. All three restart `on-failure`.

Every anvil service runs the same image (`edgenet-anvil:local`, built once from `Dockerfile.anvil`, containing foundry, curl and jq). Services differ only by environment variables, never by Dockerfile. Each one starts through `scripts/anvil-fork.sh`.

The node container also declares P2P port 26656, but compose does not publish it to the host.

`Dockerfile.edgenet` downloads two artifacts from Vercel blob storage at image build time, the chain binary and `genesis.json`. Both downloads use `curl -fL` with retries, so an HTTP error (a 404, for example) fails the build immediately instead of writing the error response to disk as if it were the artifact. The build then validates what it downloaded: the binary must start with the ELF magic bytes, and `genesis.json` must pass `jq empty`. Either a failed download or a failed check aborts the build with an error naming the exact URL it could not fetch or validate. See [Troubleshooting](#troubleshooting) below for the specific 404 you will currently hit.

### Host directories

| Path | Contents | Cleared by |
| --- | --- | --- |
| `cache/` | `snapshot-<height>.tar.lz4`, one downloaded snapshot archive per distinct height | nothing, delete it by hand to force a re-download |
| `.config/${CHAIN_ID}_edgenet/` | the node's chain home (keys, config, state) | `make clean` |

Both are git ignored. Because the cache file is now named after the snapshot height, `cache/` grows by one archive every time you point `SNAPSHOT_URL` at a different height, and it is never pruned automatically. If you upgraded from an older checkout, `cache/` may still hold a leftover `snapshot.tar.lz4` from the previous single file naming scheme; it is orphaned and safe to delete by hand.

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
| `VALIDATOR_MNEMONIC` | *(empty)* | Mnemonic of the edgenet validator account. Recovers the validator key and the address that `in-place-testnet` hands the chain to. **Required. There is no default that works.** |
| `SNAPSHOT_URL` | `https://snapshot.lumen.euclidprotocol.com/api/snapshots/latest` | URL of the snapshot **metadata** endpoint, not the archive. `scripts/edgenet.sh` fetches this URL, reads `.url` (the archive location) and `.height` from the returned JSON, then downloads the archive from `.url` and caches it at `cache/snapshot-<height>.tar.lz4`. Both a `latest` endpoint and a pinned `.../api/snapshots/<height>` endpoint are valid values. **Breaking change:** older configurations pointed `SNAPSHOT_URL` directly at a `/download` archive URL; that form is now rejected. If you have an existing `.env`, update it to a metadata endpoint. |

The validator moniker is hard coded to `validator` in `docker-compose.yml` and is not configurable from `.env`.

### Anvil forks

| Variable | Default | What it does |
| --- | --- | --- |
| `BASE_FORK_RPC_URL` | `https://mainnet.base.org` | Upstream JSON-RPC endpoint that `anvil-base` forks. |
| `SOMNIA_FORK_RPC_URL` | `https://api.infra.mainnet.somnia.network` | Upstream JSON-RPC endpoint that `anvil-somnia` forks. |
| `BASE_FORK_BLOCK` | *(empty)* | Block height `anvil-base` forks at. Empty (the default) means anvil forks the upstream chain's current tip. Set it to a positive integer to pin a specific block. A non-integer value is fatal. |
| `SOMNIA_FORK_BLOCK` | *(empty)* | Block height `anvil-somnia` forks at. Same rules as `BASE_FORK_BLOCK`. |

**Anvil forks are not automatically aligned with the Lumen snapshot.** Pinning `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` and choosing which Lumen snapshot to restore (via `SNAPSHOT_URL`) are two independent settings; nothing in the stack keeps them in sync. If your workflow needs the Cosmos and EVM sides to reflect a consistent point in time, you have to work out the corresponding block height on each upstream chain yourself (for example from a block explorer, by matching timestamps) and set `BASE_FORK_BLOCK` / `SOMNIA_FORK_BLOCK` accordingly. Leaving both empty is the simplest option when that alignment does not matter to you, at the cost of the forks drifting from whatever moment the snapshot represents.

### Variables passed to each anvil container

`docker-compose.yml` maps the per chain `.env` variables onto a fixed set of variables that `scripts/anvil-fork.sh` reads. All three are required by the script.

| Variable | Meaning |
| --- | --- |
| `CHAIN_NAME` | Label for the chain. **Logging only.** Nothing is looked up or resolved by it. Set literally in `docker-compose.yml`, not in `.env`. |
| `FORK_RPC_URL` | Upstream RPC endpoint to fork. |
| `FORK_BLOCK` | Block height to fork at, sourced from `<NAME>_FORK_BLOCK`. Empty or unset means fork the chain tip. |
| `ANVIL_PORT` | Port anvil listens on **inside the container**. The host port comes from the compose `ports:` mapping, which is a separate setting. They happen to match one to one today (8545 and 8546), and keeping them matched is the sane convention, but nothing enforces it. |

## Adding an EVM chain

Two `.env` entries and one compose block. No new Dockerfile.

1. Add the upstream RPC URL and the fork block height to `.env` (and to `.env.example`):

   ```sh
   ARBITRUM_FORK_RPC_URL=https://arb1.arbitrum.io/rpc
   ARBITRUM_FORK_BLOCK=
   ```

   Leave `ARBITRUM_FORK_BLOCK` empty to fork the chain tip, or set it to a pinned block number.

2. Add a service block to `docker-compose.yml`, picking a free port:

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

   Keep `ANVIL_PORT` and the `ports:` mapping in agreement.

3. Optionally add `anvil-arbitrum-start`, `anvil-arbitrum-stop` and `anvil-arbitrum-logs` targets to the `Makefile`, mirroring the existing ones.

The next `make edgenet` picks the service up automatically, because everything in the `edgenet` profile starts together.

## How the Lumen node boots

`scripts/edgenet.sh` is the container entrypoint. On every start it:

1. Clears the contents of the chain home directory (not the directory itself, since it is a live bind mount, see the note below), then initialises a fresh one and recovers the validator key from `VALIDATOR_MNEMONIC`.
2. Copies in the genesis file that was baked into the image at build time.
3. Sets the keyring backend to `test` and the chain id in `client.toml`.
4. Fetches the snapshot metadata JSON from `SNAPSHOT_URL`, reads `.url` (the archive location) and `.height` from it, then downloads the archive from `.url` into `cache/snapshot-<height>.tar.lz4`, but only if that file is not already there.
5. Decompresses it with `lz4` and unpacks it into the chain home.
6. Starts the chain with `in-place-testnet`, which rewrites the snapshot state so the recovered validator is the sole validator, and funds a preset development account with a large balance of `DENOM` and `STAKE_DENOM`.

The chain home is rebuilt from the snapshot on every start, so the node is disposable. Delete the matching `cache/snapshot-<height>.tar.lz4` to force a fresh snapshot download next time.

`docker-compose.yml` bind mounts `./.config/${CHAIN_ID}_edgenet/` onto the chain home inside the container, so step 1 cannot simply `rm -rf` that path (a live mountpoint cannot be unlinked from inside the container that holds it). The script instead removes everything under the directory while leaving the directory itself in place.

## How each anvil fork boots

`scripts/anvil-fork.sh` is the entrypoint of every anvil container. If `FORK_BLOCK` is set to a positive integer, it execs anvil with `--fork-url` and `--fork-block-number` pinned to that value. If `FORK_BLOCK` is empty or unset, it execs anvil with `--fork-url` only, so anvil forks the upstream chain's current tip. A non-integer `FORK_BLOCK` is fatal before anvil starts.

There is no lookup against the Lumen snapshot: the fork height and the snapshot are configured independently, see [Anvil forks](#anvil-forks) above for what that means for keeping them consistent.

There is an offline self-test that exercises the entrypoint's argument handling and its environment validation, with no network access and no extra tooling:

```sh
bash scripts/anvil-fork-test.sh
```

See DEVELOPER.md for what it covers.

## Troubleshooting

**The build fails with a strange URL error, or `BINARY` looks empty.**
You probably have no `.env`. Compose loads `./.env` on its own and does not treat a missing file as an error, it just interpolates every variable as an empty string and warns about each one (`The "BINARY" variable is not set. Defaulting to a blank string.`). Run `cp .env.example .env` and fill it in. See [DEVELOPER.md](DEVELOPER.md#8-troubleshooting) if the failure looks like a quoted value instead of an empty one.

**`exec format error`, or the binary download 404s.**
`PLATFORM` does not match your machine. Use `arm64` on Apple Silicon, `x86_64` on Intel and on most Linux hosts. Then rebuild with `make build`.

**The binary download 404s no matter what `PLATFORM` is set to, and the build error names a URL under `.../lumend/lumend_edgenet_...` (or `lumentestd`).**
This is expected right now, not a bug in this repo: the `_edgenet` build has not been uploaded to the blob store yet, so the image build will fail until that artifact is published there. Check that the blob actually exists at the URL the build printed before assuming `.env` or `PLATFORM` is wrong.

**The node fails while recovering the key.**
`VALIDATOR_MNEMONIC` is empty or invalid. It has no default.

**A port is already allocated.**
Free 26657, 1317, 9090, 8545 or 8546, or change the `ports:` mapping in `docker-compose.yml` (and `ANVIL_PORT` alongside it for an anvil service).

**Anvil exits with `FORK_BLOCK must be a positive integer block number`.**
`BASE_FORK_BLOCK` or `SOMNIA_FORK_BLOCK` is set to something other than a positive integer. Leave it empty to fork the chain tip, or set it to a plain block number.

**The node fails to fetch snapshot metadata, or complains the response is not JSON.**
`SNAPSHOT_URL` must point at a snapshot metadata endpoint (one that returns JSON with `.url` and `.height`), not at an archive file directly. If your `.env` predates this change, it may still hold the old `/download` archive URL; that form is rejected. Point it at a metadata endpoint instead, for example `https://snapshot.lumen.euclidprotocol.com/api/snapshots/latest` or a pinned `https://snapshot.lumen.euclidprotocol.com/api/snapshots/<height>`.

**The `edgenet` container fails with `Resource busy` on a path that is not quoted.**
See [DEVELOPER.md](DEVELOPER.md#8-troubleshooting), this is a different failure from the quote poisoning case below and has its own entry there.

**The stack starts from stale chain data.**
Run `make clean` to drop `.config/`, and delete the relevant `cache/snapshot-<height>.tar.lz4` if you also want a fresh snapshot download. `make clean` alone keeps the cached archive.
