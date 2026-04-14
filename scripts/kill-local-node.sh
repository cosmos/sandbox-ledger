#!/bin/bash
set -Eeuo pipefail

trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

pkill -9 sandboxd
