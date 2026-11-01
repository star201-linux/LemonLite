/* ============================================================================
 * app.js —— 配色实验室的交互层
 * ----------------------------------------------------------------------------
 * 算法全在 color.js（纯函数、可单测），这里只负责取色、渲染、复制。
 * ==========================================================================*/
(function () {
  'use strict';

  var C = window.LemonColor;
  var ll = window.lemonlite;

  var seedInput = document.getElementById('seed');
  var hexInput = document.getElementById('seed-hex');
  var rolesEl = document.getElementById('host-roles');
  var rampEl = document.getElementById('ramp');
  var previewEl = document.getElementById('preview');
  var contrastEl = document.getElementById('contrast');
  var toastEl = document.getElementById('toast');

  if (ll) { ll.setTitle('配色实验室')['catch'](function () {}); }
  else { document.getElementById('no-bridge').style.display = 'block'; }

  var PRESETS = [
    '#6750a4', '#8e7cc3', '#5e60ce', '#3949ab', '#0b57d0', '#0288d1',
    '#00838f', '#00696d', '#00897b', '#2e7d32', '#689f38', '#827717',
    '#f9a825', '#ef6c00', '#e64a19', '#c62828', '#d81b60', '#ad1457',
    '#880e4f', '#5d4037', '#795548', '#455a64', '#546e7a', '#616161'
  ];

  /* --------------------------- 宿主主题 --------------------------- */

  // 按「一对容器色」组织，这样每一格都能自己决定文字用黑还是白
  var HOST_ROLES = [
    ['primary', 'on-primary'],
    ['primary-container', 'on-primary-container'],
    ['secondary', 'on-secondary'],
    ['secondary-container', 'on-secondary-container'],
    ['tertiary', 'on-tertiary'],
    ['error', 'error-container'],
    ['surface', 'on-surface'],
    ['surface-container-highest', 'on-surface-variant']
  ];

  function renderHostRoles() {
    var theme = ll && ll.theme;
    var colors = theme && theme.colors;

    rolesEl.textContent = '';

    HOST_ROLES.forEach(function (pair) {
      var bg = colors ? colors[pair[0]] : null;
      var fg = colors ? colors[pair[1]] : null;

      var cell = document.createElement('div');
      cell.className = 'role';
      // 有真实颜色就写死成 inline style；没桥接时留空，靠 CSS 的边框兜底
      if (bg) cell.style.background = bg;
      if (fg) cell.style.color = fg;
      cell.style.borderColor = 'transparent';

      var name = document.createElement('div');
      name.className = 'name';
      name.textContent = '--md-' + pair[0];

      var hex = document.createElement('div');
      hex.className = 'hex';
      hex.textContent = bg || '（无宿主）';

      cell.appendChild(name);
      cell.appendChild(hex);
      rolesEl.appendChild(cell);
    });
  }

  /* --------------------------- 色调板 --------------------------- */

  function renderPresets() {
    var box = document.getElementById('presets');
    PRESETS.forEach(function (hex) {
      var b = document.createElement('button');
      b.className = 'preset';
      b.style.background = hex;
      b.setAttribute('aria-label', hex);
      b.addEventListener('click', function () { setSeed(hex); });
      box.appendChild(b);
    });
  }

  function renderRamp(seed) {
    var ramp = C.tonalRamp(seed);
    rampEl.textContent = '';

    ramp.forEach(function (item) {
      var cell = document.createElement('div');
      cell.className = 'tone';
      cell.style.background = item.hex;
      cell.style.color = item.on;
      cell.style.borderColor = 'transparent';

      var t = document.createElement('div');
      t.className = 't';
      t.textContent = item.tone;

      var h = document.createElement('div');
      h.className = 'h';
      h.textContent = item.hex;

      cell.appendChild(t);
      cell.appendChild(h);
      rampEl.appendChild(cell);
    });
  }

  /* --------------------------- 预览与对比度 --------------------------- */

  function renderPreview(seed) {
    var s = C.schemeFromSeed(seed);

    previewEl.style.background = s.surface;
    previewEl.style.color = s.onSurface;
    previewEl.textContent = '';

    var title = document.createElement('div');
    title.textContent = '标题：surface 上的 onSurface';
    title.style.fontWeight = '600';
    title.style.marginBottom = '8px';

    var body = document.createElement('div');
    body.textContent = '正文用 onSurface。下面是 primaryContainer 上的 onPrimaryContainer。';
    body.style.fontSize = '13px';
    body.style.marginBottom = '10px';

    var chip = document.createElement('div');
    chip.textContent = 'primaryContainer 示例';
    chip.style.background = s.primaryContainer;
    chip.style.color = s.onPrimaryContainer;
    chip.style.padding = '10px 12px';
    chip.style.borderRadius = '12px';
    chip.style.fontSize = '13px';
    chip.style.marginBottom = '10px';

    var btn = document.createElement('div');
    btn.textContent = '按钮：primary 上的 onPrimary';
    btn.style.background = s.primary;
    btn.style.color = s.onPrimary;
    btn.style.padding = '10px 14px';
    btn.style.borderRadius = '999px';
    btn.style.textAlign = 'center';
    btn.style.fontSize = '13px';

    previewEl.appendChild(title);
    previewEl.appendChild(body);
    previewEl.appendChild(chip);
    previewEl.appendChild(btn);

    // 把真实对比度算出来，别嘴上说「好看」
    var pairs = [
      ['正文 onSurface / surface', s.onSurface, s.surface],
      ['按钮 onPrimary / primary', s.onPrimary, s.primary],
      ['色块 onPrimaryContainer / primaryContainer', s.onPrimaryContainer, s.primaryContainer]
    ];

    contrastEl.textContent = '';
    pairs.forEach(function (p) {
      var ratio = C.contrastRatio(p[1], p[2]);
      var line = document.createElement('div');
      line.innerHTML = p[0] + '：<span class="' + (ratio >= 4.5 ? 'ok' : 'bad') + '">' +
        ratio.toFixed(2) + ':1</span>' + (ratio >= 4.5 ? '' : '（低于 WCAG AA 的 4.5:1）');
      contrastEl.appendChild(line);
    });
  }

  /* --------------------------- 状态同步 --------------------------- */

  var current = '#6750a4';

  function setSeed(hex, skipInputs) {
    var normalized = C.normalizeHex(hex);
    if (!normalized) return false;

    current = normalized;
    if (!skipInputs) {
      seedInput.value = normalized;
      hexInput.value = normalized;
    }
    renderRamp(normalized);
    renderPreview(normalized);
    return true;
  }

  seedInput.addEventListener('input', function () {
    setSeed(seedInput.value, true);
    hexInput.value = seedInput.value;
  });

  hexInput.addEventListener('input', function () {
    var v = hexInput.value.trim();
    // 输入到一半（比如 "#67"）时不报错也不重置，等它输完
    if (C.normalizeHex(v)) {
      setSeed(v, true);
      seedInput.value = C.normalizeHex(v);
    }
  });

  /* --------------------------- 复制 --------------------------- */

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    // 老 WebView 上 navigator.clipboard 不存在，退回 execCommand
    return new Promise(function (resolve) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); } catch (e) { /* 忽略：下面会提示失败 */ }
      document.body.removeChild(ta);
      resolve();
    });
  }

  document.getElementById('btn-copy').addEventListener('click', function () {
    var text = C.toCssVariables(current);
    copyText(text).then(function () {
      toastEl.textContent = '已复制 ' + Object.keys(C.schemeFromSeed(current)).length + ' 个变量到剪贴板';
      if (ll) { ll.showToast('CSS 变量已复制')['catch'](function () {}); }
      setTimeout(function () { toastEl.textContent = ''; }, 3000);
    });
  });

  document.getElementById('btn-from-host').addEventListener('click', function () {
    var theme = ll && ll.theme;
    var primary = theme && theme.colors && theme.colors.primary;
    if (!primary) {
      toastEl.textContent = '当前拿不到宿主主色（没有桥接？）';
      return;
    }
    setSeed(primary);
    toastEl.textContent = '已取宿主主色 ' + primary + ' 作为种子色';
  });

  /* --------------------------- 启动 --------------------------- */

  renderPresets();
  renderHostRoles();
  setSeed(current);

  if (ll) {
    // 宿主切主题时同步刷新顶部那排角色色（能直观看到「主题继承是实时的」）
    ll.onThemeChange(function () { renderHostRoles(); });
  }
})();
