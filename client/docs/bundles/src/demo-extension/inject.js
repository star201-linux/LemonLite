// 扩展的脚本：整段会被宿主包进一个函数里，所以顶层 const 不会漏到页面全局。
(function () {
  function render(list) {
    var el = document.getElementById('lemonlite-sample-badge');
    if (!el) {
      el = document.createElement('div');
      el.id = 'lemonlite-sample-badge';
      (document.body || document.documentElement).appendChild(el);
    }
    el.textContent = '示例扩展生效中 · 包 ' + (list ? list.length : 0) + ' 个';
  }

  // 包清单是宿主最先注入的，正常这里已经能读到
  render(window.__LEMONLITE_BUNDLES__);

  // 页面可能还没 body，兜底等一下
  if (!document.body) {
    document.addEventListener('DOMContentLoaded', function () { render(window.__LEMONLITE_BUNDLES__); });
  }
})();
