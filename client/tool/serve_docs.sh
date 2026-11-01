#!/usr/bin/env bash
#
# tool/serve_docs.sh
#
# 把 docs/ 当成市场服务器跑起来，方便手机在同一 WiFi 下连调（改了 index.json 立刻生效）。
#
# 用法：
#   bash tool/serve_docs.sh [端口]        # 默认 8000
#
# 然后用手机浏览器打开提示里给出的地址确认能访问，再把这个地址填进
# App 的「设置 → 开发者选项 → 自定义服务器地址」。
#
# 注意：这里必须绑定 0.0.0.0（手机要从局域网访问），所以请在可信网络里使用。
# 正式测试环境建议用 HTTPS 静态托管（GitHub Pages / 对象存储），不要长期开这个。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8000}"
DOCS="$ROOT/docs"

if [ ! -f "$DOCS/index.json" ]; then
  echo "✗ 找不到 $DOCS/index.json" >&2
  exit 1
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<本机局域网IP>}"

cat <<EOF
市场服务器已就绪（Ctrl+C 停止）

  index.json   http://$IP:$PORT/index.json
  示例小程序    http://$IP:$PORT/demo/index.html

把下面这个地址填进 App 的「设置 → 开发者选项 → 自定义服务器地址」：

  http://$IP:$PORT

EOF

cd "$DOCS"
exec python3 -m http.server "$PORT" --bind 0.0.0.0
