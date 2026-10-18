#!/usr/bin/env bash
# Runs every check of this repository: the library tests, both examples' tests, and the wasm32-orbit build of examples/edge.
# ORIN selects the launcher (default: `orin` on PATH).
set -euo pipefail
cd "$(dirname "$0")/.."
ORIN="${ORIN:-orin}"

echo "== orin-web tests"
"$ORIN" test

for ex in todo-api edge; do
  echo "== examples/$ex"
  (cd "examples/$ex" && "$ORIN" fetch && "$ORIN" test)
done

echo "== examples/edge for wasm32-orbit"
(cd examples/edge && "$ORIN" build --target=wasm32-orbit)

echo "== formatting"
"$ORIN" fmt --check

echo "ok"
