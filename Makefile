APP_NAME := sandboxd
BUILD_DIR := build

.PHONY: build install lint lint-fix test clean tidy

build:
	go build -o $(BUILD_DIR)/$(APP_NAME) ./cmd/sandboxd

install:
	go install ./cmd/sandboxd

tidy:
	go mod tidy

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
