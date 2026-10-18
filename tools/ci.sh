#!/usr/bin/env bash
# Runs every check of this repository. ORIN selects the launcher (default: `orin` on PATH).
#
#   1. the library's tests (unit tests, processors as functions, loopback-socket tests)
#   2. the annotation layer end to end: tests/annotated is a package whose main drives generated code through TestClient
#      (`orin test` cannot expand companion modules, so these are programs that trap on failure)
#   3. the compile-time diagnostics of the processors (tests/compile-fail)
#   4. the examples: todo-api (annotation style; its own tests and its selftest) and edge (functional)
#   5. wasm32-orbit: examples/edge and the end-to-end annotation tests, built and run under Node when available
#   6. formatting
set -euo pipefail
cd "$(dirname "$0")/.."
ORIN="${ORIN:-orin}"
export ORIN

echo "== orin-web tests"
"$ORIN" test

echo "== annotation layer, end to end (tests/annotated)"
(cd tests/annotated && "$ORIN" fetch >/dev/null && "$ORIN" run)

echo "== processor diagnostics (tests/compile-fail)"
tools/compile_fail.sh

echo "== examples/edge"
(cd examples/edge && "$ORIN" fetch >/dev/null && "$ORIN" test)

# todo-api imports generated companions from its entry graph, which `orin test` without a file argument cannot expand: the unit test
# is named explicitly, the end-to-end test is the selftest.
echo "== examples/todo-api"
(cd examples/todo-api && "$ORIN" fetch >/dev/null && "$ORIN" test tests/store_test.or && "$ORIN" run -- selftest 2>/dev/null)

echo "== wasm32-orbit"
(cd examples/edge && "$ORIN" build --target=wasm32-orbit)
(cd tests/annotated && "$ORIN" build --target=wasm32-orbit)
if [ -n "${WASM_RUN:-}" ]; then
  node "$WASM_RUN" examples/edge/build/dev/edge.wasm
  node "$WASM_RUN" tests/annotated/build/dev/annotated-tests.wasm
fi

echo "== formatting"
"$ORIN" fmt --check

echo "ok"
