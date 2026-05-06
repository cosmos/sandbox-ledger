//go:build systemtest

// Package systemtest exercises the running sandboxd chain over JSON-RPC.
//
// These are E2E tests that demonstrate the ledger works in isolation —
// no sandbox-backend, no frontend, no Zeto bootstrap (run local-node.sh
// with SKIP_ZETO_BOOTSTRAP=1). Use the `make test-system` target to
// orchestrate chain bring-up + tests + teardown, or bring up the chain
// yourself with `SKIP_ZETO_BOOTSTRAP=1 RUN_MODE=background make localnet`
// and run `go test -tags systemtest ./tests/systemtest/...`.
//
// The chain config (chain id, ports, denom, validator key) mirrors
// scripts/local-node.sh — keep them in sync if either side changes.

package systemtest

import (
	"context"
	"fmt"
	"log"
	"os"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/ethclient"
)

const (
	JSONRPCURL = "http://127.0.0.1:8545"

	// EVM chain id from local-node.sh:14.
	EVMChainID int64 = 19460

	// Cosmos chain id from local-node.sh:13.
	CosmosChainID = "sandbox-dev-1"

	// Native denom from local-node.sh:21 (`astake` = atto-stake).
	NativeDenom = "astake"

	// Genesis-funded validator key. Derived from the canonical mnemonic in
	// local-node.sh: "copper push brief egg ...". Same key signs blocks on
	// the POA chain and pays gas in tests.
	ValidatorPrivHex = "88cbead91aee890d27bf06e003ade3d4e952427e88f88d31d61d3ef5e5d54305"

	// Genesis-funded user keys. Derived from the same canonical mnemonics
	// the demo.sh script uses for backend keystore aliases.
	User1PrivHex = "da5b715dc62cd03c028946c9808c12d6ad62f0b46a0d0481bea48845c3c332f5"
	User2PrivHex = "8d295a867ec35c4617787fe45d038f087c9f0098196dfcd778dd245f0e66716e"
)

// TestMain waits for the chain's JSON-RPC to come up before running the
// suite. The Makefile's `test-system` target brings the chain up first;
// running these tests directly against an already-up chain works too.
func TestMain(m *testing.M) {
	if err := waitForJSONRPC(60 * time.Second); err != nil {
		log.Fatalf("chain not reachable on %s: %v\n"+
			"Bring the chain up first:\n"+
			"  SKIP_ZETO_BOOTSTRAP=1 RUN_MODE=background make localnet\n"+
			"or run via:\n"+
			"  make test-system", JSONRPCURL, err)
	}
	os.Exit(m.Run())
}

func waitForJSONRPC(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		c, err := ethclient.Dial(JSONRPCURL)
		if err != nil {
			lastErr = err
			time.Sleep(time.Second)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_, err = c.BlockNumber(ctx)
		cancel()
		c.Close()
		if err == nil {
			return nil
		}
		lastErr = err
		time.Sleep(time.Second)
	}
	return fmt.Errorf("timed out: %w", lastErr)
}
