# Shipyard Neo — Dev Makefile
#
# All commands run from the dev/ directory.
#
# First time:
#   make build-all    # build bay, ship, gull (5-15 min)
#   make up           # start bay
#
# After code changes:
#   make rebuild-bay  # rebuild + restart bay only
#   make rebuild-all  # rebuild all images
#
# Daily use:
#   make up / down / logs / status

COMPOSE = docker compose
COMPOSE_BUILD = $(COMPOSE) --profile build

# Proxy support: if HTTP_PROXY / HTTPS_PROXY are set in the environment,
# pass them as --build-arg so apt/pip/uv/npm inside the Dockerfile can reach
# the internet.  Docker daemon-level proxy only covers image pulls;
# build-time network access needs explicit build args.
BUILD_ARGS =
ifdef HTTP_PROXY
BUILD_ARGS += --build-arg HTTP_PROXY=$(HTTP_PROXY)
endif
ifdef HTTPS_PROXY
BUILD_ARGS += --build-arg HTTPS_PROXY=$(HTTPS_PROXY)
endif
ifdef http_proxy
BUILD_ARGS += --build-arg http_proxy=$(http_proxy)
endif
ifdef https_proxy
BUILD_ARGS += --build-arg https_proxy=$(https_proxy)
endif
ifdef NO_PROXY
BUILD_ARGS += --build-arg NO_PROXY=$(NO_PROXY)
endif
ifdef no_proxy
BUILD_ARGS += --build-arg no_proxy=$(no_proxy)
endif

.PHONY: build-all build-bay build-ship build-gull
.PHONY: up down restart logs status
.PHONY: rebuild-bay rebuild-all
.PHONY: clean prune

# ── First-time setup ───────────────────────────────────

build-all:
	@echo "=== Building bay ==="
	$(COMPOSE) build $(BUILD_ARGS) bay
	@echo ""
	@echo "=== Building ship (runtime, large) ==="
	$(COMPOSE_BUILD) build $(BUILD_ARGS) ship
	@echo ""
	@echo "=== Building gull (browser runtime) ==="
	$(COMPOSE_BUILD) build $(BUILD_ARGS) gull
	@echo ""
	@echo "=== Build complete ==="
	@docker images shipyard-neo/bay:dev  --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null
	@docker images shipyard-neo/ship:dev --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null
	@docker images shipyard-neo/gull:dev --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null

build-bay:
	$(COMPOSE) build $(BUILD_ARGS) bay

build-ship:
	$(COMPOSE_BUILD) build $(BUILD_ARGS) ship

build-gull:
	$(COMPOSE_BUILD) build $(BUILD_ARGS) gull

# ── Runtime ────────────────────────────────────────────

up:
	$(COMPOSE) up -d bay
	@echo ""
	@echo "Bay is starting at http://localhost:8114"
	@echo "  health: http://localhost:8114/health"
	@echo "  logs:   make logs"

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart bay

logs:
	$(COMPOSE) logs -f bay

status:
	@docker ps --filter "network=shipyard-dev" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@echo "--- Bay health ---"
	@curl -s http://localhost:8114/health 2>/dev/null || echo "(not reachable yet)"

# ── Rebuild after code changes ─────────────────────────

rebuild-bay:
	$(COMPOSE) build $(BUILD_ARGS) bay
	$(COMPOSE) up -d bay

rebuild-all:
	$(COMPOSE) build $(BUILD_ARGS) bay
	$(COMPOSE_BUILD) build $(BUILD_ARGS) ship gull
	$(COMPOSE) up -d bay

# ── Cleanup ────────────────────────────────────────────

clean:
	$(COMPOSE) down -v --remove-orphans
	rm -rf bay-data

prune:
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	rm -rf bay-data
	docker ps -a --filter "label=bay.managed=true" -q | xargs -r docker rm -f 2>/dev/null || true
	docker volume ls --filter "label=bay.managed=true" -q | xargs -r docker volume rm 2>/dev/null || true
	docker network rm shipyard-dev 2>/dev/null || true
