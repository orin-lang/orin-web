#!/usr/bin/env bash
# Compile-time diagnostics of the annotation processors. Every tests/compile-fail/*.or is the annotated module of a tiny package; its
# first line, `// expect: TEXT`, is a text that `orin check` must print while failing. (A processor reports its problems as
# compile errors at the annotated class; `orin test` cannot expand companion modules, so this runs the compiler on whole packages.)
set -uo pipefail
cd "$(dirname "$0")/.."
ORIN="${ORIN:-orin}"
root="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
for case in tests/compile-fail/*.or; do
  name="$(basename "$case" .or)"
  expect="$(head -1 "$case" | sed 's|^// expect: ||')"
  dir="$work/$name"
  mkdir -p "$dir/src"
  cat > "$dir/orin.toml" <<EOF
[package]
name = "case-$name"
version = "0.0.0"
entry = "src/main.or"

[dependencies]
orin-web = { path = "$root" }

[annotations]
processors = ["orin-web"]
EOF
  cp "$case" "$dir/src/beans.or"
  cat > "$dir/src/main.or" <<EOF
import * as generated from "./beans.gen";

function main(): void {}
EOF
  (cd "$dir" && "$ORIN" fetch >/dev/null 2>&1)
  out="$(cd "$dir" && "$ORIN" check --color=never 2>&1)"
  status=$?
  if [ $status -eq 0 ]; then
    echo "FAIL $name: expected a compile error, got success"; failed=1
  elif ! printf '%s' "$out" | grep -qF -- "$expect"; then
    echo "FAIL $name: expected the text: $expect"; printf '%s\n' "$out" | sed 's/^/    /' | head -12; failed=1
  else
    echo "ok   $name"
  fi
done
exit $failed
