/* ============================================================================
 * todo.js —— 轻记事的纯逻辑层（无 DOM 依赖，可在 node 里直接单测）
 * ----------------------------------------------------------------------------
 * 数据结构：一个数组，元素形如 { id, text, done, createdAt }。
 *
 * 这里有一条容易被忽略的原则：**从存储里读出来的东西不可信**。
 * lemonlite.setStorage 存的是 JSON，但那份数据可能来自旧版本、可能被手工改过、
 * 也可能是上个版本的结构。所以进内存之前一律先过 sanitize()，而不是直接
 * 假设它长得像我们期望的样子 —— 否则一个脏字段就能让整个列表渲染不出来。
 * ==========================================================================*/
(function (global) {
  'use strict';

  var MAX_TEXT = 200;

  /** 生成一个够用的 id：时间戳 + 序号，避免同一毫秒内连加两条时撞号。 */
  function makeId(now, seq) {
    return String(now) + '-' + String(seq);
  }

  /**
   * 把任意来源的数据洗成合法的条目数组。
   * 任何不认识的东西一律丢掉，而不是试图修复 —— 修复规则越复杂越容易再出错。
   */
  function sanitize(raw) {
    if (!Array.isArray(raw)) return [];

    var out = [];
    var seen = {};

    for (var i = 0; i < raw.length; i++) {
      var item = raw[i];
      if (!item || typeof item !== 'object') continue;

      var text = typeof item.text === 'string' ? item.text.trim() : '';
      if (!text) continue;
      if (text.length > MAX_TEXT) text = text.slice(0, MAX_TEXT);

      var id = typeof item.id === 'string' && item.id ? item.id : makeId(0, i);
      if (seen[id]) continue; // 去重：同 id 只保留第一条

      seen[id] = true;
      out.push({
        id: id,
        text: text,
        done: item.done === true,
        createdAt: typeof item.createdAt === 'number' ? item.createdAt : 0
      });
    }
    return out;
  }

  /**
   * 新增一条。
   * @return {{list:Array, error:string|null, item:object|null}}
   *         返回新数组而不是就地改，方便调用方做撤销/比较。
   */
  function addItem(list, text, now) {
    var trimmed = typeof text === 'string' ? text.trim() : '';

    if (!trimmed) return { list: list, error: '内容不能为空', item: null };
    if (trimmed.length > MAX_TEXT) {
      return { list: list, error: '最多 ' + MAX_TEXT + ' 个字', item: null };
    }

    var item = {
      id: makeId(now || 0, list.length),
      text: trimmed,
      done: false,
      createdAt: now || 0
    };
    // 新条目放最前面：待办列表里刚记的事最需要被看见
    return { list: [item].concat(list), error: null, item: item };
  }

  function toggleItem(list, id) {
    return list.map(function (item) {
      return item.id === id ? { id: item.id, text: item.text, done: !item.done, createdAt: item.createdAt } : item;
    });
  }

  function removeItem(list, id) {
    return list.filter(function (item) { return item.id !== id; });
  }

  function clearDone(list) {
    return list.filter(function (item) { return !item.done; });
  }

  /** 过滤视图。'all' / 'active' / 'done' */
  function filter(list, mode) {
    if (mode === 'active') return list.filter(function (i) { return !i.done; });
    if (mode === 'done') return list.filter(function (i) { return i.done; });
    return list;
  }

  function stats(list) {
    var done = 0;
    for (var i = 0; i < list.length; i++) if (list[i].done) done++;
    return { total: list.length, done: done, active: list.length - done };
  }

  var api = {
    MAX_TEXT: MAX_TEXT,
    makeId: makeId,
    sanitize: sanitize,
    addItem: addItem,
    toggleItem: toggleItem,
    removeItem: removeItem,
    clearDone: clearDone,
    filter: filter,
    stats: stats
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.LemonTodo = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
