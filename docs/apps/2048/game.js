/* ============================================================================
 * game.js —— 2048 的纯逻辑层（无 DOM 依赖，可在 node 里直接单测）
 * ----------------------------------------------------------------------------
 * 棋盘用一维数组表示：index = row * 4 + col，0 表示空格。
 *
 * 这个文件里最容易写错、也最值得单测的一条规则是：
 *   **同一次移动里，一个方块最多只能参与一次合并。**
 *   [2,2,2,2] 向左 → [4,4,0,0]，不是 [8,0,0,0]；
 *   [4,4,4,0] 向左 → [8,4,0,0]，不是 [4,8,0,0]。
 *   实现上靠合并后跳过下一个元素（见 slideLine 里的 i++）来保证。
 * ==========================================================================*/
(function (global) {
  'use strict';

  var SIZE = 4;
  var CELLS = SIZE * SIZE;

  var DIR = { UP: 0, RIGHT: 1, DOWN: 2, LEFT: 3 };

  function emptyGrid() {
    var g = new Array(CELLS);
    for (var i = 0; i < CELLS; i++) g[i] = 0;
    return g;
  }

  function emptyCells(grid) {
    var list = [];
    for (var i = 0; i < CELLS; i++) {
      if (grid[i] === 0) list.push(i);
    }
    return list;
  }

  /**
   * 滑动一行。
   * @param {number[]} line 长度 4，0 表示空
   * @return {{line:number[], gained:number}}
   */
  function slideLine(line) {
    var values = [];
    for (var i = 0; i < line.length; i++) {
      if (line[i] !== 0) values.push(line[i]);
    }

    var out = [];
    var gained = 0;

    for (var k = 0; k < values.length; k++) {
      if (k + 1 < values.length && values[k] === values[k + 1]) {
        var merged = values[k] * 2;
        out.push(merged);
        gained += merged;
        k++; // 关键：被吃掉的那个不再参与后续合并
      } else {
        out.push(values[k]);
      }
    }

    while (out.length < SIZE) out.push(0);
    return { line: out, gained: gained };
  }

  /** 取第 n 条线（按滑动方向，永远从「靠拢的那一侧」开始读）。 */
  function readLine(grid, dir, n) {
    var line = [];
    for (var i = 0; i < SIZE; i++) {
      var row, col;
      if (dir === DIR.LEFT) { row = n; col = i; }
      else if (dir === DIR.RIGHT) { row = n; col = SIZE - 1 - i; }
      else if (dir === DIR.UP) { row = i; col = n; }
      else { row = SIZE - 1 - i; col = n; }
      line.push(grid[row * SIZE + col]);
    }
    return line;
  }

  function writeLine(grid, dir, n, line) {
    for (var i = 0; i < SIZE; i++) {
      var row, col;
      if (dir === DIR.LEFT) { row = n; col = i; }
      else if (dir === DIR.RIGHT) { row = n; col = SIZE - 1 - i; }
      else if (dir === DIR.UP) { row = i; col = n; }
      else { row = SIZE - 1 - i; col = n; }
      grid[row * SIZE + col] = line[i];
    }
  }

  /**
   * 朝某个方向移动。
   * @return {{moved:boolean, gained:number}}
   */
  function move(grid, dir) {
    var moved = false;
    var gained = 0;

    for (var n = 0; n < SIZE; n++) {
      var before = readLine(grid, dir, n);
      var result = slideLine(before);

      for (var i = 0; i < SIZE; i++) {
        if (before[i] !== result.line[i]) { moved = true; break; }
      }

      if (moved) writeLine(grid, dir, n, result.line);
      gained += result.gained;
    }

    return { moved: moved, gained: gained };
  }

  /** 还有没有路可走：有空格，或任意相邻两格数字相同。 */
  function canMove(grid) {
    if (emptyCells(grid).length > 0) return true;

    for (var r = 0; r < SIZE; r++) {
      for (var c = 0; c < SIZE; c++) {
        var v = grid[r * SIZE + c];
        if (c + 1 < SIZE && grid[r * SIZE + c + 1] === v) return true;
        if (r + 1 < SIZE && grid[(r + 1) * SIZE + c] === v) return true;
      }
    }
    return false;
  }

  /** 在随机空格放一个 2（90%）或 4（10%）。没有空格时返回 null。 */
  function spawn(grid, random) {
    var rnd = random || Math.random;
    var cells = emptyCells(grid);
    if (!cells.length) return null;

    var index = cells[Math.floor(rnd() * cells.length)];
    grid[index] = rnd() < 0.9 ? 2 : 4;
    return index;
  }

  function hasWon(grid) {
    for (var i = 0; i < CELLS; i++) {
      if (grid[i] >= 2048) return true;
    }
    return false;
  }

  function maxTile(grid) {
    var max = 0;
    for (var i = 0; i < CELLS; i++) {
      if (grid[i] > max) max = grid[i];
    }
    return max;
  }

  /**
   * 新开一局。
   * @param {number} best 历史最高分（从宿主存储里读出来传进来）
   * @return {{grid:number[], score:number, best:number, undo:object|null, over:boolean, won:boolean, newTiles:number[]}}
   */
  function newGame(best, random) {
    var grid = emptyGrid();
    spawn(grid, random);
    spawn(grid, random);
    return {
      grid: grid,
      score: 0,
      best: best || 0,
      undo: null,
      over: false,
      won: false,
      newTiles: []
    };
  }

  /**
   * 在 state 上执行一步（会改 state.grid）。返回这一步是否有效。
   *
   * undo 只保留一层 —— 这是有意的：无限撤销会让最高分失去意义，
   * 一层足够救「手滑」，又不至于把游戏玩坏。
   */
  function step(state, dir, random) {
    if (state.over) return false;

    var snapshot = { grid: state.grid.slice(), score: state.score };
    var result = move(state.grid, dir);
    if (!result.moved) return false;

    state.undo = snapshot;
    state.score += result.gained;
    if (state.score > state.best) state.best = state.score;

    var index = spawn(state.grid, random);
    state.newTiles = index === null ? [] : [index];

    if (!state.won && hasWon(state.grid)) state.won = true;
    if (!canMove(state.grid)) state.over = true;

    return true;
  }

  function undo(state) {
    if (!state.undo) return false;
    state.grid = state.undo.grid;
    state.score = state.undo.score;
    state.undo = null;
    state.over = false;
    state.newTiles = [];
    return true;
  }

  var api = {
    SIZE: SIZE,
    CELLS: CELLS,
    DIR: DIR,
    emptyGrid: emptyGrid,
    emptyCells: emptyCells,
    slideLine: slideLine,
    move: move,
    canMove: canMove,
    spawn: spawn,
    hasWon: hasWon,
    maxTile: maxTile,
    newGame: newGame,
    step: step,
    undo: undo
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.Lemon2048 = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
