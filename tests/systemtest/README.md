# systemtest

End-to-end tests against a running `sandboxd` chain. No `sandbox-backend`,
no frontend — just the ledger speaking JSON-RPC + the EVM module.

## Run

One-shot, with chain bring-up + teardown handled for you:

```sh
make test-system     # from sandbox-ledger root
```

Against an already-running chain (faster iteration):

```sh
SKIP_ZETO_BOOTSTRAP=1 RUN_MODE=background make localnet
go test -tags systemtest -v ./tests/systemtest/...
```

The `systemtest` build tag keeps these out of the default `go test ./...`
so contributors without a chain locally don't see them fail.

## What's covered

| Test | What it asserts |
|------|------------------|
| `TestEVMChainID` | The configured EVM chain id (`19460`) is reachable over JSON-RPC. |
| `TestChainProducesBlocks` | The chain advances ≥3 blocks within 30s — basic liveness. |
| `TestValidatorHasGenesisBalance` | The POA validator's EVM-derived address was funded in genesis. |
| `TestNativeEVMTransfer` | Sign + submit a real EIP-1559 native transfer; assert recipient balance increases by exactly the sent amount. |

The validator and user mnemonics here mirror `scripts/local-node.sh`. If
either side drifts, signing keys won't match genesis allocations and
tests will start failing on `TestValidatorHasGenesisBalance`.

## Adding a test

`basic_test.go` is the template. Dial via `dial(t)`, derive keys via
`mustKey(t, hex)`, await receipts via `waitForReceipt(...)`. Read-only
assertions need no signing; mutating ones need a genesis-funded key for
gas. The `Validator*` constants in `main_test.go` are the canonical
funded account.

Heavier targets (full Zeto clone deploy, on-chain SMT membership) need
either Forge in the orchestration step or a backend `sandbox-bootstrap`
run — both currently out of scope for this minimal harness.
