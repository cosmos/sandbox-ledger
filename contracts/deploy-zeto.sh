#!/usr/bin/env bash
set -Eeuo pipefail

# ===========================================================================
# deploy-zeto.sh -- PoC Zeto deployment
#
# Registers Zeto_Anon + Zeto_AnonNullifier with the factory. The Anon variant
# needs no on-chain libraries; the AnonNullifier variant pulls in iden3
# SmtLib + PoseidonUnit2L/3L, so we deploy those first and link the rest of
# the contracts against the resulting addresses via `forge script --libraries`.
#
# Library deploy order:
#   1. PoseidonUnit2L  (raw bytecode in poseidon/PoseidonUnit2L.hex)
#   2. PoseidonUnit3L  (raw bytecode in poseidon/PoseidonUnit3L.hex)
#   3. SmtLib          (forge create — needs PoseidonUnit2L/3L linked)
# Then DeployZetoAnon.s.sol runs with all three library addresses in --libraries.
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
CHAIN_ID="${CHAIN_ID:-19460}"
DEPLOYER_MNEMONIC="${DEPLOYER_MNEMONIC:-surge sing leave bone title meadow horror green gas pipe law primary}"

DEPLOY_OUT="deployments/sandbox-dev-1.json"
mkdir -p deployments

PRIVATE_KEY=$(cast wallet derive-private-key "$DEPLOYER_MNEMONIC" 2>/dev/null)
DEPLOYER_ADDR=$(cast wallet address "$PRIVATE_KEY" 2>/dev/null)
echo "--- Deployer: $DEPLOYER_ADDR"

# ---------------------------------------------------------------------------
# Stage 1: deploy Poseidon libraries from pre-built bytecode
# ---------------------------------------------------------------------------
deploy_raw_bytecode() {
    local hex_file="$1"
    local code
    code=$(<"$hex_file")
    # poseidon/*.hex starts with 0x already; cast send --create handles either.
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
        --create "$code" \
        --json 2>/dev/null \
        | jq -r '.contractAddress'
}

echo ""
echo "=== Stage 1: deploying Poseidon libraries ==="
POSEIDON2_ADDR=$(deploy_raw_bytecode poseidon/PoseidonUnit2L.hex)
echo "  PoseidonUnit2L: $POSEIDON2_ADDR"
POSEIDON3_ADDR=$(deploy_raw_bytecode poseidon/PoseidonUnit3L.hex)
echo "  PoseidonUnit3L: $POSEIDON3_ADDR"

# ---------------------------------------------------------------------------
# Stage 2: deploy SmtLib (which links to PoseidonUnit2L/3L)
# ---------------------------------------------------------------------------
echo ""
echo "=== Stage 2: deploying SmtLib (linked to Poseidon) ==="
SMTLIB_PATH="lib/iden3-contracts/contracts/lib/SmtLib.sol:SmtLib"
POSEIDON_PATH="lib/iden3-contracts/contracts/lib/Poseidon.sol"

# forge create's --libraries flag links the dependency at deploy time.
SMTLIB_ADDR=$(forge create "$SMTLIB_PATH" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --libraries "${POSEIDON_PATH}:PoseidonUnit2L:${POSEIDON2_ADDR}" \
    --libraries "${POSEIDON_PATH}:PoseidonUnit3L:${POSEIDON3_ADDR}" \
    2>&1 | awk '/Deployed to:/ { print $3 }')
echo "  SmtLib: $SMTLIB_ADDR"

if [ -z "$SMTLIB_ADDR" ]; then
    echo "ERROR: SmtLib deploy failed" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Stage 3: deploy verifiers + impls + factory
# ---------------------------------------------------------------------------
echo ""
echo "=== Stage 3: deploying verifiers + impls + factory ==="

LIBS_FLAG=(
    --libraries "${POSEIDON_PATH}:PoseidonUnit2L:${POSEIDON2_ADDR}"
    --libraries "${POSEIDON_PATH}:PoseidonUnit3L:${POSEIDON3_ADDR}"
    --libraries "${SMTLIB_PATH}:${SMTLIB_ADDR}"
)

forge script script/DeployZetoAnon.s.sol:DeployZetoAnon \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --slow \
    --code-size-limit 65535 \
    "${LIBS_FLAG[@]}" \
    -vvv

# ---------------------------------------------------------------------------
# Collect deployment addresses
# ---------------------------------------------------------------------------
echo ""
echo "=== Collecting deployment addresses ==="

BROADCAST_FILE="broadcast/DeployZetoAnon.s.sol/${CHAIN_ID}/run-latest.json"

if [ -f "$BROADCAST_FILE" ]; then
    jq --arg p2 "$POSEIDON2_ADDR" --arg p3 "$POSEIDON3_ADDR" --arg smt "$SMTLIB_ADDR" '{
        contracts: ([
            {name: "PoseidonUnit2L", address: $p2},
            {name: "PoseidonUnit3L", address: $p3},
            {name: "SmtLib",          address: $smt}
        ] + [.transactions[] | select(.transactionType == "CREATE") | {
            name: .contractName,
            address: .contractAddress
        }]),
        bootstrapped_tokens: []
    }' "$BROADCAST_FILE" > "$DEPLOY_OUT"

    echo "  Addresses written to: $DEPLOY_OUT"

    FACTORY=$(jq -r '.contracts[] | select(.name == "ZetoTokenFactory") | .address' "$DEPLOY_OUT")
    echo ""
    echo "=== Deployment complete ==="
    echo "  Factory: $FACTORY"
else
    echo "  WARNING: Broadcast log not found at $BROADCAST_FILE"
    echo "  Check forge script output above for errors."
    exit 1
fi
