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
