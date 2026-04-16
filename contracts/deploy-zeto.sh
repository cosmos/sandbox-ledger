#!/usr/bin/env bash
set -Eeuo pipefail

# ===========================================================================
# deploy-zeto.sh -- Two-phase Zeto deployment to sandbox-ledger
#
# Phase 1: Deploy Poseidon hash libraries via cast (raw bytecode)
# Phase 2: Deploy verifiers, tokens, and factory via Forge script
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
CHAIN_ID="${CHAIN_ID:-19460}"
# Default: sandbox-ledger user-1 test wallet
DEPLOYER_MNEMONIC="${DEPLOYER_MNEMONIC:-surge sing leave bone title meadow horror green gas pipe law primary}"

DEPLOY_OUT="deployments/sandbox-dev-1.json"
mkdir -p deployments

# ---------------------------------------------------------------------------
# Derive deployer private key
# ---------------------------------------------------------------------------
PRIVATE_KEY=$(cast wallet derive-private-key "$DEPLOYER_MNEMONIC" 2>/dev/null)
DEPLOYER_ADDR=$(cast wallet address "$PRIVATE_KEY" 2>/dev/null)
echo "--- Deployer: $DEPLOYER_ADDR"

# ---------------------------------------------------------------------------
# PHASE 1: Deploy Poseidon libraries (raw bytecodes from circomlibjs)
# ---------------------------------------------------------------------------
echo ""
echo "=== PHASE 1: Deploying Poseidon libraries ==="

deploy_raw() {
    local name="$1"
    local hex_file="$2"
    local bytecode
    bytecode=$(cat "$hex_file")

    echo -n "  Deploying $name... " >&2
    local result
    result=$(cast send \
        --confirmations 1 \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$RPC_URL" \
        --json \
        --create "$bytecode")

    local addr
    addr=$(echo "$result" | jq -r '.contractAddress')
    if [ -z "$addr" ] || [ "$addr" = "null" ]; then
        echo "FAILED" >&2
        echo "  cast output: $result" >&2
        exit 1
    fi
    echo "$addr" >&2
    echo "$addr"
}

P2=$(deploy_raw "PoseidonUnit2L" "poseidon/PoseidonUnit2L.hex")
P3=$(deploy_raw "PoseidonUnit3L" "poseidon/PoseidonUnit3L.hex")
P5=$(deploy_raw "PoseidonUnit5L" "poseidon/PoseidonUnit5L.hex")
P6=$(deploy_raw "PoseidonUnit6L" "poseidon/PoseidonUnit6L.hex")

echo ""
echo "--- Poseidon addresses:"
echo "  PoseidonUnit2L: $P2"
echo "  PoseidonUnit3L: $P3"
echo "  PoseidonUnit5L: $P5"
echo "  PoseidonUnit6L: $P6"

# ---------------------------------------------------------------------------
# PHASE 2: Deploy everything else via Forge
# ---------------------------------------------------------------------------
echo ""
echo "=== PHASE 2: Deploying verifiers, tokens, and factory via Forge ==="

POSEIDON_SOL="lib/iden3-contracts/contracts/lib/Poseidon.sol"

forge script script/DeployZeto.s.sol:DeployZeto \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    --code-size-limit 65535 \
    --libraries "${POSEIDON_SOL}:PoseidonUnit2L:${P2}" \
    --libraries "${POSEIDON_SOL}:PoseidonUnit3L:${P3}" \
    --libraries "${POSEIDON_SOL}:PoseidonUnit5L:${P5}" \
    --libraries "${POSEIDON_SOL}:PoseidonUnit6L:${P6}" \
    -vvv

# ---------------------------------------------------------------------------
# Collect deployment addresses
# ---------------------------------------------------------------------------
echo ""
echo "=== Collecting deployment addresses ==="

BROADCAST_FILE="broadcast/DeployZeto.s.sol/${CHAIN_ID}/run-latest.json"

if [ -f "$BROADCAST_FILE" ]; then
    jq '{
        poseidon: {
            PoseidonUnit2L: $p2,
            PoseidonUnit3L: $p3,
            PoseidonUnit5L: $p5,
            PoseidonUnit6L: $p6
        },
        contracts: [.transactions[] | select(.transactionType == "CREATE") | {
            name: .contractName,
            address: .contractAddress
        }]
    }' --arg p2 "$P2" --arg p3 "$P3" --arg p5 "$P5" --arg p6 "$P6" \
        "$BROADCAST_FILE" > "$DEPLOY_OUT"

    echo "  Addresses written to: $DEPLOY_OUT"

    # Print factory address
    FACTORY=$(jq -r '.contracts[] | select(.name == "ZetoTokenFactory") | .address' "$DEPLOY_OUT")
    echo ""
    echo "=== Deployment complete ==="
    echo "  Factory: $FACTORY"
else
    echo "  WARNING: Broadcast log not found at $BROADCAST_FILE"
    echo "  Check forge script output above for errors."
    exit 1
fi
