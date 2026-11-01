#!/usr/bin/env bash
# 从宿主机读容器里 LemonLite 的数据（Waydroid 没有 root，这是唯一可用的通道）
set -u
PKG=com.lemonlite.lemonlite
BASE="$HOME/.local/share/waydroid/data"

echo "=========== 1. 应用私有目录布局 ==========="
for d in "$BASE/data/$PKG" "$BASE/user/0/$PKG"; do
  [ -d "$d" ] && { echo "--- $d"; find "$d" -maxdepth 2 | head -30; }
done

echo
echo "=========== 2. 权限决定（shared_prefs）==========="
for f in "$BASE/data/$PKG/shared_prefs/"*.xml "$BASE/user/0/$PKG/shared_prefs/"*.xml; do
  [ -f "$f" ] || continue
  echo "--- $f"
  grep -oE '<(string|boolean|int) name="[^"]+">[^<]*' "$f" | sed 's/<[a-z]* name="//; s/">/ = /' | sort
done

echo
echo "=========== 3. 自检日志 ==========="
for f in "$BASE/data/$PKG/app_flutter/autotest.log" "$BASE/user/0/$PKG/app_flutter/autotest.log"; do
  [ -f "$f" ] && { echo "--- $f"; cat "$f"; }
done

echo
echo "=========== 4. 对话框截图 ==========="
find "$BASE" -path "*$PKG*" -name 'capture-*.png' 2>/dev/null | while read -r p; do
  echo "$(stat -c%s "$p") 字节  $p"
done

echo
echo "=========== 5. 小程序文件沙箱（appfiles）==========="
for root in "$BASE/media/0/Android/data/$PKG/files" "$BASE/data/$PKG/files"; do
  [ -d "$root" ] || continue
  echo "--- $root"
  find "$root" -type f | head -20
done

echo
echo "=========== 6. 自检报告 ==========="
for f in $(find "$BASE" -path "*appfiles*" -name 'report.json' 2>/dev/null | head -1) \
         $(find "$BASE" -path "*appfiles*" -name 'after-background.json' 2>/dev/null | head -1); do
  echo "--- $f"
  head -c 4000 "$f"
  echo
done
