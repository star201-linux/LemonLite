/* ============================================================================
 * app.js —— 2048 的交互层
 * ----------------------------------------------------------------------------
 * 规则全在 game.js，这里只做：渲染、手势/键盘、最高分持久化。
 * ==========================================================================*/
(function () {
  'use strict';

  var G = window.Lemon2048;
  var ll = window.lemonlite;
  var BEST_KEY = 'game2048.best';

  var boardEl = document.getElementById('board');
  var scoreEl = document.getElementById('score');
  var bestEl = document.getElementById('best');
  var overlayEl = document.getElementById('overlay');
  var overlayTextEl = document.getElementById('overlay-text');
  var overlaySubEl = document.getElementById('overlay-sub');
  var undoBtn = document.getElementById('btn-undo');

  if (ll) { ll.setTitle('2048')['catch'](function () {}); }
  else { document.getElementById('no-bridge').style.display = 'block'; }

  // 先把 16 个格子建出来，之后每次渲染只改文字和 class（不重建 DOM）
  var cells = [];
  for (var i = 0; i < G.CELLS; i++) {
    var cell = document.createElement('div');
    cell.className = 'cell empty';
    boardEl.appendChild(cell);
    cells.push(cell);
  }

  var state = G.newGame(0);
  var best = 0;

  /* --------------------------- 渲染 --------------------------- */

  function tileClass(value) {
    if (value <= 2048) return 'v' + value;
    return 'vbig';
  }

  function render() {
    for (var i = 0; i < G.CELLS; i++) {
      var value = state.grid[i];
      var cell = cells[i];

      // 只改变化的部分：classList 全量重建会让 CSS 过渡每次都重来
      var next = value === 0 ? 'cell empty' : 'cell ' + tileClass(value);
      if (cell.className !== next) cell.className = next;

      var text = value === 0 ? '' : String(value);
      if (cell.textContent !== text) cell.textContent = text;

      // 四位数需要更小的字号，否则会在格子里换行
      if (value >= 1000) cell.classList.add('d4');
      else if (value >= 100) cell.classList.add('d3');
    }

    scoreEl.textContent = String(state.score);
    bestEl.textContent = String(state.best);
    undoBtn.disabled = !state.undo;

    if (state.over) {
      overlayTextEl.textContent = '没有可走的方向了';
      overlaySubEl.textContent = '本局得分 ' + state.score + ' · 最大方块 ' + G.maxTile(state.grid);
      overlayEl.classList.add('show');
    } else if (state.won && !overlayEl.classList.contains('show')) {
      // 首次合成 2048：只提示一次，点掉之后继续玩
      overlayTextEl.textContent = '合成 2048 了';
      overlaySubEl.textContent = '点下面继续，还能往上叠';
      overlayEl.classList.add('show');
    }
  }

  /** 给新出现的方块加一个缩放动画。 */
  function popNewTiles() {
    (state.newTiles || []).forEach(function (index) {
      var cell = cells[index];
      if (!cell) return;
      cell.classList.remove('pop');
      // 强制重排，否则连续两次同类动画不会重新播放
      void cell.offsetWidth;
      cell.classList.add('pop');
    });
  }

  function persistBest() {
    // 这两件事必须分开：即使没有桥接（拿不到存储），本局之内的高分也要能带到下一局。
    // 早期版本把「更新本地 best」和「写存储」写在了同一个提前 return 后面，
    // 结果没有桥接时 best 永远是 0 —— 点「新游戏」最高分就归零了。
    if (best === state.best) return;
    best = state.best;
    if (ll) { ll.setStorage(BEST_KEY, best)['catch'](function () {}); }
  }

  /* --------------------------- 操作 --------------------------- */

  function act(dir) {
    if (overlayEl.classList.contains('show') && !state.over) {
      // 胜利提示挡着的时候，先让路再走
      overlayEl.classList.remove('show');
    }
    if (G.step(state, dir)) {
      render();
      popNewTiles();
      persistBest();
    }
  }

  document.getElementById('btn-new').addEventListener('click', function () {
    state = G.newGame(best);
    overlayEl.classList.remove('show');
    render();
    popNewTiles();
  });

  undoBtn.addEventListener('click', function () {
    if (G.undo(state)) {
      overlayEl.classList.remove('show');
      render();
    }
  });

  overlayEl.addEventListener('click', function () {
    if (state.over) {
      state = G.newGame(best);
      overlayEl.classList.remove('show');
      render();
      popNewTiles();
    } else {
      overlayEl.classList.remove('show');
    }
  });

  /* --------------------------- 手势 --------------------------- */

  var startX = 0, startY = 0, tracking = false;
  var THRESHOLD = 24; // 低于这个位移当作误触，避免轻微抖动就滑一格

  boardEl.addEventListener('touchstart', function (ev) {
    if (ev.touches.length !== 1) return;
    startX = ev.touches[0].clientX;
    startY = ev.touches[0].clientY;
    tracking = true;
  }, { passive: true });

  boardEl.addEventListener('touchmove', function (ev) {
    // 阻止页面跟着一起滚，否则滑到一半页面就跑了
    if (tracking) ev.preventDefault();
  }, { passive: false });

  boardEl.addEventListener('touchend', function (ev) {
    if (!tracking) return;
    tracking = false;

    var touch = ev.changedTouches[0];
    var dx = touch.clientX - startX;
    var dy = touch.clientY - startY;

    if (Math.abs(dx) < THRESHOLD && Math.abs(dy) < THRESHOLD) return;

    if (Math.abs(dx) > Math.abs(dy)) {
      act(dx > 0 ? G.DIR.RIGHT : G.DIR.LEFT);
    } else {
      act(dy > 0 ? G.DIR.DOWN : G.DIR.UP);
    }
  });

  document.addEventListener('keydown', function (ev) {
    var map = {
      ArrowUp: G.DIR.UP, ArrowRight: G.DIR.RIGHT,
      ArrowDown: G.DIR.DOWN, ArrowLeft: G.DIR.LEFT,
      w: G.DIR.UP, d: G.DIR.RIGHT, s: G.DIR.DOWN, a: G.DIR.LEFT
    };
    var dir = map[ev.key];
    if (dir === undefined) return;
    ev.preventDefault();
    act(dir);
  });

  /* --------------------------- 启动 --------------------------- */

  if (ll) {
    ll.getStorage(BEST_KEY, 0)
      .then(function (res) {
        best = typeof res.value === 'number' ? res.value : 0;
        state = G.newGame(best);
        render();
        popNewTiles();
      })
      ['catch'](function () {
        state = G.newGame(0);
        render();
      });
  } else {
    render();
    popNewTiles();
  }
})();
