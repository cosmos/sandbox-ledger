APP_NAME := sandboxd
BUILD_DIR := build

.PHONY: build install lint lint-fix test test-system clean tidy

build:
	go build -o $(BUILD_DIR)/$(APP_NAME) ./cmd/sandboxd

install:
	go install ./cmd/sandboxd

tidy: ## Tidy every Go module in the repo
	./scripts/go-mod-tidy-all.sh

test:
	go test ./...

lint:
	golangci-lint run ./...

lint-fix:
	golangci-lint run --fix ./...

clean:
	rm -rf $(BUILD_DIR)

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

test-system: build ## Boot a chain (no Zeto bootstrap), run system tests, tear down
	@bash -c 'set -e; \
		trap "./scripts/kill-local-node.sh >/dev/null 2>&1 || true" EXIT; \
		./scripts/kill-local-node.sh >/dev/null 2>&1 || true; \
		echo "--- Bringing up chain (SKIP_ZETO_BOOTSTRAP=1)"; \
		SKIP_ZETO_BOOTSTRAP=1 RUN_MODE=background ./scripts/local-node.sh > /tmp/sandboxd-systemtest.log 2>&1; \
		echo "--- Running system tests"; \
		go test -tags systemtest -timeout 5m -v ./tests/systemtest/...'

## Contract deployment targets

.PHONY: submodules contracts-setup contracts-build deploy-zeto contracts-clean

# Initialize git submodules + drop the iden3 shims into place. The shims
# under `contracts/iden3-shims/` patch the pinned upstream
# iden3-contracts revision for compatibility with newer Zeto: it imports
# `IHasher` + `PoseidonHasher` (don't exist upstream at our pin) and
# calls `SmtLib.setHasher` (which the upstream `SmtLib.sol` doesn't
# expose). The shims are minimal additions / a no-op override; the real
# hashing path still goes through `PoseidonUnit{2,3}L`. Safe to re-run.
submodules:
	git submodule update --init --recursive
	@mkdir -p contracts/lib/iden3-contracts/contracts/interfaces
	@mkdir -p contracts/lib/iden3-contracts/contracts/lib/hash
	@cp contracts/iden3-shims/IHasher.sol \
		contracts/lib/iden3-contracts/contracts/interfaces/IHasher.sol
	@cp contracts/iden3-shims/PoseidonHasher.sol \
		contracts/lib/iden3-contracts/contracts/lib/hash/PoseidonHasher.sol
	@cp contracts/iden3-shims/SmtLib.sol \
		contracts/lib/iden3-contracts/contracts/lib/SmtLib.sol
	@echo "Submodules initialised; iden3 shims populated."

contracts-setup: submodules ## Initialize submodules + iden3 shims (replaces `forge install`)

contracts-build: ## Compile all Zeto contracts
	cd contracts && forge build

deploy-zeto: build ## Deploy Zeto privacy contracts to the local chain
	cd contracts && bash deploy-zeto.sh

contracts-clean: ## Remove contract build artifacts
	cd contracts && forge clean
	rm -rf contracts/out contracts/cache contracts/broadcast
