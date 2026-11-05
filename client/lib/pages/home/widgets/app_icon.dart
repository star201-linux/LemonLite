// lib/pages/home/widgets/app_icon.dart
//
// 应用图标。三种情况都要好看：
//   1. 有图标并且能加载 → 网络图片
//   2. 加载中 → 转圈占位（避免布局跳动）
//   3. 没有图标 / 加载失败 → 用名称首字 + 主题色生成占位图标
// M3 的 App 图标习惯是「圆角方形」，所以统一用 28% 圆角裁切。
//
// 优先用**本地缓存的图标**（IconCacheService 落盘的图片）：
// 应用管理里显示的是已安装小程序，图标已经在装的时候缓存好了，
// 这时不该再走一次网络 —— 断网时也应该有图标。没有本地缓存才退回网络。

import 'dart:io';

import 'package:flutter/material.dart';

class AppIcon extends StatelessWidget {
  const AppIcon({
    super.key,
    required this.name,
    this.iconUrl,
    this.localPath,
    this.size = 56,
    this.heroTag,
  });

  final String name;

  /// 远程图标地址（没有本地缓存时用）
  final String? iconUrl;

  /// 本地缓存的图标文件路径。存在就优先用它。
  final String? localPath;

  final double size;

  /// 共享元素转场的标签（列表 → 详情）。null 表示不参与转场。
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? url = iconUrl;
    final String? local = localPath;
    final String? tag = heroTag;

    // 图标在界面上只有几十 dp，但市场里的原图往往是 512/1024 的。
    // 不限制解码尺寸的话，Image.network 会把原图整张解进内存：
    // 一屏卡片就是几十 MB 的位图，滚动时 GC 与上传纹理的压力全在这里。
    // cacheWidth/Height 让它在**解码阶段**就缩到显示尺寸（按设备像素比）。
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int decodeSize = (size * dpr).clamp(1.0, 4096.0).round();

    final Widget image =
        (local != null && local.isNotEmpty && File(local).existsSync())
        ? Image.file(
            File(local),
            // 本地文件读取失败（被清理 / 写到一半）时退回网络，再退回占位图
            errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                _networkOrFallback(url, scheme, decodeSize),
            cacheWidth: decodeSize,
            cacheHeight: decodeSize,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          )
        : _networkOrFallback(url, scheme, decodeSize);

    final Widget icon = ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: SizedBox(width: size, height: size, child: image),
    );

    if (tag == null) return icon;
    return Hero(tag: tag, child: icon);
  }

  /// 有远程地址就走网络，否则占位图。
  Widget _networkOrFallback(String? url, ColorScheme scheme, int decodeSize) {
    if (url == null || url.isEmpty) return _fallback(scheme);
    return Image.network(
      url,
      // 图标加载失败不应该让卡片报错，直接退回占位图标
      errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
          _fallback(scheme),
      loadingBuilder:
          (BuildContext c, Widget child, ImageChunkEvent? progress) {
            if (progress == null) return child;
            return _fallback(scheme, loading: true);
          },
      cacheWidth: decodeSize,
      cacheHeight: decodeSize,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
  }

  Widget _fallback(ColorScheme scheme, {bool loading = false}) {
    return ColoredBox(
      color: scheme.secondaryContainer,
      child: Center(
        child: loading
            ? SizedBox(
                width: size * 0.32,
                height: size * 0.32,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onSecondaryContainer,
                ),
              )
            : Text(
                _initial,
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: size * 0.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  String get _initial {
    final String text = name.trim();
    if (text.isEmpty) return '?';
    // runes.first 而不是 substring(0,1)：后者会把 emoji 切成半个码元
    return String.fromCharCode(text.runes.first).toUpperCase();
  }
}
