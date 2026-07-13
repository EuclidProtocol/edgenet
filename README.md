# Edgenet

A local Euclid development stack. One command starts a Lumen edgenet node (an in place testnet restored from a live network snapshot) together with one anvil fork per configured EVM chain.

Every anvil fork is pinned to the block whose timestamp best matches the Lumen snapshot's chain time, so the Cosmos side and the EVM side start from a consistent view of the world.

For internals (how the fork block is resolved, the binary search, the self-test), see [DEVELOPER.md](DEVELOPER.md).

## Prerequisites

* **Docker** with **Compose v2** (`docker compose`, not `docker-compose`) and **BuildKit**. The Makefile sets `DOCKER_BUILDKIT=1` for you.
* **make**.
* **Free host ports**: `26657`, `1317`, `9090`, `8545`, `8546`.
* **Network egress**. The build downloads the Lumen binary and genesis file, and at runtime the node downloads a compressed chain snapshot while each anvil service queries the snapshot API and the upstream EVM RPC.
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

### Host directories

| Path | Contents | Cleared by |
| --- | --- | --- |
| `cache/` | `snapshot.tar.lz4`, the downloaded snapshot archive | nothing, delete it by hand to force a re-download |
| `.config/${CHAIN_ID}_edgenet/` | the node's chain home (keys, config, state) | `make clean` |

Both are git ignored.

## Make targets

**Whole stack** (all services in the `edgenet` profile):

```sh
make edgenet         # build and start everything, detached
make edgenet-up      # same, but in the foreground
make edgenet-stop    # stop containers, keep them
make edgenet-down    # stop and remove containers and the network
make edgenet-logs    # tail logs for everything
make build           # build all images, start nothing
```

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
| `SNAPSHOT_URL` | Lumen snapshot download endpoint | URL of the snapshot **archive** (`.tar.lz4`). The node downloads this to `cache/snapshot.tar.lz4` and extracts it into the chain home. This is the chain data itself. |

The validator moniker is hard coded to `validator` in `docker-compose.yml` and is not configurable from `.env`.

### Anvil forks

| Variable | Default | What it does |
| --- | --- | --- |
| `SNAPSHOT_API_URL` | Lumen snapshot API root | URL of the snapshot **metadata** endpoint. Each anvil service fetches it and reads the `blockTime` field (an ISO 8601 UTC timestamp), which is the chain time the fork block must match. This is metadata only, not the archive. |
| `BASE_FORK_RPC_URL` | `https://mainnet.base.org` | Upstream JSON-RPC endpoint that `anvil-base` forks. |
| `SOMNIA_FORK_RPC_URL` | `https://api.infra.mainnet.somnia.network` | Upstream JSON-RPC endpoint that `anvil-somnia` forks. |
| `BASE_BLOCK_TIME_MS` | `2000` | Nominal block time of the **upstream** Base chain, in milliseconds. See below. |
| `SOMNIA_BLOCK_TIME_MS` | `1000` | Nominal block time of the **upstream** Somnia chain, in milliseconds. See below. |

`SNAPSHOT_URL` and `SNAPSHOT_API_URL` are easy to confuse. `SNAPSHOT_URL` is the archive the Lumen node restores. `SNAPSHOT_API_URL` is the metadata document whose `blockTime` decides which EVM block each fork starts from. Changing one without the other will desynchronise the Cosmos and EVM sides.

### `BLOCK_TIME_MS` is not anvil's mining interval

This trips people up. `scripts/anvil-fork.sh` never passes `--block-time` to anvil. The forks mine on anvil's own default behaviour, and `BLOCK_TIME_MS` has no effect on it.

`BLOCK_TIME_MS` describes the **upstream** chain. It is a nominal average used to seed the binary search that resolves the fork block: given the snapshot's target timestamp and the upstream chain head, the script estimates how many blocks back to look. The search then self-corrects, so a rough value is fine (the order of magnitude matters, exactness does not). It must be a positive integer number of milliseconds. Milliseconds rather than seconds because sub-second chains like Somnia exist.

### Variables passed to each anvil container

`docker-compose.yml` maps the per chain `.env` variables onto a fixed set of variables that `scripts/anvil-fork.sh` reads. All five are required by the script.

| Variable | Meaning |
| --- | --- |
| `CHAIN_NAME` | Label for the chain. **Logging only.** Nothing is looked up or resolved by it. Set literally in `docker-compose.yml`, not in `.env`. |
| `FORK_RPC_URL` | Upstream RPC endpoint to fork. |
| `BLOCK_TIME_MS` | Nominal upstream block time in ms, seeds the fork block search. |
| `SNAPSHOT_API_URL` | Snapshot metadata endpoint. |
| `ANVIL_PORT` | Port anvil listens on **inside the container**. The host port comes from the compose `ports:` mapping, which is a separate setting. They happen to match one to one today (8545 and 8546), and keeping them matched is the sane convention, but nothing enforces it. |

## Adding an EVM chain

Two `.env` entries and one compose block. No new Dockerfile.

1. Add the upstream RPC URL and the nominal block time to `.env` (and to `.env.example`):

   ```sh
   ARBITRUM_FORK_RPC_URL="https://arb1.arbitrum.io/rpc"
   ARBITRUM_BLOCK_TIME_MS=250
   ```

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
       - BLOCK_TIME_MS=${ARBITRUM_BLOCK_TIME_MS:-250}
       - SNAPSHOT_API_URL=${SNAPSHOT_API_URL}
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

1. Deletes the existing chain home, then initialises a fresh one and recovers the validator key from `VALIDATOR_MNEMONIC`.
2. Copies in the genesis file that was baked into the image at build time.
3. Sets the keyring backend to `test` and the chain id in `client.toml`.
4. Downloads the snapshot archive from `SNAPSHOT_URL` into `cache/snapshot.tar.lz4`, but only if that file is not already there.
5. Decompresses it with `lz4` and unpacks it into the chain home.
6. Starts the chain with `in-place-testnet`, which rewrites the snapshot state so the recovered validator is the sole validator, and funds a preset development account with a large balance of `DENOM` and `STAKE_DENOM`.

The chain home is rebuilt from the snapshot on every start, so the node is disposable. Delete `cache/snapshot.tar.lz4` to force a fresh snapshot download next time.

## How each anvil fork boots

`scripts/anvil-fork.sh` is the entrypoint of every anvil container. It fetches `SNAPSHOT_API_URL`, reads `blockTime` as the target chain time, then searches the upstream chain for the greatest block whose timestamp is at or before that target, and finally execs anvil with `--fork-url` and `--fork-block-number` pinned to that block.

It never guesses. If the upstream RPC cannot serve a block it needs, it fails loudly rather than silently forking at the wrong height. DEVELOPER.md covers the search itself.

There is an offline self-test that exercises the resolver against a simulated chain, with no network access and no extra tooling:

```sh
bash scripts/anvil-fork-test.sh
```

See DEVELOPER.md for what it covers.

## Troubleshooting

**The build fails with a strange URL error, or `BINARY` looks empty.**
You probably have no `.env`. Compose loads `./.env` on its own and does not treat a missing file as an error, it just interpolates every variable as an empty string and warns about each one (`The "BINARY" variable is not set. Defaulting to a blank string.`). Run `cp .env.example .env` and fill it in. See [DEVELOPER.md](DEVELOPER.md#8-troubleshooting) if the failure looks like a quoted value instead of an empty one.

**`exec format error`, or the binary download 404s.**
`PLATFORM` does not match your machine. Use `arm64` on Apple Silicon, `x86_64` on Intel and on most Linux hosts. Then rebuild with `make build`.

**The node fails while recovering the key.**
`VALIDATOR_MNEMONIC` is empty or invalid. It has no default.

**A port is already allocated.**
Free 26657, 1317, 9090, 8545 or 8546, or change the `ports:` mapping in `docker-compose.yml` (and `ANVIL_PORT` alongside it for an anvil service).

**Anvil exits with `RPC cannot serve block N (pruned history)`.**
The snapshot's chain time is older than the history your upstream RPC retains, so the fork block cannot be verified. Use an RPC endpoint with deeper history (an archive node), or take a fresher snapshot. Public RPC endpoints are usually not archival.

**Anvil exits with `snapshot metadata has no blockTime`.**
The snapshot predates `blockTime` support. Take a fresh snapshot.

**Anvil exits with `chain '<name>' is younger than the snapshot`.**
The upstream chain's genesis is later than the snapshot's chain time. Nothing to fork against.

**The stack starts from stale chain data.**
Run `make clean` to drop `.config/`, and delete `cache/snapshot.tar.lz4` if you also want a fresh snapshot. `make clean` alone keeps the cached archive.
