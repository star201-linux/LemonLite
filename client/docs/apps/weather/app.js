/* ============================================================================
 * app.js —— 天气卡片的交互层
 * ----------------------------------------------------------------------------
 * 解析全在 weather.js，这里只做：取数（桥接优先，退回 fetch）、渲染、缓存。
 * ==========================================================================*/
(function () {
  'use strict';

  var W = window.LemonWeather;
  var ll = window.lemonlite;
  var CITY_KEY = 'weather.city';
  var CACHE_KEY = 'weather.cache';

  var cardEl = document.getElementById('card');
  var iconEl = document.getElementById('icon');
  var tempEl = document.getElementById('temp');
  var labelEl = document.getElementById('label');
  var apparentEl = document.getElementById('apparent');
  var humidityEl = document.getElementById('humidity');
  var windEl = document.getElementById('wind');
  var footEl = document.getElementById('foot');
  var errorEl = document.getElementById('error');
  var refreshBtn = document.getElementById('btn-refresh');

  if (ll) { ll.setTitle('天气卡片')['catch'](function () {}); }
  else { document.getElementById('no-bridge').style.display = 'block'; }

  var city = W.CITIES[0];
  var busy = false;
  var lastData = null;   // 最近一次成功渲染的数据，供主题切换时重算夜间形态

  /* --------------------------------------------------------------------------
   * 图标：按天气类别给一组固定的 SVG 形状。
   * 这些标记是写在代码里的字面量，不是用户输入，所以用 innerHTML 是安全的
   * （用户内容一律走 textContent，见下面的渲染）。
   * ------------------------------------------------------------------------*/

  var CLOUD = '<circle cx="36" cy="54" r="13"/><circle cx="54" cy="45" r="17"/>' +
              '<circle cx="71" cy="55" r="12"/><rect x="36" y="54" width="35" height="13" rx="6.5"/>';

  var ICONS = {
    clear: '<circle cx="50" cy="50" r="19"/>' +
           '<g stroke="currentColor" stroke-width="5" stroke-linecap="round">' +
           '<path d="M50 12v10M50 78v10M12 50h10M78 50h10M23 23l7 7M70 70l7 7M77 23l-7 7M30 70l-7 7"/></g>',
    partly: '<circle cx="40" cy="36" r="14"/>' +
            '<g stroke="currentColor" stroke-width="4" stroke-linecap="round">' +
            '<path d="M40 12v6M16 36h6M22 18l5 5M58 18l-5 5"/></g>' +
            '<g transform="translate(6,10)">' + CLOUD + '</g>',
    cloudy: CLOUD,
    fog: '<g stroke="currentColor" stroke-width="6" stroke-linecap="round">' +
         '<path d="M22 34h56M16 50h68M26 66h48"/></g>',
    drizzle: CLOUD + '<g stroke="currentColor" stroke-width="4" stroke-linecap="round">' +
             '<path d="M40 74v6M54 74v6M68 74v6"/></g>',
    rain: CLOUD + '<g stroke="currentColor" stroke-width="4" stroke-linecap="round">' +
          '<path d="M38 72l-4 12M54 72l-4 12M70 72l-4 12"/></g>',
    shower: CLOUD + '<g stroke="currentColor" stroke-width="4" stroke-linecap="round">' +
            '<path d="M34 70l-5 14M48 70l-5 14M62 70l-5 14M76 70l-5 14"/></g>',
    snow: CLOUD + '<g fill="currentColor"><circle cx="40" cy="78" r="3.5"/>' +
          '<circle cx="54" cy="84" r="3.5"/><circle cx="68" cy="78" r="3.5"/></g>',
    thunder: CLOUD + '<path d="M56 66l-14 20h10l-4 14 16-22H54z" fill="currentColor"/>',
    unknown: '<circle cx="50" cy="50" r="22" fill="none" stroke="currentColor" stroke-width="6"/>' +
             '<g stroke="currentColor" stroke-width="6" stroke-linecap="round"><path d="M50 62v.1"/></g>' +
             '<path d="M38 40a12 12 0 1 1 14 12v6" fill="none" stroke="currentColor" stroke-width="6" stroke-linecap="round"/>'
  };

  function iconFor(category) {
    var body = ICONS[category] || ICONS.unknown;
    return '<svg viewBox="0 0 100 100" fill="currentColor">' + body + '</svg>';
  }

  /* --------------------------- 渲染 --------------------------- */

  function applyNightMode(data) {
    var themeMode = (ll && ll.theme && ll.theme.mode) || 'light';
    var night = W.isNightMode(data, themeMode);
    cardEl.classList.toggle('night', night);
  }

  function render(data, stale) {
    lastData = data;
    iconEl.innerHTML = iconFor(data.category);
    tempEl.textContent = W.formatTemperature(data.temperature);
    labelEl.textContent = data.label;
    apparentEl.textContent = W.formatTemperature(data.apparent);
    humidityEl.textContent = data.humidity === null ? '--' : data.humidity + '%';
    windEl.textContent = data.wind === null ? '--' : data.wind + ' km/h';

    applyNightMode(data);

    var when = data.time ? data.time.replace('T', ' ') : '';
    footEl.textContent = stale
      ? '离线缓存 · ' + when + '（刷新失败，显示的是上一次的数据）'
      : city.name + ' · ' + when;
  }

  function showError(message) {
    errorEl.textContent = message;
    errorEl.style.display = 'block';
  }

  function clearError() {
    errorEl.style.display = 'none';
  }

  function renderCities() {
    var box = document.getElementById('cities');
    box.textContent = '';
    W.CITIES.forEach(function (item) {
      var btn = document.createElement('button');
      btn.textContent = item.name;
      btn.className = item.id === city.id ? 'active' : '';
      btn.addEventListener('click', function () {
        city = item;
        if (ll) ll.setStorage(CITY_KEY, city.id)['catch'](function () {});
        renderCities();
        load();
      });
      box.appendChild(btn);
    });
  }

  /* --------------------------- 取数 --------------------------- */

  /** 桥接优先：宿主的 dio 不受 CORS 限制；没有桥接时退回 fetch。 */
  function requestJson(url) {
    if (ll) {
      return ll.request({ url: url, method: 'GET', timeout: 15000 })
        .then(function (res) { return res.data; });
    }
    return fetch(url).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    });
  }

  function load() {
    if (busy) return;
    busy = true;
    refreshBtn.disabled = true;
    // 只有「一张卡片都还没画出来」时才显示加载文案。已经有数据时保持卡片不动，
    // 否则刷新失败会把标签永久卡在「正在获取…」上
    if (!lastData) labelEl.textContent = '正在获取…';

    requestJson(W.buildUrl(city))
      .then(function (json) {
        var parsed = W.parseResponse(json);
        if (!parsed.ok) throw new Error(parsed.error);

        clearError();
        render(parsed.data, false);
        if (ll) {
          ll.setStorage(CACHE_KEY, { city: city.id, data: parsed.data })['catch'](function () {});
        }
      })
      ['catch'](function (err) {
        var reason = (err && (err.message || err.code)) || '未知原因';
        showError('获取天气失败：' + reason + '。下拉或点「刷新」重试。');
        // 已经有上一次的数据时，卡片保持原样、只弹错误条 ——
        // 把标签改成「获取失败」而温度还留着 25°，会让人以为那个 25° 是坏的
        if (!lastData) labelEl.textContent = '获取失败';
      })
      .then(function () {
        busy = false;
        refreshBtn.disabled = false;
      });
  }

  /* --------------------------- 启动 --------------------------- */

  refreshBtn.addEventListener('click', load);

  // 宿主切主题时重算夜间形态 —— 深色主题下卡片必须跟着沉下去
  if (ll) {
    ll.onThemeChange(function () {
      if (lastData) applyNightMode(lastData);
    });
  }

  function boot(cityId, cache) {
    if (cityId) city = W.cityById(cityId);
    renderCities();

    // 先把缓存画出来，网络回来再覆盖 —— 断网时至少不是一片空白
    if (cache && cache.city === city.id && cache.data) {
      var parsed = W.parseResponse({ current: {
        temperature_2m: cache.data.temperature,
        relative_humidity_2m: cache.data.humidity,
        apparent_temperature: cache.data.apparent,
        weather_code: cache.data.code,
        wind_speed_10m: cache.data.wind,
        is_day: cache.data.isDay ? 1 : 0,
        time: cache.data.time
      }, timezone: cache.data.timezone });

      if (parsed.ok) render(parsed.data, true);
    }

    load();
  }

  if (ll) {
    Promise.all([ll.getStorage(CITY_KEY, null), ll.getStorage(CACHE_KEY, null)])
      .then(function (res) {
        boot(res[0] && res[0].value, res[1] && res[1].value);
      })
      ['catch'](function () { boot(null, null); });
  } else {
    boot(null, null);
  }
})();
