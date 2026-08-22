#!/usr/bin/env bash
# 基线不变量检查：不依赖 Swift 工具链，任何时候都能跑。
# 在仓库根执行：bash scripts/baseline_check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FROZEN_SHA="70fd6b2c47d48ce03932e7e43b930f9ee26fcec7"
FROZEN_LICENSE_SHA256="373fa50f9c6ca5b9ddbf5addf3c18eb6b0331fd2b8d98925960a6f6d436bd6c9"

fail=0
check() { # check <描述> <命令>
  if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi
}

check "HEAD 是冻结基准 $FROZEN_SHA 的后代（含基准未漂移）" \
  "[ \"\$(git merge-base HEAD \"$FROZEN_SHA\")\" = \"$FROZEN_SHA\" ]"
check "LICENSE 内容与基准一致（MIT, $(echo "$FROZEN_LICENSE_SHA256" | cut -c1-8)…）" \
  "[ \"\$(shasum -a 256 LICENSE | cut -d' ' -f1)\" = \"$FROZEN_LICENSE_SHA256\" ]"
check "LICENSE 仍是 MIT 且保留版权声明" "grep -q 'MIT License' LICENSE && grep -q 'Moamen Basel' LICENSE"
check "冻结基准的 28 个上游源码文件全部存在" \
  "[ \"\$(git ls-tree -r --name-only \"$FROZEN_SHA\" -- Sources | grep -c '.swift\$')\" = \"28\" ]"
check "上游源码零改动（Sources/ 与冻结基准逐字节一致）" \
  "[ -z \"\$(git diff \"$FROZEN_SHA\" -- Sources)\" ]"
check "无第三方依赖（Package.swift 无外部 package 声明）" \
  "! grep -q '\.package(' Package.swift"
check "无遥测/分析 SDK 引用" \
  "[ -z \"\$(grep -rniE 'analytics|telemetry|crashlytics|mixpanel' Sources/ scripts/ packaging/ Tests/ | grep -v 'scripts/baseline_check.sh' || true)\" ]"
check "测试基线存在" "[ -f Tests/PestyBaselineTests/BaselineTests.swift ]"

echo
if [ "$fail" -eq 0 ]; then echo "基线检查全部通过。"; else echo "存在失败项，先核对再继续重构。"; exit 1; fi
