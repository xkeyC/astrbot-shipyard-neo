.PHONY: help install test test-integration test-unit clean build run

# 默认目标
help:
	@echo "Available targets:"
	@echo "  help              - Show this help message"
	@echo "  test-integration  - Run integration tests only"
	@echo "  clean             - Clean up Docker containers and images"
	@echo "  build             - Build Docker image"
	@echo "  run               - Run the ship container"

# 运行集成测试
test-integration:
	python -m pytest tests/integration/ -v -m integration

# 清理Docker资源
clean:
	@echo "Cleaning up Docker resources..."
	-docker container prune -f
	-docker image rm soulter/shipyard-ship:test 2>/dev/null || true
	-docker system prune -f

# 构建期镜像源（Dockerfile 里全部可选，不传就走官方源）。`make build MIRROR_ARGS=` 用官方源。
MIRROR_ARGS ?= \
	--build-arg PACMAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/archlinux \
	--build-arg PYPI_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple \
	--build-arg CONDA_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud \
	--build-arg MINIFORGE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease \
	--build-arg RUSTUP_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/rustup \
	--build-arg PLAYWRIGHT_MIRROR=https://registry.npmmirror.com/-/binary/playwright \
	--build-arg PYTHON_MIRROR=https://registry.npmmirror.com/-/binary/python-build-standalone \
	--build-arg NIXPKGS_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixpkgs-unstable/nixexprs.tar.xz

# 构建Docker镜像
build:
	docker build $(MIRROR_ARGS) -t soulter/shipyard-ship:latest .

# 运行Ship容器
run: build
	docker run --rm -p 8123:8123 soulter/shipyard-ship:latest

# 开发模式运行（本地）
dev:
	python run.py
