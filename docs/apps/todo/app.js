/* ============================================================================
 * app.js —— 轻记事的交互层
 * ----------------------------------------------------------------------------
 * 增删改查全在 todo.js，这里只做：持久化、渲染、事件绑定。
 * ==========================================================================*/
(function () {
  'use strict';

  var T = window.LemonTodo;
  var ll = window.lemonlite;
  var KEY = 'todo.items';

  var inputEl = document.getElementById('input');
  var listEl = document.getElementById('list');
  var statEl = document.getElementById('stat');
  var clearBtn = document.getElementById('btn-clear');

  if (ll) { ll.setTitle('轻记事')['catch'](function () {}); }
  else { document.getElementById('no-bridge').style.display = 'block'; }

  var items = [];
  var filterMode = 'all';

  /* --------------------------- 持久化 --------------------------- */

  function save() {
    if (!ll) return;
    ll.setStorage(KEY, items)['catch'](function (err) {
      // 存储失败（配额满 / 写入异常）必须让用户知道，否则他记的东西会静默消失
      if (ll) ll.showToast('保存失败：' + ((err && err.message) || '未知原因'))['catch'](function () {});
    });
  }

  function commit(next) {
    items = next;
    render();
    save();
  }

  /* --------------------------- 渲染 --------------------------- */

  function render() {
    var visible = T.filter(items, filterMode);
    listEl.textContent = '';

    if (!visible.length) {
      var empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = items.length
        ? '这个筛选下没有条目'
        : '还没有条目，在上面输入框里记一条吧';
      listEl.appendChild(empty);
    } else {
      visible.forEach(function (item) {
        listEl.appendChild(renderItem(item));
      });
    }

    var s = T.stats(items);
    statEl.textContent = s.total === 0
      ? '还没有条目'
      : '共 ' + s.total + ' 条 · 未完成 ' + s.active + ' · 已完成 ' + s.done;
    clearBtn.disabled = s.done === 0;
  }

  function renderItem(item) {
    var li = document.createElement('li');
    if (item.done) li.className = 'done';

    var check = document.createElement('button');
    check.className = 'check';
    check.textContent = '✓';
    check.setAttribute('aria-label', item.done ? '标记为未完成' : '标记为已完成');
    check.addEventListener('click', function () { commit(T.toggleItem(items, item.id)); });

    var text = document.createElement('div');
    text.className = 'text';
    // 用 textContent 而不是 innerHTML：用户输入里带 < 或 & 时不会被当成标签
    text.textContent = item.text;

    var del = document.createElement('button');
    del.className = 'del';
    del.textContent = '删除';
    del.addEventListener('click', function () { commit(T.removeItem(items, item.id)); });

    li.appendChild(check);
    li.appendChild(text);
    li.appendChild(del);
    return li;
  }

  /* --------------------------- 事件 --------------------------- */

  function add() {
    var result = T.addItem(items, inputEl.value, Date.now());

    if (result.error) {
      if (ll) ll.showToast(result.error)['catch'](function () {});
      return;
    }

    inputEl.value = '';
    // 在「已完成」筛选下新增的条目会被过滤掉，用户会以为没加上 —— 先切回「全部」
    if (filterMode === 'done') setFilter('all');
    commit(result.list);
    inputEl.focus();
  }

  document.getElementById('btn-add').addEventListener('click', add);

  inputEl.addEventListener('keydown', function (ev) {
    if (ev.key === 'Enter') { ev.preventDefault(); add(); }
  });

  function setFilter(mode) {
    filterMode = mode;
    Array.prototype.forEach.call(document.querySelectorAll('[data-filter]'), function (btn) {
      btn.classList.toggle('active', btn.getAttribute('data-filter') === mode);
    });
  }

  Array.prototype.forEach.call(document.querySelectorAll('[data-filter]'), function (btn) {
    btn.addEventListener('click', function () {
      setFilter(btn.getAttribute('data-filter'));
      render();
    });
  });

  clearBtn.addEventListener('click', function () {
    var removed = T.stats(items).done;
    commit(T.clearDone(items));
    if (ll) ll.showToast('清除了 ' + removed + ' 条已完成')['catch'](function () {});
  });

  /* --------------------------- 启动 --------------------------- */

  function boot(raw) {
    // 存储里的东西不可信：先清洗再进内存
    items = T.sanitize(raw);
    render();
  }

  if (ll) {
    ll.getStorage(KEY, [])
      .then(function (res) { boot(res && res.value); })
      ['catch'](function () { boot([]); });
  } else {
    boot([]);
  }
})();
