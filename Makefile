# Docker Compose loads ./.env itself; Make must not parse or export it.
COMPOSE := DOCKER_BUILDKIT=1 docker compose --profile edgenet

.PHONY: edgenet edgenet-up edgenet-stop edgenet-down edgenet-logs build build-force rebuild clean \
	node-start node-startd node-stop node-logs \
	anvil-base-start anvil-base-stop anvil-base-logs \
	anvil-somnia-start anvil-somnia-stop anvil-somnia-logs

# ──────────────────────────────────────────────────────────────
# Single entrypoint: Lumen edgenet node + all anvil forks
# ──────────────────────────────────────────────────────────────

# Start the full edgenet stack in the background
edgenet:
	@mkdir -p cache
	@$(COMPOSE) up -d --build

# Start the full edgenet stack in the foreground
edgenet-up:
	@mkdir -p cache
	@$(COMPOSE) up --build

# Stop all services (containers kept)
edgenet-stop:
	@$(COMPOSE) stop

# Stop and remove all containers and the network
edgenet-down:
	@$(COMPOSE) down

# Tail logs for the whole stack
edgenet-logs:
	@$(COMPOSE) logs -f --since 10s

# Build all images without starting anything
build:
	@mkdir -p cache
	@$(COMPOSE) build

# Build all images from scratch, ignoring the layer cache.
# --pull also refreshes the base images. Without it, --no-cache still reuses
# whatever alpine and foundry:stable are already on disk, and foundry:stable is
# a moving tag, so a stale local copy can pin you to an old anvil.
# Reach for this when a cached layer is serving something stale, for example a
# binary or genesis.json that was re-uploaded to the blob store under the same
# URL (Docker keys the RUN curl layer on the command text, not on the response).
build-force:
	@mkdir -p cache
	@$(COMPOSE) build --no-cache --pull

# Force a clean rebuild and bring the stack back up in the background
rebuild: build-force
	@$(COMPOSE) up -d

# ──────────────────────────────────────────────────────────────
# Lumen edgenet node (26657 RPC, 1317 LCD, 9090 GRPC)
# ──────────────────────────────────────────────────────────────

node-start:
	@mkdir -p cache
	@$(COMPOSE) up --build edgenet

node-startd:
	@mkdir -p cache
	@$(COMPOSE) up -d --build edgenet

node-stop:
	@$(COMPOSE) stop edgenet

node-logs:
	@$(COMPOSE) logs -f edgenet --since 10s

# ──────────────────────────────────────────────────────────────
# Anvil forks (one service per EVM chain)
# ──────────────────────────────────────────────────────────────

anvil-base-start:
	@$(COMPOSE) up -d --build anvil-base

anvil-base-stop:
	@$(COMPOSE) stop anvil-base

anvil-base-logs:
	@$(COMPOSE) logs -f anvil-base --since 10s

anvil-somnia-start:
	@$(COMPOSE) up -d --build anvil-somnia

anvil-somnia-stop:
	@$(COMPOSE) stop anvil-somnia

anvil-somnia-logs:
	@$(COMPOSE) logs -f anvil-somnia --since 10s

# ──────────────────────────────────────────────────────────────
# Housekeeping
# ──────────────────────────────────────────────────────────────

# Remove chain data (the snapshot cache in cache/ is kept)
clean:
	@rm -rf .config
