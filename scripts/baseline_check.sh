#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

FROZEN_SHA="70fd6b2c47d48ce03932e7e43b930f9ee26fcec7"
FROZEN_LICENSE_SHA256="373fa50f9c6ca5b9ddbf5addf3c18eb6b0331fd2b8d98925960a6f6d436bd6c9"

# Two enforcement profiles:
#   freeze — the baseline branch (agent/clipboard-foundation-v01): production
#            Sources must stay byte-identical to the frozen upstream SHA.
#   dev    — development branches: Sources may change, but structural
#            invariants (file count floor, license, hygiene) still apply.
# Freeze also forces on explicitly with FREEZE=1.
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
FREEZE="${FREEZE:-}"
if [ -z "$FREEZE" ]; then
  case "$BRANCH" in
    agent/clipboard-foundation-v01) FREEZE=1 ;;
    *) FREEZE=0 ;;
  esac
fi
echo "mode: $([ "$FREEZE" = 1 ] && echo freeze || echo dev) (branch: ${BRANCE:-${BRANCH}})"

fail=0

check() {
  description="$1"
  command="$2"
  if eval "$command" >/dev/null 2>&1; then
    echo "PASS: $description"
  else
    echo "FAIL: $description"
    fail=1
  fi
}

check "HEAD descends from frozen base" \
  "[ \"$(git merge-base HEAD "$FROZEN_SHA")\" = "$FROZEN_SHA" ]"

check "LICENSE byte hash is frozen" \
  "[ \"$(shasum -a 256 LICENSE | cut -d' ' -f1)\" = "$FROZEN_LICENSE_SHA256" ]"

check "LICENSE remains MIT with original attribution" \
  "grep -q 'MIT License' LICENSE && grep -q 'Moamen Basel' LICENSE"

check "all 28 frozen Swift source files still exist" \
  "[ \"$(git ls-tree -r --name-only "$FROZEN_SHA" -- Sources | grep -c '.swift$')\" = '28' ]"

if [ "$FREEZE" = 1 ]; then
  check "production Sources are byte-identical to frozen base" \
    "[ -z \"$(git diff "$FROZEN_SHA" -- Sources)\" ]"
else
  check "dev: Sources tree holds >= 28 Swift files (no accidental deletions)" \
    "[ \"$(git ls-files 'Sources/**/*.swift' | grep -c '.swift$')\" -ge 28 ]"
fi

check "Package.swift declares no external package dependency" \
  "! grep -q '\\.package(' Package.swift"

check "no telemetry/analytics SDK reference in executable code" \
  "[ -z \"$(grep -rniE 'analytics|telemetry|crashlytics|mixpanel' Sources scripts packaging Tests 2>/dev/null | grep -v 'baseline_check.sh' || true)\" ]"

check "baseline tests exist" \
  "[ -f Tests/PestyBaselineTests/BaselineTests.swift ] || [ -f Tests/ClipBarBaselineTests/BaselineTests.swift ]"

check "required audit documents exist" \
  "[ -f BASELINE.md ] && [ -f ARCHITECTURE.md ] && [ -f RISKS.md ] && [ -f TESTING.md ] && [ -f EVIDENCE.md ] && [ -f KNOWN_ISSUES.md ]"

check "single CI entrypoint exists" \
  "[ -f scripts/run_baseline_ci.sh ] && [ -f scripts/smoke_noninteractive.sh ]"

check "CI workflow calls the single entrypoint" \
  "grep -q 'scripts/run_baseline_ci.sh' .github/workflows/ci.yml"

check "CI entrypoint includes all required gates" \
  "grep -q 'scripts/baseline_check.sh' scripts/run_baseline_ci.sh &&
   grep -q 'swift test' scripts/run_baseline_ci.sh &&
   grep -q 'swift build' scripts/run_baseline_ci.sh &&
   grep -q 'scripts/build_app.sh' scripts/run_baseline_ci.sh &&
   grep -q 'scripts/smoke_noninteractive.sh' scripts/run_baseline_ci.sh"

check "repository automation does not mutate Xcode license acceptance state" \
  "[ -z \"$(grep -rniE 'IDELastGMLicenseAgreedTo|IDEXcodeVersionForAgreedToGMLicense|defaults[[:space:]]+write[[:space:]]+/Library/Preferences/com\\.apple\\.dt\\.Xcode' scripts .github 2>/dev/null | grep -v "baseline_check.sh" || true)\" ]"

echo
if [ "$fail" -eq 0 ]; then
  echo "Baseline invariants passed."
else
  echo "Baseline invariant failure."
  exit 1
fi
