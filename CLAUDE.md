# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
make build                  # Regenerate *.pb.go, compile binary to build/sandboxd
make clean                  # Remove build/

# Test & Lint
make test                   # go test ./...
make lint                   # golangci-lint run ./...
make lint-fix               # golangci-lint run --fix ./...
make tidy                   # go mod tidy

# Protobuf
make proto-all              # Format + lint + regenerate .pb.go files
make proto-gen              # Regenerate only (requires buf on PATH)
make proto-tools            # Install protoc-gen-gocosmos + protoc-gen-grpc-gateway
make proto-gen-docker       # Docker fallback if host tools are unavailable

# Local node
make localnet-start         # Start single-validator chain in foreground
make localnet               # Start in background
make localnet-stop          # Kill running node

# Solidity contracts (Zeto)
make contracts-build        # forge build
make deploy-zeto            # Two-phase deploy: Poseidon libraries + Zeto suite (requires running node)
```

**Run a single Go test:**
```bash
go test ./x/ift/keeper/... -run TestFoo -v
```

**Required tools:** Go 1.25, `buf` (proto), `golangci-lint` v2.4.0, `forge`/`cast` (Foundry).

## Architecture

**sandbox-ledger** is a Cosmos SDK chain with Proof-of-Authority consensus, full EVM compatibility, IBC v2 transfers, and an Interchain Fungible Token (IFT) bridge. The binary is `sandboxd`.

### Consensus: POA replaces staking

The `poa` module (from `cosmos/cosmos-sdk/enterprise/poa`) fully replaces the standard staking, distribution, slashing, and mint modules. The POA admin manages the validator set directly. All transaction fees are routed to the POA module account and distributed proportionally to validators — there is no fee collector, no staking rewards, and no inflation.

Because there is no staking keeper, several EVM precompiles that depend on it are explicitly disabled in `app/app.go`: staking, distribution, slashing, ICS-20, and vesting precompiles. The `POAKeeper` is passed as the `StakingKeeper` interface to the EVM and ERC-20 modules.

### EVM: cosmos/evm

Full Ethereum execution via the `evmd` module (`cosmos/evm`). Enabled precompiles: Prague set, P256, Bech32, Bank, Gov, ICS-02. The EVM chain ID for local dev is `19460`.

The ERC-20 module provides bidirectional conversion between native Cosmos bank denoms and ERC-20 tokens.

### IBC cross-chain architecture

IBC v1 and v2 are both active. The packet routing for v2 is:

```
transfer port  →  transfer-v2  →  erc20-v2 middleware
gmpport (ICS-27)  →  gmp module  →  callbacks-v2 middleware  →  IFT keeper
```

**Attestations light client** (registered as the only client type; 07-tendermint is excluded): enables non-Cosmos chains (EVM, Solana) to act as IBC counterparties without Tendermint light clients. Verification uses EIP-191 signatures over ABI-encoded attestations checked at packet receive and timeout.

### IFT bridge (`x/ift`)

The IFT module bridges token supply across chains via ICS-27 GMP (`MsgSendCall`). A bridge pair links a local TokenFactory denom to a counterparty contract. Inbound mints are triggered by GMP callbacks; outbound burns happen on the source chain. Three constructor types are supported for counterparty chain addressing: EVM, Cosmos-tx, and Solana.

The IFT keeper consumes mint/burn capabilities from the TokenFactory keeper.

### TokenFactory (`x/tokenfactory`)

Permissionless denom creation in the `factory/<creator>/<subdenom>` namespace. The creator becomes the denom admin and can mint/burn. Used by IFT for bridge-managed supply.

### Module interdependency summary

| Consumer | Dependency |
|---|---|
| EVM + ERC-20 modules | `POAKeeper` as `StakingKeeper` |
| IFT keeper | TokenFactory mint/burn capabilities |
| All fee collection | POA module account (not `x/auth` fee collector) |

### Local dev chain parameters

- Chain ID: `sandbox-dev-1`, EVM chain ID: `19460`
- Native denom: `astake` (display: `stake`)
- 10 pre-funded test wallets (`user-1` through `user-10`) with deterministic mnemonics
- Ports: 26656 (P2P), 26657 (RPC), 9090 (gRPC), 1317 (REST), 8545/8546 (EVM JSON-RPC)

### Protobuf

Proto sources live in `proto/sandbox/` (modules `ift` and `tokenfactory`). Generated files (`*.pb.go`, `*.pb.gw.go`) live in `x/ift/types/` and `x/tokenfactory/types/`. Run `make proto-gen` after editing `.proto` files; never edit generated files directly.

### Solidity contracts

The `contracts/` directory is a Foundry project for Zeto privacy contracts. Config: Solc 0.8.27, optimizer 25 runs, `via_ir=true`, EVM version `osaka`, max code size 65535 (to support large Groth16 verifiers). Deployment is two-phase: Poseidon library bytecodes first (`cast`), then the Zeto contract suite (`forge script DeployZeto`).
