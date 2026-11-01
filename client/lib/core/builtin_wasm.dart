// lib/core/builtin_wasm.dart
//
// 随宿主内置的 WebAssembly 模块。
//
// 为什么是「内置」而不是让小程序自己去网上下：
//   小程序可能跑在没有外网的内网环境（市场服务器就在局域网），
//   把 wasm 打进 APK 才能保证任何网络下都可用；也避免了「下载的 wasm 是谁的」
//   这种来源可信问题 —— 包里的东西跟宿主一起被签名。
//
// 传输方式：Dart 读 asset → base64 → 过 JSBridge 交给页面 → JS 侧自己
// `WebAssembly.instantiate`。之所以不返回二进制数组：
//   JSBridge 的返回值必须能 JSON 序列化，Uint8List 过不去；
//   base64 是唯一在所有 WebView 版本上都稳的编码。
//   996 字节的模块编码后只有 1.3KB，这点开销可以忽略。
//
// 增加模块：在 kBuiltinWasmModules 里加一条 + 把 .wasm 放进 assets/wasm/ 并在
// pubspec.yaml 声明，`lemonlite.wasm.list()` 会自动带上它。

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// 一个内置 wasm 模块的元数据。
///
/// `exports` 是**手写**的符号表而不是运行时解析出来的：
/// 解析 wasm 导出段要么加依赖，要么自己写一段二进制解析器，
/// 而这份清单的用途只是给小程序做提示与自动补全 —— 写死更简单也更稳。
/// 它的正确性由 tool/wasm/verify_wasm.mjs 保证（脚本会打印真实导出与这里的差异）。
class BuiltinWasmModule {
  const BuiltinWasmModule({
    required this.name,
    required this.assetPath,
    required this.description,
    required this.exports,
  });

  /// 小程序侧引用的名字（lemonlite.wasm.instantiate(name)）
  final String name;

  /// Flutter asset 路径
  final String assetPath;

  final String description;

  /// 导出的函数名（不含 memory）
  final List<String> exports;

  bool get hasMemory => true;
}

/// 内置模块清单。`lemonlite` 是通用数学/内存示例，
/// 用 tool/wasm/lemonlite_wasm.c 编译而来（无任何 import，纯计算）。
const List<BuiltinWasmModule> kBuiltinWasmModules = <BuiltinWasmModule>[
  BuiltinWasmModule(
    name: 'lemonlite',
    assetPath: 'assets/wasm/lemonlite.wasm',
    description: '通用整数/内存示例模块：四则运算、斐波那契、累加、gcd、popcount、clamp、内存求和',
    exports: <String>[
      'version',
      'add',
      'sub',
      'mul',
      'fib',
      'sum_to',
      'gcd',
      'popcount',
      'clamp',
      'sum_bytes',
    ],
  ),
];

/// 内置 wasm 的读取入口（带缓存：同一个模块只从 asset 读一次）
class BuiltinWasm {
  const BuiltinWasm._();

  static final Map<String, Uint8List> _cache = <String, Uint8List>{};

  static BuiltinWasmModule? byName(String name) {
    for (final BuiltinWasmModule module in kBuiltinWasmModules) {
      if (module.name == name) return module;
    }
    return null;
  }

  static List<String> get names =>
      kBuiltinWasmModules.map((BuiltinWasmModule m) => m.name).toList(growable: false);

  /// 读取模块字节；名字不存在或 asset 缺失时返回 null（调用方转成结构化错误）
  static Future<Uint8List?> bytes(String name) async {
    final BuiltinWasmModule? module = byName(name);
    if (module == null) return null;
    final Uint8List? cached = _cache[name];
    if (cached != null) return cached;
    try {
      final ByteData data = await rootBundle.load(module.assetPath);
      final Uint8List result = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      _cache[name] = result;
      return result;
    } catch (_) {
      return null;
    }
  }
}
