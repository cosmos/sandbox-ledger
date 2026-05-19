# sandbox-ledger

A Cosmos SDK chain with Proof-of-Authority consensus, full EVM compatibility,
and IBC v2 transfers. Includes a token-factory module and an IFT (Interchain
Fungible Token) bridge built on top of ICS-27 GMP for cross-chain mint/burn.

## What's in the box

| Module | Purpose |
|---|---|
| **auth / bank** | Account management and bank transfers |
| **POA** | Validator set + fee distribution (replaces staking / distribution / slashing / mint) |
| **gov** | On-chain governance, voting power weighted by POA |
| **upgrade** | Coordinated chain upgrades |
| **EVM** (vm + feemarket + erc20) | Ethereum execution, ETH JSON-RPC, ERC-20 ↔ Cosmos coin conversion |
| **IBC core + transfer (v2)** | IBC v2 packet path for transfer and GMP routing |
| **IBC callbacks (v2)** | Lets contracts/modules receive ack & timeout callbacks on transfer / GMP packets |
| **27-gmp** | ICS-27 General Message Passing — IBC v2 cross-chain `MsgSendCall` |
| **attestations** light client | Sole IBC light-client type — counterparties verify packets via signed attestations from a configured EOA quorum (no 07-tendermint) |
| **tokenfactory** | Permissionless `factory/<creator>/<sub>` token creation; admin-gated mint/burn |
| **ift** | Interchain Fungible Token bridge: pairs a tokenfactory denom with a counterparty contract over GMP, with EVM, Cosmos-tx, and Solana mint constructors |

## Architecture

- **No staking, distribution, slashing, or mint modules.** POA manages
  validators directly via an admin authority and distributes collected fees
  to validators proportionally.
- **Fees** route to the POA module account, not the standard fee collector.
- **EVM precompiles** active on this chain: Prague, P256, Bech32, Bank, Gov,
  ICS-02. Disabled: staking / distribution / slashing / ICS-20 / vesting
  (their backing modules aren't included).
- **IBC v2 routing**:
  - `transfer` port → transfer-v2 → erc20-v2 middleware
  - `gmpport` (ICS-27) → gmp module → callbacks-v2 middleware → IFT keeper
- **IBC light client**: only the `attestations` light client is registered
  on the 02-client router — `07-tendermint` is **not** included. Every
  counterparty connection terminates in an attestations client whose state
  declares a set of EOA attestor addresses and a `min_required_sigs`
  quorum. Packet proofs are EIP-191-style signatures over an ABI-encoded
  attestation, verified at receive/timeout time. This is what lets
  non-Cosmos chains (EVM, Solana) participate without running a Tendermint
  light client.
- **IFT bridge model**: a registered bridge associates a tokenfactory denom
  with `(client_id, counterparty_contract, constructor_type)`. Outgoing
  transfers burn locally and emit a GMP `MsgSendCall` carrying a constructor-
  serialized mint payload; incoming `MsgIFTMint` from the counterparty mints
  via the tokenfactory keeper.

## Build

Requires Go 1.25 and `buf` on your `PATH`.

```bash
brew install bufbuild/buf/buf            # one-time
make build                                # regenerates *.pb.go, then compiles
```

`make build` runs the full proto pipeline (clean → buf generate → go build) so
the binary is always in sync with the `.proto` sources. Output: `build/sandboxd`.

### Other targets

```bash
make test                # go test ./...
make lint                # golangci-lint
make proto-all           # proto-format + proto-lint + proto-gen
make proto-tools         # install protoc-gen-gocosmos + grpc-gateway
make proto-gen-docker    # Docker fallback (no host tooling required)
make clean               # rm -rf build/
```

See the `proto-*` and `proto-*-docker` blocks in the [Makefile](Makefile) for
the full set.

## Run a local node

```bash
make localnet-start    # foreground, fresh chain
make localnet          # background
make localnet-stop     # kill
make localnet-init     # generate config only, don't start
```

The script ([scripts/local-node.sh](scripts/local-node.sh)) initializes a
single-validator POA chain with deterministic mnemonics, patches genesis with
EVM/POA/gov defaults, enables the API and JSON-RPC servers, and starts on:

| Port | Service |
|---|---|
| 26656 | CometBFT P2P |
| 26657 | CometBFT RPC |
| 9090  | gRPC |
| 1317  | REST API (LCD) |
| 8545 / 8546 | EVM JSON-RPC (HTTP / WS) |

Default chain ID: `sandbox-dev-1`, EVM chain ID `19460`, denom `astake`.

## Manual init (without the script)

```bash
sandboxd init <moniker> --chain-id <chain-id>          # writes ~/.sandboxd
sandboxd genesis add-genesis-account <addr> 1000000000stake
# … patch POA validator into genesis (see scripts/local-node.sh) …
sandboxd start
```

`sandboxd init` produces a self-consistent genesis: bank denom metadata for
the EVM denom is injected automatically, so the chain boots without external
patching. POA still requires you to inject at least one validator before
`start` — that step depends on the node's consensus key and has to happen
after `init` (the sample script handles this).

## Container

```bash
docker build -t sandbox-ledger .
docker run --rm -v sandbox-data:/data \
  -p 26657:26657 -p 9090:9090 -p 1317:1317 -p 8545:8545 \
  sandbox-ledger
```

Image notes:
- Runs as non-root (`sandbox`, UID 1000). The binary at `/bin/sandboxd` is
  root-owned `0555`, so the runtime user can execute but not modify it.
- Chain state lives at `/data` (declared `VOLUME`). Use a named volume or pre-
  chown a bind mount to UID 1000.
- The default `CMD` is `start --home=/data`. Override it to run any other
  subcommand: `docker run … sandbox-ledger init my-node --chain-id sandbox-1`.
- Kubernetes: set `securityContext.fsGroup: 1000` so the mounted volume is
  writable by the runtime user.

## EVM contracts (Zeto)

The `contracts/` tree contains the Zeto privacy contracts and a Forge
deployment script:

```bash
make submodules          # git submodule update --init --recursive (idempotent)
make contracts-build     # forge build
make deploy-zeto         # deploys to the local chain at $RPC_URL
```

`make contracts-setup` is an alias for `make submodules`. Fresh clones
need it once; subsequent pulls only when submodule pins move.

Note: `contracts/lib/iden3-contracts/` is the `kaleido-io/contracts`
fork on the `keccak256` branch — Zeto's own upstream dependency. It
ships the `IHasher` / `PoseidonHasher` interfaces and a `setHasher`
extension on `SmtLib` that canonical `iden3/contracts` doesn't have.

The script ([contracts/deploy-zeto.sh](contracts/deploy-zeto.sh)) deploys the
Poseidon hash libraries first (raw bytecode via `cast`), then verifiers,
tokens, and the factory (Forge script). Deployer key defaults to the
local-node `user-1` mnemonic; override via `DEPLOYER_MNEMONIC` /
`PRIVATE_KEY` env vars.

### Contracts

| Contract | Source | Purpose |
|---|---|---|
| `Zeto_AnonNullifierBurnable` (impl) | `lib/zeto/...` (submodule) | UUPS-cloneable Zeto fungible token: anonymous transfers via nullifiers, with a `burn(...)` entry point gated by a Groth16 burn verifier. Registered with `ZetoTokenFactory` so per-tenant instances can be spawned. |
| `ZetoTokenFactory` | `lib/zeto/...` (submodule) | Registers Zeto implementations and clones them behind ERC1967 proxies via `deployZetoFungibleToken(name, symbol, implName, initialOwner)`. |
| [`WrappedZeto`](contracts/src/WrappedZeto.sol) | local (STACK-2757) | Self-minting ERC20 paired one-to-one with a `Zeto_AnonNullifierBurnable` instance. Bridges public ERC20 ↔ private Zeto notes so the wrapped supply can ride IBC v2 transfers while value is preserved on the private side. The wrapper holds Zeto ownership and is the sole minter/burner of its own ERC20 supply. |

`WrappedZeto` surface:

- `shield(uint256[] commitments, uint256[] amounts, bytes data)` — burns
  `sum(amounts)` of the caller's wrapped ERC20 and calls
  `Zeto.mint(commitments, data)`. Conservation: ERC20 supply ↓ by
  `sum(amounts)`, private commitment value ↑ by the same amount
  (commitments must encode `amounts` off-chain; the wrapper enforces
  structural parity but not the cryptographic equality, which is the
  caller's responsibility).
- `unshield(uint256[] inputs, uint256 output, uint256 root, Commonlib.Proof proof, address evm_recipient, uint256 amount, bytes data)`
  — calls `Zeto.burn(inputs, output, root, proof, data)` (the
  burnable-variant burn entry point: consumes input nullifiers,
  produces one remainder UTXO, gated by the burn Groth16 verifier),
  then mints `amount` wrapped ERC20 to `evm_recipient`.
- `acceptZetoOwnership()` — one-shot bootstrap that wraps the Zeto's
  `Ownable2Step.acceptOwnership` so the wrapper can be promoted to
  Zeto owner after `transferOwnership(address(wrapper))` is staged.

[`contracts/script/DeployWrappedZeto.s.sol`](contracts/script/DeployWrappedZeto.s.sol)
spawns a fresh `Zeto_AnonNullifier_Burnable` instance via the factory,
deploys the wrapper, performs the 2-step ownership handoff, and appends a
`wrapped_zeto` block to `contracts/deployments/sandbox-dev-1.json`. The
`deploy-zeto.sh` orchestrator invokes it as Stage 4 after the factory and
implementation registration are complete.

## Layout

```
app/                  application wiring (modules, ante handler, mempool, root cmd)
cmd/sandboxd/         binary entrypoint
proto/sandbox/{ift,tokenfactory}/
                      .proto sources
scripts/              local-node bring-up + proto codegen helper
testutil/             address-prefix init for tests
x/ift/                Interchain Fungible Token module
x/tokenfactory/       Token Factory module
contracts/            Foundry / Forge tree for Zeto privacy contracts
.github/workflows/    CI (build + lint + Docker publish)
```

## CI

Three workflows under [.github/workflows/](.github/workflows/):
- **build.yml** — `make build && make test` on amd64 and arm64.
- **lint.yml** — golangci-lint on PRs.
- **docker-publish.yml** — multi-arch image publish to `ghcr.io/<org>/sandbox-ledger`:
  - PR commits → `pr-<short-sha>` (same-repo only; fork PRs build but don't push)
  - `main` push → `latest`
  - manual dispatch → user-supplied tag

## Status

Pre-release. Wire-format identifiers (proto package names, module store keys)
are stable for development but should be reviewed before any external
deployment.

### Counterparty compatibility note

Because this chain registers only the `attestations` light client, IBC
counterparties must support it too — a stock Tendermint chain cannot open
an IBC connection to this chain via `07-tendermint`. The expected
counterparties are EVM and Solana chains that operate as attestors over a
shared `MsgSendCall` payload. To peer with another Cosmos chain, that
chain would need to wire in `attestations` from the same ibc-go release.
