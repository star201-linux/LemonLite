// app.js — Lemon 天气应用逻辑（MD3 版）
// 使用 lemonlite JSBridge 的 setStorage / request 替代 localStorage / fetch
import { WeatherIcons } from './icons.js';

(function () {
  'use strict';

  const STORAGE_KEY = 'wx-cities';
    const API_BASE = 'https://uapis.cn/api/v1/misc/weather';

  let myCities = [];
  let currentCity = null;
  let activeRequest = null;

  const $ = (id) => document.getElementById(id);
  const el = {
    themeToggle:    $('themeToggle'),
    searchInput:    $('searchInput'),
    searchClear:    $('searchClear'),
    searchBtn:      $('searchBtn'),
    cityChips:      $('cityChips'),
    loading:        $('loading'),
    errorCard:      $('errorCard'),
    errorTitle:     $('errorTitle'),
    errorDesc:      $('errorDesc'),
    retryBtn:       $('retryBtn'),
    weatherContent: $('weatherContent'),
    citySheet:      $('citySheet'),
    sheetClose:     $('sheetClose'),
    cityList:       $('cityList'),
    addCityInput:   $('addCityInput'),
    addCityBtn:     $('addCityBtn'),
  };

  /* ============================================================
     存储层：优先 lemonlite.setStorage，降级 localStorage
     参考: 开发文档 §5.2
     ============================================================ */
  const store = {
    async get(key, fallback) {
      if (window.lemonlite?.getStorage) {
        try {
          const v = await window.lemonlite.getStorage(key, fallback);
          return v ?? fallback;
        } catch { /* fall through */ }
      }
      try {
        const raw = localStorage.getItem(key);
        return raw ? JSON.parse(raw) : fallback;
      } catch { return fallback; }
    },
    async set(key, value) {
      if (window.lemonlite?.setStorage) {
        try {
          await window.lemonlite.setStorage(key, value);
          return;
        } catch { /* fall through */ }
      }
      try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* ignore */ }
    },
  };

  /* ============================================================
     网络层：优先 lemonlite.request，降级 fetch
     参考: 开发文档 §5.3
     lemonlite.request 解析后返回 { status, statusText, headers, data, durationMs, url }
     其中 data 已 JSON 解码（宿主 _decodeBody 完成）；4xx 也算 resolve，
     由我们检查 status；5xx 才会 reject { code: 20003, message }。
     ============================================================ */
  async function httpRequest(url) {
    if (window.lemonlite?.request) {
      const res = await window.lemonlite.request({
        url,
        method: 'GET',
        timeout: 12000,
      });
      // 宿主返回 { status, data, ... } —— data 已解码
      if (res && typeof res === 'object' && 'status' in res && 'data' in res) {
        const status = res.status;
        if (status >= 400) {
          const err = new Error('HTTP ' + status);
          err.status = status;
          err.httpBody = res.data;
          throw err;
        }
        // data 可能已经是对象（JSON 解码过）或字符串
        if (typeof res.data === 'string') {
          try { return JSON.parse(res.data); } catch { return res.data; }
        }
        return res.data;
      }
      // 未知结构，原样返回
      return res;
    }
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 12000);
    try {
      const res = await fetch(url, { signal: controller.signal });
      if (!res.ok) {
        const err = new Error('HTTP ' + res.status);
        err.status = res.status;
        throw err;
      }
      return await res.json();
    } finally {
      clearTimeout(timeoutId);
    }
  }

  /* ============================================================
     主题
     宿主的 applyTheme 会往 :root 注入 --md-* 变量（含暗色值），
     并设置 data-md-brightness。本页 CSS 的暗色块 [data-theme="dark"]
     里的 var(--md-x, 暗色默认值) 会优先读到宿主注入的暗色值。
     ============================================================ */
  let manualTheme = null; // 用户手动切换后记录，暂停跟随宿主

  function applyBrightness(brightness) {
    const root = document.documentElement;
    root.setAttribute('data-theme', brightness);
    root.setAttribute('data-md-brightness', brightness);
    root.style.colorScheme = brightness;
  }

  function currentBrightness() {
    if (manualTheme) return manualTheme;
    if (window.lemonlite?.theme?.mode) return window.lemonlite.theme.mode;
    return document.documentElement.getAttribute('data-theme') || 'light';
  }

  function initTheme() {
    applyBrightness(currentBrightness());
  }

  // 跟随宿主主题变化（用户手动切换后停止跟随）
  if (window.lemonlite?.onThemeChange) {
    window.lemonlite.onThemeChange(function (theme) {
      if (!manualTheme && theme && theme.mode) applyBrightness(theme.mode);
    });
  }

  el.themeToggle.addEventListener('click', () => {
    const next = currentBrightness() === 'dark' ? 'light' : 'dark';
    manualTheme = next; // 手动切换：暂停宿主跟随
    applyBrightness(next);
  });

  /* ============================================================
     城市管理
     ============================================================ */
  async function loadCities() {
    const list = await store.get(STORAGE_KEY, []);
    return Array.isArray(list) ? list : [];
  }

  function saveCities(list) {
    store.set(STORAGE_KEY, list);
  }

  function renderCityChips() {
    const container = el.cityChips;
    if (myCities.length === 0) {
      container.innerHTML =
        '<span class="empty-hint">还没有收藏的城市</span>' +
        '<button class="manage-btn" id="openCityManager">' +
        '<span class="material-symbols-outlined">edit</span>' +
        ' 管理</button>';
      $('openCityManager')?.addEventListener('click', openCitySheet);
      return;
    }
    let html = myCities.map((c) =>
      `<button class="city-chip${c === currentCity ? ' active' : ''}" data-city="${escapeHtml(c)}" role="listitem">${escapeHtml(c)}</button>`
    ).join('');
    html +=
      '<button class="manage-btn" id="openCityManager">' +
      '<span class="material-symbols-outlined">edit</span>' +
      ' 管理</button>';
    container.innerHTML = html;

    container.querySelectorAll('.city-chip').forEach((chip) => {
      chip.addEventListener('click', function () {
        const city = this.dataset.city;
        if (city === currentCity) return;
        currentCity = city;
        el.searchInput.value = city;
        updateActiveChip();
        fetchWeather({ city });
      });
    });
    $('openCityManager')?.addEventListener('click', openCitySheet);
  }

  function updateActiveChip() {
    document.querySelectorAll('.city-chip').forEach((c) => {
      c.classList.toggle('active', c.dataset.city === currentCity);
    });
  }

  function openCitySheet() {
    el.citySheet.classList.add('open');
    el.citySheet.setAttribute('aria-hidden', 'false');
    renderCityList();
  }
  function closeCitySheet() {
    el.citySheet.classList.remove('open');
    el.citySheet.setAttribute('aria-hidden', 'true');
  }

  el.sheetClose.addEventListener('click', closeCitySheet);
  el.citySheet.addEventListener('click', function (e) {
    if (e.target === this) closeCitySheet();
  });

  function renderCityList() {
    const list = el.cityList;
    if (myCities.length === 0) {
      list.innerHTML = '<div class="sheet-empty">还没有收藏的城市</div>';
      return;
    }
    list.innerHTML = myCities.map((c) =>
      `<li>
        <span class="city-name">${escapeHtml(c)}</span>
        <button class="city-delete-btn" data-city="${escapeHtml(c)}">
          <span class="material-symbols-outlined">delete</span> 删除
        </button>
      </li>`
    ).join('');
    list.querySelectorAll('.city-delete-btn').forEach((btn) => {
      btn.addEventListener('click', function () {
        const city = this.dataset.city;
        myCities = myCities.filter((c) => c !== city);
        saveCities(myCities);
        if (currentCity === city) {
          currentCity = myCities.length ? myCities[0] : null;
          el.searchInput.value = currentCity || '';
        }
        renderCityList();
        renderCityChips();
        fetchWeather(currentCity ? { city: currentCity } : {});
      });
    });
  }

  el.addCityBtn.addEventListener('click', addCity);
  el.addCityInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') addCity();
  });

  function addCity() {
    const city = el.addCityInput.value.trim();
    if (!city) return;
    if (myCities.includes(city)) {
      showToast('城市已存在');
      return;
    }
    myCities.push(city);
    saveCities(myCities);
    renderCityList();
    renderCityChips();
    el.addCityInput.value = '';
    currentCity = city;
    el.searchInput.value = city;
    updateActiveChip();
    fetchWeather({ city });
    closeCitySheet();
  }

  /* ============================================================
     搜索
     ============================================================ */
  el.searchInput.addEventListener('input', function () {
    el.searchClear.classList.toggle('visible', !!this.value);
  });

  el.searchClear.addEventListener('click', function () {
    el.searchInput.value = '';
    this.classList.remove('visible');
    el.searchInput.focus();
  });

  el.searchBtn.addEventListener('click', () => {
    const v = el.searchInput.value.trim();
    if (v) {
      currentCity = v;
      updateActiveChip();
      fetchWeather({ city: v });
    }
  });

  el.searchInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') el.searchBtn.click();
  });

  /* ============================================================
     API
     ============================================================ */
  function buildUrl(params) {
    const url = new URL(API_BASE);
    if (params.city) url.searchParams.set('city', params.city);
    url.searchParams.set('extended', 'true');
    url.searchParams.set('forecast', 'true');
    url.searchParams.set('hourly', 'true');
    url.searchParams.set('indices', 'true');
    url.searchParams.set('minutely', 'true');
    url.searchParams.set('lang', 'zh');
    return url.toString();
  }

  async function fetchWeather(params) {
    showLoading();

    if (activeRequest) activeRequest.cancelled = true;
    const req = { cancelled: false };
    activeRequest = req;

    try {
      const data = await httpRequest(buildUrl(params));
      if (req.cancelled) return;
      renderWeather(data);
      showContent();
    } catch (err) {
      if (req.cancelled) return;
      if (err.code === 20002) {
        showError('请求超时', '网络连接较慢，请稍后重试');
      } else if (err.code === 20003) {
        const m = String(err.message || '').match(/(\d{3})/);
        if (m && m[1] === '404') {
          showError('城市未找到', '请检查城市名称是否正确');
        } else if (m && m[1] === '503') {
          showError('服务不可用', '天气服务暂时不可用');
        } else {
          showError('请求失败', err.message || '天气服务返回错误');
        }
      } else if (err.code === 20001) {
        showError('网络错误', '无法连接到天气服务，请检查网络');
      } else if (err.status === 404) {
        showError('城市未找到', '请检查城市名称是否正确');
      } else if (err.status === 429) {
        showError('请求过于频繁', '天气接口暂时限流，请稍后再试');
      } else if (err.status === 503) {
        showError('服务不可用', '天气服务暂时不可用');
      } else if (err.status && err.status >= 400) {
        showError('请求失败', '天气服务返回 HTTP ' + err.status);
      } else if (err.name === 'AbortError') {
        showError('请求超时', '网络连接较慢，请稍后重试');
      } else if (err instanceof TypeError) {
        showError('网络错误', '无法连接到天气服务，请检查网络');
      } else {
        showError('加载失败', err.message || '未知错误');
      }
    }
  }

  /* ============================================================
     UI 状态切换
     ============================================================ */
  function showLoading() {
    el.loading.classList.add('visible');
    el.weatherContent.classList.remove('visible');
    el.errorCard.classList.remove('visible');
  }
  function showContent() {
    el.loading.classList.remove('visible');
    el.weatherContent.classList.add('visible');
    el.errorCard.classList.remove('visible');
  }
  function showError(title, desc) {
    el.errorTitle.textContent = title;
    el.errorDesc.textContent = desc || '';
    el.errorCard.classList.add('visible');
    el.loading.classList.remove('visible');
    el.weatherContent.classList.remove('visible');
  }

  el.retryBtn.addEventListener('click', () => {
    fetchWeather(currentCity ? { city: currentCity } : {});
  });

  /* ============================================================
     辅助
     ============================================================ */
  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function showToast(msg) {
    if (window.lemonlite?.showToast) {
      window.lemonlite.showToast(msg);
    } else {
      alert(msg);
    }
  }

  function extractHourMinute(timeStr) {
    if (!timeStr) return '';
    const match = timeStr.match(/(\d{2}):(\d{2})/);
    if (match) return match[1] + ':' + match[2];
    try {
      const d = new Date(timeStr);
      if (!isNaN(d.getTime())) {
        return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
      }
    } catch { /* ignore */ }
    return timeStr.slice(-5);
  }

  function getAlertLevelClass(level) {
    if (!level) return 'alert-default';
    const l = String(level).toLowerCase();
    if (l.includes('蓝')) return 'alert-blue';
    if (l.includes('黄')) return 'alert-yellow';
    if (l.includes('橙')) return 'alert-orange';
    if (l.includes('红')) return 'alert-red';
    return 'alert-default';
  }

  const DETAIL_ICONS = {
    thermometer: 'thermometer',
    visibility:  'visibility',
    pressure:    'speed',
    uv:          'wb_sunny',
    precip:      'water_drop',
    cloud:       'cloud',
  };

  const SECTION_ICONS = {
    weather:  'water',
    aqi:      'air',
    hourly:   'schedule',
    forecast: 'calendar_month',
    indices:  'favorite',
  };

  function sectionIconHtml(key) {
    return `<span class="material-symbols-outlined">${SECTION_ICONS[key] || 'info'}</span>`;
  }

  function detailIconHtml(key) {
    return `<span class="material-symbols-outlined" style="font-size:14px">${DETAIL_ICONS[key] || 'info'}</span>`;
  }

  /* ============================================================
     渲染
     ============================================================ */
  function renderWeather(d) {
    const wc = el.weatherContent;
    let html = '';

    html += '<div class="hero">' +
      '<div class="hero-loc">' +
      '<span class="material-symbols-outlined loc-icon" aria-hidden="true">location_on</span>' +
      escapeHtml(d.city || '--') +
      (d.district ? '<span class="sub">' + escapeHtml(d.district) + '</span>' : '') +
      '</div>' +
      '<div class="hero-weather">' +
      '<div class="hero-icon">' + WeatherIcons.getSVG(d.weather_icon) + '</div>' +
      '<span class="hero-temp">' + (d.temperature != null ? d.temperature + '°' : '--') + '</span>' +
      '</div>' +
      '<div class="hero-desc">' + escapeHtml(d.weather || '') + '</div>' +
      (d.report_time
        ? '<div class="hero-update"><span class="material-symbols-outlined" style="font-size:16px">update</span> 更新于 ' + escapeHtml(d.report_time) + '</div>'
        : '') +
      '</div>';

    if (d.alerts && d.alerts.length) {
      let alertHtml = '';
      d.alerts.forEach((a) => {
        const levelClass = getAlertLevelClass(a.level);
        let guidanceHtml = '';
        if (a.guidance && a.guidance.length) {
          guidanceHtml = '<ul class="alert-guidance">' +
            a.guidance.map((g) => '<li>' + escapeHtml(g) + '</li>').join('') + '</ul>';
        }
        alertHtml += '<div class="alert-card ' + levelClass + '">' +
          '<div class="alert-header">' +
          '<span class="alert-type">' + escapeHtml(a.type || '预警') + '</span>' +
          '<span class="alert-level">' + escapeHtml(a.level || '') + '</span></div>' +
          (a.title ? '<div class="alert-title">' + escapeHtml(a.title) + '</div>' : '') +
          (a.text ? '<div class="alert-text">' + escapeHtml(a.text) + '</div>' : '') +
          guidanceHtml +
          '<div class="alert-meta">' +
          (a.publish_time ? '<span>发布时间: ' + escapeHtml(a.publish_time) + '</span>' : '') +
          (a.publisher ? '<span>发布单位: ' + escapeHtml(a.publisher) + '</span>' : '') +
          '</div></div>';
      });
      html += '<div>' + alertHtml + '</div>';
    }

    const extItems = [];
    if (d.feels_like != null)    extItems.push({ label: '体感温度', value: d.feels_like + '°',        icon: 'thermometer' });
    if (d.visibility != null)    extItems.push({ label: '能见度',   value: d.visibility + ' km',     icon: 'visibility' });
    if (d.pressure   != null)    extItems.push({ label: '气压',     value: d.pressure + ' hPa',      icon: 'pressure' });
    if (d.uv         != null)    extItems.push({ label: '紫外线',   value: d.uv,                     icon: 'uv' });
    if (d.precipitation != null) extItems.push({ label: '降水量',   value: d.precipitation + ' mm', icon: 'precip' });
    if (d.cloud      != null)    extItems.push({ label: '云量',     value: d.cloud + '%',            icon: 'cloud' });

    if (extItems.length) {
      html += '<div class="section-title">' + sectionIconHtml('weather') + ' 气象详情</div>';
      html += '<div class="details-grid">';
      extItems.forEach((item) => {
        html += '<div class="detail-card">' +
          '<span class="detail-label">' + detailIconHtml(item.icon) + ' ' + item.label + '</span>' +
          '<span class="detail-value">' + item.value + '</span></div>';
      });
      html += '</div>';
    }

    if (d.aqi != null) {
      html += '<div class="section-title">' + sectionIconHtml('aqi') + ' 空气质量</div>';
      html += '<div class="aqi-section"><div class="aqi-main">' +
        '<span class="aqi-number">' + d.aqi + '</span>' +
        '<div class="aqi-info">' +
        '<span class="aqi-category">' + escapeHtml(d.aqi_category || '') + '</span>' +
        '<span class="aqi-primary">' + (d.aqi_primary ? '主要污染物: ' + escapeHtml(d.aqi_primary) : '') + '</span>' +
        '</div></div>';

      const pollutants = d.air_pollutants;
      if (pollutants && typeof pollutants === 'object') {
        const pMap = { pm25: 'PM2.5', pm10: 'PM10', o3: 'O3', no2: 'NO₂', so2: 'SO₂', co: 'CO' };
        const pItems = [];
        for (const key in pMap) {
          if (pollutants[key] != null) {
            pItems.push({ label: pMap[key], value: pollutants[key] + (key === 'co' ? ' mg/m³' : ' μg/m³') });
          }
        }
        if (pItems.length) {
          html += '<div class="pollutants-grid">';
          pItems.forEach((p) => {
            html += '<div class="pollutant-item">' +
              '<div class="p-name">' + p.label + '</div>' +
              '<div class="p-value">' + p.value + '</div></div>';
          });
          html += '</div>';
        }
      }
      html += '</div>';
    }

    if (d.hourly_forecast && d.hourly_forecast.length) {
      html += '<div class="section-title">' + sectionIconHtml('hourly') + ' 逐小时</div>';
      html += '<div class="hourly-scroll">';
      d.hourly_forecast.forEach((h) => {
        const timeStr = extractHourMinute(h.time);
        const extra = [];
        if (h.precip != null) extra.push(h.precip + 'mm');
        if (h.pop != null) extra.push(h.pop + '%');
        if (h.wind_scale) extra.push(h.wind_scale);
        const extraStr = extra.join(' · ');
        html += '<div class="hr-card">' +
          '<div class="hr-time">' + timeStr + '</div>' +
          '<div class="hr-icon">' + WeatherIcons.getSVGFromText(h.weather || '') + '</div>' +
          '<div class="hr-temp">' + (h.temperature != null ? h.temperature + '°' : '--') + '</div>' +
          (extraStr ? '<div class="hr-extra">' + extraStr + '</div>' : '') +
          '</div>';
      });
      html += '</div>';
    }

    if (d.minutely_precip && d.minutely_precip.data && d.minutely_precip.data.length) {
      const summary = d.minutely_precip.summary || '';
      const updateTime = d.minutely_precip.update_time || '';
      html += '<div class="section-title">' + sectionIconHtml('weather') +
        ' 分钟级降水 ' + (summary ? '<span class="section-badge">' + escapeHtml(summary) + '</span>' : '') + '</div>';
      html += '<div class="minutely-scroll">';
      d.minutely_precip.data.slice(0, 60).forEach((item) => {
        const timeStr = extractHourMinute(item.time);
        const precipVal = item.precip != null ? Number(item.precip).toFixed(1) : '0.0';
        const hasRain = parseFloat(precipVal) > 0;
        html += '<div class="minute-card' + (hasRain ? ' has-rain' : '') + '">' +
          '<div class="m-time">' + timeStr + '</div>' +
          '<div class="m-precip">' + precipVal + 'mm</div></div>';
      });
      html += '</div>';
      if (updateTime) html += '<div class="minute-update">更新: ' + extractHourMinute(updateTime) + '</div>';
    }

    if (d.forecast && d.forecast.length) {
      html += '<div class="section-title">' + sectionIconHtml('forecast') + ' 7天预报</div>';
      html += '<div class="forecast-scroll">';
      d.forecast.forEach((f, idx) => {
        const isToday = idx === 0;
        const dateStr = f.date ? f.date.slice(-5) : '';
        const iconText = f.weather_day || f.weather_night || '';
        const extraParts = [];
        if (f.wind_dir_day) extraParts.push(f.wind_dir_day);
        if (f.humidity != null) extraParts.push(f.humidity + '%');
        const extraStr = extraParts.join(' · ');
        html += '<div class="fc-card' + (isToday ? ' today' : '') + '">' +
          '<div class="fc-date">' + (isToday ? '今天' : dateStr) + '</div>' +
          '<div class="fc-icon">' + WeatherIcons.getSVGFromText(iconText) + '</div>' +
          '<div class="fc-range">' +
          '<span class="fc-max">' + (f.temp_max != null ? f.temp_max + '°' : '--') + '</span>' +
          '<span class="fc-min">' + (f.temp_min != null ? f.temp_min + '°' : '--') + '</span>' +
          '</div>' +
          (extraStr ? '<div class="fc-extra">' + extraStr + '</div>' : '') +
          '</div>';
      });
      html += '</div>';
    }

    const indices = d.life_indices;
    if (indices && typeof indices === 'object') {
      const idxMap = {
        clothing: '穿衣', uv: '紫外线', car_wash: '洗车', drying: '晾晒',
        air_conditioner: '空调', cold_risk: '感冒', exercise: '运动',
        comfort: '舒适度', travel: '出行', fishing: '钓鱼', allergy: '过敏',
        sunscreen: '防晒', mood: '心情', beer: '啤酒', umbrella: '雨伞',
        traffic: '交通', air_purifier: '净化器', pollen: '花粉',
      };
      let hasIndex = false;
      let idxHtml = '';
      Object.keys(idxMap).forEach((key) => {
        const data = indices[key];
        if (data && data.level) {
          hasIndex = true;
          idxHtml += '<div class="index-card">' +
            '<div class="idx-name">' + idxMap[key] + '</div>' +
            '<div class="idx-level">' + escapeHtml(data.level) + '</div>' +
            '<div class="idx-brief">' + escapeHtml(data.brief || '') + '</div></div>';
        }
      });
      if (hasIndex) {
        html += '<div class="section-title">' + sectionIconHtml('indices') + ' 生活指数</div>';
        html += '<div class="indices-grid">' + idxHtml + '</div>';
      }
    }

    wc.innerHTML = html;
  }

  /* ============================================================
     启动
     ============================================================ */
  initTheme();
  renderCityChips();

  (async () => {
    myCities = await loadCities();
    renderCityChips();
    if (myCities.length) {
      currentCity = myCities[0];
      el.searchInput.value = currentCity;
      fetchWeather({ city: currentCity });
    } else {
      // 无收藏城市：尝试定位获取城市；被拒/失败则用默认城市
      const locCity = await locateCity();
      if (locCity) {
        currentCity = locCity;
        el.searchInput.value = currentCity;
        // 定位到的城市顺带收藏，下次打开直接用
        if (!myCities.includes(locCity)) {
          myCities.push(locCity);
          store.set(STORAGE_KEY, myCities);
        }
        fetchWeather({ city: currentCity });
      } else {
        // 无定位结果：不猜城市，让用户自己搜（API 不传 city 返回的是
        // 服务端固定城市，和用户的实际位置无关）
        showToast('请搜索你所在的城市', { duration: 2000 });
        el.searchInput.focus();
        fetchWeather({});
      }
    }
  })();

  /* ============================================================
     定位获取城市
     权限状态由宿主管理（浏览器受控资源）：
     - 首次调用触发宿主授权弹窗；拒绝后返回 PERMISSION_DENIED(1)
     - 定位成功 → 逆地理拿城市名（uapis 支持 lon/lat 参数）
     - 被拒/失败 → 返回 null，不阻塞页面
     ============================================================ */
  async function locateCity() {
    if (!navigator.geolocation) return null;
    return new Promise((resolve) => {
      let done = false;
      const finish = (v) => { if (!done) { done = true; resolve(v); } };

      // 8 秒没结果就不等了，避免卡在 loading
      setTimeout(() => finish(null), 8000);

      navigator.geolocation.getCurrentPosition(
        async (pos) => {
          try {
            const lon = pos.coords.longitude.toFixed(4);
            const lat = pos.coords.latitude.toFixed(4);
            const data = await httpRequest(
              API_BASE + '?lon=' + lon + '&lat=' + lat + '&lang=zh'
            );
            if (data && data.city) finish(data.city);
            else finish(null);
          } catch { finish(null); }
        },
        () => finish(null), // PERMISSION_DENIED / 超时等一律回退
        { enableHighAccuracy: false, timeout: 6000, maximumAge: 300000 }
      );
    });
  }
})();
