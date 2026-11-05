// lib/bridge/injected_js.dart
//
// 注入到 WebView 的 JS SDK（阶段一：浏览器基础 API）。
//
// 注入时机：UserScript + AT_DOCUMENT_START，**早于页面自身的任何脚本**，
// 因此小程序在自己的 <script> 里可以直接用 window.lemonlite。
//
// 与 Dart 层的通信协议（务必与 js_bridge.dart / bridge_api.dart 保持一致）：
//   JS  → Dart：window.flutter_inappwebview.callHandler('lemonlite', { method, params })
//   Dart → JS ：{ "code": 0, "data": {...} }            成功
//               { "code": 10001, "message": "..." }    失败
// JS 侧把成功包成 resolve(data)，失败包成 reject({code, message})，
// 于是小程序写起来就是标准的 Promise：
//
//   // 1) 系统信息
//   const info = await lemonlite.getSystemInfo();
//
//   // 2) 主题（含 cssVariables，可用于 JS 侧动态配色）
//   const theme = await lemonlite.getTheme();
//
//   // 3) 标题 / 提示 / 返回
//   await lemonlite.setTitle('待办清单');
//   await lemonlite.showToast('保存成功');
//   await lemonlite.navigateBack();
//
//   // 4) 外部链接
//   await lemonlite.openUrl('https://flutter.dev');
//
//   // 5) HTTP（由宿主 dio 发起，无跨域问题）
//   const res = await lemonlite.request({ url: 'https://api.example.com/todos' });
//   const post = await lemonlite.request({
//     url: 'https://api.example.com/todos',
//     method: 'POST',
//     data: { title: '买菜' },
//   });
//
//   // 6) 存储（值可以是对象，宿主做 JSON 编解码）
//   await lemonlite.setStorage('token', { v: 1, at: Date.now() });
//   const token = await lemonlite.getStorage('token', null);
//   await lemonlite.removeStorage('token');
//
//   // 7) 主题变化订阅（用户切深色 / 换主题色时回调）
//   const off = lemonlite.onThemeChange((t) => console.log(t.mode));
//   off();
//
//   // 8) 蓝牙 / NFC（首次调用会弹权限确认框；拒绝时 reject code=40001）
//   const devs = await lemonlite.bluetooth.scan({ durationMs: 5000 });
//   await lemonlite.bluetooth.connect(devs.devices[0].address);
//   const tag = await lemonlite.nfc.read();
//   await lemonlite.nfc.writeText('你好，NFC');
//
//   // 统一错误结构
//   try { await lemonlite.openUrl(''); }
//   catch (e) { console.warn(e.code, e.message); } // 10001 openUrl(url)：url 必须是非空字符串

class LemonJsSdk {
  const LemonJsSdk._();

  /// 注入到页面的 SDK 源码。
  /// 用 raw string（r'''）以免 Dart 对 $ 做插值 —— JS 里的模板字符串才能正常书写。
  static const String source = r'''
/* LemonLite JS SDK (0.1.5)
 * 挂在 window.lemonlite 上；所有 API 均为异步，统一错误结构 { code, message }。
 *
 * 0.2 新增：音量 / 亮度、页面方向与熄屏标记、小程序专属文件目录（共享/私有
 *           两个作用域）、后台运行。
 * 0.1.5 新增：下载（lemonlite.download.*，交给系统下载器）；
 *           WebAssembly 改为**插件**提供（仍然挂在 lemonlite.wasm.* 上，
 *           但实现已经不属于宿主核心 —— 没装插件时调用会得到明确错误）。
 *
 * 大多数桥接能力不需要授权：它们要么只作用于小程序自己的命名空间与
 * 沙箱目录，要么是 Android 本来就不禁止应用自行调整的设备状态。
 *
 * 两类能力要走「权限管理」：
 *   1) 浏览器受控资源（不走这里）：
 *      getUserMedia() → 摄像头 / 麦克风；File System Access API → 手机存储
 *      被拒绝时页面拿到的是浏览器的 DOMException（NotAllowedError）。
 *   2) 宿主原生能力（走这里）：
 *      lemonlite.bluetooth.* / lemonlite.nfc.*
 *      第一次调用会弹应用内确认框；拒绝时 Promise 以 {code:40001} reject。
 */
(function () {
  'use strict';

  if (window.lemonlite && window.lemonlite.__installed) { return; }

  var HANDLER = 'lemonlite';
  var SDK_VERSION = '0.1.5';
  var BRIDGE_TIMEOUT = 5000;

  /* ============================== 桥接调用 ============================== */

  function waitForBridge(timeoutMs) {
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function poll() {
        var bridge = window.flutter_inappwebview;
        if (bridge && typeof bridge.callHandler === 'function') { resolve(bridge); return; }
        if (Date.now() - start > timeoutMs) {
          reject({ code: 10002, message: 'JSBridge 未就绪：当前页面可能不是由 LemonLite 容器打开的' });
          return;
        }
        setTimeout(poll, 20);
      })();
    });
  }

  var readyPromise = null;
  function bridgeReady() {
    if (!readyPromise) {
      readyPromise = waitForBridge(BRIDGE_TIMEOUT)['catch'](function (err) {
        readyPromise = null; // 允许下次重试
        throw err;
      });
    }
    return readyPromise;
  }

  function invoke(method, params) {
    return bridgeReady().then(function (bridge) {
      return new Promise(function (resolve, reject) {
        var call = null;
        try {
          call = bridge.callHandler(HANDLER, { method: method, params: params || {} });
        } catch (e) {
          reject({ code: 90001, message: 'JSBridge 调用异常：' + ((e && e.message) || e) });
          return;
        }
        if (!call || typeof call.then !== 'function') {
          resolve(call); // 兼容：极少数情况下返回的是普通值
          return;
        }
        call.then(function (res) {
          if (res && typeof res === 'object' && typeof res.code === 'number') {
            if (res.code === 0) { resolve(res.data); }
            else { reject({ code: res.code, message: res.message || '调用失败' }); }
          } else {
            resolve(res);
          }
        }, function (err) {
          reject({ code: 90001, message: '桥接调用失败：' + ((err && err.message) || err) });
        });
      });
    });
  }

  function requireKey(key, api) {
    if (typeof key !== 'string' || key.length === 0) {
      return { code: 10001, message: api + '：key 必须是非空字符串' };
    }
    return null;
  }

  function requirePath(path, api) {
    if (path === undefined || path === null) { path = '.'; }
    if (typeof path !== 'string') {
      return { code: 10001, message: api + '：path 必须是字符串' };
    }
    if (path.length > 512) {
      return { code: 10001, message: api + '：path 过长（上限 512 字符）' };
    }
    return null;
  }

  /* =========================== 插件提供的 WASM =========================== */

  /**
   * base64 → Uint8Array。
   * 桥接只能传字符串（返回值要能 JSON 序列化），所以 wasm 二进制以 base64 过桥，
   * 在这里还原。atob 在 Android WebView 里一直可用。
   */
  function base64ToBytes(base64) {
    var binary = atob(base64);
    var length = binary.length;
    var bytes = new Uint8Array(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  /**
   * Uint8Array / 字节数组 → base64。
   * 蓝牙写特征值、NFC 记录这类二进制过桥都要它（JSON 传不了二进制）。
   */
  function bytesToBase64(bytes) {
    if (!bytes || typeof bytes.length !== 'number') { return ''; }
    var binary = '';
    for (var i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i] & 0xFF);
    }
    return btoa(binary);
  }

  /** 已编译模块缓存：同一个模块只编译一次 */
  var wasmModuleCache = {};

  /** 取模块的原始信息（含 base64 与导出清单） */
  function wasmInfo(name) {
    return invoke('wasmRead', { name: name });
  }

  /** 编译并缓存模块。注意 WebAssembly.compile 的结果可以反复 instantiate */
  function wasmModule(name) {
    if (wasmModuleCache[name]) { return Promise.resolve(wasmModuleCache[name]); }
    if (typeof WebAssembly === 'undefined') {
      return Promise.reject({ code: 10003, message: '当前 WebView 不支持 WebAssembly' });
    }
    return wasmInfo(name).then(function (info) {
      return WebAssembly.compile(base64ToBytes(info.base64)).then(function (mod) {
        wasmModuleCache[name] = mod;
        return mod;
      });
    });
  }

  /* ============================== 主题 ============================== */

  var currentTheme = null;
  var themeListeners = [];

  /* ============================== 宿主事件 ============================== */

  /**
   * 宿主 → 页面的事件订阅。
   *
   * 蓝牙的 notify / 连接状态 / 扫描结果 / 配对状态是**原生主动推送**的，
   * 不属于请求/响应，所以单独一条事件通道：
   *   宿主 evaluateJavascript → lemonlite.__dispatchEvent(type, payload)
   *   页面通过 lemonlite.bluetooth.onNotification(cb) 等订阅。
   */
  var eventListeners = Object.create(null);

  function subscribeEvent(type, callback) {
    if (typeof callback !== 'function') { return function () {}; }
    var key = String(type || '');
    if (!key) { return function () {}; }
    var list = eventListeners[key];
    if (!list) { list = []; eventListeners[key] = list; }
    list.push(callback);
    return function () {
      var i = list.indexOf(callback);
      if (i >= 0) { list.splice(i, 1); }
    };
  }

  function dispatchEvent(type, payload) {
    var list = eventListeners[String(type || '')];
    if (!list || !list.length) { return; }
    // 复制一份再遍历：回调里取消订阅不能影响这一轮派发
    var snapshot = list.slice();
    for (var i = 0; i < snapshot.length; i++) {
      try { snapshot[i](payload, type); } catch (e) { /* 页面回调异常不影响框架 */ }
    }
  }

  /**
   * 把主题快照写成 CSS 变量。
   * 两种写法都做：
   *   1) 注入一个 :root{...} 样式表 —— 页面样式表里可以直接 var(--md-primary)
   *   2) 写到 <html> 的行内 style —— 优先级更高，且支持 runtime 覆盖
   */
  function applyTheme(payload) {
    if (!payload || typeof payload !== 'object') { return; }
    currentTheme = payload;

    var root = document.documentElement;
    var vars = payload.cssVariables || {};
    var key;

    var cssText = ':root{';
    for (key in vars) {
      if (Object.prototype.hasOwnProperty.call(vars, key)) {
        cssText += key + ':' + vars[key] + ';';
      }
    }
    cssText += '}';

    var styleEl = document.getElementById('lemonlite-theme-vars');
    if (!styleEl) {
      styleEl = document.createElement('style');
      styleEl.id = 'lemonlite-theme-vars';
      (document.head || root).appendChild(styleEl);
    }
    styleEl.textContent = cssText;

    for (key in vars) {
      if (Object.prototype.hasOwnProperty.call(vars, key)) {
        root.style.setProperty(key, vars[key]);
      }
    }

    var mode = payload.mode === 'dark' ? 'dark' : 'light';
    root.setAttribute('data-md-brightness', mode);
    root.style.colorScheme = mode;

    for (var i = 0; i < themeListeners.length; i++) {
      try { themeListeners[i](currentTheme); } catch (e) { /* 页面回调异常不影响框架 */ }
    }
  }

  /* ============================== 公开 API ============================== */

  var lemonlite = {
    version: SDK_VERSION,
    __installed: true,

    /** 桥接就绪（await 之后再调用其它 API 就不会因为「桥没起来」失败） */
    get ready() { return bridgeReady(); },

    /** 当前主题快照（同步读取，来源是最近一次注入/更新的结果） */
    get theme() { return currentTheme; },

    /**
     * 获取系统信息。
     * @returns {Promise<Object>} platform / platformVersion / model / brand / sdkInt /
     *                            screenWidth / screenHeight / pixelRatio /
     *                            safeAreaTop / safeAreaBottom / brightness /
     *                            primaryColor / themeMode / appVersion / framework
     * 示例：const info = await lemonlite.getSystemInfo();
     */
    getSystemInfo: function () { return invoke('getSystemInfo'); },

    /**
     * 获取当前 MD3 主题（含 colors 与 cssVariables）。
     * 示例：const t = await lemonlite.getTheme(); console.log(t.colors.primary);
     */
    getTheme: function () { return invoke('getTheme'); },

    /**
     * 修改小程序页面标题（显示在宿主 AppBar 上）。
     * 示例：await lemonlite.setTitle('天气');
     */
    setTitle: function (title) {
      return invoke('setTitle', { title: title == null ? '' : String(title) });
    },

    /**
     * MD3 浮动提示。
     * 示例：await lemonlite.showToast('已保存', { type: 'error', duration: 3000 });
     */
    showToast: function (message, options) {
      var opts = options || {};
      return invoke('showToast', {
        message: message == null ? '' : String(message),
        type: opts.type || 'info',
        duration: typeof opts.duration === 'number' ? opts.duration : 2000
      });
    },

    /**
     * 返回上一页；退无可退时关闭小程序、回到宿主。
     * 示例：await lemonlite.navigateBack();
     */
    navigateBack: function (options) {
      var opts = options || {};
      return invoke('navigateBack', {
        delta: typeof opts.delta === 'number' ? opts.delta : 1
      });
    },

    /**
     * 用系统浏览器打开外部链接（http / https / mailto / tel）。
     * 示例：await lemonlite.openUrl('https://flutter.dev');
     */
    openUrl: function (url) {
      if (typeof url !== 'string' || url.length === 0) {
        return Promise.reject({ code: 10001, message: 'openUrl(url)：url 必须是非空字符串' });
      }
      return invoke('openUrl', { url: url });
    },

    /**
     * HTTP 请求（由宿主用 dio 发起，因此没有浏览器跨域限制）。
     * @param {Object} options { url, method, headers, data, params, timeout }
     * @returns {Promise<Object>} { status, statusText, headers, data, durationMs, url }
     * 示例：
     *   const res = await lemonlite.request({ url: 'https://api.example.com/list' });
     *   const created = await lemonlite.request({
     *     url: 'https://api.example.com/todos', method: 'POST', data: { title: '买菜' }
     *   });
     */
    request: function (options) {
      if (!options || typeof options !== 'object' ||
          typeof options.url !== 'string' || options.url.length === 0) {
        return Promise.reject({ code: 10001, message: 'request(options)：options.url 必填' });
      }
      return invoke('request', {
        url: options.url,
        method: (options.method || 'GET').toUpperCase(),
        headers: options.headers || {},
        data: options.data === undefined ? null : options.data,
        params: options.params || null,
        timeout: typeof options.timeout === 'number' ? options.timeout : 15000
      });
    },

    /**
     * 写入键值（值可以是对象/数组，宿主会 JSON 编解码）。
     * 示例：await lemonlite.setStorage('profile', { name: '张三' });
     */
    setStorage: function (key, value) {
      var err = requireKey(key, 'setStorage(key, value)');
      if (err) { return Promise.reject(err); }
      return invoke('setStorage', { key: key, value: value === undefined ? null : value });
    },

    /**
     * 读取键值，不存在时返回 defaultValue。
     * 示例：const profile = await lemonlite.getStorage('profile', {});
     */
    getStorage: function (key, defaultValue) {
      var err = requireKey(key, 'getStorage(key)');
      if (err) { return Promise.reject(err); }
      return invoke('getStorage', {
        key: key,
        defaultValue: defaultValue === undefined ? null : defaultValue
      });
    },

    /**
     * 删除键值。
     * 示例：await lemonlite.removeStorage('profile');
     */
    removeStorage: function (key) {
      var err = requireKey(key, 'removeStorage(key)');
      if (err) { return Promise.reject(err); }
      return invoke('removeStorage', { key: key });
    },

    /** 清空当前小程序的全部键值。示例：await lemonlite.clearStorage(); */
    clearStorage: function () { return invoke('clearStorage'); },

    /** 列出当前小程序已写入的 key。示例：const keys = await lemonlite.getStorageKeys(); */
    getStorageKeys: function () { return invoke('getStorageKeys'); },

    /* ------------------------------ 音量 / 亮度 ------------------------------ */

    /**
     * 读取媒体音量（受「音量控制」权限管辖）。
     * @returns {Promise<{level:number,max:number,percent:number}>}
     * 示例：const v = await lemonlite.getVolume(); console.log(v.percent);
     */
    getVolume: function () { return invoke('getVolume'); },

    /**
     * 设置媒体音量。
     * @param {number} percent 0~1 的比例（超出会被夹到边界）
     * 示例：await lemonlite.setVolume(0.5);
     */
    setVolume: function (percent) {
      var value = typeof percent === 'number' ? percent : Number(percent);
      if (isNaN(value)) {
        return Promise.reject({ code: 10001, message: 'setVolume(percent)：percent 必须是 0~1 的数字' });
      }
      return invoke('setVolume', { percent: value });
    },

    /**
     * 读取亮度（受「屏幕亮度」权限管辖）。
     * @returns {Promise<{window:number,system:number,followSystem:boolean}>}
     *          window 是本 App 的窗口亮度，-1 表示跟随系统。
     */
    getBrightness: function () { return invoke('getBrightness'); },

    /**
     * 设置本 App 的窗口亮度（不改系统亮度，因此不需要任何特殊权限）。
     * @param {number} value 0~1；传 -1 恢复「跟随系统」
     * 示例：await lemonlite.setBrightness(0.8);
     */
    setBrightness: function (value) {
      var num = typeof value === 'number' ? value : Number(value);
      if (isNaN(num)) {
        return Promise.reject({ code: 10001, message: 'setBrightness(value)：value 必须是 -1 或 0~1 的数字' });
      }
      return invoke('setBrightness', { value: num });
    },

    /* ---------------------------- 页面标记：方向 ---------------------------- */

    /**
     * 给「本页面」标记屏幕方向。
     *
     * 这是小程序侧的能力标记（类似安卓调 SDK），不是用户设置 ——
     * 页面在哪一屏显示由写页面的人最清楚。标记跟着会话走：
     * 小程序退到后台时会自动恢复成 auto，不会拖累宿主其它页面。
     *
     * @param {string} orientation 'portrait' | 'landscape' | 'portraitReverse'
     *                             | 'landscapeReverse' | 'auto'
     * 示例：await lemonlite.setPageOrientation('landscape');
     */
    setPageOrientation: function (orientation) {
      var value = orientation == null ? '' : String(orientation);
      if (value.length === 0) {
        return Promise.reject({
          code: 10001,
          message: 'setPageOrientation(orientation)：取值必须是 portrait / landscape / portraitReverse / landscapeReverse / auto'
        });
      }
      return invoke('setPageOrientation', { orientation: value });
    },

    /** 读取当前页面的方向标记。示例：const o = await lemonlite.getPageOrientation(); */
    getPageOrientation: function () { return invoke('getPageOrientation'); },

    /* ---------------------------- 页面标记：熄屏 ---------------------------- */

    /**
     * 标记本页面是否允许熄屏。
     * @param {boolean} enabled true = 屏幕常亮（不允许熄屏）；false = 允许熄屏
     * 示例：await lemonlite.setKeepScreenOn(true);   // 看视频时别黑屏
     */
    setKeepScreenOn: function (enabled) {
      return invoke('setKeepScreenOn', { enabled: !!enabled });
    },

    /**
     * setKeepScreenOn 的反义写法，读起来更贴近需求：
     * 示例：await lemonlite.setAllowScreenOff(false);  // 不允许熄屏
     */
    setAllowScreenOff: function (allow) {
      return invoke('setKeepScreenOn', { allowScreenOff: !!allow });
    },

    /** 读取熄屏标记：{keepScreenOn, allowScreenOff} */
    getKeepScreenOn: function () { return invoke('getKeepScreenOn'); },

    /* ------------------------------ 蓝牙（BLE） ------------------------------ */

    /**
     * 蓝牙能力。
     *
     * 首次执行扫描 / 配对列表 / 连接 / 读写时，宿主会先弹应用内权限确认框；
     * 同意后才申请 Android 运行时权限。拒绝时 Promise 会以 code=40001 reject。
     *
     * 只支持 BLE（GATT）：扫描、连接、按服务/特征值读写。
     * 不支持经典蓝牙 SPP / A2DP —— 那类能力没有适合网页的通用读写语义。
     * 本版也没有「订阅通知」：JSBridge 只有请求/响应，没有服务端推送；
     * 需要持续数据的特征值请用 read() 轮询（或由模块/扩展自行封装）。
     */
    bluetooth: {
      /**
       * 适配器状态：{supported, enabled, bleSupported, permissionGranted}
       * （查询不弹权限框；permissionGranted=false 时先调 listPaired/scan 触发授权）
       */
      status: function () { return invoke('bluetoothStatus'); },

      /** 已配对（已绑定）的设备：{count, devices:[{address,name,type,rssi}]} */
      listPaired: function () { return invoke('bluetoothListPaired'); },

      /** 本 App 当前已连接的设备。 */
      connections: function () { return invoke('bluetoothConnections'); },

      /** 请求系统打开蓝牙（会弹系统确认框；用 status() 轮询是否已打开）。 */
      requestEnable: function () { return invoke('bluetoothRequestEnable'); },

      /**
       * 扫描附近的 BLE / 经典蓝牙设备。
       * @param {Object} [options] { durationMs: 1000~20000，默认 5000 }
       * @returns {Promise<{count:number, devices:Array<{
       *            address:string, name:string, rssi:number,
       *            type:'le'|'classic'|'dual'|'unknown', connectable:boolean }>}>}
       * 示例：const r = await lemonlite.bluetooth.scan({ durationMs: 4000 });
       */
      scan: function (options) {
        var opts = options || {};
        var duration = Number(opts.durationMs);
        if (!isFinite(duration) || duration <= 0) { duration = 5000; }
        var mode = opts.mode ? String(opts.mode) : 'ble';
        var uuids = [];
        if (opts.serviceUuids && typeof opts.serviceUuids.length === 'number') {
          for (var i = 0; i < opts.serviceUuids.length; i++) {
            uuids.push(String(opts.serviceUuids[i]));
          }
        }
        return invoke('bluetoothScan', {
          durationMs: Math.round(duration),
          mode: mode,
          serviceUuids: uuids,
          namePrefix: opts.namePrefix ? String(opts.namePrefix) : ''
        });
      },

      /**
       * 订阅扫描过程中的实时发现事件。
       * 回调参数：{address,name,rssi,type,source,connectable}
       * @returns {Function} 取消订阅
       */
      onScanResult: function (callback) {
        return subscribeEvent('bluetooth:scanResult', callback);
      },

      /** 订阅连接状态变化：{address,name,connected,state} */
      onConnectionState: function (callback) {
        return subscribeEvent('bluetooth:connectionState', callback);
      },

      /**
       * 订阅特征值通知（notify / indicate）。
       * 回调参数：{address,service,characteristic,value(base64),time}
       */
      onNotification: function (callback) {
        return subscribeEvent('bluetooth:notification', callback);
      },

      /** 订阅配对状态变化：{address,name,state:'bonded'|'bonding'|'none',previousState} */
      onBondState: function (callback) {
        return subscribeEvent('bluetooth:bondState', callback);
      },

      /**
       * 连接 BLE 设备并发现服务。
       * @param {string} address 设备地址（扫描结果里的 address）
       * @returns {Promise<{address:string,name:string,services:Array<{
       *            uuid:string, characteristics:Array<{uuid:string, properties:string[]}> }>}>}
       * 示例：const info = await lemonlite.bluetooth.connect(address);
       */
      connect: function (address) {
        var value = address == null ? '' : String(address);
        if (!value) {
          return Promise.reject({ code: 10001, message: 'bluetooth.connect(address)：address 不能为空' });
        }
        return invoke('bluetoothConnect', { address: value });
      },

      /** 断开连接（没连上也返回成功）。 */
      disconnect: function (address) {
        return invoke('bluetoothDisconnect', { address: address == null ? '' : String(address) });
      },

      /**
       * 读特征值。
       * @param {Object} options { address, service, characteristic }
       * @returns {Promise<{address,service,characteristic,value:string,bytes:Uint8Array}>}
       *          value 是 base64；bytes 已经替你解码好。
       * 示例：const r = await lemonlite.bluetooth.read({ address, service, characteristic });
       *       console.log(new TextDecoder().decode(r.bytes));
       */
      read: function (options) {
        var opts = options || {};
        if (!opts.address || !opts.service || !opts.characteristic) {
          return Promise.reject({
            code: 10001,
            message: 'bluetooth.read(options)：需要 address / service / characteristic'
          });
        }
        return invoke('bluetoothRead', {
          address: String(opts.address),
          service: String(opts.service),
          characteristic: String(opts.characteristic)
        }).then(function (data) {
          data.bytes = base64ToBytes(data.value || '');
          return data;
        });
      },

      /**
       * 写特征值。
       * @param {Object} options {
       *   address, service, characteristic,
       *   data: string(base64) | Uint8Array | number[],
       *   withResponse: boolean（默认 true；false 走无响应写入）
       * }
       * 示例：await lemonlite.bluetooth.write({
       *   address, service, characteristic,
       *   data: new TextEncoder().encode('hello')
       * });
       */
      write: function (options) {
        var opts = options || {};
        if (!opts.address || !opts.service || !opts.characteristic) {
          return Promise.reject({
            code: 10001,
            message: 'bluetooth.write(options)：需要 address / service / characteristic'
          });
        }
        var raw = opts.data !== undefined ? opts.data : opts.value;
        var data;
        if (typeof raw === 'string') {
          data = raw;
        } else if (raw && typeof raw.length === 'number') {
          data = bytesToBase64(raw);
        } else {
          return Promise.reject({
            code: 10001,
            message: 'bluetooth.write(options)：data 必须是 base64 字符串或字节数组'
          });
        }
        return invoke('bluetoothWrite', {
          address: String(opts.address),
          service: String(opts.service),
          characteristic: String(opts.characteristic),
          data: data,
          withResponse: opts.withResponse !== false
        });
      },

      /**
       * 订阅特征值通知（notify / indicate）。
       * @param {Object} options { address, service, characteristic }
       * 示例：await lemonlite.bluetooth.subscribe({ address, service, characteristic });
       *       const off = lemonlite.bluetooth.onNotification(function (e) { ... });
       */
      subscribe: function (options) {
        var opts = options || {};
        if (!opts.address || !opts.service || !opts.characteristic) {
          return Promise.reject({
            code: 10001,
            message: 'bluetooth.subscribe(options)：需要 address / service / characteristic'
          });
        }
        return invoke('bluetoothSubscribe', {
          address: String(opts.address),
          service: String(opts.service),
          characteristic: String(opts.characteristic)
        });
      },

      /** 取消订阅特征值通知。参数同 subscribe。 */
      unsubscribe: function (options) {
        var opts = options || {};
        return invoke('bluetoothUnsubscribe', {
          address: opts.address == null ? '' : String(opts.address),
          service: opts.service == null ? '' : String(opts.service),
          characteristic: opts.characteristic == null ? '' : String(opts.characteristic)
        });
      },

      /** 读取连接 RSSI：{address, rssi} */
      rssi: function (address) {
        return invoke('bluetoothRssi', { address: address == null ? '' : String(address) });
      },

      /**
       * 请求更大的 MTU。
       * @param {Object} options { address, mtu:23~517（默认 512） }
       * @returns {Promise<{address,mtu}>}
       */
      mtu: function (options) {
        var opts = options || {};
        var mtu = Number(opts.mtu);
        if (!isFinite(mtu) || mtu <= 0) { mtu = 512; }
        return invoke('bluetoothMtu', {
          address: opts.address == null ? '' : String(opts.address),
          mtu: Math.round(mtu)
        });
      },

      /**
       * 发起配对（经典蓝牙 / 双模设备）。
       * 结果通过 onBondState 事件通知。
       */
      pair: function (address) {
        return invoke('bluetoothPair', { address: address == null ? '' : String(address) });
      },

      /** 断开全部连接（清理动作，不弹权限框）。 */
      disconnectAll: function () { return invoke('bluetoothDisconnectAll'); }
    },

    /* -------------------------------- NFC -------------------------------- */

    /**
     * NFC（Reader Mode）。
     *
     * 调用 read() / writeText() 后请让用户把标签贴到手机背面；
     * 原生侧会在 timeoutMs 内等一张卡。超时会以 code=20002 reject，
     * 取消 / 页面离开则以 message 说明原因（code 为 90001）。
     * 首次调用会先弹应用内权限确认框（NFC 本身不需要 Android 运行时权限，
     * 但「哪个小程序能读你的卡」必须由你确认）。
     */
    nfc: {
      /** 设备是否有 NFC、是否已打开：{supported, enabled} */
      status: function () { return invoke('nfcStatus'); },

      /**
       * 等待一张 NFC 标签。
       * @param {Object} [options] { timeoutMs: 2000~60000，默认 15000 }
       * @returns {Promise<{
       *   id:string, techList:string[], ndefSupported:boolean, writable:boolean,
       *   formatable:boolean, maxSize:number,
       *   records:Array<{tnf:number,type:string,payload:string,text:string|null,uri:string|null}>
       * }>}
       * 示例：const tag = await lemonlite.nfc.read({ timeoutMs: 10000 });
       */
      read: function (options) {
        var opts = options || {};
        var timeout = Number(opts.timeoutMs);
        if (!isFinite(timeout) || timeout <= 0) { timeout = 15000; }
        return invoke('nfcRead', { timeoutMs: Math.round(timeout) });
      },

      /** 取消正在等待的读卡 / 写卡（幂等）。 */
      cancel: function () { return invoke('nfcCancel'); },

      /**
       * 等待一张标签并写入一条 NDEF Text 记录。
       * @param {string} text 写入内容（UTF-8，上限 4096 字符）
       * @param {Object} [options] { timeoutMs, formatIfNeeded:boolean（默认 true） }
       * 示例：await lemonlite.nfc.writeText('你好，NFC');
       */
      writeText: function (text, options) {
        var value = text == null ? '' : String(text);
        if (!value) {
          return Promise.reject({ code: 10001, message: 'nfc.writeText(text)：text 不能为空' });
        }
        var opts = options || {};
        var timeout = Number(opts.timeoutMs);
        if (!isFinite(timeout) || timeout <= 0) { timeout = 15000; }
        return invoke('nfcWriteText', {
          text: value,
          timeoutMs: Math.round(timeout),
          formatIfNeeded: opts.formatIfNeeded !== false
        });
      }
    },

    /* ---------------------------- 文件（专属目录） ---------------------------- */

    /**
     * 小程序专属目录的绝对路径。
     *
     * 小程序有**两个**可写目录，用 scope 选：
     *   'files'   （默认）Android/data/包名/files/appfiles/小程序id
     *             用户能在文件管理器里看到并拷走
     *   'private'        data/data/包名/files/appfiles/小程序id
     *             只有宿主读得到，卸载后随应用一起消失
     *
     * 所有文件 API 的 path 都相对所选的这个目录，
     * 且**不允许** `..` 或绝对路径逃逸出去。
     *
     * @param {Object} [options] { scope: 'files' | 'private' }
     * @returns {Promise<{appId,scope,path,displayPath,scopes:Array}>}
     *          scopes 里带着两个目录各自的 displayPath，方便一次看全。
     */
    getAppFileDir: function (options) {
      var opts = options || {};
      return invoke('getAppFileDir', { scope: opts.scope || 'files' });
    },

    /**
     * 读文件。
     * @param {string} path 相对小程序目录的路径，例如 'notes/a.txt'
     * @param {Object} [options] { encoding: 'utf8' | 'base64', scope: 'files' | 'private' }
     * @returns {Promise<{path:string,scope:string,found:boolean,data:string,bytes:number}>}
     *          文件不存在时 found=false，不报错（首次读很常见）。
     */
    readFile: function (path, options) {
      var err = requirePath(path, 'readFile(path)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('readFile', {
        path: path,
        encoding: opts.encoding || 'utf8',
        scope: opts.scope || 'files'
      });
    },

    /**
     * 写文件（覆盖）。
     * @param {string} path 相对路径
     * @param {string} data 内容
     * @param {Object} [options] { encoding: 'utf8' | 'base64', scope: 'files' | 'private' }
     * 示例：await lemonlite.writeFile('notes/a.txt', '你好');
     *       await lemonlite.writeFile('cache.json', json, { scope: 'private' });
     */
    writeFile: function (path, data, options) {
      var err = requirePath(path, 'writeFile(path, data)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('writeFile', {
        path: path,
        data: data === undefined || data === null ? '' : String(data),
        encoding: opts.encoding || 'utf8',
        scope: opts.scope || 'files'
      });
    },

    /**
     * 追加写文件。
     * 示例：await lemonlite.appendFile('log.txt', '一行日志\n');
     */
    appendFile: function (path, data, options) {
      var err = requirePath(path, 'appendFile(path, data)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('appendFile', {
        path: path,
        data: data === undefined || data === null ? '' : String(data),
        encoding: opts.encoding || 'utf8',
        scope: opts.scope || 'files'
      });
    },

    /**
     * 列目录。
     * @param {string} [path] 相对路径，默认 '.'
     * @param {Object} [options] { scope: 'files' | 'private' }
     * @returns {Promise<{path:string,scope:string,count:number,entries:Array}>}
     *          entries 元素：{name, path, isDirectory, bytes, modifiedAt}
     */
    listFiles: function (path, options) {
      var err = requirePath(path, 'listFiles(path)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('listFiles', {
        path: path === undefined ? '.' : path,
        scope: opts.scope || 'files'
      });
    },

    /** 删除文件或目录（目录会递归删除）。示例：await lemonlite.deleteFile('notes/a.txt'); */
    deleteFile: function (path, options) {
      var err = requirePath(path, 'deleteFile(path)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('deleteFile', { path: path, scope: opts.scope || 'files' });
    },

    /** 创建目录（含中间层级）。示例：await lemonlite.mkdir('notes/2026'); */
    mkdir: function (path, options) {
      var err = requirePath(path, 'mkdir(path)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('mkdir', { path: path, scope: opts.scope || 'files' });
    },

    /** 判断路径是否存在。示例：if ((await lemonlite.exists('a.txt')).exists) {...} */
    exists: function (path, options) {
      var err = requirePath(path, 'exists(path)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('exists', { path: path, scope: opts.scope || 'files' });
    },

    /** 文件详情：{path, exists, isDirectory, bytes, modifiedAt} */
    fileInfo: function (path, options) {
      var err = requirePath(path, 'fileInfo(path)');
      if (err) { return Promise.reject(err); }
      var opts = options || {};
      return invoke('fileInfo', { path: path, scope: opts.scope || 'files' });
    },

    /* -------------------------------- 下载 -------------------------------- */

    /**
     * 把 http(s) 文件保存到系统「下载」目录（Download/）。
     *
     * 落盘由系统的 DownloadManager 完成，所以：
     *   * 不需要「所有文件」权限（Android 10+ 零权限）；
     *   * 下载过程活过页面/宿主进程，进度可以在宿主「设置 → 下载管理」里看；
     *   * 只能传 http(s) 地址；blob: / data: 这类没有可拉取地址的内容请先在
     *     页面里转成真实链接。
     *
     * @param {string} url
     * @param {Object} [options] { fileName?: string, mimeType?: string }
     * @returns {Promise<{id:number, fileName:string, path:string, status:string}>}
     * 示例：await lemonlite.download.save(pdfUrl, { fileName: '发票.pdf' });
     */
    download: {
      save: function (url, options) {
        if (typeof url !== 'string' || url.length === 0) {
          return Promise.reject({ code: 10001, message: 'download.save(url)：url 必须是非空字符串' });
        }
        var opts = options || {};
        return invoke('downloadSave', {
          url: url,
          fileName: opts.fileName === undefined ? '' : String(opts.fileName),
          mimeType: opts.mimeType === undefined ? '' : String(opts.mimeType)
        });
      },

      /** 当前下载记录：{count, directory, tasks: [{id,fileName,path,status,...}]} */
      list: function () { return invoke('downloadList'); }
    },

    /* -------------------------------- 会话 -------------------------------- */

    /**
     * 主动转入后台运行（等价于悬浮菜单里的「后台运行」）。
     * 页面不会被销毁，用户可以从「后台应用」里回到这一页。
     * 示例：await lemonlite.runInBackground();
     */
    runInBackground: function () { return invoke('runInBackground'); },

    /**
     * 关闭当前小程序（销毁页面，不留后台会话）。
     * 示例：if (confirm('退出？')) await lemonlite.close();
     */
    close: function () { return invoke('close'); },

    /* ------------------------------ 插件 ------------------------------ */

    /**
     * 插件总览（当前设备）。
     *
     * 插件和「扩展 / 模块」是两种东西：扩展/模块往页面注入 JS/CSS，
     * 插件则是给**宿主**增加能力（例如 WebAssembly 运行时）。插件会声明
     * 自己支持哪些平台，宿主只在自己的平台上启用它。
     *
     * @returns {Promise<{platform:string, count:number, plugins:Array,
     *                    wasm:{available:boolean, plugin?:string}}>}
     * 示例：const s = await lemonlite.plugins.list();
     *       if (!s.wasm.available) console.warn('请先安装 WebAssembly 插件');
     */
    plugins: {
      /** 全部插件（含停用 / 平台不支持的，带 active 标记） */
      list: function () { return invoke('pluginsList'); },

      /**
       * 这台设备上是否有一项能力可用。
       * @param {string} capability 能力名，目前只有 'wasm'
       * @returns {Promise<boolean>}
       */
      has: function (capability) {
        var name = capability === undefined ? 'wasm' : String(capability);
        return invoke('pluginsList').then(function (summary) {
          if (name === 'wasm') { return !!(summary.wasm && summary.wasm.available); }
          return (summary.plugins || []).some(function (p) {
            return p.active && (p.capabilities || []).indexOf(name) >= 0;
          });
        });
      }
    },

    /* ------------------------------ WASM ------------------------------ */

    /**
     * 由**插件**提供的 WebAssembly 模块（设置 → 插件 → WebAssembly 运行时）。
     *
     * 从 0.1.5 起 wasm 不再打进宿主：模块在插件包里，插件的 manifest 声明
     * `capabilities: ["wasm"]` 与模块文件。没安装/没启用插件时，
     * 这里会返回明确错误（10003），`list()` 则返回空模块列表。
     *
     * 离线可用：模块字节来自插件包，不依赖网络，也不受 CSP 影响。
     * 典型用法：
     *   const { instance } = await lemonlite.wasm.instantiate('lemonlite');
     *   console.log(instance.exports.add(2, 3));   // 5
     *
     * 也可以自己拿字节做别的事（例如传给别的 loader）：
     *   const bytes = await lemonlite.wasm.bytes('lemonlite');
     */
    wasm: {
      /** 列出可用模块：[{name, description, bytes, exports, hasMemory}] */
      list: function () { return invoke('wasmList'); },

      /** 模块详情（含 base64 原文），一般用不到，调试时有用 */
      info: function (name) { return wasmInfo(name || ''); },

      /** 模块字节（Uint8Array） */
      bytes: function (name) {
        return wasmInfo(name || '').then(function (info) {
          return base64ToBytes(info.base64);
        });
      },

      /** 编译好的 WebAssembly.Module（会缓存，重复调用不重新编译） */
      module: function (name) { return wasmModule(name || ''); },

      /**
       * 实例化模块。
       * @param {string} name 模块名
       * @param {Object} [imports] 导入对象
       * @returns {Promise<{name, instance, module, exports:string[]}>}
       */
      instantiate: function (name, imports) {
        var key = name || '';
        return wasmModule(key).then(function (mod) {
          return WebAssembly.instantiate(mod, imports || {}).then(function (instance) {
            return {
              name: key,
              module: mod,
              instance: instance,
              exports: Object.keys(instance.exports)
            };
          });
        });
      },

      /**
       * 便捷调用：实例化后直接调一个导出函数（同步返回结果）。
       * 示例：const sum = await lemonlite.wasm.call('lemonlite', 'add', 2, 3);
       */
      call: function (name, fn) {
        var args = Array.prototype.slice.call(arguments, 2);
        return this.instantiate(name).then(function (result) {
          var target = result.instance.exports[fn];
          if (typeof target !== 'function') {
            throw { code: 10001, message: 'wasm 模块 ' + name + ' 没有导出函数 ' + fn };
          }
          return target.apply(null, args);
        });
      }
    },

    /**
     * 订阅主题变化（用户切深色模式 / 换主题色都会触发）。
     * @returns {Function} 取消订阅
     * 示例：
     *   const off = lemonlite.onThemeChange(function (theme) {
     *     document.body.setAttribute('data-dark', theme.mode === 'dark');
     *   });
     *   off();
     */
    onThemeChange: function (callback) {
      if (typeof callback !== 'function') { return function () {}; }
      themeListeners.push(callback);
      if (currentTheme) {
        setTimeout(function () {
          try { callback(currentTheme); } catch (e) { /* ignore */ }
        }, 0);
      }
      return function () {
        var i = themeListeners.indexOf(callback);
        if (i >= 0) { themeListeners.splice(i, 1); }
      };
    },

    /** 内部使用：宿主做主题热更新时调用，小程序不要直接调用 */
    __applyTheme: applyTheme,

    /**
     * 订阅任意宿主事件（高级用法；蓝牙请优先用 bluetooth.onXxx）。
     * 事件名例如 'bluetooth:notification'。
     * @returns {Function} 取消订阅
     */
    onEvent: subscribeEvent,

    /** 内部使用：宿主把原生事件送进页面时调用，小程序不要直接调用 */
    __dispatchEvent: dispatchEvent,

    /**
     * 内部使用：模块（manifest.bridge 声明的方法）通过它转发到宿主。
     * 小程序不要直接调用 —— 那是给框架生成的包装函数用的。
     */
    __invoke: invoke
  };

  window.lemonlite = lemonlite;

  // 宿主先注入 window.__LEMONLITE_THEME__（数据），再注入本 SDK（逻辑），
  // 所以这里一定能读到，并在 <body> 渲染前就把 CSS 变量准备好 —— 避免主题闪烁。
  if (window.__LEMONLITE_THEME__) { applyTheme(window.__LEMONLITE_THEME__); }
})();
''';
}
