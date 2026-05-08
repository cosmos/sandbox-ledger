#!/bin/bash
set -Eeuo pipefail

trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Match on the start subcommand so we don't collide with macOS's
# /usr/libexec/sandboxd (the OS sandbox daemon) on developer machines.
# `|| true` keeps `set -e` from tripping when no process is found — that's
# the desired exit-zero behavior for a stop-if-running script.
pkill -9 -f "sandboxd start" || true
