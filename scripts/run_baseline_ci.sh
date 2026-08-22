#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run bash scripts/baseline_check.sh
run swift test
run swift build
run env VERSION=0.0.0 BUILD=ci bash scripts/build_app.sh
run bash scripts/smoke_noninteractive.sh

printf '\nBaseline CI entrypoint completed successfully.\n'
