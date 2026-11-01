/* ============================================================================
 * weather.js —— 天气卡片的纯逻辑层（无 DOM、无网络调用，可在 node 里单测）
 * ----------------------------------------------------------------------------
 * 数据源是 Open-Meteo：免注册、无 API key、返回 JSON。
 * 之所以能直接从前端调它，是因为请求走的是**宿主的 lemonlite.request**
 * （由 Flutter 侧的 dio 发出），不经过浏览器的 CORS 检查；在普通浏览器里
 * 退回 fetch 也能用，因为 Open-Meteo 带了 `Access-Control-Allow-Origin: *`。
 *
 * 这个文件只负责「把返回的 JSON 变成能显示的东西」，不负责发请求 ——
 * 这样解析逻辑可以脱离网络单测，天气码的映射表也能逐条核对。
 * ==========================================================================*/
(function (global) {
  'use strict';

  /**
   * WMO 天气码 → 中文描述。
   * 表来自 Open-Meteo 的官方说明（WMO Weather interpretation codes）。
   * 遇到表里没有的码不要瞎猜，返回「未知天气」并把原码带上 —— 让用户看到
   * 「未知(XX)」比看到一个编出来的「多云」有用得多。
   */
  var WMO = {
    0: '晴',
    1: '大部晴朗',
    2: '局部多云',
    3: '阴',
    45: '有雾',
    48: '雾凇',
    51: '小毛毛雨',
    53: '毛毛雨',
    55: '大毛毛雨',
    56: '冻毛毛雨',
    57: '强冻毛毛雨',
    61: '小雨',
    63: '中雨',
    65: '大雨',
    66: '冻雨',
    67: '强冻雨',
    71: '小雪',
    73: '中雪',
    75: '大雪',
    77: '雪粒',
    80: '小阵雨',
    81: '阵雨',
    82: '强阵雨',
    85: '小阵雪',
    86: '大阵雪',
    95: '雷阵雨',
    96: '雷阵雨伴小冰雹',
    99: '雷阵雨伴大冰雹'
  };

  /** 天气码 → 一个简单的类别，用来决定卡片上画什么图形。 */
  function categoryOf(code) {
    if (code === 0 || code === 1) return 'clear';
    if (code === 2) return 'partly';
    if (code === 3) return 'cloudy';
    if (code === 45 || code === 48) return 'fog';
    if (code >= 51 && code <= 57) return 'drizzle';
    if (code >= 61 && code <= 67) return 'rain';
    if (code >= 71 && code <= 77) return 'snow';
    if (code >= 80 && code <= 82) return 'shower';
    if (code >= 85 && code <= 86) return 'snow';
    // 上界不能省：WMO 的码最大到 99，写成 `code >= 95` 的话任何未知的大码
    // （比如接口将来新增的值）都会被当成雷阵雨 —— 描述显示「未知天气(999)」
    // 而图标画闪电，自相矛盾
    if (code >= 95 && code <= 99) return 'thunder';
    return 'unknown';
  }

  function describe(code) {
    return WMO[code] || ('未知天气(' + code + ')');
  }

  /** 城市预设。经纬度写死，避免为了选城市再引一个地理编码接口。 */
  var CITIES = [
    { id: 'beijing', name: '北京', latitude: 39.9042, longitude: 116.4074 },
    { id: 'shanghai', name: '上海', latitude: 31.2304, longitude: 121.4737 },
    { id: 'guangzhou', name: '广州', latitude: 23.1291, longitude: 113.2644 },
    { id: 'chengdu', name: '成都', latitude: 30.5728, longitude: 104.0668 },
    { id: 'harbin', name: '哈尔滨', latitude: 45.8038, longitude: 126.5349 },
    { id: 'lhasa', name: '拉萨', latitude: 29.6520, longitude: 91.1721 }
  ];

  function cityById(id) {
    for (var i = 0; i < CITIES.length; i++) {
      if (CITIES[i].id === id) return CITIES[i];
    }
    return CITIES[0];
  }

  function buildUrl(city) {
    return 'https://api.open-meteo.com/v1/forecast' +
      '?latitude=' + city.latitude +
      '&longitude=' + city.longitude +
      '&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day' +
      '&timezone=auto';
  }

  /**
   * 解析 Open-Meteo 的响应。
   *
   * 这里对每个字段都做了存在性检查：接口可能改结构、可能返回 `{"error":true,...}`，
   * 而一个 undefined 温度渲染成 "undefined°C" 比直接报错更让人困惑。
   *
   * @return {{ok:boolean, error:string|null, data:object|null}}
   */
  function parseResponse(json) {
    if (!json || typeof json !== 'object') {
      return { ok: false, error: '返回内容不是 JSON 对象', data: null };
    }
    if (json.error) {
      return { ok: false, error: json.reason || '接口返回了错误', data: null };
    }

    var current = json.current;
    if (!current || typeof current !== 'object') {
      return { ok: false, error: '响应里没有 current 字段', data: null };
    }
    if (typeof current.temperature_2m !== 'number') {
      return { ok: false, error: '响应里没有温度数据', data: null };
    }

    var code = typeof current.weather_code === 'number' ? current.weather_code : -1;

    return {
      ok: true,
      error: null,
      data: {
        temperature: current.temperature_2m,
        apparent: typeof current.apparent_temperature === 'number' ? current.apparent_temperature : null,
        humidity: typeof current.relative_humidity_2m === 'number' ? current.relative_humidity_2m : null,
        wind: typeof current.wind_speed_10m === 'number' ? current.wind_speed_10m : null,
        code: code,
        label: describe(code),
        category: categoryOf(code),
        // is_day 缺失时按白天处理：夜间样式是「锦上添花」，不能因为字段缺失就不显示
        isDay: current.is_day !== 0,
        time: typeof current.time === 'string' ? current.time : null,
        timezone: typeof json.timezone === 'string' ? json.timezone : null
      }
    };
  }

  /**
   * 是不是「夜间样式」。
   * 两个条件满足其一就算：当地是夜里，或者宿主的主题是深色 ——
   * 深色主题下用一套亮色卡片会很刺眼，这里让它们统一。
   */
  function isNightMode(data, themeMode) {
    if (themeMode === 'dark') return true;
    if (data && data.isDay === false) return true;
    return false;
  }

  function formatTemperature(value) {
    if (typeof value !== 'number' || !isFinite(value)) return '--';
    return (Math.round(value * 10) / 10) + '°';
  }

  var api = {
    WMO: WMO,
    CITIES: CITIES,
    cityById: cityById,
    buildUrl: buildUrl,
    parseResponse: parseResponse,
    describe: describe,
    categoryOf: categoryOf,
    isNightMode: isNightMode,
    formatTemperature: formatTemperature
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.LemonWeather = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
