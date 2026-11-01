/* ============================================================================
 * md.js —— 一个够用的 Markdown 渲染器（无 DOM 依赖，可在 node 里单测）
 * ----------------------------------------------------------------------------
 * 设计原则，按重要性排序：
 *
 *   1) **先转义，再做格式**。整段文本先 escapeHtml，再在上面匹配语法。
 *      反过来的话，`<img src=x onerror=...>` 会被当成 HTML 直接插进预览区。
 *      这个顺序没有例外。
 *   2) **支持子集，不支持就原样显示**。宁可少支持几种语法，也不要为了
 *      「看起来支持」而写出边界行为诡异的解析器。当前支持：
 *        标题 #~###### / 段落 / 粗体 / 斜体 / 删除线 / 行内代码
 *        围栏代码块 / 无序列表 / 有序列表 / 引用 / 分割线 / 链接 / 图片
 *      不支持：表格、嵌套列表、任务列表、脚注、HTML 内联。
 *   3) **链接不直接跳转**。渲染成带 class 的 <a>，由页面决定怎么打开 ——
 *      在小程序里应该走 lemonlite.openUrl 交给系统浏览器，而不是让 WebView
 *      自己导航走（那样用户就离开小程序了，且没有返回栈）。
 * ==========================================================================*/
(function (global) {
  'use strict';

  var PLACEHOLDER = '\u0001';

  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /**
   * 只放行明确的几种协议与相对路径。
   * 拦掉 javascript: / data: / vbscript: —— 这些是 XSS 的常见入口。
   */
  function safeUrl(url) {
    var u = String(url).trim();
    if (/^(https?:\/\/|mailto:|tel:)/i.test(u)) return u;
    if (/^[./#]/.test(u)) return u;
    return null;
  }

  function linkTag(url, text, isImage) {
    var safe = safeUrl(url);
    if (!safe) return text; // 不安全就退化成纯文本，而不是悄悄丢掉

    if (isImage) {
      return '<img class="md-img" src="' + safe + '" alt="' + text + '" loading="lazy">';
    }
    // href 照常写，点击行为由页面接管（见 app.js 的 .md-link 处理）
    return '<a class="md-link" href="' + safe + '">' + text + '</a>';
  }

  /** 行内语法。输入必须是**已经转义过**的文本。 */
  function inline(text) {
    var s = text;
    var codes = [];

    // 行内代码最先抽走 —— 里面的 * _ [ ] 都不该再被当成语法
    s = s.replace(/`([^`]+)`/g, function (m, code) {
      codes.push(code);
      return PLACEHOLDER + (codes.length - 1) + PLACEHOLDER;
    });

    // 图片要在链接之前匹配，否则 ![]() 会被链接规则先吃掉
    s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, function (m, alt, url) {
      return linkTag(url, alt, true);
    });
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (m, label, url) {
      return linkTag(url, label, false);
    });

    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/__([^_]+)__/g, '<strong>$1</strong>');
    s = s.replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
    s = s.replace(/(^|[^_])_([^_]+)_/g, '$1<em>$2</em>');
    s = s.replace(/~~([^~]+)~~/g, '<del>$1</del>');

    s = s.replace(new RegExp(PLACEHOLDER + '(\\d+)' + PLACEHOLDER, 'g'), function (m, idx) {
      return '<code class="md-code">' + codes[Number(idx)] + '</code>';
    });

    return s;
  }

  var HR = /^\s{0,3}([-*_])\s*(\1\s*){2,}$/;
  var HEADING = /^(#{1,6})\s+(.*)$/;
  var FENCE = /^\s*```(.*)$/;
  var QUOTE = /^\s*>/;
  var ULIST = /^\s*[-*+]\s+/;
  var OLIST = /^\s*\d+\.\s+/;

  function isBlockStart(line) {
    return HEADING.test(line) || FENCE.test(line) || HR.test(line) ||
      QUOTE.test(line) || ULIST.test(line) || OLIST.test(line);
  }

  function render(src) {
    var lines = String(src).replace(/\r\n?/g, '\n').split('\n');
    var out = [];
    var i = 0;

    while (i < lines.length) {
      var line = lines[i];

      // ---- 围栏代码块 ----
      var fence = line.match(FENCE);
      if (fence) {
        var lang = fence[1].trim();
        var body = [];
        i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) {
          body.push(lines[i]);
          i++;
        }
        i++; // 跳过收尾的 ```
        out.push('<pre class="md-pre"><code' +
          (lang ? ' data-lang="' + escapeHtml(lang) + '"' : '') + '>' +
          escapeHtml(body.join('\n')) + '</code></pre>');
        continue;
      }

      // ---- 空行 ----
      if (/^\s*$/.test(line)) { i++; continue; }

      // ---- 分割线 ----
      if (HR.test(line)) { out.push('<hr class="md-hr">'); i++; continue; }

      // ---- 标题 ----
      var h = line.match(HEADING);
      if (h) {
        var level = h[1].length;
        out.push('<h' + level + ' class="md-h' + level + '">' + inline(escapeHtml(h[2].trim())) + '</h' + level + '>');
        i++;
        continue;
      }

      // ---- 引用：剥掉 > 后递归，天然支持嵌套 ----
      if (QUOTE.test(line)) {
        var quoted = [];
        // 引用的「懒续行」只对段落行成立：遇到 # / ``` / 列表 这类块开头就该收尾，
        // 否则 `> 引用` 后面紧跟的标题会被错误地吞进引用块里
        while (i < lines.length && (QUOTE.test(lines[i]) ||
          (quoted.length && !/^\s*$/.test(lines[i]) && !isBlockStart(lines[i])))) {
          quoted.push(lines[i].replace(/^\s*>\s?/, ''));
          i++;
        }
        out.push('<blockquote class="md-quote">' + render(quoted.join('\n')) + '</blockquote>');
        continue;
      }

      // ---- 列表（单层，不做嵌套 —— 见文件头第 2 条） ----
      if (ULIST.test(line) || OLIST.test(line)) {
        var ordered = OLIST.test(line);
        var items = [];
        while (i < lines.length && (ordered ? OLIST.test(lines[i]) : ULIST.test(lines[i]))) {
          items.push(lines[i].replace(/^\s*(?:[-*+]|\d+\.)\s+/, ''));
          i++;
        }
        var tag = ordered ? 'ol' : 'ul';
        out.push('<' + tag + ' class="md-list">' + items.map(function (item) {
          return '<li>' + inline(escapeHtml(item)) + '</li>';
        }).join('') + '</' + tag + '>');
        continue;
      }

      // ---- 段落：连续非空、且不是其它块开头的行 ----
      var para = [];
      while (i < lines.length && !/^\s*$/.test(lines[i]) && !isBlockStart(lines[i])) {
        para.push(lines[i]);
        i++;
      }
      if (para.length) {
        // 段内换行按 Markdown 规则折叠成空格（浏览器天然如此），不额外插 <br>
        out.push('<p class="md-p">' + inline(escapeHtml(para.join('\n'))) + '</p>');
      } else {
        // 兜底：不认识的块开头，原样吐出去，避免死循环
        out.push('<p class="md-p">' + inline(escapeHtml(line)) + '</p>');
        i++;
      }
    }

    return out.join('\n');
  }

  /** 粗略的统计，给页面上显示「N 字 / M 行」用。 */
  function stats(src) {
    var text = String(src);
    return {
      chars: text.length,
      lines: text ? text.split('\n').length : 0,
      words: (text.match(/[\u4e00-\u9fa5]|[a-zA-Z0-9_]+/g) || []).length
    };
  }

  var api = { render: render, escapeHtml: escapeHtml, safeUrl: safeUrl, stats: stats };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.LemonMD = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
