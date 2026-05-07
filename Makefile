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
