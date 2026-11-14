# material3_expressive_loading_indicator

[![pub package](https://img.shields.io/pub/v/material3_expressive_loading_indicator.svg)](https://pub.dev/packages/material3_expressive_loading_indicator)
[![style: flutter lints](https://img.shields.io/badge/style-flutter__lints-blue.svg)](https://pub.dev/packages/flutter_lints)
[![license: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)

**Material Design 3 expressive loading and progress indicators for Flutter** — bringing Android's newest M3 Expressive animations to the Flutter ecosystem.

<p align="center">
  <a href="https://drive.google.com/file/d/1LTVRxFJB-MDsARDnWICLj9VjPBbHgAGZ/view?usp=sharing">
    <img src="https://raw.githubusercontent.com/priyanshupatra02/material3_expressive_loading_indicator/main/screenshots/demo_screenshot.png" alt="Expressive Loading Indicator Demo" width="320"/>
  </a>
</p>

---

## ✨ Features

| Indicator | Widget | Description |
|---|---|---|
| **Circular (Filled)** | `ExpressiveLoadingIndicator()` | Morphs between rounded polygons with a spring-driven animation — matching Android's `LoadingIndicator`. |
| **Circular (Outlined)** | `ExpressiveLoadingIndicator(style: .outlined)` | Same morphing geometry rendered as a stroked outline for a lighter visual weight. |
| **Linear Wavy** | `ExpressiveLinearProgressIndicator()` | Sinusoidal wavy progress bar supporting both **determinate** and **indeterminate** modes — inspired by Compose's `LinearWavyProgressIndicator`. |

### Why use this package?

- 🎨 **True Material 3 Expressive** — Faithful port of Android's latest M3 Expressive loading indicators
- 🔄 **Shape morphing** — Smooth spring-physics transitions between `RoundedPolygon` shapes (soft burst, cookie, pentagon, pill, sunny, oval, and more)
- 🌊 **Wavy linear progress** — Scrolling sinusoidal wave with configurable wavelength, amplitude, and speed
- 🎛️ **Highly customizable** — Colors, sizes, shapes, stroke widths, wave parameters, gap sizes, and stop indicators
- 🧩 **Theme-aware** — Respects `ProgressIndicatorTheme` and `ColorScheme` out of the box
- ♿ **Accessible** — Full semantics support with `semanticsLabel` and `semanticsValue`
- 📦 **Zero platform dependencies** — Pure Dart/Flutter implementation, works everywhere Flutter runs

---

## 📦 Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  material3_expressive_loading_indicator: ^0.1.0
```

Or install via command line:

```bash
flutter pub add material3_expressive_loading_indicator
```

> **Note:** This package depends on [`material_new_shapes`](https://pub.dev/packages/material_new_shapes) (pulled in automatically). You only need to import it yourself if you pass custom `polygons`.

---

## 🚀 Quick Start

```dart
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';
```

**Drop-in circular loader:**

```dart
const ExpressiveLoadingIndicator()
```

**Drop-in linear progress bar:**

```dart
ExpressiveLinearProgressIndicator()
```

That's it! Both widgets work out of the box with your app's `ThemeData` and `ColorScheme`.

---

## 📖 Usage

### Circular Loading Indicator

#### Default (Filled)

The simplest usage — a morphing shape indicator using the default Material 3 polygon sequence:

```dart
const ExpressiveLoadingIndicator()
```

#### Outlined Style

Render the same morphing geometry as a stroked outline:

```dart
const ExpressiveLoadingIndicator(
  style: ExpressiveLoadingIndicatorStyle.outlined,
)
```

#### Custom Color

```dart
const ExpressiveLoadingIndicator(
  color: Colors.teal,
)
```

#### Custom Size

Control the indicator size via `BoxConstraints`:

```dart
const ExpressiveLoadingIndicator(
  constraints: BoxConstraints(
    minWidth: 72.0,
    minHeight: 72.0,
    maxWidth: 72.0,
    maxHeight: 72.0,
  ),
)
```

#### Custom Shapes

Pass your own sequence of `RoundedPolygon` shapes from [`material_new_shapes`](https://pub.dev/packages/material_new_shapes):

```dart
import 'package:material_new_shapes/material_new_shapes.dart';

ExpressiveLoadingIndicator(
  polygons: [
    MaterialShapes.softBurst,
    MaterialShapes.pill,
    MaterialShapes.pentagon,
  ],
)
```

#### Outlined with Custom Stroke Width & Color

```dart
const ExpressiveLoadingIndicator(
  style: ExpressiveLoadingIndicatorStyle.outlined,
  color: Colors.deepPurple,
  strokeWidth: 4,
)
```

---

### Linear Wavy Progress Indicator

#### Indeterminate Mode

When no `value` is provided, the indicator animates continuously:

```dart
ExpressiveLinearProgressIndicator()
```

#### Determinate Mode

Pass a `value` between `0.0` and `1.0` to show specific progress:

```dart
ExpressiveLinearProgressIndicator(value: 0.6)
```

#### Custom Wave Parameters

Fine-tune the wave appearance:

```dart
ExpressiveLinearProgressIndicator(
  value: 0.72,
  minHeight: 14,
  amplitude: 0.45,       // 0.0 (flat) to 1.0 (full wave)
  wavelength: 30,         // pixels per wave cycle
  waveSpeed: 40,          // pixels per second scroll speed
)
```

#### Custom Colors

```dart
ExpressiveLinearProgressIndicator(
  value: 0.5,
  color: Colors.deepPurple,
  backgroundColor: Colors.deepPurple.withValues(alpha: 0.2),
)
```

#### With Stop Indicator & Gap

```dart
ExpressiveLinearProgressIndicator(
  value: 0.5,
  gapSize: 6,
  stopIndicatorRadius: 3,
  stopIndicatorColor: Colors.deepPurple,
)
```

#### Full-Featured Example

```dart
Scaffold(
  body: Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Circular morphing loader
        const ExpressiveLoadingIndicator(),
        const SizedBox(height: 32),

        // Linear determinate progress
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ExpressiveLinearProgressIndicator(
            value: downloadProgress,  // 0.0 to 1.0
            minHeight: 8,
            amplitude: 0.6,
          ),
        ),
      ],
    ),
  ),
)
```

---

## 🔧 API Reference

### `ExpressiveLoadingIndicator`

A circular loading indicator that morphs between rounded polygon shapes.

| Property | Type | Default | Description |
|---|---|---|---|
| `color` | `Color?` | Theme primary | Fill/stroke color of the indicator. |
| `polygons` | `List<RoundedPolygon>?` | 7 built-in shapes | Sequence of shapes to morph between (minimum 2). |
| `constraints` | `BoxConstraints?` | `48×48` | Size constraints for the indicator. |
| `style` | `ExpressiveLoadingIndicatorStyle` | `filled` | `filled` or `outlined` rendering mode. |
| `strokeWidth` | `double?` | Proportional to size | Stroke width for `outlined` style. |
| `semanticsLabel` | `String?` | `null` | Accessibility label. |
| `semanticsValue` | `String?` | `null` | Accessibility value. |

### `ExpressiveLoadingIndicatorStyle`

| Value | Description |
|---|---|
| `filled` | Solid filled morphing shape (default). |
| `outlined` | Stroked outline of the morphing shape. |

### `ExpressiveLinearProgressIndicator`

A wavy linear progress indicator with sinusoidal stroke animation.

| Property | Type | Default | Description |
|---|---|---|---|
| `value` | `double?` | `null` (indeterminate) | Progress value from `0.0` to `1.0`. `null` for indeterminate. |
| `color` | `Color?` | Theme primary | Color of the active progress wave. |
| `backgroundColor` | `Color?` | `surfaceContainerHighest` | Color of the track wave. |
| `valueColor` | `Animation<Color?>?` | `null` | Animated color (overrides `color`). |
| `minHeight` | `double?` | `4.0` | Vertical height of the bar. |
| `borderRadius` | `BorderRadiusGeometry?` | `null` | Corner radius for clipping. |
| `wavelength` | `double?` | `24.0` | Pixels per full wave cycle. |
| `waveSpeed` | `double?` | `= wavelength` | Scroll speed in pixels/second. |
| `amplitude` | `double?` | `1.0` | Wave height fraction (`0.0`–`1.0`). |
| `gapSize` | `double?` | `4.0` | Gap between progress head and stop indicator. |
| `stopIndicatorRadius` | `double?` | `2.0` | Radius of the stop dot (set `0` to hide). |
| `stopIndicatorColor` | `Color?` | `= color` | Color of the stop indicator dot. |
| `indicatorStrokeWidth` | `double?` | Derived from height | Stroke width of the active wave. |
| `trackStrokeWidth` | `double?` | `= indicatorStrokeWidth` | Stroke width of the track wave. |
| `controller` | `AnimationController?` | Internal | External animation controller for indeterminate phase. |
| `semanticsLabel` | `String?` | `null` | Accessibility label. |
| `semanticsValue` | `String?` | `null` | Accessibility value. |

---

## 🎨 Theming

Both widgets respect Flutter's `ProgressIndicatorTheme`. You can set defaults app-wide:

```dart
MaterialApp(
  theme: ThemeData(
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: Colors.deepPurple,
      linearTrackColor: Colors.deepPurple.withValues(alpha: 0.15),
      linearMinHeight: 6,
      trackGap: 4,
      stopIndicatorRadius: 2,
    ),
  ),
)
```

The widgets also automatically resolve colors from your `ColorScheme`:
- **Circular indicator** → `colorScheme.primary`
- **Linear active wave** → `colorScheme.primary`  
- **Linear track** → `colorScheme.surfaceContainerHighest`

---

## 📂 Example App

A full demo app is included in the [`example/`](example/) directory with interactive demonstrations of every feature:

```bash
cd example && flutter run
```

The example includes:
- All circular indicator variants (filled, outlined, custom color, custom size, custom shapes)
- Indeterminate and determinate linear progress
- Interactive sliders for progress and amplitude control

---

## 📋 Requirements

| Requirement | Version |
|---|---|
| **Dart SDK** | `^3.8.1` |
| **Flutter** | `≥ 3.22.0` |

---

## 🔗 See Also

- [Material 3 — Progress indicators](https://m3.material.io/components/progress-indicators/overview)
- [AOSP `LoadingIndicator.kt`](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/LoadingIndicator.kt) (reference implementation)
- [`material_new_shapes`](https://pub.dev/packages/material_new_shapes) — the polygon shapes used by this package
- [`material_loading_indicator`](https://github.com/ksokolovskyi/material_loading_indicator) — alternative implementation with a different API

---

## 🙏 Credits

- [Kostia Sokolovskyi](https://github.com/ksokolovskyi) for [`material_new_shapes`](https://github.com/ksokolovskyi/material_shapes) — the Material shape primitives that power custom polygon morphing.
- [Tamim Arafat](https://github.com/arafatamim) — original circular indicator port from Android's `LoadingIndicator.kt`.
- Linear wavy and outlined extensions build on that foundation.

---

## 📄 License & Attribution

This package is released under the **[MIT License](LICENSE)**.

Portions are derived from the **Android Open Source Project** (Apache 2.0). See [NOTICE](NOTICE) for full details.

---

## 🤝 Contributing

Contributions are welcome! If you find a bug or want to request a feature:

1. [Open an issue](https://github.com/priyanshupatra02/material3_expressive_loading_indicator/issues)
2. Fork the repository
3. Create your feature branch (`git checkout -b feature/amazing-feature`)
4. Commit your changes (`git commit -m 'Add amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request
