# sandbox-ledger

A Cosmos SDK blockchain combining Proof-of-Authority validator management with full EVM compatibility and IBC interoperability.

## Modules

| Module | Purpose |
|--------|---------|
| **auth / bank** | Account management and token transfers |
| **POA** | Proof-of-Authority validator set management and fee distribution (replaces staking) |
| **EVM** | Ethereum Virtual Machine execution (vm + feemarket + erc20) |
| **IBC** | Inter-Blockchain Communication with transfer, ERC-20 middleware, and callbacks |
| **gov** | On-chain governance with POA-weighted voting power |
| **upgrade** | Coordinated chain upgrades |

## Architecture

- **No staking, distribution, slashing, or mint modules.** The POA module manages the validator set directly via an admin authority, and distributes fees to validators proportionally.
- **EVM precompiles** include Prague, P256, Bech32, Bank, Gov, and ICS02. Precompiles that depend on staking/distribution/slashing (staking, distribution, slashing, ICS20, vesting) are disabled.
- **Fees are routed to the POA module account**, not the standard fee collector, enabling POA-controlled fee distribution.
- **EVM transactions** are handled by the Cosmos EVM ante handler, which supports both Ethereum and Cosmos SDK transaction types.

## Build

```bash
make build    # outputs build/sandboxd
make install  # installs to $GOPATH/bin
```

## Usage

```bash
# Initialize the node
sandboxd init <moniker> --chain-id <chain-id>

# Start the node
sandboxd start

# EVM JSON-RPC is available when configured
```
