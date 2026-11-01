# 放置小程序的位置

把每个小程序的 HTML（以及它用到的 CSS / JS / 图片）放到自己的子目录里，例如：

```
docs/apps/hello/index.html
docs/apps/hello/style.css
docs/apps/hello/app.js
```

然后在 `docs/index.json` 的 `apps` 里加一条，`url` 写**相对路径**即可：

```json
{
  "id": "hello",
  "name": "Hello",
  "url": "apps/hello/index.html"
}
```

框架会用服务器根地址解析这个相对路径，所以换域名 / 换仓库名时不用改 `index.json`。

> 一个文件就能是一个完整小程序：视图见 `docs/demo/index.html`
> （它在 `index.json` 里被多个条目复用，通过 `?title=xxx` 区分标题）。

---

## 这里已经有的 7 个示例

`index.json` 里挂着的这些不是占位，是**真能跑**的页面：

| 目录 | 名字 | 说明 |
| --- | --- | --- |
| `todo/` | 轻记事 | 待办清单。重点在**从存储读出来的数据先过一遍 `sanitize()`** —— 那份数据可能来自旧版本，直接当成合法结构用，一个脏字段就能让整个列表渲染不出来。 |
| `weather/` | 天气卡片 | 走 `lemonlite.request` 拉 Open-Meteo 的真实数据（宿主 dio 发出，不受 CORS 限制；没有桥接时退回 `fetch`）。深色主题或当地夜间时切成夜间形态，结果缓存在宿主存储里，断网还能看上一次的。 |
| `pomodoro/` | 番茄钟 | 计时按**真实经过的秒数**推进，不是「每秒减一」—— WebView 在后台会被降频，固定减一的写法会让计时越走越慢。溢出到下一阶段的时间会被带过去。 |
| `markdown/` | Markdown 预览 | `md.js` 是自写的渲染器：**先转义 HTML 再做格式**，所以 `<img onerror=…>` 这类输入不会被当成标签执行。链接由页面接管，走 `lemonlite.openUrl` 交给系统浏览器，不会把 WebView 导航走。 |
| `qrcode/` | 二维码生成 | `qr.js` 是自写的 QR 编码器（Byte 模式 / 纠错等级 M / 版本 1–40 自动选择）。不引任何 CDN —— 市场服务器可能在内网或离线，引外部脚本就等于把「能不能用」押在别人身上。 |
| `palette/` | 配色实验室 | `color.js` 把 tone 当作 CIELAB 的 L\*，二分反解 HSL 的 lightness，所以**亮度是按规范来的**；色相与彩度随 tone 的变化仍是近似（真正的 M3 在 HCT 空间保持 chroma）。页面会实时算出各组的 WCAG 对比度，不达标的标红。 |
| `2048/` | 2048 | `game.js` 是纯规则层（一维数组 + 四向滑动），方块颜色全部映射到 `--md-*` 角色，所以跟着宿主主题走。最高分存进宿主存储。 |

### 为什么把逻辑拆成单独的文件

每个小程序都是「纯逻辑 `.js` + 页面 `index.html` + 交互 `app.js`」三件套。纯逻辑层结尾挂了

```js
if (typeof module !== 'undefined' && module.exports) module.exports = api;
```

所以同一个文件既能被 `<script>` 直接加载，也能在 node 里 `require` 出来跑断言 —— 这几个模块的
单元测试就是这么做的（滑动的合并规则、Markdown 的转义顺序、色调的亮度对齐，都是容易被写错、
又只能靠跑一遍才能确认的地方）。
