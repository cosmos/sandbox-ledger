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
# deploys: iden3's SmtLib (linked at deploy time against
# PoseidonUnit2L/3L), the Zeto factory and AnonEncNullifierNonRepudiation
# token implementation, and the vendored Zeto verifiers the factory
# registers in the VerifiersInfo struct.
contracts=(
  # iden3 SmtLib (linked at deploy time against PoseidonUnit2L/3L)
  "SmtLib.sol:SmtLib"

  # Zeto factory + AnonEncNullifierNonRepudiation implementation
  "factory.sol:ZetoTokenFactory"
  "zeto_anon_enc_nullifier_non_repudiation.sol:Zeto_AnonEncNullifierNonRepudiation"

  # Vendored Zeto verifiers registered with the factory
  "verifier_anon_enc_nullifier_non_repudiation.sol:Groth16Verifier_AnonEncNullifierNonRepudiation"
  "verifier_anon_enc_nullifier_non_repudiation_batch.sol:Groth16Verifier_AnonEncNullifierNonRepudiationBatch"
  "verifier_deposit.sol:Groth16Verifier_Deposit"
  "verifier_withdraw_nullifier.sol:Groth16Verifier_WithdrawNullifier"
  "verifier_withdraw_nullifier_batch.sol:Groth16Verifier_WithdrawNullifierBatch"
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

# Guardrail: every shipped artifact whose bytecode references library
# placeholders MUST also expose linkReferences. The previous release
# shipped artifacts that looked complete (non-empty bytecode, empty
# linkReferences) but in fact had synthetic addresses 0x...5002/5003/5a47
# baked in by foundry.toml's libraries setting. Consumers that cast-send
# those bytecodes deploy contracts that delegate-call dead addresses and
# silently fail with OZ FailedCall(). Catch the regression here.
#
# Library-agnostic pattern: any 20-byte address consisting of >=32 leading
# zero nibbles (i.e. numeric value < 2^32) is treated as a placeholder
# candidate. Real on-chain addresses are essentially uniform random over
# 2^160, so the chance of a legitimate address landing in this range is
# ~1 in 2^128 — any hit in shipped bytecode is the foundry.toml regression
# class. Catches future synthetic addresses (0x...6000, 0x...1234, etc.)
# without enumerating each one. Precompile addresses (0x...0001-0x...000a)
# match too but don't normally appear as PUSH32 constants in user
# contracts that go through libraries.
echo "🔍 Verifying shipped artifacts are properly linked"
for art in "$staging/bytecode/"*.json; do
  bc=$(jq -r '.bytecode.object // empty' "$art")
  drt=$(jq -r '.deployedBytecode.object // empty' "$art")
  refs_creation=$(jq -r '.bytecode.linkReferences // {} | [.. | objects | select(has("start"))] | length' "$art")
  refs_runtime=$(jq -r '.deployedBytecode.linkReferences // {} | [.. | objects | select(has("start"))] | length' "$art")
  # `|| true` keeps `set -e` from aborting when grep matches nothing.
  hits=$(printf '%s%s' "$bc" "$drt" \
         | grep -oE "0{32}[0-9a-f]{8}" \
         | grep -v "^0\{40\}$" \
         | wc -l | tr -d ' ' || true)
  if [ "${hits:-0}" -gt 0 ] && [ $((refs_creation + refs_runtime)) -eq 0 ]; then
    echo "❌ $art has $hits placeholder-shaped address(es) baked in but"
    echo "   linkReferences is empty. Downstream tools cannot patch the"
    echo "   bytecode and will deploy contracts that revert at runtime."
    echo "   Fix: remove the offending entry from contracts/foundry.toml"
    echo "   [profile.default].libraries, or move it under [profile.test]."
    exit 1
  fi
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
