/* ============================================================================
 * app.js —— 二维码生成页的交互层
 * ----------------------------------------------------------------------------
 * 只做三件事：读输入 → 调 qr.js 编码 → 画到 canvas。
 * 编码逻辑全在 qr.js 里（纯函数，可在 node 里单测），这里不掺任何算法。
 * ==========================================================================*/
(function () {
  'use strict';

  var SAMPLE = 'https://star201-linux.github.io/';
  var QUIET_ZONE = 4; // 静默区：规范要求四周各留 4 个模块，否则扫描器可能找不到边界

  var input = document.getElementById('text');
  var canvas = document.getElementById('qr');
  var metaEl = document.getElementById('meta');
  var errorEl = document.getElementById('error');
  var ll = window.lemonlite;

  if (ll) { ll.setTitle('二维码生成')['catch'](function () {}); }
  else { document.getElementById('no-bridge').style.display = 'block'; }

  /* ------------------------------- 绘制 ------------------------------- */

  function draw(result) {
    var total = result.size + QUIET_ZONE * 2;
    var dpr = window.devicePixelRatio || 1;

    // 每个模块取整数个物理像素，避免缩放产生半像素导致边缘模糊 —— 模糊会直接
    // 影响扫描成功率，所以这里宁可留一点空白也不做平滑缩放。
    var cssWidth = Math.min(320, Math.max(160, window.innerWidth - 96));
    var scale = Math.max(1, Math.floor((cssWidth * dpr) / total));

    canvas.width = total * scale;
    canvas.height = total * scale;
    canvas.style.width = cssWidth + 'px';

    var ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#000000';

    for (var row = 0; row < result.size; row++) {
      for (var col = 0; col < result.size; col++) {
        if (result.modules[row * result.size + col]) {
          ctx.fillRect((col + QUIET_ZONE) * scale, (row + QUIET_ZONE) * scale, scale, scale);
        }
      }
    }
  }

  /* ------------------------------- 状态 ------------------------------- */

  function chip(text, warn) {
    var el = document.createElement('span');
    el.className = warn ? 'chip warn' : 'chip';
    el.textContent = text;
    return el;
  }

  function showError(message) {
    errorEl.textContent = message;
    errorEl.style.display = 'block';
    metaEl.textContent = '';
    // 出错时把画布清成空白，避免残留上一张二维码让人误以为是最新的
    var ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
  }

  function render() {
    var text = input.value;

    if (!text) {
      errorEl.style.display = 'none';
      metaEl.textContent = '';
      var ctx = canvas.getContext('2d');
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      return;
    }

    var result;
    try {
      result = window.LemonQR.encode(text);
    } catch (err) {
      showError(err && err.message ? err.message : String(err));
      return;
    }

    errorEl.style.display = 'none';
    draw(result);

    var bytes = new TextEncoder().encode(text).length;
    metaEl.textContent = '';
    metaEl.appendChild(chip('版本 v' + result.version));
    metaEl.appendChild(chip('纠错 M'));
    metaEl.appendChild(chip('掩码 ' + result.mask));
    metaEl.appendChild(chip('矩阵 ' + result.size + '×' + result.size));
    metaEl.appendChild(chip(bytes + ' / ' + window.LemonQR.maxBytes() + ' 字节', bytes > 800));
  }

  /* ------------------------------- 输入 ------------------------------- */

  var timer = null;
  function schedule() {
    if (timer) clearTimeout(timer);
    // 防抖：每敲一个字就重算 + 重绘在长文本下会明显掉帧
    timer = setTimeout(render, 160);
  }

  input.addEventListener('input', schedule);

  document.getElementById('btn-clear').addEventListener('click', function () {
    input.value = '';
    render();
    input.focus();
  });

  document.getElementById('btn-sample').addEventListener('click', function () {
    input.value = SAMPLE;
    render();
  });

  /* ------------------------------- 启动 ------------------------------- */

  input.value = SAMPLE;
  render();
})();
