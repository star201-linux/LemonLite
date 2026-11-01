/* ============================================================================
 * timer.js —— 番茄钟的纯逻辑层（无 DOM、无 setInterval，可在 node 里直接单测）
 * ----------------------------------------------------------------------------
 * 设计上刻意把「时间怎么流逝」交给调用方：这里只有一个 tick(state, seconds)，
 * 由页面用**真实经过的时间**去喂它，而不是每 1000ms 固定减 1。
 *
 * 为什么这么设计：WebView 在后台或被系统省电时会把定时器降频到几十秒一次，
 * 「每秒减一」的写法会让计时器越走越慢，用户切出去再回来发现根本没走完。
 * 用「实际经过了多少秒」去减，降频只会让刷新变粗，不会让时间变错。
 * ==========================================================================*/
(function (global) {
  'use strict';

  var PHASE = { FOCUS: 'focus', BREAK: 'break' };

  function create(focusMinutes, breakMinutes) {
    return {
      phase: PHASE.FOCUS,
      running: false,
      remaining: focusMinutes * 60,
      focusSeconds: focusMinutes * 60,
      breakSeconds: breakMinutes * 60,
      completed: 0,     // 累计完成的专注轮数
      finished: false   // 刚刚结束了一轮（供页面弹提示，读到后由页面清掉）
    };
  }

  function start(state) {
    if (state.remaining <= 0) return state;
    state.running = true;
    return state;
  }

  function pause(state) {
    state.running = false;
    return state;
  }

  function toggle(state) {
    return state.running ? pause(state) : start(state);
  }

  /** 回到当前阶段的起点。不清 completed —— 那是历史战绩，不该被一次重置抹掉。 */
  function reset(state) {
    state.running = false;
    state.finished = false;
    state.remaining = state.phase === PHASE.FOCUS ? state.focusSeconds : state.breakSeconds;
    return state;
  }

  /** 跳过当前阶段，直接进入下一个。跳过不计入 completed。 */
  function skip(state) {
    switchPhase(state, false);
    return state;
  }

  function switchPhase(state, countIt) {
    if (countIt && state.phase === PHASE.FOCUS) state.completed++;

    state.phase = state.phase === PHASE.FOCUS ? PHASE.BREAK : PHASE.FOCUS;
    state.remaining = state.phase === PHASE.FOCUS ? state.focusSeconds : state.breakSeconds;
    state.running = false;
  }

  /**
   * 推进 seconds 秒（可以是小数）。
   * @return {{finished:boolean, phase:string|null, completed:number}}
   *         finished 表示这一轮刚好在这一 tick 里走完。
   */
  function tick(state, seconds) {
    if (!state.running || seconds <= 0) {
      return { finished: false, phase: null, completed: state.completed };
    }

    state.remaining -= seconds;

    if (state.remaining > 0) {
      return { finished: false, phase: null, completed: state.completed };
    }

    // 走完了：先记下是哪个阶段结束的，再切到下一阶段
    var ended = state.phase;
    var carried = -state.remaining; // 溢出到下一阶段的秒数，别丢掉

    switchPhase(state, true);
    state.finished = true;

    // 溢出时间接着扣，避免长间隔（定时器被降频）导致每次都少算一截
    if (carried > 0) state.remaining = Math.max(0.001, state.remaining - carried);

    return { finished: true, phase: ended, completed: state.completed };
  }

  /** 0~1 的进度，给进度环用。 */
  function progress(state) {
    var total = state.phase === PHASE.FOCUS ? state.focusSeconds : state.breakSeconds;
    if (total <= 0) return 0;
    return Math.min(1, Math.max(0, 1 - state.remaining / total));
  }

  /** 秒 → mm:ss。向上取整，这样 59.2 秒显示 01:00 而不是 00:59。 */
  function formatClock(seconds) {
    var total = Math.ceil(Math.max(0, seconds));
    var mm = Math.floor(total / 60);
    var ss = total % 60;
    return (mm < 10 ? '0' : '') + mm + ':' + (ss < 10 ? '0' : '') + ss;
  }

  var api = {
    PHASE: PHASE,
    create: create,
    start: start,
    pause: pause,
    toggle: toggle,
    reset: reset,
    skip: skip,
    tick: tick,
    progress: progress,
    formatClock: formatClock
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.LemonTimer = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
