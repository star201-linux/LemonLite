/* ============================================================================
 * app.js —— Markdown 预览的交互层
 * ----------------------------------------------------------------------------
 * 渲染全在 md.js，这里只做：草稿持久化、工具栏插入、链接接管、统计。
 * ==========================================================================*/
(function () {
  'use strict';

  var MD = window.LemonMD;
  var ll = window.lemonlite;
  var DRAFT_KEY = 'markdown.draft';

  var srcEl = document.getElementById('src');
  var previewEl = document.getElementById('preview');
  var savedEl = document.getElementById('stat-saved');

  if (ll) { ll.setTitle('Markdown 预览')['catch'](function () {}); }
  else { document.getElementById('no-bridge').style.display = 'block'; }

  var SAMPLE = [
    '# Markdown 预览',
    '',
    '这是一个跑在 **LemonLite** 里的小程序。页面配色全部来自宿主注入的',
    '`--md-*` 变量，所以切深色模式或换主题色时，*这里也会跟着变*。',
    '',
    '## 支持的语法',
    '',
    '- **粗体**、*斜体*、~~删除线~~、`行内代码`',
    '- 有序列表：',
    '  1. 第一项',
    '  2. 第二项',
    '- 引用与代码块：',
    '',
    '> 引用的内容会被渲染成带左侧色条的块。',
    '',
    '```js',
    "// 小程序侧调用宿主能力，全部返回 Promise",
    "lemonlite.setStorage('key', { value: 1 });",
    '```',
    '',
    '---',
    '',
    '链接会被交给系统浏览器打开，不会把 WebView 导航走：',
    '[Flutter 官网](https://flutter.dev)',
    '',
    '草稿会自动保存到宿主的本地存储，退出再进来还在。'
  ].join('\n');

  /* --------------------------- 渲染 --------------------------- */

  function render() {
    var text = srcEl.value;
    // md.js 内部先转义再做格式，所以这里直接把结果插进 DOM 是安全的
    previewEl.innerHTML = MD.render(text);

    var s = MD.stats(text);
    document.getElementById('stat-chars').textContent = s.chars + ' 字';
    document.getElementById('stat-lines').textContent = s.lines + ' 行';
    document.getElementById('stat-words').textContent = s.words + ' 词';
  }

  /* --------------------------- 草稿 --------------------------- */

  function markSaved(ok) {
    savedEl.textContent = ok ? '草稿已保存' : '草稿未保存';
  }

  var saveTimer = null;
  function scheduleSave() {
    if (!ll) return;
    if (saveTimer) clearTimeout(saveTimer);
    // 和渲染分开防抖：渲染要快（160ms），落盘可以慢一点（800ms）
    saveTimer = setTimeout(function () {
      ll.setStorage(DRAFT_KEY, srcEl.value)
        .then(function () { markSaved(true); })
        ['catch'](function () { markSaved(false); });
    }, 800);
  }

  var renderTimer = null;
  srcEl.addEventListener('input', function () {
    if (renderTimer) clearTimeout(renderTimer);
    renderTimer = setTimeout(render, 160);
    scheduleSave();
  });

  /* --------------------------- 工具栏 --------------------------- */

  var SNIPPETS = {
    h2: { wrap: ['## ', ''], fallback: '标题' },
    bold: { wrap: ['**', '**'], fallback: '粗体' },
    italic: { wrap: ['*', '*'], fallback: '斜体' },
    code: { wrap: ['`', '`'], fallback: 'code' },
    list: { wrap: ['- ', ''], fallback: '列表项' },
    quote: { wrap: ['> ', ''], fallback: '引用' },
    link: { wrap: ['[', '](https://)'], fallback: '链接文字' },
    fence: { wrap: ['```\n', '\n```'], fallback: '代码' }
  };

  function insert(kind) {
    var spec = SNIPPETS[kind];
    if (!spec) return;

    var start = srcEl.selectionStart;
    var end = srcEl.selectionEnd;
    var selected = srcEl.value.slice(start, end) || spec.fallback;

    var replacement = spec.wrap[0] + selected + spec.wrap[1];
    srcEl.value = srcEl.value.slice(0, start) + replacement + srcEl.value.slice(end);

    // 选中插入进去的内容本身，方便连续操作（比如连着加两处粗体）
    srcEl.focus();
    srcEl.setSelectionRange(start + spec.wrap[0].length, start + spec.wrap[0].length + selected.length);

    render();
    scheduleSave();
  }

  Array.prototype.forEach.call(document.querySelectorAll('[data-insert]'), function (btn) {
    btn.addEventListener('click', function () { insert(btn.getAttribute('data-insert')); });
  });

  /* --------------------------- 链接接管 --------------------------- */

  // 让 WebView 自己导航走的话，用户就离开小程序了，而且没有返回栈。
  // 所以这里拦住默认行为，改用宿主的 openUrl 交给系统浏览器。
  previewEl.addEventListener('click', function (ev) {
    var anchor = ev.target.closest ? ev.target.closest('.md-link') : null;
    if (!anchor) return;

    ev.preventDefault();
    var url = anchor.getAttribute('href');

    if (ll) {
      ll.openUrl(url)['catch'](function (err) {
        ll.showToast('打不开这个链接：' + ((err && err.message) || url))['catch'](function () {});
      });
    } else {
      window.open(url, '_blank', 'noopener');
    }
  });

  /* --------------------------- 启动 --------------------------- */

  function boot(draft) {
    srcEl.value = typeof draft === 'string' && draft.length ? draft : SAMPLE;
    render();
    markSaved(typeof draft === 'string' && draft.length > 0);
  }

  if (ll) {
    ll.getStorage(DRAFT_KEY, null)
      .then(function (res) { boot(res && res.value); })
      ['catch'](function () { boot(null); });
  } else {
    boot(null);
  }
})();
