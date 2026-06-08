#!/bin/bash -eu

set -Eeuo pipefail

trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

CWD="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

NEWLINE=$'\n'
NODE_BIN="${1:-$CWD/../build/sandboxd}"

# These options can be overridden by env
CHAIN_ID="${CHAIN_ID:-sandbox-dev-1}"
EVM_CHAIN_ID="${EVM_CHAIN_ID:-19460}"
CHAIN_DIR="${CHAIN_DIR:-$CWD/node-data}"
CONFIG_TOML="$CHAIN_DIR/config/config.toml"
APP_TOML="$CHAIN_DIR/config/app.toml"
GENESIS="$CHAIN_DIR/config/genesis.json"
TMP_GENESIS=$CHAIN_DIR/config/tmp_genesis.json

DENOM="${DENOM:-astake}"
DISPLAY_DENOM="${DISPLAY_DENOM:-stake}"
SYMBOL="${SYMBOL:-STAKE}"
CLEANUP="${CLEANUP:-1}"
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_PATH="$CHAIN_DIR/sandboxd.log"
VOTING_PERIOD="${VOTING_PERIOD:-20s}"
RUN_MODE="${RUN_MODE:-background}"
CONFIG_ONLY="${CONFIG_ONLY:-false}"

# Portable helper that works with BSD and GNU sed.
sed_in_place() {
  local target="$1"
  shift
  local backup="${target}.bak"
  if sed -i.bak "$@" "$target"; then
    rm -f "$backup"
  else
    local status=$?
    rm -f "$backup"
    return $status
  fi
}

KEYRING="test"
KEYALGO="eth_secp256k1"

VAL0_KEY="val"
VAL0_MNEMONIC="copper push brief egg scan entry inform record adjust fossil boss egg comic alien upon aspect dry avoid interest fury window hint race symptom"

WALLETS=(
  "user-1:surge sing leave bone title meadow horror green gas pipe law primary"
  "user-2:cheap nest such fix tongue glow live climb balcony length capital moon"
  "user-3:tenant helmet dial tattoo awake squirrel detect click wild manual clip crime"
  "user-4:field pottery bitter hold want advance key ketchup grace traffic swift toy"
  "user-5:solar south author fetch dad license boil rookie boil reason sibling acid"
  "user-6:luggage police rabbit poet use figure indicate remember verify monitor skirt apology"
  "user-7:setup other thrive rice humble beyond own rice trip place elder unknown"
  "user-8:seek seven seed trend guard tiger surge inmate upper cigar common decorate"
  "user-9:panda van tuition beyond upper drink doctor write sorry luggage drastic prepare"
  "user-10:flip badge spend oval yellow humble sting leave submit guilt brush help"
)

GENESIS_AMOUNT="10000000000000000000$DENOM"

echo "--- Chain ID = $CHAIN_ID"
echo "--- Chain Dir = $CHAIN_DIR"
echo "--- Coin Denom = $DENOM"

if [ ! -f "$NODE_BIN" ]; then
  echo "$NODE_BIN does not exist. Build it first with: make build"
  exit 1
fi

echo "--- Cleaning up any existing chain data..."
"$CWD/kill-local-node.sh" || true
rm -rf "$CHAIN_DIR"

echo "--- Initializing chain (chain-id=$CHAIN_ID)..."
"$NODE_BIN" init my-val --home "$CHAIN_DIR" --chain-id "$CHAIN_ID"

echo "--- Importing validator key..."
echo "$VAL0_MNEMONIC$NEWLINE" | "$NODE_BIN" keys add $VAL0_KEY --keyring-backend $KEYRING --algo $KEYALGO --recover --home "$CHAIN_DIR"

echo "--- Importing wallet keys..."
for wallet_entry in "${WALLETS[@]}"; do
  wallet_name="${wallet_entry%%:*}"
  wallet_mnemonic="${wallet_entry#*:}"
  echo "$wallet_mnemonic$NEWLINE" | "$NODE_BIN" keys add "$wallet_name" --keyring-backend $KEYRING --algo $KEYALGO --recover --home "$CHAIN_DIR"
done

echo "--- Adding genesis accounts..."
VAL_ADDR=$("$NODE_BIN" keys show $VAL0_KEY -a --keyring-backend test --home "$CHAIN_DIR")
"$NODE_BIN" genesis add-genesis-account "$VAL_ADDR" "$GENESIS_AMOUNT" --home "$CHAIN_DIR"

for wallet_entry in "${WALLETS[@]}"; do
  wallet_name="${wallet_entry%%:*}"
  "$NODE_BIN" genesis add-genesis-account "$("$NODE_BIN" keys show "$wallet_name" -a --keyring-backend test --home "$CHAIN_DIR")" "$GENESIS_AMOUNT" --home "$CHAIN_DIR"
done

# ---------------------------------------------------------------------------
# Patch genesis: POA validator + params
# ---------------------------------------------------------------------------

echo "--- Patching genesis (POA + EVM + gov)..."

# Replace default "stake" denom everywhere in genesis
sed_in_place "$GENESIS" -e "s|\"stake\"|\"$DENOM\"|g"

# --- POA genesis ---
# Extract consensus pubkey from priv_validator_key.json (base64-encoded ed25519)
CONS_PUBKEY=$(jq -r '.pub_key.value' "$CHAIN_DIR/config/priv_validator_key.json")
CONS_PUBKEY_TYPE=$(jq -r '.pub_key.type' "$CHAIN_DIR/config/priv_validator_key.json")

# Map tendermint key type to proto type_url
if [ "$CONS_PUBKEY_TYPE" = "tendermint/PubKeyEd25519" ]; then
  PROTO_TYPE="/cosmos.crypto.ed25519.PubKey"
else
  PROTO_TYPE="/cosmos.crypto.secp256k1.PubKey"
fi

# Patch POA genesis: set admin to validator address, add initial validator
jq --arg admin "$VAL_ADDR" \
   --arg pubkey "$CONS_PUBKEY" \
   --arg type_url "$PROTO_TYPE" \
   '.app_state["poa"] = {
      "params": { "admin": $admin },
      "validators": [{
        "pub_key": { "@type": $type_url, "key": $pubkey },
        "power": "10000",
        "metadata": { "moniker": "my-val", "description": "", "operator_address": $admin }
      }],
      "allocated_fees": []
    }' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

# --- IFT params ---
jq --arg authority "$VAL_ADDR" '.app_state["ift"]["params"]["authority"]=$authority' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

# --- Gov params ---
jq --arg denom "$DENOM" '.app_state["gov"]["params"]["min_deposit"][0]["denom"]=$denom' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
jq --arg denom "$DENOM" '.app_state["gov"]["params"]["expedited_min_deposit"][0]["denom"]=$denom' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

sed_in_place "$GENESIS" 's/"max_deposit_period": "172800s"/"max_deposit_period": "30s"/g'
sed_in_place "$GENESIS" 's/"voting_period": "172800s"/"voting_period": "30s"/g'
sed_in_place "$GENESIS" 's/"expedited_voting_period": "86400s"/"expedited_voting_period": "15s"/g'

# --- EVM params ---
jq --arg denom "$DENOM" '.app_state["evm"]["params"]["evm_denom"]=$denom' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
jq '.app_state["feemarket"]["params"]["no_base_fee"]=true' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

# Active precompiles (only the ones this chain registers — no staking/distr/slashing/ics20/vesting)
jq '.app_state["evm"]["params"]["active_static_precompiles"]=[
  "0x0000000000000000000000000000000000000100",
  "0x0000000000000000000000000000000000000400",
  "0x0000000000000000000000000000000000000804",
  "0x0000000000000000000000000000000000000805",
  "0x0000000000000000000000000000000000000807"
]' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

# --- Bank denom metadata ---
jq --arg denom "$DENOM" --arg display_denom "$DISPLAY_DENOM" --arg symbol "$SYMBOL" \
  '.app_state["bank"]["denom_metadata"]=[{
    "description": "The native token of the sandbox chain.",
    "denom_units": [
      {"denom": $denom, "exponent": 0, "aliases": ["atto" + $display_denom]},
      {"denom": $display_denom, "exponent": 18, "aliases": []}
    ],
    "base": $denom,
    "display": $display_denom,
    "name": "Staking Token",
    "symbol": $symbol,
    "uri": "",
    "uri_hash": ""
  }]' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

# --- Block params ---
jq '.consensus.params.block.max_gas="200000000"' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

# Zero-fee chain. Sandbox is RPC-gated (no open mempool), so fees aren't
# acting as a spam deterrent. The Paymaster pattern in the backend exists
# for sender-anonymity, not gas coverage — neither admin nor paymaster
# keys need to hold a balance.
jq '.app_state["feemarket"]["params"]["no_base_fee"]=true' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
jq '.app_state["feemarket"]["params"]["base_fee"]="0.000000000000000000"' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

if [ "${LOAD_TESTING:-}" = "true" ]; then
  echo "--- Applying load testing optimizations..."
  jq '.consensus.params.block.max_gas="52500000"' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
  jq '.consensus.params.block.max_bytes="104857600"' "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
fi

echo "--- Validating genesis..."
"$NODE_BIN" genesis validate --home "$CHAIN_DIR"

# ---------------------------------------------------------------------------
# Config tweaks
# ---------------------------------------------------------------------------

echo "--- Modifying config..."

# Faster block times
sed_in_place "$CONFIG_TOML" 's/timeout_propose = "3s"/timeout_propose = "2s"/g'
sed_in_place "$CONFIG_TOML" 's/timeout_propose_delta = "500ms"/timeout_propose_delta = "200ms"/g'
sed_in_place "$CONFIG_TOML" 's/timeout_prevote = "1s"/timeout_prevote = "500ms"/g'
sed_in_place "$CONFIG_TOML" 's/timeout_prevote_delta = "500ms"/timeout_prevote_delta = "200ms"/g'
sed_in_place "$CONFIG_TOML" 's/timeout_precommit = "1s"/timeout_precommit = "500ms"/g'
sed_in_place "$CONFIG_TOML" 's/timeout_precommit_delta = "500ms"/timeout_precommit_delta = "200ms"/g'
sed_in_place "$CONFIG_TOML" 's/timeout_commit = "5s"/timeout_commit = "500ms"/g'
sed_in_place "$CONFIG_TOML" 's/timeout_broadcast_tx_commit = "10s"/timeout_broadcast_tx_commit = "5s"/g'

# Larger mempool
sed_in_place "$CONFIG_TOML" 's/size = 5000/size = 5000000/g'

# Enable prometheus and all APIs
sed_in_place "$CONFIG_TOML" 's/prometheus = false/prometheus = true/'
sed_in_place "$APP_TOML" 's/prometheus-retention-time = 0/prometheus-retention-time  = 1000000000000/g'
sed_in_place "$APP_TOML" 's/enabled = false/enabled = true/g'
sed_in_place "$APP_TOML" 's/enable = false/enable = true/g'
sed_in_place "$APP_TOML" -e "s/^[[:space:]]*minimum-gas-prices[[:space:]]*=[[:space:]]*\"[^\"]*\"/minimum-gas-prices = \"0$DENOM\"/"

# Exit early if only generating configs
if [ "$CONFIG_ONLY" = "true" ]; then
  echo "--- Config generation complete (CONFIG_ONLY=true)"
  echo "--- Files at: $CHAIN_DIR/config/"
  exit 0
fi

# ---------------------------------------------------------------------------
# Start node
# ---------------------------------------------------------------------------

echo "--- Starting chain..."
cmd=("$NODE_BIN" start
  --api.enable true
  --grpc.address="127.0.0.1:9090"
  --api.enabled-unsafe-cors
  --grpc-web.enable=true
  --log_level "$LOG_LEVEL"
  --json-rpc.api eth,txpool,personal,net,debug,web3
  --json-rpc.enable true
  --evm.evm-chain-id "$EVM_CHAIN_ID"
  --home "$CHAIN_DIR"
)

echo "--- Start command: ${cmd[*]}"

if [ "$RUN_MODE" = "foreground" ]; then
  echo "--- Running in foreground mode"
  "${cmd[@]}"
else
  echo "--- Running in background mode"
  "${cmd[@]}" > "$LOG_PATH" 2>&1 &
  pid=$!
  echo "--- Node started (PID $pid)"
  echo
  echo "Logs:  tail -f $LOG_PATH"
  echo "tail -f $LOG_PATH" | pbcopy 2>/dev/null || true
  echo
  echo "CLI:   $NODE_BIN --home $CHAIN_DIR status"

  # ---------------------------------------------------------------------------
  # Deploy Zeto contracts (skip with SKIP_ZETO_BOOTSTRAP=1).
  #
  # Waits briefly for the EVM JSON-RPC port, then runs deploy-zeto.sh which
  # registers the Zeto_AnonEncNullifierNonRepudiation impl + verifiers
  # with the factory and writes contracts/deployments/sandbox-dev-1.json.
  #
  # App-level bootstrap (CBDC token deploy, genesis allocations) is the
  # responsibility of whatever app is consuming this chain — see the sandbox
  # repo's scripts/demo.sh for the reference invocation. Keeping the ledger
  # free of app-specific binaries means this repo can ship public without
  # leaking private app code.
  # ---------------------------------------------------------------------------
  if [ "${SKIP_ZETO_BOOTSTRAP:-0}" != "1" ]; then
    # deploy-zeto.sh has its own wait_for_rpc that polls cast block-number
    # until the chain has produced a block — strictly stronger than a TCP
    # port check, so we hand off directly.
    DEPLOY_SCRIPT="$CWD/../contracts/deploy-zeto.sh"
    echo "--- Deploying Zeto contracts..."
    bash "$DEPLOY_SCRIPT"
  fi
fi
