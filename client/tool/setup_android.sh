#!/usr/bin/env bash
#
# tool/setup_android.sh
#
# 生成 Android 平台目录（android/、gradle wrapper、启动图标等），
# 但**绝不覆盖**手写的 lib/、pubspec.yaml、analysis_options.yaml。
#
# 为什么需要这个脚本：本仓库只提交 Dart 代码与配置，平台目录交给 flutter create 生成。
# 手写 build.gradle / 图标二进制资源极易出错，生成才是正确姿势。
#
# 用法：
#   bash tool/setup_android.sh
#
# 它做四件事：
#   1. android/ **不存在**时：在临时目录执行 flutter create --platforms android 并拷进项目
#   2. android/ 已存在时：**跳过生成**，直接进入打补丁阶段
#      —— 因为 android/app/src/main/kotlin/.../MainActivity.kt 里有手写的原生通道
#      （音量 / 亮度 / 常亮 / 屏幕方向，见 lib/core/native_bridge.dart），
#      整个目录重新生成会把它冲掉。确实要重来请显式加 --force。
#   3. 给主 AndroidManifest.xml 补 INTERNET 权限；把 minSdk 提到 24
#      （dynamic_color 1.9 要求 minSdk >= 24，否则 AGP 会直接报合并失败）；
#      这两步都是幂等的，重复执行不会重复插入。
#   4. flutter pub get
#
# 用法：
#   bash tool/setup_android.sh          # 缺失则生成，已存在则只打补丁
#   bash tool/setup_android.sh --force  # 强制重新生成（原 android/ 备份为 android.bak/）

set -euo pipefail

PROJECT_NAME="lemonlite"
ORG="com.lemonlite"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "✗ 未找到 flutter 命令。请先安装 Flutter 稳定版（>= 3.27）并加入 PATH。" >&2
  exit 1
fi

echo "==> 项目目录：$ROOT"
flutter --version | head -n 1

# ------------------------------------------------- 1./2. 脚手架与拷贝
FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
fi

if [ -d android ] && [ "$FORCE" -eq 0 ]; then
  echo "==> android/ 已存在，跳过脚手架生成（保住手写的 MainActivity.kt 原生通道）"
  echo "    确实要重新生成：bash tool/setup_android.sh --force"
else
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  echo "==> 在临时目录生成 Android 脚手架"
  flutter create \
    --platforms android \
    --project-name "$PROJECT_NAME" \
    --org "$ORG" \
    --description "LemonLite" \
    "$TMP_DIR/scaffold" >/dev/null

  if [ -d android ]; then
    echo "==> 已存在 android/，备份为 android.bak/"
    rm -rf android.bak
    mv android android.bak
  fi
  cp -R "$TMP_DIR/scaffold/android" android
  echo "==> 已生成 android/"

  # .metadata 只在缺失时创建（它记录 Flutter 版本与迁移信息）
  if [ ! -f .metadata ]; then
    cp "$TMP_DIR/scaffold/.metadata" .metadata
  fi
fi

# ------------------------------------------------- 3. 打两个必要的补丁
python3 - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
manifest = os.path.join(root, 'android', 'app', 'src', 'main', 'AndroidManifest.xml')
gradle_files = [
    os.path.join(root, 'android', 'app', 'build.gradle.kts'),   # 新版 Flutter 默认 Kotlin DSL
    os.path.join(root, 'android', 'app', 'build.gradle'),       # 老版 Groovy DSL
]

# --- 3.1 INTERNET 权限 ---
# flutter create 只在 debug / profile 的 manifest 里加 INTERNET，
# release 包要联网访问 index.json 与小程序页面，必须补到主 manifest。
if os.path.exists(manifest):
    with open(manifest, encoding='utf-8') as handle:
        text = handle.read()
    if 'android.permission.INTERNET' in text:
        print('   · INTERNET 权限已存在，跳过')
    else:
        text = text.replace(
            '<application',
            '    <!-- 访问远端 index.json 与小程序页面需要联网 -->\n'
            '    <uses-permission android:name="android.permission.INTERNET"/>\n\n'
            '    <application',
            1,
        )
        with open(manifest, 'w', encoding='utf-8') as handle:
            handle.write(text)
        print('   ✓ 已补 INTERNET 权限')

    # 桌面显示名：flutter create 用的是小写项目名（lemonlite），改成 LemonLite
    with open(manifest, encoding='utf-8') as handle:
        text = handle.read()
    if 'android:label="lemonlite"' in text:
        text = text.replace('android:label="lemonlite"', 'android:label="LemonLite"')
        with open(manifest, 'w', encoding='utf-8') as handle:
            handle.write(text)
        print('   ✓ 桌面显示名已改为 LemonLite')
else:
    print('   ! 未找到 AndroidManifest.xml，请手动确认') 

# --- 3.2 minSdk = 24 ---
patched = False
for path in gradle_files:
    if not os.path.exists(path):
        continue
    with open(path, encoding='utf-8') as handle:
        text = handle.read()
    new = re.sub(
        r'minSdk\s*=\s*flutter\.minSdkVersion',
        'minSdk = 24  // dynamic_color 1.9 要求 minSdk >= 24',
        text,
    )
    new = re.sub(
        r'minSdkVersion\s+flutter\.minSdkVersion',
        'minSdkVersion 24  // dynamic_color 1.9 要求 minSdk >= 24',
        new,
    )
    if new != text:
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write(new)
        print(f'   ✓ 已在 {os.path.basename(path)} 中把 minSdk 设为 24')
        patched = True

if not patched:
    print('   ! 没有匹配到 minSdk = flutter.minSdkVersion，'
          '请手动确认 android/app/build.gradle(.kts) 里 minSdk >= 24')

# --- 3.3 debug 包允许明文 HTTP ---
# Android 9(API 28) 起默认禁止 cleartext HTTP。开发时经常要走
# http://192.168.x.x:8000 这种局域网测试服务器，所以只在 debug 变体里放开，
# release 保持默认的安全策略。
debug_manifest = os.path.join(root, 'android', 'app', 'src', 'debug', 'AndroidManifest.xml')
if os.path.exists(debug_manifest):
    with open(debug_manifest, encoding='utf-8') as handle:
        text = handle.read()
    if 'usesCleartextTraffic' in text:
        print('   · debug 明文 HTTP 已放开，跳过')
    else:
        if '<application' in text:
            text = text.replace(
                '<application',
                '<application android:usesCleartextTraffic="true"',
                1,
            )
        else:
            text = text.replace(
                '</manifest>',
                '    <!-- 仅 debug：允许连本地/局域网 HTTP 测试服务器 -->\n'
                '    <application android:usesCleartextTraffic="true" />\n'
                '</manifest>',
                1,
            )
        with open(debug_manifest, 'w', encoding='utf-8') as handle:
            handle.write(text)
        print('   ✓ 已在 debug manifest 中放开明文 HTTP（release 不受影响）')
else:
    print('   ! 未找到 debug AndroidManifest.xml，跳过明文 HTTP 设置')
PY

# ---------------------------------------------------------------- 4. 依赖
echo "==> flutter pub get"
flutter pub get

cat <<'EOF'

✓ 完成。接下来：

    flutter devices            # 确认手机 / 模拟器已连接
    flutter run -d <device-id>

自检（可选但推荐）：

    flutter analyze
    flutter test

EOF
