/* ============================================================================
 * app.js —— 番茄钟的交互层
 * ----------------------------------------------------------------------------
 * 状态机全在 timer.js，这里只做：按真实时间驱动 tick、渲染、提示、持久化。
 * ==========================================================================*/
(function () {
  'use strict';

  var T = window.LemonTimer;
  var ll = window.lemonlite;
  var KEY = 'pomodoro.completed';

  // 圆环周长 = 2πr = 2π×96 ≈ 603.19，和 HTML 里 stroke-dasharray 的值必须一致
  var CIRCUMFERENCE = 2 * Math.PI * 96;
  var TICK_MS = 250;

  var clockEl = document.getElementById('clock');
  var phaseEl = document.getElementById('phase');
  var barEl = document.getElementById('bar');
  var toggleBtn = document.getElementById('btn-toggle');
  var completedEl = document.getElementById('stat-completed');
  var stateEl = document.getElementById('stat-state');

  if (ll) { ll.setTitle('番茄钟')['catch'](function () {}); }
  else { document.getElementById('no-bridge').style.display = 'block'; }

  var LENGTHS = [
    { label: '15 / 3', focus: 15, brk: 3 },
    { label: '25 / 5', focus: 25, brk: 5 },
    { label: '45 / 10', focus: 45, brk: 10 },
    { label: '50 / 10', focus: 50, brk: 10 }
  ];

  var current = LENGTHS[1];
  var state = T.create(current.focus, current.brk);
  var timer = null;
  var lastTick = 0;
  var bestCompleted = 0;

  /* --------------------------- 渲染 --------------------------- */

  function render() {
    clockEl.textContent = T.formatClock(state.remaining);
    phaseEl.textContent = state.phase === T.PHASE.FOCUS ? '专注' : '休息';
    document.body.classList.toggle('break', state.phase === T.PHASE.BREAK);

    var p = T.progress(state);
    barEl.setAttribute('stroke-dashoffset', String(CIRCUMFERENCE * (1 - p)));

    toggleBtn.textContent = state.running ? '暂停' : (state.remaining === phaseTotal() ? '开始' : '继续');
    completedEl.textContent = '已完成 ' + state.completed + ' 轮';
    stateEl.textContent = state.running
      ? (state.phase === T.PHASE.FOCUS ? '专注中' : '休息中')
      : (state.remaining === phaseTotal() ? '未开始' : '已暂停');
  }

  function phaseTotal() {
    return state.phase === T.PHASE.FOCUS ? state.focusSeconds : state.breakSeconds;
  }

  /* --------------------------- 计时 --------------------------- */

  function loop() {
    var now = Date.now();
    // 用真实经过的时间去推进，而不是固定减 1 —— 定时器被降频时时间才不会走歪
    var elapsed = (now - lastTick) / 1000;
    lastTick = now;

    var result = T.tick(state, elapsed);

    if (result.finished) {
      onPhaseEnd(result.phase);
    }
    render();
  }

  function onPhaseEnd(endedPhase) {
    if (endedPhase === T.PHASE.FOCUS) {
      persistCompleted();
      if (ll) ll.showToast('专注结束，休息一下')['catch'](function () {});
    } else if (ll) {
      ll.showToast('休息结束，继续专注')['catch'](function () {});
    }

    // 自动接着跑下一阶段：番茄钟的使用场景就是「别让我再点一次」
    state.running = true;
    lastTick = Date.now();
  }

  function startLoop() {
    if (timer) return;
    lastTick = Date.now();
    timer = setInterval(loop, TICK_MS);
  }

  function stopLoop() {
    if (!timer) return;
    clearInterval(timer);
    timer = null;
  }

  /* --------------------------- 持久化 --------------------------- */

  function persistCompleted() {
    if (state.completed > bestCompleted) bestCompleted = state.completed;
    if (ll) { ll.setStorage(KEY, bestCompleted)['catch'](function () {}); }
  }

  /* --------------------------- 事件 --------------------------- */

  toggleBtn.addEventListener('click', function () {
    T.toggle(state);
    if (state.running) startLoop(); else stopLoop();
    render();
  });

  document.getElementById('btn-reset').addEventListener('click', function () {
    T.reset(state);
    stopLoop();
    render();
  });

  document.getElementById('btn-skip').addEventListener('click', function () {
    T.skip(state);
    stopLoop();
    render();
  });

  function renderLengths() {
    var box = document.getElementById('lengths');
    box.textContent = '';
    LENGTHS.forEach(function (item) {
      var btn = document.createElement('button');
      btn.textContent = item.label;
      btn.className = item === current ? 'active' : '';
      btn.addEventListener('click', function () {
        current = item;
        // 换时长等于重新开一局：不清 completed（那是历史战绩）
        state = T.create(item.focus, item.brk);
        state.completed = bestCompleted;
        stopLoop();
        renderLengths();
        render();
      });
      box.appendChild(btn);
    });
  }

  /* --------------------------- 启动 --------------------------- */

  renderLengths();

  if (ll) {
    ll.getStorage(KEY, 0)
      .then(function (res) {
        bestCompleted = typeof res.value === 'number' ? res.value : 0;
        state.completed = bestCompleted;
        render();
      })
      ['catch'](function () { render(); });
  } else {
    render();
  }

  // 从后台切回前台时立刻补一次 tick。
  // 注意这里**不能**重置 lastTick —— 页面被冻结期间的时间要靠「上次 tick 到现在」
  // 这个差值补回来，把它抹掉就等于这段时间白走了。
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && state.running) loop();
  });
})();
