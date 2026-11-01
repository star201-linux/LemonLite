#!/usr/bin/env bash
# scripts/build-apk.sh
#
# 在**有 Flutter SDK 的机器**上打一个测试包，并放到 dist/。
#
# 用法：
#   ./scripts/build-apk.sh              # release，arm64（绝大多数手机）
#   ./scripts/build-apk.sh debug        # debug 包（带调试符号，体积大）
#   ./scripts/build-apk.sh release all  # release，所有 ABI（体积大，通用）
#
# 注意：
#   * 这个脚本**不能**在手机容器里跑（那里没有 Flutter SDK，也没有
#     arm64 的 aapt2）。手机上的容器只适合改代码，出包用 GitHub Actions
#     （见 .github/workflows/build-apk.yml）或在一台电脑上跑本脚本。
#   * 没有 client/android/key.properties 时会回落到 debug 签名，
#     装到已有正式签名的机器上需要先卸载旧版。

set -euo pipefail

MODE="${1:-release}"
ABI="${2:-android-arm64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$ROOT/client"

if ! command -v flutter >/dev/null 2>&1; then
  echo "✗ 没找到 flutter。请先安装 Flutter 3.47+：https://docs.flutter.dev/get-started/install" >&2
  echo "  （手机容器里没有 Flutter SDK，这是预期行为 —— 出包请用 GitHub Actions）" >&2
  exit 1
fi

echo "==> flutter pub get"
cd "$CLIENT"
flutter pub get

if [ "$MODE" = "debug" ]; then
  echo "==> flutter build apk --debug（仅 $ABI）"
  flutter build apk --debug --target-platform "$ABI"
else
  if [ "$ABI" = "all" ]; then
    echo "==> flutter build apk --release（全部 ABI，通用包）"
    flutter build apk --release
  else
    echo "==> flutter build apk --release（仅 $ABI）"
    flutter build apk --release --target-platform "$ABI"
  fi
fi

mkdir -p "$ROOT/dist"
cp "$CLIENT"/build/app/outputs/flutter-apk/*.apk "$ROOT/dist/"
echo ""
echo "✓ 产物已复制到 $ROOT/dist/"
ls -lh "$ROOT/dist"/*.apk
