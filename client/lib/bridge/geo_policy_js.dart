// lib/bridge/geo_policy_js.dart
//
// 定位策略注入脚本（页面侧）。
//
// 为什么需要它：WebView 的 `onGeolocationPermissionsShowPrompt` 只能回答
// 「给不给」，**改不了坐标**。而框架的定位授权有两个独立维度：
//   * 精度：精确 / 近似（近似要模糊到约 3 平方公里）；
//   * 后台：小程序切到后台后还能不能读位置。
// 这两件事只能在页面侧做 —— 把 `navigator.geolocation` 包一层：
//   1. 页面被宿主标记为「后台且不允许后台定位」时，直接回 PERMISSION_DENIED；
//   2. 精度是「近似」时，把坐标按 0.02° 网格取整、精度至少报 1500m，
//      并抹掉海拔 / 速度 / 方向（Android 的近似位置也是这么给的）。
//
// 策略从哪来：宿主在建 WebView 时先注入 `window.__LEMONLITE_GEO__`（快照），
// 之后任何变化都通过 `window.__lemonliteApplyGeo({...})` 推下来。
// 这样页面里读到的永远是**当前**策略，不需要页面自己去问。

/// 页面侧的定位包装脚本。必须在页面脚本之前注入（AT_DOCUMENT_START）。
class GeoPolicyJs {
  const GeoPolicyJs._();

  /// 包住 navigator.geolocation 的源码。幂等：重复注入只生效一次。
  static const String source = r'''
/* LemonLite geolocation policy shim */
(function () {
  'use strict';
  if (window.__lemonliteGeoInstalled) { return; }
  var geo = navigator.geolocation;
  if (!geo || typeof geo.getCurrentPosition !== 'function') { return; }
  window.__lemonliteGeoInstalled = true;

  var DEFAULTS = {
    allowed: false,
    precision: 'fine',
    background: false,
    foreground: true,
    grid: 0,
    accuracy: 0
  };

  var policy = {};
  (function () {
    var seed = window.__LEMONLITE_GEO__ || {};
    for (var k in DEFAULTS) {
      policy[k] = seed[k] === undefined ? DEFAULTS[k] : seed[k];
    }
  })();

  var nativeGet = geo.getCurrentPosition.bind(geo);
  var nativeWatch = geo.watchPosition.bind(geo);
  var nativeClear = geo.clearWatch.bind(geo);

  /** 当前这次读位置是否被策略挡住（后台未授权时挡住） */
  function blocked() {
    if (!policy.allowed) { return true; }
    if (!policy.foreground && !policy.background) { return true; }
    return false;
  }

  /**
   * 把一次真实定位结果改成策略允许的样子。
   * 精确模式下原样返回（同一个 Position 对象，页面拿到的精度不受影响）。
   */
  function shape(pos) {
    if (policy.precision !== 'coarse') { return pos; }
    var grid = Number(policy.grid) || 0;
    if (!grid) { return pos; }
    var c = pos.coords || {};
    var lat = Math.round((c.latitude || 0) / grid) * grid;
    var lng = Math.round((c.longitude || 0) / grid) * grid;
    var accuracy = Math.max(Number(c.accuracy) || 0, Number(policy.accuracy) || 1500);
    return {
      coords: {
        latitude: lat,
        longitude: lng,
        accuracy: accuracy,
        altitude: null,
        altitudeAccuracy: null,
        heading: null,
        speed: null
      },
      timestamp: pos.timestamp || Date.now()
    };
  }

  /** 造一个和 GeolocationPositionError 形状一致的对象（构造函数不可用） */
  function denyError(callback) {
    if (typeof callback !== 'function') { return; }
    var err = {
      code: 1,
      message: '位置权限未授予（LemonLite 权限管理）',
      PERMISSION_DENIED: 1,
      POSITION_UNAVAILABLE: 2,
      TIMEOUT: 3
    };
    setTimeout(function () { callback(err); }, 0);
  }

  geo.getCurrentPosition = function (success, error, options) {
    if (blocked()) { denyError(error); return; }
    // 近似位置直接透传 options：宿主已经按 COARSE 申请过系统权限，
    // 这里再改 enableHighAccuracy 只会让页面困惑。
    nativeGet(
      function (pos) { if (typeof success === 'function') { success(shape(pos)); } },
      error,
      options
    );
  };

  geo.watchPosition = function (success, error, options) {
    if (blocked()) { denyError(error); return -1; }
    var denied = false;
    var id = nativeWatch(
      function (pos) {
        // 监听期间小程序可能被切到后台：那一刻起不再投递（后台未授权）
        if (blocked()) {
          if (!denied) { denied = true; denyError(error); }
          return;
        }
        if (typeof success === 'function') { success(shape(pos)); }
      },
      error,
      options
    );
    return id;
  };

  geo.clearWatch = function (id) {
    if (id === -1) { return; }
    nativeClear(id);
  };

  /** 宿主推新策略（权限页改动 / 前后台切换）时调用 */
  window.__lemonliteApplyGeo = function (next) {
    if (!next || typeof next !== 'object') { return; }
    for (var k in DEFAULTS) {
      if (next[k] !== undefined) { policy[k] = next[k]; }
    }
  };

  /** 只读快照，方便小程序自己判断（例如提前提示「只能拿到大致位置」） */
  window.lemonliteGeoPolicy = function () {
    return {
      allowed: policy.allowed,
      precision: policy.precision,
      background: policy.background
    };
  };
})();
''';
}
