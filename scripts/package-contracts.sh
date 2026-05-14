#!/usr/bin/env bash
#
# Build and package pre-compiled solidity contract artifacts as a release tarball.
#
# Performs a clean forge build under contracts/, then copies the full forge
# JSON (ABI + bytecode + metadata) for each contract deployed by deploy-zeto.sh
# into release-artifacts/solidity-contracts/bytecode/. Pre-built Poseidon
# library bytecode (deployed via raw cast send rather than forge) ships
# alongside under poseidon/. Stamps a TAG_NAME file and produces
# solidity-contracts-<tag>.tar.gz at the repo root.
#
# Requires `forge` on PATH and the contracts/lib submodules already
# initialized (CI does this via actions/checkout's `submodules: recursive`;
# locally run `make submodules` first).
#
# Reads the release tag from the TAG_NAME environment variable (default: "dev").
# Usage:   TAG_NAME=solidity-v2.0.1 ./scripts/package-contracts.sh
# Example: ./scripts/package-contracts.sh                          # → dev
#          TAG_NAME=solidity-v2.0.1 ./scripts/package-contracts.sh # → tagged release

set -euo pipefail

TAG_NAME="${TAG_NAME:-dev}"
echo "📌 Version: $TAG_NAME"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Always clean up the staging tree on exit (success or failure)
trap 'rm -rf release-artifacts' EXIT

# Forge artifacts to ship as full JSON (ABI + bytecode + metadata).
# Format: "<source.sol>:<ContractName>" — resolves to
# contracts/out/<source.sol>/<ContractName>.json. The source filename
# does not always match the contract name (e.g. zeto verifiers), so both
# are listed explicitly. Only concrete deployable contracts are included;
# interfaces, libraries with no runtime bytecode, and abstract bases are
# excluded.
#
# This set mirrors what deploy-zeto.sh + script/DeployZetoAnon.s.sol
# deploys: our local AnonNullifier transfer verifier, iden3's SmtLib
# (linked at deploy time against PoseidonUnit2L/3L), the Zeto factory
# and burnable nullifier token implementation, and the vendored Zeto
# verifiers the factory registers in the VerifiersInfo struct.
contracts=(
  # Local verifier (snarkjs-generated against our zkey)
  "Verifier_AnonNullifierTransfer.sol:Groth16Verifier_AnonNullifierTransfer"

  # iden3 SmtLib (linked at deploy time against PoseidonUnit2L/3L)
  "SmtLib.sol:SmtLib"

  # Zeto factory + Zeto_AnonNullifier_Burnable implementation
  "factory.sol:ZetoTokenFactory"
  "zeto_anon_nullifier_burnable.sol:Zeto_AnonNullifierBurnable"

  # Vendored Zeto verifiers registered with the factory
  "verifier_anon_nullifier_transfer_batch.sol:Groth16Verifier_AnonNullifierTransferBatch"
  "verifier_deposit.sol:Groth16Verifier_Deposit"
  "verifier_withdraw_nullifier.sol:Groth16Verifier_WithdrawNullifier"
  "verifier_withdraw_nullifier_batch.sol:Groth16Verifier_WithdrawNullifierBatch"
  "verifier_burn_nullifier.sol:Groth16Verifier_BurnNullifier"
)

# Pre-built Poseidon library bytecode. These are circom-generated blobs
# deployed via raw `cast send --create` (see contracts/deploy-zeto.sh
# Stage 1), not forge build output — they ship as-is.
poseidon_hex=(
  PoseidonUnit2L.hex
  PoseidonUnit3L.hex
)

echo "🧹 Cleaning previous build output"
rm -rf contracts/out contracts/cache contracts/broadcast

echo "🔨 Building contracts"
(cd contracts && forge build)

staging="release-artifacts/solidity-contracts"
rm -rf "$staging"
mkdir -p "$staging/bytecode" "$staging/poseidon"

for entry in "${contracts[@]}"; do
  src_file="${entry%%:*}"
  contract_name="${entry##*:}"
  src="contracts/out/${src_file}/${contract_name}.json"
  if [ ! -f "$src" ]; then
    echo "❌ Missing forge artifact: $src"
    exit 1
  fi
  cp "$src" "$staging/bytecode/${contract_name}.json"
done

for hex in "${poseidon_hex[@]}"; do
  src="contracts/poseidon/${hex}"
  if [ ! -f "$src" ]; then
    echo "❌ Missing poseidon bytecode: $src"
    exit 1
  fi
  cp "$src" "$staging/poseidon/${hex}"
done

echo "$TAG_NAME" > "$staging/TAG_NAME"

tarball="solidity-contracts-${TAG_NAME}.tar.gz"
tar -czvf "$tarball" -C release-artifacts solidity-contracts

echo "✅ Packaged: $tarball"
