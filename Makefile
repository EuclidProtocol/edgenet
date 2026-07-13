-include .env
export

COMPOSE := DOCKER_BUILDKIT=1 docker compose --profile edgenet

.PHONY: edgenet edgenet-up edgenet-stop edgenet-down edgenet-logs build clean \
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
