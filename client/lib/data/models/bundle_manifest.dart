// lib/data/models/bundle_manifest.dart
//
// 「模块 / 扩展」包（bundle）的 manifest 解析。
//
// 两种包共用一套格式，靠 manifest 里的 type 区分：
//
//   type = "extension" —— 浏览器插件式的**扩展**：往匹配的小程序页面注入 CSS / JS。
//                          不新增任何宿主能力，只改页面。
//   type = "module"     —— mod 式的**模块**：除注入脚本外，还能通过 manifest.bridge
//                          声明自己的 JSBridge 方法（由宿主用已有能力组合实现）。
//   type = "plugin"     —— **插件**：不注入任何代码，而是给宿主**增加能力**。
//                          与模块的根本区别：模块是"往页面里塞代码"，插件是
//                          "宿主多一项能力，所有页面都能用"；插件还必须声明
//                          自己支持哪些平台（多平台架构），宿主只在匹配的平台上启用它。
//
// 包形态：一个 zip，或一个目录。根目录（或最外层子目录）必须有 lemonlite.json：
//
//   lemonlite.json        （manifest，名字固定）
//   inject.js             （被 manifest 的 js 字段引用）
//   inject.css            （被 manifest 的 css 字段引用）
//
// manifest 示例（扩展）：
//   {
//     "type": "extension",
//     "id": "com.example.demo-extension",
//     "name": "示例扩展",
//     "version": "1.0.0",
//     "description": "给所有页面加一条调试边框",
//     "author": "someone",
//     "matches": ["*"],
//     "css": ["inject.css"],
//     "js": ["inject.js"]
//   }
//
// manifest 示例（模块，多声明了一个桥接方法）：
//   {
//     "type": "module",
//     "id": "com.example.demo-module",
//     "name": "示例模块",
//     "version": "1.0.0",
//     "matches": ["*"],
//     "bridge": [
//       { "name": "ping", "action": "const", "params": { "pong": true } },
//       { "name": "fetchConfig", "action": "http.get",
//         "params": { "url": "https://example.com/config.json" } }
//     ]
//   }
//
// manifest 示例（插件）：
//   {
//     "type": "plugin",
//     "id": "lemonlite.wasm",
//     "name": "WebAssembly 运行时",
//     "version": "1.0.0",
//     "platforms": ["android", "ios", "macos", "windows", "linux", "web"],
//     "capabilities": ["wasm"],
//     "wasm": {
//       "modules": [
//         { "name": "lemonlite", "file": "modules/lemonlite.wasm",
//           "description": "…", "exports": ["add", "fib"] }
//       ]
//     }
//   }
//
// 解析原则与 index.json 一致：**宽松读取 + 结构性错误才抛**。
// 但这里比 index.json 严格一点：id / type / version 缺失会直接判为非法包，
// 因为它们决定落盘目录名与是否覆盖已有包，猜错会留下坏数据。

import 'json_utils.dart';

/// 包类型
enum BundleType {
  /// 扩展：只注入 CSS / JS
  extension('extension', '扩展'),

  /// 模块：可注入脚本 + 声明桥接方法
  module('module', '模块'),

  /// 插件：为宿主增加一项跨平台能力（不注入页面）
  plugin('plugin', '插件');

  const BundleType(this.wireName, this.label);

  /// manifest 里写的字符串
  final String wireName;

  /// 界面上的中文名
  final String label;

  /// 对应目录名，形如 `lemonlite/extensions/<包 id>`
  String get directoryName => '${wireName}s';

  static BundleType? parse(Object? value) {
    final String text = asString(value).toLowerCase();
    for (final BundleType type in BundleType.values) {
      if (type.wireName == text) return type;
    }
    return null;
  }
}

/// 注入时机
enum BundleRunAt {
  documentStart('documentStart', '页面脚本之前'),
  documentEnd('documentEnd', '页面脚本之后');

  const BundleRunAt(this.wireName, this.label);

  final String wireName;
  final String label;

  /// 缺省放在页面脚本之后：绝大多数扩展只是想改渲染结果，
  /// 提前跑反而会拿不到页面元素。
  static BundleRunAt parse(Object? value) {
    final String text = asString(value).toLowerCase();
    return text == 'documentstart'
        ? BundleRunAt.documentStart
        : BundleRunAt.documentEnd;
  }
}

/// 模块用 manifest.bridge 声明的一个新 JSBridge 方法
class BundleBridgeMethod {
  const BundleBridgeMethod({
    required this.name,
    required this.action,
    this.params = const <String, dynamic>{},
  });

  /// 方法名：小程序侧写 `lemonlite.<name>(params)`
  final String name;

  /// 宿主用哪种已有能力来实现它（http.get / storage.set / ui.toast / const …）
  final String action;

  /// manifest 里写死的默认参数；小程序调用时传的参数会覆盖同名项
  final Map<String, dynamic> params;

  /// action 是否是宿主已实现的（导入时据此拦截，避免装进去才发现不能用）
  static const Set<String> supportedActions = <String>{
    'const',
    'http.get',
    'http.post',
    'storage.get',
    'storage.set',
    'storage.remove',
    'storage.clear',
    'storage.keys',
    'ui.toast',
    'ui.setTitle',
    'shell.openUrl',
  };

  /// 模块里不允许覆盖的宿主内置方法名
  static const Set<String> reservedNames = <String>{
    'getSystemInfo',
    'getTheme',
    'setTitle',
    'showToast',
    'navigateBack',
    'openUrl',
    'request',
    'setStorage',
    'getStorage',
    'removeStorage',
    'clearStorage',
    'getStorageKeys',
  };

  static BundleBridgeMethod? parse(Map<String, dynamic> json) {
    final String name = asString(json['name']);
    final String action = asString(json['action']);
    if (name.isEmpty || action.isEmpty) return null;

    final Object? rawParams = json['params'];
    Map<String, dynamic> params = <String, dynamic>{};
    if (rawParams is Map) {
      params = rawParams.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    }
    return BundleBridgeMethod(name: name, action: action, params: params);
  }
}

/// 一条注入规则。matches 与脚本/样式按规则成组，
/// 不能把多个规则的资源拍平，否则会把只应命中特定站点的脚本注入到其它页面。
class BundleContentScript {
  const BundleContentScript({
    required this.matches,
    required this.jsFiles,
    required this.cssFiles,
    required this.runAt,
  });

  final List<String> matches;
  final List<String> jsFiles;
  final List<String> cssFiles;
  final BundleRunAt runAt;
}

/// 插件声明的一个 WebAssembly 模块。
///
/// 宿主只负责把字节交给页面（`WebAssembly.instantiate` 在页面里做），
/// `exports` 是给小程序做提示/补全用的**手写清单**，
/// 由 tool/wasm/verify_wasm.mjs 校验它和二进制里的真实导出是否一致。
class PluginWasmModule {
  const PluginWasmModule({
    required this.name,
    required this.file,
    this.description = '',
    this.exports = const <String>[],
  });

  /// 页面侧引用的名字（lemonlite.wasm.instantiate(name)）
  final String name;

  /// 包内相对路径，如 `modules/lemonlite.wasm`
  final String file;

  final String description;
  final List<String> exports;

  bool get hasMemory => true;

  static PluginWasmModule? parse(Map<String, dynamic> json) {
    final String name = asString(json['name']).trim();
    final String file = asString(json['file']).trim();
    if (name.isEmpty || file.isEmpty) return null;
    return PluginWasmModule(
      name: name,
      file: file,
      description: asString(json['description']),
      exports: asStringList(json['exports']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'file': file,
    'description': description,
    'exports': exports,
  };
}

/// manifest 解析结果
class BundleManifest {
  const BundleManifest({
    required this.type,
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.runAt,
    required this.matches,
    required this.jsFiles,
    required this.cssFiles,
    required this.bridgeMethods,
    this.contentScripts = const <BundleContentScript>[],
    this.platforms = const <String>[],
    this.capabilities = const <String>[],
    this.wasmModules = const <PluginWasmModule>[],
  });

  final BundleType type;
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final BundleRunAt runAt;

  /// URL 匹配模式；`*` 表示全部小程序页面
  final List<String> matches;

  /// 包内相对路径（相对包根）
  final List<String> jsFiles;
  final List<String> cssFiles;

  /// 仅模块有：声明的新桥接方法
  final List<BundleBridgeMethod> bridgeMethods;

  /// 多条规则分组注入；单规则包为空时使用顶层字段。
  final List<BundleContentScript> contentScripts;

  /// 仅插件有：支持的平台（空 = 全平台）。
  ///
  /// 取值是 Flutter 的平台名：android / ios / macos / windows / linux / web。
  /// 宿主在别的平台上**不加载**这个插件，但插件仍然留在列表里
  /// （让用户知道"它存在，只是这台设备跑不了"），这比静默消失更诚实。
  final List<String> platforms;

  /// 仅插件有：向宿主声明自己提供哪些能力，例如 `wasm`。
  ///
  /// 能力名是宿主与插件之间的契约：宿主认识 `wasm`，就用包里的
  /// wasm 模块回答 `lemonlite.wasm.*`；将来认识的能力越多，插件只要
  /// 多声明一行就能接上。
  final List<String> capabilities;

  /// 仅插件有：声明的 wasm 模块
  final List<PluginWasmModule> wasmModules;

  /// 是否声明了某个能力
  bool hasCapability(String capability) => capabilities.contains(capability);

  List<BundleContentScript> get effectiveContentScripts =>
      contentScripts.isNotEmpty
      ? contentScripts
      : <BundleContentScript>[
          BundleContentScript(
            matches: matches,
            jsFiles: jsFiles,
            cssFiles: cssFiles,
            runAt: runAt,
          ),
        ];

  /// 列表页上的一行摘要
  String get summary {
    final String desc = description.trim();
    if (desc.isNotEmpty) return desc;
    final List<String> bits = <String>[
      'v$version',
      if (author.isNotEmpty) author,
      if (type == BundleType.module) '${bridgeMethods.length} 个 API',
      if (jsFiles.isNotEmpty || cssFiles.isNotEmpty) '含注入脚本',
      if (type == BundleType.plugin) '${platforms.isEmpty ? "全平台" : platforms.join("/")}',
      if (type == BundleType.plugin && capabilities.isNotEmpty)
        '能力 ${capabilities.join("/")}',
    ];
    return bits.join(' · ');
  }

  /// manifest 文件名（约定）
  static const String manifestFileName = 'lemonlite.json';

  /// id 规则：小写字母数字与 . _ -，不允许以符号开头，最长 64。
  /// 之所以收紧：id 直接当目录名与 SharedPreferences key，
  /// 放开会出现 `../../` 这类路径穿越，或者同形不同码的重复包。
  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

  /// 解析失败时抛出，code 用于 UI 归类
  static BundleManifest parse(Map<String, dynamic> json) {
    final BundleType? type = BundleType.parse(json['type']);
    if (type == null) {
      throw BundleManifestException(
        'type',
        '缺少 type 字段，或不是 module / extension',
      );
    }

    final String id = asString(json['id']).toLowerCase();
    if (!idPattern.hasMatch(id)) {
      throw BundleManifestException(
        'id',
        'id 非法：只能是小写字母、数字与 . _ -，且必须以字母或数字开头',
      );
    }

    final String name = asString(json['name']);
    if (name.isEmpty) {
      throw const BundleManifestException('name', '缺少 name');
    }

    final String version = asString(json['version']);
    if (version.isEmpty) {
      throw const BundleManifestException('version', '缺少 version');
    }

    // matches 缺省等于「全部页面」：多数包只想全局生效
    List<String> matches = asStringList(json['matches']);
    if (matches.isEmpty) matches = <String>['*'];

    // ---- 插件专属字段（其它类型忽略）----
    final List<String> platforms = asStringList(json['platforms'])
        .map((String value) => value.trim().toLowerCase())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    final List<String> capabilities = asStringList(json['capabilities'])
        .map((String value) => value.trim().toLowerCase())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    final List<PluginWasmModule> wasmModules = <PluginWasmModule>[];
    final Object? rawWasm = json['wasm'];
    if (rawWasm is Map) {
      final Object? rawModules = rawWasm['modules'];
      if (rawModules is List) {
        for (final Object? item in rawModules) {
          if (item is! Map) continue;
          final PluginWasmModule? module = PluginWasmModule.parse(
            item.map<String, dynamic>(
              (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
            ),
          );
          if (module == null) {
            throw const BundleManifestException('wasm', 'wasm.modules 里有一项缺少 name 或 file');
          }
          wasmModules.add(module);
        }
      }
    }
    if (type == BundleType.plugin) {
      if (capabilities.isEmpty) {
        throw const BundleManifestException('capabilities', '插件必须声明至少一项能力');
      }
      if (capabilities.contains('wasm') && wasmModules.isEmpty) {
        throw const BundleManifestException('wasm', '声明了 wasm 能力，但 wasm.modules 是空的');
      }
    }

    final List<BundleBridgeMethod> methods = <BundleBridgeMethod>[];
    final Object? rawBridge = json['bridge'];
    if (rawBridge is List) {
      for (final Object? item in rawBridge) {
        if (item is! Map) continue;
        final BundleBridgeMethod? method = BundleBridgeMethod.parse(
          item.map<String, dynamic>(
            (Object? k, Object? v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
        if (method == null) {
          throw const BundleManifestException(
            'bridge',
            'bridge 里有一项缺少 name 或 action',
          );
        }
        if (BundleBridgeMethod.reservedNames.contains(method.name)) {
          throw BundleManifestException(
            'bridge',
            'bridge 里的 ${method.name} 与宿主内置 API 重名，不能覆盖',
          );
        }
        if (!BundleBridgeMethod.supportedActions.contains(method.action)) {
          throw BundleManifestException(
            'bridge',
            '${method.name} 用了宿主不支持的 action：${method.action}'
                '（可用：${BundleBridgeMethod.supportedActions.join(', ')}）',
          );
        }
        methods.add(method);
      }
    }

    final List<BundleContentScript> contentScripts = <BundleContentScript>[];
    final Object? rawContentScripts = json['contentScripts'];
    if (rawContentScripts is List) {
      for (final Object? rawRule in rawContentScripts) {
        if (rawRule is! Map) continue;
        final Map<String, dynamic> rule = rawRule.map<String, dynamic>(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        );
        final List<String> ruleMatches = asStringList(rule['matches'])
            .map((String p) => p == '<all_urls>' ? '*' : p)
            .toList(growable: false);
        final List<String> js = asStringList(rule['js']);
        final List<String> css = asStringList(rule['css']);
        if (ruleMatches.isEmpty || (js.isEmpty && css.isEmpty)) continue;
        contentScripts.add(
          BundleContentScript(
            matches: ruleMatches,
            jsFiles: js,
            cssFiles: css,
            runAt: BundleRunAt.parse(rule['runAt']),
          ),
        );
      }
    }

    return BundleManifest(
      type: type,
      id: id,
      platforms: platforms,
      capabilities: capabilities,
      wasmModules: wasmModules,
      name: name,
      version: version,
      description: asString(json['description']),
      author: asString(json['author']),
      runAt: BundleRunAt.parse(json['runAt']),
      matches: matches,
      jsFiles: asStringList(json['js']),
      cssFiles: asStringList(json['css']),
      bridgeMethods: methods,
      contentScripts: contentScripts,
    );
  }
}

/// manifest 结构性错误。字段名单独带出来，UI 上更好定位。
class BundleManifestException implements Exception {
  const BundleManifestException(this.field, this.message);

  final String field;
  final String message;

  @override
  String toString() => '$field：$message';
}

/// URL 匹配：把带 `*` 的模式翻译成「分段按顺序子串匹配」。
///
/// 为什么不直接用正则全匹配：小程序的 URL 通常是
/// `https://host/apps/hello/index.html`，作者更习惯写
/// `*apps/hello/*` 或 `*hello*` 这种片段模式，而不是完整协议+主机名。
/// 分段匹配同时支持 `*`、`apps/hello/*`、`https://*.example.com/*` 三种写法。
bool matchesBundlePattern(String url, String pattern) {
  final String target = url.trim();
  final String rule = pattern.trim();
  if (rule.isEmpty) return false;
  if (rule == '*' || rule == '<all_urls>') return true;

  // 完整 match pattern：scheme://host/path。与通用子串模式分开处理，
  // 避免 https://*.example.com/* 被当成容易误命中的任意文本。
  final int separator = rule.indexOf('://');
  if (separator > 0) {
    final Uri? uri = Uri.tryParse(target);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final String schemePattern = rule.substring(0, separator).toLowerCase();
    if (schemePattern != '*' && schemePattern != uri.scheme.toLowerCase()) {
      return false;
    }

    final String hostAndPath = rule.substring(separator + 3);
    final int slash = hostAndPath.indexOf('/');
    if (slash <= 0) return false;
    final String hostPattern = hostAndPath.substring(0, slash).toLowerCase();
    final String host = uri.host.toLowerCase();
    final bool hostMatches =
        hostPattern == '*' ||
        (hostPattern.startsWith('*.') &&
            (host == hostPattern.substring(2) ||
                host.endsWith('.${hostPattern.substring(2)}'))) ||
        host == hostPattern;
    if (!hostMatches) return false;

    final String pathPattern = hostAndPath.substring(slash);
    final String path = uri.path.isEmpty ? '/' : uri.path;
    final String pathExpression = pathPattern
        .split('*')
        .map(RegExp.escape)
        .join('.*');
    final String expression = '^$pathExpression\$';
    return RegExp(expression).hasMatch(path);
  }

  final List<String> parts = rule.split('*');
  // 没有通配符：要求整串包含（作者写域名或路径片段时最常见）
  if (parts.length == 1) return target.contains(parts.first);

  int cursor = 0;
  for (int i = 0; i < parts.length; i++) {
    final String part = parts[i];
    if (part.isEmpty) continue;
    final int index = target.indexOf(part, cursor);
    if (index < 0) return false;
    cursor = index + part.length;
  }
  return true;
}

/// 单条 content script 规则是否适用于给定 URL。
bool contentScriptMatchesUrl(BundleContentScript rule, String? url) {
  if (url == null || url.isEmpty) {
    // 本地 assets 打开的小程序没有 URL，只能执行明示为全站的规则。
    return rule.matches.any(
      (String p) => p.trim() == '*' || p.trim() == '<all_urls>',
    );
  }
  return rule.matches.any((String p) => matchesBundlePattern(url, p));
}

/// 包是否适用于给定 URL
bool bundleMatchesUrl(BundleManifest manifest, String? url) => manifest
    .effectiveContentScripts
    .any((BundleContentScript rule) => contentScriptMatchesUrl(rule, url));
