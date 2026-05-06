#!/usr/bin/env bash
set -Eeuo pipefail

# go-mod-tidy-all.sh — `go mod tidy` every Go module in this repo.
#
# Today there's a single go.mod at the root, but if we ever split a
# component (a tools sub-module, a separate systemtest module, etc.) the
# root tidy alone wouldn't cover it. This walks every go.mod in the tree
# (skipping vendored deps) and tidies each.
#
# CI's tidy gate fails on any uncommitted go.mod / go.sum diff after
# `go mod tidy`, so running this before `git commit` keeps the cycle
# tight.
#
# Usage:
#   ./scripts/go-mod-tidy-all.sh           # tidy each, print a summary
#   ./scripts/go-mod-tidy-all.sh --check   # exit non-zero if any module would change

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK=0
if [ "${1:-}" = "--check" ]; then
    CHECK=1
fi

# Find every go.mod, ignoring vendored / build / node_modules trees and
# anything under .git. Sort for stable output across runs.
modules=()
while IFS= read -r mod; do
    modules+=("$(dirname "$mod")")
done < <(
    find . -type f -name go.mod \
        -not -path "./.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/vendor/*" \
        -not -path "*/build/*" \
        -not -path "*/lib/*" \
        | sort
)

if [ "${#modules[@]}" -eq 0 ]; then
    echo "No go.mod files found."
    exit 0
fi

dirty=()
for dir in "${modules[@]}"; do
    rel="${dir#./}"
    [ -z "$rel" ] && rel="."
    echo "--- $rel: go mod tidy"
    ( cd "$dir" && go mod tidy )

    if ! git diff --quiet HEAD -- "$dir/go.mod" "$dir/go.sum" 2>/dev/null; then
        dirty+=("$rel")
    fi
done

echo

if [ "${#dirty[@]}" -eq 0 ]; then
    echo "All modules clean."
    exit 0
fi

echo "Modules with uncommitted go.mod / go.sum changes:"
for rel in "${dirty[@]}"; do
    echo "  - $rel"
    if [ "$rel" = "." ]; then
        git --no-pager diff --stat HEAD -- go.mod go.sum | sed 's/^/      /'
    else
        git --no-pager diff --stat HEAD -- "$rel/go.mod" "$rel/go.sum" | sed 's/^/      /'
    fi
done

if [ "$CHECK" -eq 1 ]; then
    echo
    echo "Run without --check to commit the result."
    exit 1
fi
