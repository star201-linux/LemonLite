// Port of Android's LoadingIndicator
// Source: androidx/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/LoadingIndicator.kt
// Copyright (c) 2024 The Android Open Source Project
// Licensed under the Apache License, Version 2.0
//
// Dart port by Priyanshu Patra
// Copyright (c) 2026 Priyanshu Patra
// Licensed under MIT License

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show clampDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

// Mirrors androidx.compose.material3.ProgressIndicator value/controller rule.
const String _kLinearValueControllerAssertion =
    'A progress indicator cannot have both a value and a controller.\n'
    'The "value" property is for a determinate indicator with a specific progress, '
    'while the "controller" is for controlling the animation of an indeterminate indicator.\n'
    'To resolve this, provide only one of the two properties.';

/// Visual style for [ExpressiveLoadingIndicator].
///
/// [filled] draws the morphing shape as a solid (default). [outlined] draws
/// the same path as a stroke for a Material 3–style outlined expressive
/// indicator.
enum ExpressiveLoadingIndicatorStyle { filled, outlined }

/// A Material Design loading indicator.
///
/// This version of the loading indicator morphs between its [polygons] shapes.
/// ![Loading indicator image](https://developer.android.com/images/reference/androidx/compose/material3/loading-indicator.png)
class ExpressiveLoadingIndicator extends ProgressIndicator {
  /// A list of [RoundedPolygon]s for the sequence of shapes this loading indicator
  /// will morph between. The loading indicator expects at least two items in that list.
  final List<RoundedPolygon>? polygons;

  /// Defines minimum and maximum sizes for an [ExpressiveLoadingIndicator].
  /// If null, then the [ProgressIndicatorThemeData.constraints] will be used. Otherwise, defaults to a minimum width and height of 48 pixels.
  final BoxConstraints? constraints;

  /// Whether the indicator is drawn filled or as an outline.
  ///
  /// Outlined mode uses the same morphing geometry as [filled], stroked with
  /// [strokeWidth].
  final ExpressiveLoadingIndicatorStyle style;

  /// Stroke width when [style] is [ExpressiveLoadingIndicatorStyle.outlined].
  ///
  /// If null, a width proportional to the indicator size is used (~3 logical
  /// pixels at the default 48×48 size).
  final double? strokeWidth;

  const ExpressiveLoadingIndicator({
    super.key,
    super.color,
    this.polygons,
    this.constraints,
    this.style = ExpressiveLoadingIndicatorStyle.filled,
    this.strokeWidth,
    super.semanticsLabel,
    super.semanticsValue,
  }) : assert(polygons != null ? polygons.length > 1 : true),
       assert(
         strokeWidth == null || strokeWidth > 0,
         'strokeWidth must be positive',
       );

  @override
  State<ExpressiveLoadingIndicator> createState() =>
      _ExpressiveLoadingIndicatorState();
}

class _ExpressiveLoadingIndicatorState extends State<ExpressiveLoadingIndicator>
    with TickerProviderStateMixin {
  static final List<RoundedPolygon> _defaultPolygons = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.pill,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
  ];

  static final BoxConstraints _defaultConstraints = BoxConstraints(
    minWidth: 48.0,
    minHeight: 48.0,
    maxWidth: 48.0,
    maxHeight: 48.0,
  ); // default from kotlin source

  late final List<RoundedPolygon> _polygons;

  static const int _globalRotationDurationMs = 4666;
  static const int _morphIntervalMs = 650;
  static const double _fullRotation = 360.0;

  static const double _quarterRotation = _fullRotation / 4;
  static const double _activeSize = 38; // based on source spec

  late final List<Morph> _morphSequence;

  late final AnimationController _morphController;
  late final AnimationController _globalRotationController;
  int _currentMorphIndex = 0;
  double _morphRotationTargetAngle = _quarterRotation;

  Timer? _morphTimer;

  final _morphAnimationSpec = SpringSimulation(
    SpringDescription.withDampingRatio(ratio: 0.6, stiffness: 200.0, mass: 1.0),
    0.0,
    1.0,
    5.0,
    snapToEnd: true,
  );

  late BoxConstraints _constraints;
  late Color _color;

  @override
  Widget build(BuildContext context) {
    final indicatorTheme = ProgressIndicatorTheme.of(context);
    _color =
        widget.color ??
        indicatorTheme.color ??
        Theme.of(context).colorScheme.primary;
    _constraints =
        widget.constraints ?? indicatorTheme.constraints ?? _defaultConstraints;

    final minSide = math.min(_constraints.maxWidth, _constraints.maxHeight);
    final activeIndicatorScale = _activeSize / minSide;

    final isOutlined = widget.style == ExpressiveLoadingIndicatorStyle.outlined;
    final effectiveStrokeWidth = isOutlined
        ? (widget.strokeWidth ?? (minSide * (3.0 / 48.0)))
        : null;

    // Inset scale so outlined strokes stay inside the bounds (stroke extends
    // past the path by half the stroke width).
    final outlineInsetFactor = isOutlined && effectiveStrokeWidth != null
        ? (1.0 - (effectiveStrokeWidth / minSide)).clamp(0.55, 1.0)
        : 1.0;

    final shapesScaleFactor =
        _calculateScaleFactor(_polygons) *
        activeIndicatorScale *
        outlineInsetFactor;

    return Semantics.fromProperties(
      properties: SemanticsProperties(
        label: widget.semanticsLabel,
        value: widget.semanticsValue,
      ),
      child: RepaintBoundary(
        child: ConstrainedBox(
          constraints: _constraints,
          child: AspectRatio(
            aspectRatio: 1.0,
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _morphController,
                _globalRotationController,
              ]),
              builder: (context, child) {
                final morphProgress = _morphController.value.clamp(0.0, 1.0);
                final globalRotationDegrees =
                    _globalRotationController.value * _fullRotation;

                // calculate total rotation (clockwise, matching Kotlin implementation)
                final totalRotationDegrees =
                    morphProgress * _quarterRotation +
                    _morphRotationTargetAngle +
                    globalRotationDegrees;

                final totalRotationRadians =
                    totalRotationDegrees * (math.pi / 180.0);

                return Transform.rotate(
                  angle: totalRotationRadians,
                  child: CustomPaint(
                    painter: _MorphPainter(
                      morph: _morphSequence[_currentMorphIndex],
                      progress: morphProgress,
                      color: _color,
                      scaleFactor: shapesScaleFactor,
                      style: widget.style,
                      strokeWidth: effectiveStrokeWidth,
                      repaint: Listenable.merge([
                        _morphController,
                        _globalRotationController,
                      ]),
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _morphTimer?.cancel();
    _morphController.dispose();
    _globalRotationController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    _polygons = widget.polygons ?? _defaultPolygons;

    _morphSequence = _createMorphSequence(_polygons, circularSequence: true);

    _morphController = AnimationController.unbounded(vsync: this);

    // continuous linear rotation
    _globalRotationController = AnimationController(
      duration: const Duration(milliseconds: _globalRotationDurationMs),
      vsync: this,
    );

    _startAnimations();
  }

  List<Morph> _createMorphSequence(
    List<RoundedPolygon> polygons, {
    required bool circularSequence,
  }) {
    final morphs = <Morph>[];

    for (int i = 0; i < polygons.length; i++) {
      if (i + 1 < polygons.length) {
        morphs.add(Morph(polygons[i], polygons[i + 1]));
      } else if (circularSequence) {
        // morph from last shape back to first shape
        morphs.add(Morph(polygons[i], polygons[0]));
      }
    }

    return morphs;
  }

  /// Calculates a scale factor that will be used when scaling the provided [RoundedPolygon]s into a
  /// specified sized container.
  ///
  /// Since the polygons may rotate, a simple [RoundedPolygon.calculateBounds] is not enough to
  /// determine the size the polygon will occupy as it rotates. Using the simple bounds calculation may
  /// result in a clipped shape.
  ///
  /// This function calculates and returns a scale factor by utilizing the
  /// [RoundedPolygon.calculateMaxBounds] and comparing its result to the
  /// [RoundedPolygon.calculateBounds]. The scale factor can later be used when calling [processPath].
  ///
  /// Port of Kotlin implementation.
  double _calculateScaleFactor(List<RoundedPolygon> polygons) {
    var scaleFactor = 1.0;

    for (final polygon in polygons) {
      final bounds = polygon.calculateBounds();
      final maxBounds = polygon.calculateMaxBounds();

      final boundsWidth = bounds[2] - bounds[0];
      final boundsHeight = bounds[3] - bounds[1];

      final maxBoundsWidth = maxBounds[2] - maxBounds[0];
      final maxBoundsHeight = maxBounds[3] - maxBounds[1];

      final scaleX = boundsWidth / maxBoundsWidth;
      final scaleY = boundsHeight / maxBoundsHeight;

      // We use max(scaleX, scaleY) to handle cases like a pill-shape that can throw off the
      // entire calculation.
      scaleFactor = math.min(scaleFactor, math.max(scaleX, scaleY));
    }

    return scaleFactor;
  }

  void _startAnimations() {
    // infinite global rotation
    _globalRotationController.repeat();

    // periodic morph cycle
    _morphTimer = Timer.periodic(
      const Duration(milliseconds: _morphIntervalMs),
      (_) => _startMorphCycle(),
    );

    _startMorphCycle();
  }

  void _startMorphCycle() {
    if (!mounted) return;

    // move to next morph in sequence
    _currentMorphIndex = (_currentMorphIndex + 1) % _morphSequence.length;

    // accumulate rotation target
    _morphRotationTargetAngle =
        (_morphRotationTargetAngle + _quarterRotation) % _fullRotation;

    // Reset and start morph animation
    _morphController
      ..value = 0.0
      ..animateWith(_morphAnimationSpec);
  }
}

class _MorphPainter extends CustomPainter {
  final Morph morph;
  final double progress;
  final Color color;

  /// A scale factor that will be taken into account uniformly when the [path] is
  /// scaled (i.e. the scaleX would be the [size] width x the scale factor, and the scaleY would be
  /// the [size] height x the scale factor)
  final double scaleFactor;

  final ExpressiveLoadingIndicatorStyle style;

  /// Non-null when [style] is [ExpressiveLoadingIndicatorStyle.outlined].
  final double? strokeWidth;

  _MorphPainter({
    required this.morph,
    required this.progress,
    required this.color,
    this.scaleFactor = 1.0,
    this.style = ExpressiveLoadingIndicatorStyle.filled,
    this.strokeWidth,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = morph.toPath(progress: progress);
    final processedPath = _processPath(path, size);

    if (style == ExpressiveLoadingIndicatorStyle.outlined) {
      final w =
          strokeWidth ?? (math.min(size.width, size.height) * (3.0 / 48.0));
      canvas.drawPath(
        processedPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      );
    } else {
      canvas.drawPath(
        processedPath,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) {
    return oldDelegate.morph != morph ||
        oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.scaleFactor != scaleFactor ||
        oldDelegate.style != style ||
        oldDelegate.strokeWidth != strokeWidth;
  }

  /// Process a given path to scale it and center it inside the given size.
  ///
  /// [path] takes a [Path] that was generated by a _normalized_ [Morph] or [RoundedPolygon].
  /// [size] takes a [Size] that the provided [path] is going to be scaled and centered into.
  Path _processPath(Path path, Size size) {
    // a [Matrix] that would be used to apply the scaling. Note that any provided
    // matrix will be reset in this function.
    final Matrix4 scaleMatrix = Matrix4.diagonal3Values(
      size.width * scaleFactor,
      size.height * scaleFactor,
      1,
    );
    final Path scaledPath = path.transform(scaleMatrix.storage);

    // Translate the path so that its center aligns with the center of the container.
    final Rect bounds = scaledPath.getBounds();
    final Offset translation =
        Offset(size.width / 2, size.height / 2) - bounds.center;
    final Path finalPath = scaledPath.shift(translation);

    return finalPath;
  }
}

/// Material Design 3 **expressive** linear progress indicator with a sinusoidal
/// stroke (aligned with Compose’s
/// [`LinearWavyProgressIndicator`](https://developer.android.com/reference/kotlin/androidx/compose/material3/package-summary)).
///
/// Supports **determinate** mode ([ProgressIndicator.value] between `0.0` and
/// `1.0`) and **indeterminate** mode (`value` is null), with an animated phase so
/// the wave scrolls along the bar when [waveSpeed] is greater than zero.
///
/// The track and active segment are drawn as stroked wave paths; [gapSize] and
/// the optional stop indicator follow the same ideas as Material 3’s
/// [LinearProgressIndicator] track gap / stop treatment.
class ExpressiveLinearProgressIndicator extends ProgressIndicator {
  /// Minimum height of the indicator (the bar’s vertical extent).
  ///
  /// If null, [ProgressIndicatorThemeData.linearMinHeight] is used, then `4`.
  final double? minHeight;

  /// Corner radius for clipping the bar. If null, uses
  /// [ProgressIndicatorThemeData.borderRadius] when available, otherwise no clip.
  final BorderRadiusGeometry? borderRadius;

  /// Horizontal length of one full wave cycle, in logical pixels.
  ///
  /// Material 3 expressive defaults use a short wavelength relative to width;
  /// `24` is a reasonable default at typical bar widths.
  final double? wavelength;

  /// How fast the wave scrolls, in logical pixels per second.
  ///
  /// Defaults to [wavelength] so the pattern advances by about one wavelength
  /// per second (matching Compose’s default pairing).
  final double? waveSpeed;

  /// Wave height as a fraction of the half-bar (before stroke inset), `0`–`1`.
  ///
  /// `0` yields a flat line; `1` uses the maximum amplitude that still fits
  /// inside [minHeight] with the current stroke widths.
  final double? amplitude;

  /// Space between the determinate progress head and the round stop indicator.
  ///
  /// If null, [ProgressIndicatorThemeData.trackGap] is used, then `4`.
  final double? gapSize;

  /// Radius of the circular cap at the end of the track (determinate only).
  ///
  /// If null, [ProgressIndicatorThemeData.stopIndicatorRadius] is used, then `2`.
  /// Set to `0` to hide the stop.
  final double? stopIndicatorRadius;

  /// Color of the stop indicator. If null, uses [ProgressIndicatorThemeData],
  /// then the indicator [color].
  final Color? stopIndicatorColor;

  /// Stroke width of the active (value) wave. If null, derived from [minHeight].
  final double? indicatorStrokeWidth;

  /// Stroke width of the track wave. If null, matches [indicatorStrokeWidth].
  final double? trackStrokeWidth;

  /// Optional [AnimationController] for indeterminate wave phase (`value == null`).
  ///
  /// The controller’s value is expected to run `0.0` → `1.0` linearly for one
  /// cycle; the widget will [AnimationController.repeat] the internal controller
  /// when this is null.
  final AnimationController? controller;

  // ignore: prefer_const_constructors_in_immutables — asserts reference fields.
  ExpressiveLinearProgressIndicator({
    super.key,
    super.value,
    super.backgroundColor,
    super.color,
    super.valueColor,
    this.minHeight,
    this.borderRadius,
    this.wavelength,
    this.waveSpeed,
    this.amplitude,
    this.gapSize,
    this.stopIndicatorRadius,
    this.stopIndicatorColor,
    this.indicatorStrokeWidth,
    this.trackStrokeWidth,
    this.controller,
    super.semanticsLabel,
    super.semanticsValue,
  }) : assert(
         value == null || controller == null,
         _kLinearValueControllerAssertion,
       ),
       assert(minHeight == null || minHeight > 0),
       assert(wavelength == null || wavelength > 0),
       assert(waveSpeed == null || waveSpeed > 0),
       assert(amplitude == null || (amplitude >= 0 && amplitude <= 1));

  /// Default duration for one full phase cycle when [waveSpeed] equals
  /// [wavelength] (one wavelength per second).
  static Duration defaultWaveDuration({
    required double wavelength,
    required double waveSpeed,
  }) {
    final ms = (1000.0 * wavelength / waveSpeed).round().clamp(400, 8000);
    return Duration(milliseconds: ms);
  }

  @override
  State<ExpressiveLinearProgressIndicator> createState() =>
      _ExpressiveLinearProgressIndicatorState();
}

class _ExpressiveLinearProgressIndicatorState
    extends State<ExpressiveLinearProgressIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _internalController;

  @override
  void initState() {
    super.initState();
    final w = widget.wavelength ?? _WavyLinearPainter.kDefaultWavelength;
    final s = widget.waveSpeed ?? w;
    _internalController = AnimationController(
      vsync: this,
      duration: ExpressiveLinearProgressIndicator.defaultWaveDuration(
        wavelength: w,
        waveSpeed: s,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _manageInternalControllerRepeat();
  }

  @override
  void didUpdateWidget(covariant ExpressiveLinearProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wavelength != widget.wavelength ||
        oldWidget.waveSpeed != widget.waveSpeed) {
      final w = widget.wavelength ?? _WavyLinearPainter.kDefaultWavelength;
      final s = widget.waveSpeed ?? w;
      _internalController.duration =
          ExpressiveLinearProgressIndicator.defaultWaveDuration(
            wavelength: w,
            waveSpeed: s,
          );
    }
    if (oldWidget.controller != widget.controller &&
        widget.controller != null) {
      _internalController.stop();
    }
    _manageInternalControllerRepeat();
  }

  /// Repeats the internally owned controller whenever it drives the wave
  /// (including determinate mode, so the wave scrolls per M3 expressive spec).
  void _manageInternalControllerRepeat() {
    if (!identical(_waveController, _internalController)) {
      return;
    }
    if (!_internalController.isAnimating) {
      _internalController.repeat();
    }
  }

  @override
  void dispose() {
    _internalController.dispose();
    super.dispose();
  }

  AnimationController get _waveController {
    if (widget.value == null) {
      return widget.controller ??
          ProgressIndicatorTheme.of(context).controller ??
          _internalController;
    }
    // Determinate: wave phase always uses the internal controller so a theme
    // indeterminate controller does not override (see [LinearProgressIndicator]).
    return _internalController;
  }

  @override
  Widget build(BuildContext context) {
    final ProgressIndicatorThemeData indicatorTheme = ProgressIndicatorTheme.of(
      context,
    );
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final Color trackColor =
        widget.backgroundColor ??
        indicatorTheme.linearTrackColor ??
        scheme.surfaceContainerHighest;

    final double resolvedMinHeight =
        widget.minHeight ?? indicatorTheme.linearMinHeight ?? 4.0;

    final BorderRadiusGeometry? effectiveRadius =
        widget.borderRadius ?? indicatorTheme.borderRadius;

    final double gap = widget.gapSize ?? indicatorTheme.trackGap ?? 4.0;
    final double stopR =
        widget.stopIndicatorRadius ?? indicatorTheme.stopIndicatorRadius ?? 2.0;

    final Color indicatorColor =
        widget.valueColor?.value ??
        widget.color ??
        indicatorTheme.color ??
        scheme.primary;

    final Color resolvedStopColor =
        widget.stopIndicatorColor ??
        indicatorTheme.stopIndicatorColor ??
        indicatorColor;

    final TextDirection textDirection = Directionality.of(context);

    final double wavelength =
        widget.wavelength ?? _WavyLinearPainter.kDefaultWavelength;

    return AnimatedBuilder(
      animation: _waveController,
      builder: (BuildContext context, Widget? _) {
        Widget child = ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: double.infinity,
            minHeight: resolvedMinHeight,
          ),
          child: CustomPaint(
            painter: _WavyLinearPainter(
              trackColor: trackColor,
              indicatorColor: indicatorColor,
              stopIndicatorColor: resolvedStopColor,
              value: widget.value,
              phaseT: _waveController.value,
              textDirection: textDirection,
              wavelength: wavelength,
              amplitude: widget.amplitude ?? 1.0,
              gapSize: gap,
              stopIndicatorRadius: stopR,
              indicatorStrokeWidth: widget.indicatorStrokeWidth,
              trackStrokeWidth: widget.trackStrokeWidth,
              minHeight: resolvedMinHeight,
              repaint: _waveController,
            ),
          ),
        );

        if (effectiveRadius != null) {
          child = ClipRRect(
            borderRadius: effectiveRadius.resolve(textDirection),
            child: child,
          );
        }

        String? expandedSemanticsValue = widget.semanticsValue;
        if (widget.value != null) {
          expandedSemanticsValue ??=
              '${(clampDouble(widget.value!, 0.0, 1.0) * 100).round()}%';
        }

        return Semantics(
          label: widget.semanticsLabel,
          value: expandedSemanticsValue,
          child: child,
        );
      },
    );
  }
}

class _WavyLinearPainter extends CustomPainter {
  _WavyLinearPainter({
    required this.trackColor,
    required this.indicatorColor,
    required this.stopIndicatorColor,
    required this.value,
    required this.phaseT,
    required this.textDirection,
    required this.wavelength,
    required this.amplitude,
    required this.gapSize,
    required this.stopIndicatorRadius,
    required this.minHeight,
    this.indicatorStrokeWidth,
    this.trackStrokeWidth,
    super.repaint,
  });

  static const double kDefaultWavelength = 24.0;

  final Color trackColor;
  final Color indicatorColor;
  final Color stopIndicatorColor;
  final double? value;
  final double phaseT;
  final TextDirection textDirection;
  final double wavelength;
  final double amplitude;
  final double gapSize;
  final double stopIndicatorRadius;
  final double minHeight;
  final double? indicatorStrokeWidth;
  final double? trackStrokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    if (w <= 0 || h <= 0) {
      return;
    }

    final double iStroke = math.min(
      indicatorStrokeWidth ?? math.min(6.0, minHeight),
      h,
    );
    final double tStroke = math.min(trackStrokeWidth ?? iStroke, h);

    final double maxAmp =
        (h / 2 - iStroke / 2).clamp(0.0, h / 2) * amplitude.clamp(0.0, 1.0);

    // One controller cycle (see [defaultWaveDuration]) scrolls the pattern by
    // one [wavelength], matching Compose’s default waveSpeed/wavelength pairing.
    final double phaseOffset = phaseT * wavelength;

    final bool ltr = textDirection != TextDirection.rtl;

    double xLogical(double x) => ltr ? x : w - x;

    double waveY(double xLogicalPos) {
      return h / 2 +
          maxAmp *
              math.sin(2 * math.pi * (xLogicalPos + phaseOffset) / wavelength);
    }

    Path wavePathSegment(double x0, double x1) {
      final path = Path();
      final int steps = (w / 2).ceil().clamp(16, 120);
      var started = false;
      for (int i = 0; i <= steps; i++) {
        final double t = i / steps;
        final double xL = x0 + (x1 - x0) * t;
        final double xDraw = xLogical(xL);
        final double y = waveY(xL);
        if (!started) {
          path.moveTo(xDraw, y);
          started = true;
        } else {
          path.lineTo(xDraw, y);
        }
      }
      return path;
    }

    final Paint trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = tStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(wavePathSegment(0, w), trackPaint);

    final Paint indicatorPaint = Paint()
      ..color = indicatorColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = iStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (value == null) {
      canvas.drawPath(wavePathSegment(0, w), indicatorPaint);
      return;
    }

    final double v = clampDouble(value!, 0.0, 1.0);
    if (v <= 0) {
      return;
    }

    final double headLogical = v * w;
    final double clipEndLogical = math.max(0.0, headLogical - gapSize);

    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        ltr ? 0.0 : xLogical(clipEndLogical),
        0.0,
        ltr ? clipEndLogical : w,
        h,
      ),
    );
    canvas.drawPath(wavePathSegment(0, w), indicatorPaint);
    canvas.restore();

    if (stopIndicatorRadius > 0 && v > 1e-3 && v < 1.0 - 1e-3) {
      final double hx = xLogical(headLogical);
      final double hy = waveY(headLogical);
      final Paint stopPaint = Paint()
        ..color = stopIndicatorColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(hx, hy), stopIndicatorRadius, stopPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavyLinearPainter oldDelegate) {
    return oldDelegate.trackColor != trackColor ||
        oldDelegate.indicatorColor != indicatorColor ||
        oldDelegate.stopIndicatorColor != stopIndicatorColor ||
        oldDelegate.value != value ||
        oldDelegate.phaseT != phaseT ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.wavelength != wavelength ||
        oldDelegate.amplitude != amplitude ||
        oldDelegate.gapSize != gapSize ||
        oldDelegate.stopIndicatorRadius != stopIndicatorRadius ||
        oldDelegate.minHeight != minHeight ||
        oldDelegate.indicatorStrokeWidth != indicatorStrokeWidth ||
        oldDelegate.trackStrokeWidth != trackStrokeWidth;
  }
}
