#!/usr/bin/env bash
# 每版固定验证（发布前必跑）
#
# 用法：
#   bash tools/verify_release.sh            # 分析 + 测试 + 版本一致性（不构建）
#   bash tools/verify_release.sh --build    # 额外构建 release APK 并打印校验信息
#
# 退出码非 0 表示门禁未过，禁止发布。
set -u
cd "$(dirname "$0")/.."

export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export PATH="$PATH:$ANDROID_HOME/platform-tools"

FAIL=0
say() { printf '%s\n' "$*"; }
step() { say ""; say "=== $* ==="; }

step "1/5 版本一致性（pubspec / README / 已构建产物）"
VER=$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
CODE=$(grep -m1 '^version:' pubspec.yaml | sed 's/.*+//')
say "pubspec: versionName=$VER versionCode=$CODE"
if ! grep -q "v$VER (${CODE})" README.md; then
  say "  ✗ README 当前版本行未写 v$VER (${CODE})"
  FAIL=1
else
  say "  ✓ README 版本行一致"
fi

step "2/5 静态分析（flutter analyze）"
OUT=$(flutter analyze 2>&1)
echo "$OUT" | tail -3
if echo "$OUT" | grep -qE " (error|warning) • "; then
  say "  ✗ 存在 error/warning"
  echo "$OUT" | grep -E " (error|warning) • "
  FAIL=1
else
  say "  ✓ 0 error / 0 warning（info 级不阻断）"
fi

step "3/5 全量测试（flutter test）"
TEST=$(flutter test 2>&1 | tail -3)
echo "$TEST"
if ! echo "$TEST" | grep -q "All tests passed"; then
  say "  ✗ 测试未全绿"
  FAIL=1
else
  say "  ✓ 全量测试通过"
fi

step "4/5 性能静态审计（tools/perf_audit.py）"
python3 tools/perf_audit.py || FAIL=1

step "5/5 构建（可选）"
if [[ "${1:-}" == "--build" ]]; then
  flutter build apk --release --target-platform android-arm64 2>&1 | tail -2
  APK="build/app/outputs/flutter-apk/app-release.apk"
  if [[ -f "$APK" ]]; then
    SIZE=$(du -h "$APK" | cut -f1)
    say "  APK: $APK ($SIZE)"
    cp -f "$APK" "${RELEASE_DIR:-/workspace/releases}/camby-${VER}-release-arm64.apk"
    say "  已复制到 ${RELEASE_DIR:-/workspace/releases}/camby-${VER}-release-arm64.apk"
  else
    say "  ✗ 构建产物缺失"
    FAIL=1
  fi
else
  say "  跳过（加 --build 执行）"
fi

say ""
if [[ $FAIL -eq 0 ]]; then
  say "✅ 发布门禁通过（v$VER / $CODE）"
else
  say "❌ 发布门禁未过，禁止推送 Release"
fi
exit $FAIL
