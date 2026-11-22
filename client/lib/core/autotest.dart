
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';

import '../data/services/miniapp_storage_service.dart';
import 'globals.dart';

/// 是否开启自检
const String kAutotestMode = String.fromEnvironment('LEMONLITE_AUTOTEST');

/// 弹窗的自动答案：`allow`（默认）/ `deny`
const String kAutotestAnswer = String.fromEnvironment(
  'LEMONLITE_AUTOTEST_ANSWER',
  defaultValue: 'allow',
);

bool get autotestEnabled => kAutotestMode.isNotEmpty;

bool get autotestAllows => kAutotestAnswer.toLowerCase() != 'deny';

/// 自检模式下要打开的本地小程序（自检页面，随包内置）
const String kAutotestAsset = 'assets/miniapp-selftest/index.html';

/// 原生通道（与 lib/core/native_bridge.dart 用的是同一条，这里直接用是为了不让
/// 自检专用的方法混进 NativeBridge 那个"平台能力"接口里）
const MethodChannel _nativeChannel = MethodChannel('lemonlite/native');

/// 自检日志文件（写在应用私有目录，避免任何权限问题）
File? _logFile;

Future<void> autotestLog(String message) async {
  if (!autotestEnabled) return;
  try {
    final File file = await _resolveLogFile();
    final String stamp = DateTime.now().toIso8601String().substring(11, 23);
    await file.writeAsString('[$stamp] $message\n', mode: FileMode.append, flush: true);
    // 日志文件默认 0600，宿主机读不到；每次写完顺手放开（仅自检模式）
    await autotestRelaxPermissions();
  } catch (e) {
    // 自检日志写不进去也不能影响 App 本体
    lemonLog('Autotest', '写日志失败：$e');
  }
}

Future<File> _resolveLogFile() async {
  final File? cached = _logFile;
  if (cached != null) return cached;
  final Directory dir = await getApplicationDocumentsDirectory();
  final File file = File('${dir.path}/autotest.log');
  if (!await file.exists()) {
    await file.create(recursive: true);
    await file.writeAsString(
      'LemonLite 自检日志（构建期 --dart-define=LEMONLITE_AUTOTEST 开启）\n',
      flush: true,
    );
  }
  _logFile = file;
  return file;
}

/// 把本应用的数据目录放开给宿主机读（仅自检模式）。
///
/// Waydroid 没有 root 时，应用私有目录（0700 / 应用 uid）在宿主机上读不到，
/// 自检证据就出不来。这里调用原生侧一个被**硬限制在本应用 dataDir 之内**的方法
/// 把权限改成 o+rX（见 MainActivity.kt 的 makeReadable）。
/// 正式包不会走到这里：autotestEnabled 为 false 时整段代码是空转。
Future<int> autotestRelaxPermissions([String? path]) async {
  if (!autotestEnabled) return 0;
  try {
    final String target = path ?? (await _dataDirPath());
    final int count = await _nativeChannel.invokeMethod<int>(
          'makeReadable',
          <String, dynamic>{'path': target},
        ) ??
        0;
    return count;
  } catch (e) {
    lemonLog('Autotest', '放开目录权限失败：$e');
    return 0;
  }
}

/// 应用私有数据目录（app_flutter 的上一级 = /data/user/0/<包名>）
Future<String> _dataDirPath() async {
  final Directory docs = await getApplicationDocumentsDirectory();
  return docs.parent.path;
}

Future<List<String>> autotestMirrorSandbox() async {
  if (!autotestEnabled) return const <String>[];
  final List<String> copied = <String>[];
  try {
    final Directory docs = await getApplicationDocumentsDirectory();
    final String sandbox = await MiniappStorageService.instance.appFilesPath(
      'lemonlite.selftest',
    );
    final Directory dir = Directory(sandbox);
    if (!await dir.exists()) return copied;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (!name.endsWith('.json') && !name.endsWith('.txt')) continue;
      final File target = File('${docs.path}/mirror-$name');
      await target.writeAsBytes(await entity.readAsBytes(), flush: true);
      copied.add(name);
    }
  } catch (e) {
    lemonLog('Autotest', '镜像沙箱文件失败：$e');
  }
  return copied;
}

/// 把当前 Flutter 界面截图存成 PNG。
///
/// 默认截整棵界面（`app.dart` 根部的 `RepaintBoundary(key: kAppCaptureBoundaryKey)`），
/// 也可以传 [boundaryKey] 只截某个子树 —— 权限弹窗就是这么截的：
/// 它是纯 Flutter 图层，不含平台视图，所以**一定**截得到；
/// 而整屏截图里 WebView 那块会是空白（平台视图不走引擎光栅化）。
Future<String?> autotestCapture(String name, {GlobalKey? boundaryKey}) async {
  if (!autotestEnabled) return null;
  try {
    final BuildContext? context =
        (boundaryKey ?? kAppCaptureBoundaryKey).currentContext;
    if (context == null) {
      await autotestLog('capture($name) 跳过：RepaintBoundary 还没挂上');
      return null;
    }
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      await autotestLog('capture($name) 跳过：根部不是 RepaintBoundary');
      return null;
    }
    final ui.Image image = await renderObject.toImage(pixelRatio: 1);
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      await autotestLog('capture($name) 失败：PNG 编码返回空');
      return null;
    }
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File('${dir.path}/capture-$name.png');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    await autotestRelaxPermissions();
    await autotestLog(
      'capture($name) -> ${file.path}（${data.lengthInBytes} 字节）',
    );
    return file.path;
  } catch (e) {
    await autotestLog('capture($name) 异常：$e');
    return null;
  }
}
