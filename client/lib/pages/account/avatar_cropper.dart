// lib/pages/account/avatar_cropper.dart
//
// 头像裁剪器：正方形裁切 + 缩放 + 拖动 + 导出 PNG。
//
// 为什么自己写而不是引 image_cropper：
//   那个包要加原生依赖（Android 侧是 uCrop），为了一个正方形裁切
//   多一层原生构建风险不值得 —— 尤其是这个工程已经因为 AGP 9
//   在 plugin 版本上踩过坑（见 README 的兼容性说明）。
//   纯 Flutter 实现只有一件事要小心：**导出时的坐标换算**。
//
// 坐标模型（理解这个就能理解整个文件）：
//
//   图片以「cover」方式铺满裁切框：
//     scale = 裁切框边长 / min(图片宽, 图片高)
//   用户再叠一个缩放手势 zoom（>= 1）与一个平移 offset。
//
//   屏幕上看到的那一块 = 图片的一个矩形区域。
//   导出时用 ui.PictureRecorder 重画同一块区域，
//   所以「看到什么就得到什么」—— 不需要反推变换矩阵。
//
// 导出尺寸固定 512×512：头像在客户端最大显示 96dp（3x 屏 = 288px），
// 512 已经留了余量，同时把上传体积压在几十 KB。

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AvatarCropResult {
  const AvatarCropResult({required this.pngBytes, required this.size});

  final Uint8List pngBytes;
  final int size;
}

class AvatarCropper extends StatefulWidget {
  const AvatarCropper({super.key, required this.imageBytes, this.outputSize = 512});

  /// 原图字节（由 file_picker 读进来的）
  final Uint8List imageBytes;

  /// 导出边长（px）
  final int outputSize;

  static Future<AvatarCropResult?> show(
    BuildContext context, {
    required Uint8List imageBytes,
    int outputSize = 512,
  }) {
    return Navigator.of(context).push<AvatarCropResult>(
      MaterialPageRoute<AvatarCropResult>(
        fullscreenDialog: true,
        builder: (BuildContext ctx) =>
            AvatarCropper(imageBytes: imageBytes, outputSize: outputSize),
      ),
    );
  }

  @override
  State<AvatarCropper> createState() => _AvatarCropperState();
}

class _AvatarCropperState extends State<AvatarCropper> {
  ui.Image? _image;

  /// 缩放（1 = 刚好铺满裁切框）
  double _zoom = 1.0;

  /// 平移（逻辑像素，相对「铺满」时的位置）
  Offset _offset = Offset.zero;

  /// 手势开始时的基准值（避免累积误差）
  double _startZoom = 1.0;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  /// 裁切框的边长（由 LayoutBuilder 给出）
  double _boxSize = 0;

  /// 图片加载失败
  String? _error;

  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(widget.imageBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '这张图片解不出来（$e）');
    }
  }

  /// 「刚好铺满裁切框」时的缩放比
  double _baseScale() {
    final ui.Image? img = _image;
    if (img == null || _boxSize <= 0) return 1;
    return _boxSize / math.min(img.width, img.height);
  }

  /// 当前总缩放
  double _totalScale() => _baseScale() * _zoom;

  /// 图片在裁切框坐标系里的尺寸
  Size _scaledImageSize() {
    final ui.Image? img = _image;
    if (img == null) return Size.zero;
    final double s = _totalScale();
    return Size(img.width * s, img.height * s);
  }

  /// 把平移限制在「图片不露出裁切框空白」的范围内
  Offset _clampOffset(Offset raw) {
    if (_image == null || _boxSize <= 0) return Offset.zero;
    final Size scaled = _scaledImageSize();
    // 图片比裁切框大时，最多能移动「超出部分」的一半（两边各留一半余量）
    final double maxX = math.max(0, (scaled.width - _boxSize) / 2);
    final double maxY = math.max(0, (scaled.height - _boxSize) / 2);
    return Offset(
      raw.dx.clamp(-maxX, maxX),
      raw.dy.clamp(-maxY, maxY),
    );
  }

  Future<void> _export() async {
    final ui.Image? img = _image;
    if (img == null || _boxSize <= 0) return;
    setState(() => _exporting = true);

    try {
      final int out = widget.outputSize;
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);

      // 画到 out×out 的画布上，坐标系缩放 out / _boxSize
      final double canvasScale = out / _boxSize;
      canvas.scale(canvasScale);

      // 裁切框在画布上是 [0, _boxSize] 的正方形
      canvas.clipRect(Rect.fromLTWH(0, 0, _boxSize, _boxSize));

      // 图片左上角（与 build 里的 Positioned 算法完全一致）
      final Size scaled = _scaledImageSize();
      final double left = (_boxSize - scaled.width) / 2 + _offset.dx;
      final double top = (_boxSize - scaled.height) / 2 + _offset.dy;

      canvas.drawImageRect(
        img,
        // 源：整张图
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        // 目标：按当前缩放铺开
        Rect.fromLTWH(left, top, scaled.width, scaled.height),
        Paint()..filterQuality = FilterQuality.high,
      );

      final ui.Picture picture = recorder.endRecording();
      final ui.Image rendered = await picture.toImage(out, out);
      final ByteData? data = await rendered.toByteData(
        format: ui.ImageByteFormat.png,
      );
      picture.dispose();
      rendered.dispose();

      if (data == null) {
        throw StateError('导出 PNG 失败');
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        AvatarCropResult(pngBytes: data.buffer.asUint8List(), size: out),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('调整头像'),
        actions: <Widget>[
          TextButton(
            onPressed: _exporting || _image == null ? null : _export,
            child: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('完成'),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: <Widget>[
                const SizedBox(height: 16),
                Expanded(
                  child: Center(
                    child: LayoutBuilder(
                      builder: (BuildContext ctx, BoxConstraints box) {
                        _boxSize = math.min(box.maxWidth, box.maxHeight) - 32;
                        return _cropArea(scheme);
                      },
                    ),
                  ),
                ),
                _controls(scheme),
                const SizedBox(height: 12),
              ],
            ),
    );
  }

  Widget _cropArea(ColorScheme scheme) {
    final ui.Image? img = _image;
    if (img == null) {
      return const SizedBox(
        width: 200,
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final Size scaled = _scaledImageSize();
    final double left = (_boxSize - scaled.width) / 2 + _offset.dx;
    final double top = (_boxSize - scaled.height) / 2 + _offset.dy;

    return GestureDetector(
      onScaleStart: (ScaleStartDetails d) {
        _startZoom = _zoom;
        _startOffset = _offset;
        _startFocal = d.localFocalPoint;
      },
      onScaleUpdate: (ScaleUpdateDetails d) {
        setState(() {
          // 缩放：把手势的 scale 乘到起始 zoom 上，限制在 1~6
          _zoom = (_startZoom * d.scale).clamp(1.0, 6.0);
          // 平移：手势焦点位移 + 起始偏移
          // 焦点位移要除以 canvasScale 吗？不用 —— 这里全是逻辑像素，
          // 图片同样用逻辑像素定位，所以直接相加。
          _offset = _clampOffset(
            _startOffset + (d.localFocalPoint - _startFocal),
          );
        });
      },
      child: SizedBox(
        width: _boxSize,
        height: _boxSize,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: <Widget>[
              Positioned(
                left: left,
                top: top,
                width: scaled.width,
                height: scaled.height,
                child: RawImage(image: img, fit: BoxFit.fill),
              ),
              // 遮罩：四边压暗，只剩中间正方形
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: scheme.primary,
                      width: 2,
                    ),
                  ),
                ),
              ),
              // 九宫格辅助线
              IgnorePointer(child: _gridLines(scheme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gridLines(ColorScheme scheme) {
    final List<Widget> lines = <Widget>[];
    for (int i = 1; i <= 2; i++) {
      final double p = (i / 3) * _boxSize;
      lines.add(
        Positioned(
          left: p,
          top: 0,
          bottom: 0,
          child: Container(width: 1, color: scheme.onSurface.withValues(alpha: 0.25)),
        ),
      );
      lines.add(
        Positioned(
          top: p,
          left: 0,
          right: 0,
          child: Container(height: 1, color: scheme.onSurface.withValues(alpha: 0.25)),
        ),
      );
    }
    return Stack(children: lines);
  }

  Widget _controls(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: <Widget>[
          Icon(Icons.photo_size_select_small, color: scheme.onSurfaceVariant),
          Expanded(
            child: Slider(
              value: _zoom,
              min: 1,
              max: 6,
              // 缩放时把偏移一起收进新范围：否则放大后再缩小，
              // 图片会偏出裁切框。
              onChanged: (double v) {
                setState(() {
                  _zoom = v;
                  _offset = _clampOffset(_offset);
                });
              },
            ),
          ),
          Icon(Icons.photo_size_select_large, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
