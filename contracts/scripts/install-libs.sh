#!/usr/bin/env bash
set -Eeuo pipefail

# Populate contracts/lib with the Forge dependencies at pinned commits.
# `contracts/lib/` is gitignored, so submodule init is a no-op and CI
# needs to fetch them explicitly. Pins match the working local state on
# 2026-05-06 — bump deliberately and verify forge build + forge test
# still pass before committing a change here.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

clone_at() {
    local repo="$1" sha="$2" dest="$3"
    if [ -d "lib/$dest/.git" ]; then
        echo "lib/$dest already exists; skipping clone"
        return 0
    fi
    git clone --quiet "https://github.com/$repo" "lib/$dest"
    git -C "lib/$dest" checkout --quiet "$sha"
    echo "lib/$dest @ $(git -C "lib/$dest" rev-parse --short HEAD) ($repo)"
}

mkdir -p lib
clone_at foundry-rs/forge-std 8b531a016 forge-std
clone_at OpenZeppelin/openzeppelin-contracts 69c8def5f openzeppelin-contracts
clone_at OpenZeppelin/openzeppelin-contracts-upgradeable 723f8cab0 openzeppelin-contracts-upgradeable
clone_at iden3/contracts 5286d5007 iden3-contracts
clone_at hyperledger-labs/zeto 055ce56a9 zeto

# Overlay iden3 shim files. Newer Zeto imports
# `@iden3/contracts/contracts/lib/hash/PoseidonHasher.sol` and
# `@iden3/contracts/contracts/interfaces/IHasher.sol`, which don't exist
# at the iden3 SHA we pin; SmtLib also needs a no-op `setHasher` to satisfy
# Zeto's wiring. The overlay tree under `scripts/shims/iden3-contracts/`
# mirrors the iden3 layout, so a recursive copy puts each file where the
# remappings expect it.
echo "overlaying iden3 shims"
cp -R scripts/shims/iden3-contracts/. lib/iden3-contracts/
