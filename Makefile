APP_NAME := sandboxd
BUILD_DIR := build

.PHONY: build install lint lint-fix test clean tidy

build:
	go build -o $(BUILD_DIR)/$(APP_NAME) ./cmd/sandboxd

install:
	go install ./cmd/sandboxd

tidy:
	go mod tidy

test:
	go test ./...

lint:
	golangci-lint run ./...

lint-fix:
	golangci-lint run --fix ./...

clean:
	rm -rf $(BUILD_DIR)

## Protobuf targets (host-based; Docker fallback below)
##
## Required tools on PATH:
##   - buf                          (https://buf.build/docs/installation)
##   - protoc-gen-gocosmos          (`go install github.com/cosmos/gogoproto/protoc-gen-gocosmos@latest`)
##   - protoc-gen-grpc-gateway      (`go install github.com/grpc-ecosystem/grpc-gateway/protoc-gen-grpc-gateway@latest`)
##   - clang-format (proto-format only, optional)
##
## `make proto-tools` installs the two Go-based plugins for you. `buf` and
## `clang-format` are system tools and must be installed via your package
## manager.

GOBIN ?= $(shell go env GOPATH)/bin

# Make Go-installed binaries (buf, protoc-gen-*) visible to every target's
# recipe — the user's interactive shell may not include $GOBIN on PATH.
export PATH := $(GOBIN):$(PATH)

# Generated Go files derived from .proto sources. Listed explicitly so
# proto-clean can remove them without touching anything else.
PROTO_GO_OUTS := $(shell find x -type f \( -name '*.pb.go' -o -name '*.pb.gw.go' \) 2>/dev/null)

.PHONY: proto-all proto-gen proto-clean proto-format proto-lint proto-tools

proto-all: proto-format proto-lint proto-gen ## Format, lint, and regenerate Protobuf bindings

proto-tools: ## Install Go-based protoc plugins under $(GOBIN)
	@echo "--- proto-tools"
	@command -v buf >/dev/null 2>&1 || { \
	  echo "buf not found. Install: https://buf.build/docs/installation"; exit 1; }
	@test -x "$(GOBIN)/protoc-gen-gocosmos"      || go install github.com/cosmos/gogoproto/protoc-gen-gocosmos@latest
	@test -x "$(GOBIN)/protoc-gen-grpc-gateway"  || go install github.com/grpc-ecosystem/grpc-gateway/protoc-gen-grpc-gateway@latest

proto-clean: ## Remove all generated *.pb.go and *.pb.gw.go files
	@echo "--- proto-clean"
	@rm -f $(PROTO_GO_OUTS)

# Run on host: regenerates *.pb.go from scratch.
# Depends on proto-clean so stale generated files can't survive a regen.
proto-gen: proto-tools proto-clean ## Regenerate *.pb.go from .proto files (host)
	@echo "--- proto-gen"
	@sh ./scripts/protocgen.sh

proto-format: ## Format .proto files in place (requires clang-format)
	@echo "--- proto-format"
	@command -v clang-format >/dev/null 2>&1 || { \
	  echo "clang-format not found. Install via your package manager (e.g. brew install clang-format)."; exit 1; }
	@find ./proto -name "*.proto" -exec clang-format -i {} \;

proto-lint: ## Lint .proto files (host)
	@echo "--- proto-lint"
	@cd proto && buf lint --error-format=json

## Docker-based proto pipeline (no host tooling required).
##
## Use these on a fresh machine, or in CI containers without Go plugins
## installed. They mirror the host targets one-for-one.
DOCKER          ?= docker
PROTO_VER       := 0.17.1
PROTO_IMG       := ghcr.io/cosmos/proto-builder:$(PROTO_VER)
PROTO_RUN       := $(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace $(PROTO_IMG)

.PHONY: proto-gen-docker proto-format-docker proto-lint-docker

proto-gen-docker: proto-clean ## Regenerate *.pb.go via the cosmos/proto-builder image
	@echo "--- proto-gen-docker"
	@$(PROTO_RUN) sh ./scripts/protocgen.sh

proto-format-docker: ## Format .proto files via the cosmos/proto-builder image
	@echo "--- proto-format-docker"
	@$(PROTO_RUN) find ./proto -name "*.proto" -exec clang-format -i {} \;

proto-lint-docker: ## Lint .proto files via the cosmos/proto-builder image
	@echo "--- proto-lint-docker"
	@$(PROTO_RUN) sh -c "cd proto && buf lint --error-format=json"

## Local network targets
.PHONY: localnet-init localnet-start localnet-stop localnet

localnet-init: build ## Initialize a local single-node chain (config only, does not start)
	CONFIG_ONLY=true ./scripts/local-node.sh

localnet-start: build ## Start a local single-node chain in the foreground
	RUN_MODE=foreground ./scripts/local-node.sh

localnet: build ## Start a local single-node chain in the background
	RUN_MODE=background ./scripts/local-node.sh

localnet-stop: ## Stop the running local node
	./scripts/kill-local-node.sh

## Contract deployment targets

.PHONY: contracts-setup contracts-build deploy-zeto contracts-clean

contracts-setup: ## Install Forge dependencies for Zeto contracts
	cd contracts && forge install

contracts-build: ## Compile all Zeto contracts
	cd contracts && forge build

deploy-zeto: build ## Deploy Zeto privacy contracts to the local chain
	cd contracts && bash deploy-zeto.sh

contracts-clean: ## Remove contract build artifacts
	cd contracts && forge clean
	rm -rf contracts/out contracts/cache contracts/broadcast
