# Changelog

## Unreleased

### Added

- Initial standalone edgenet stack, ported from lumen-bootstrap.
- `docker-compose.yml` with the Lumen edgenet node (26657, 1317, 9090) and anvil forks for Base (8545) and Somnia (8546), all under one `edgenet` profile and one shared network.
- `Dockerfile.anvil`, a single shared image (foundry, curl, jq) reused by every anvil service, entrypoint `scripts/anvil-fork.sh`.
- Per chain block time (`BLOCK_TIME_MS`, integer milliseconds), sourced from `<NAME>_BLOCK_TIME_MS` in `.env`. Chains differ too widely for a shared value, and sub second chains such as Somnia cannot be expressed in whole seconds.
- `Makefile` with `make edgenet` as the single entrypoint plus per service start, stop and logs targets.
- `.env.example` documenting all configuration.
- `README.md` covering prerequisites, quick start, services, configuration, adding an EVM chain and troubleshooting.
- `DEVELOPER.md` covering the architecture, the fork block resolution algorithm in `scripts/anvil-fork.sh`, the node boot sequence, the self-test, image build details and a known gaps backlog.

### Fixed

- `Dockerfile.edgenet` now installs `lz4` and `bash`. The original image in lumen-bootstrap was missing both while `edgenet.sh` uses a bash shebang and calls `lz4 -dc` to extract the snapshot.
- `README.md` no longer claims `BLOCK_TIME_MS` sets anvil's mining interval. `scripts/anvil-fork.sh` never passes `--block-time` to anvil. The value is a nominal average for the upstream chain and only seeds the binary search that resolves the fork block.
- `README.md` no longer claims `CHAIN_NAME` drives snapshot lookups. It is used for logging only.
- `README.md` now separates `SNAPSHOT_URL` (the archive the node restores) from `SNAPSHOT_API_URL` (the metadata endpoint whose `blockTime` selects each EVM fork block), which were easy to conflate.
