#!/usr/bin/env bash
#
# Generate Go bindings from .proto files using buf + the gogo plugin.
# Intended to be invoked inside the cosmos/proto-builder Docker image
# (see the `proto-gen` target in the Makefile).

set -euo pipefail

GO_MOD_PACKAGE="github.com/cosmos/sandbox-ledger"

echo "Generating gogo proto code"
cd proto

proto_dirs=$(find . -path -prune -o -name '*.proto' -print0 | xargs -0 -n1 dirname | sort -u)

for dir in $proto_dirs; do
  for file in $(find "${dir}" -maxdepth 1 -name '*.proto'); do
    # Generate when the file declares a go_package that does NOT target the
    # api/ tree (api/ is reserved for google.golang.org/protobuf-generated
    # files, which gogo should not touch).
    if grep -q "option go_package" "$file" \
        && ! grep -q "option go_package.*$GO_MOD_PACKAGE/api" "$file"; then
      buf generate --template buf.gen.gogo.yaml "$file"
    fi
  done
done

cd ..

# buf writes generated files under <out>/<go_package>; copy them into the
# repo's actual layout and clean up the staging tree.
cp -r "$GO_MOD_PACKAGE"/* ./
rm -rf github.com
