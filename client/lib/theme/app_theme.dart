// lib/theme/app_theme.dart
//
// M3 Expressive（Material Design 3 表达性版式）主题生成。
//
// 规范来源（m3.material.io，2026-10 版 M3E）：
//   * 形状：十级圆角刻度（none 0 / xs 4 / s 8 / m 12 / l 16 / l+ 20 /
//     xl 28 / xl+ 32 / xxl 48 / full）。按钮默认映射到 full（胶囊）；
//     信息密集的卡片保持 medium 12；导航栏 / 对话框 28；chips 8。
//   * 色彩：整份配色由 `ColorScheme.fromSeed` / 动态取色推导，
//     「强调容器化」—— secondary / tertiary 的 container 角色是
//     视觉落点（选中态、导航指示器、hero 容器），而不是到处铺 primary。
//   * 动效：M3E 的物理弹簧系统。Flutter 的路线转场按时间 / 曲线做，
//     这里用 MDC-Web 给出的 M3E 弹簧近似曲线（带过冲的空间动效）：
//       入场 ≈ cubic-bezier(0.3, 0, 0.2, 1.5)
//       退场 ≈ cubic-bezier(0.3, 0, 0.7, 0.2)
//     配合「缩放 + 圆角形变」的页面转场（M3E 形状形变特性）。
//   * 排版：M3 基线字阶上叠加「强调」字重（emphasized type styles）：
//     display / headline w800–w700，title w600，body / label 保持基线。
//
// 核心约定不变：整个 App 只有两个 ThemeData（light / dark），
// 全部由 ColorScheme 推导，页面里不出现任何硬编码颜色，
// 「切换主色 → 全 App 立即响应」天然成立。

import 'package:flutter/material.dart';

import '../core/globals.dart';

/// 预设主色。设置页手动选色用。
/// 选色原则：都是适合做 M3 种子色（tonal）的起点色，
/// `ColorScheme.fromSeed` 会由它推导出 30+ 个颜色角色，所以只需要一个种子色。
class PresetSeedColor {
  const PresetSeedColor(this.name, this.color);

  final String name;
  final Color color;
}

const List<PresetSeedColor> kPresetSeedColors = <PresetSeedColor>[
  PresetSeedColor('紫罗兰', Color(0xFF6750A4)),
  PresetSeedColor('薰衣草', Color(0xFF8E7CC3)),
  PresetSeedColor('蓝紫', Color(0xFF5E60CE)),
  PresetSeedColor('靛蓝', Color(0xFF3949AB)),
  PresetSeedColor('湖蓝', Color(0xFF0B57D0)),
  PresetSeedColor('天蓝', Color(0xFF0288D1)),
  PresetSeedColor('青蓝', Color(0xFF00838F)),
  PresetSeedColor('青绿', Color(0xFF00696D)),
  PresetSeedColor('薄荷', Color(0xFF00897B)),
  PresetSeedColor('森林', Color(0xFF2E7D32)),
  PresetSeedColor('青柠', Color(0xFF689F38)),
  PresetSeedColor('橄榄', Color(0xFF827717)),
  PresetSeedColor('柠檬', Color(0xFFF9A825)),
  PresetSeedColor('琥珀', Color(0xFFEF6C00)),
  PresetSeedColor('橘橙', Color(0xFFE64A19)),
  PresetSeedColor('赤红', Color(0xFFC62828)),
  PresetSeedColor('玫瑰', Color(0xFFD81B60)),
  PresetSeedColor('洋红', Color(0xFFAD1457)),
  PresetSeedColor('莓果', Color(0xFF880E4F)),
  PresetSeedColor('暖棕', Color(0xFF5D4037)),
  PresetSeedColor('焦糖', Color(0xFF795548)),
  PresetSeedColor('石墨', Color(0xFF455A64)),
  PresetSeedColor('蓝灰', Color(0xFF546E7A)),
  PresetSeedColor('中性灰', Color(0xFF616161)),
];

/// M3 Expressive 形状刻度（dp）。组件取哪个刻度见 buildTheme 里的注释；
/// 嵌套容器遵循「外半径 − 内边距 = 内半径」的光学圆度。
/// MD3 默认种子色（紫罗兰），设置页的持久化默认值。
const Color kDefaultSeedColor = Color(0xFF6750A4);

/// M3 Expressive 形状刻度（dp）。组件取哪个刻度见 buildTheme 里的注释；
/// 嵌套容器遵循「外半径 − 内边距 = 内半径」的光学圆度。
abstract final class M3EShape {
  static const double extraSmall = 4;
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
  static const double largeIncreased = 20;
  static const double extraLarge = 28;
  static const double extraLargeIncreased = 32;
  static const double extraExtraLarge = 48;
}

/// M3 Expressive 动效常量。
///
/// 曲线取值对齐 MDC-Web 的 M3E 弹簧近似值（空间动效带过冲），
/// effects（颜色 / 透明度）类弹簧不过冲。
abstract final class M3EMotion {
  /// 入场 / 默认：带过冲的空间弹簧近似
  static const Curve springIn = Cubic(0.3, 0.0, 0.2, 1.5);

  /// 退场：加速曲线
  static const Curve springOut = Cubic(0.3, 0.0, 0.7, 0.2);

  /// 颜色 / 透明度类 effects 弹簧（不过冲）
  static const Curve effectIn = Cubic(0.05, 0.7, 0.1, 1.0);

  /// 快（小元素）/ 默认 / 慢（大面积）三档，M3E 空间弹簧的三档速度
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration standard = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 500);
}

/// 在 M3 基线字阶上叠加「强调」字重（emphasized type styles）。
/// 只动字重与字距，不动字号 —— 字号仍由系统 / 平台管（含字体缩放），
/// 强调风格只负责「这一行是重点」。
class M3EType {
  const M3EType._();

  static TextStyle emphasize(TextStyle? base, {required FontWeight weight}) {
    if (base == null) return const TextStyle();
    return base.copyWith(
      fontWeight: weight,
      letterSpacing: (base.letterSpacing ?? 0) - 0.25,
    );
  }
}

class AppTheme {
  const AppTheme._();

  /// 生成 ColorScheme。
  /// 优先级：动态取色（系统壁纸色） > 手动种子色。
  static ColorScheme buildScheme({
    required Brightness brightness,
    required Color seed,
    ColorScheme? dynamicScheme,
  }) {
    if (dynamicScheme != null && dynamicScheme.brightness == brightness) {
      return dynamicScheme;
    }
    return ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  }

  /// 由 ColorScheme 构建 M3 Expressive 主题的 ThemeData。
  ///
  /// 设计说明：
  /// * 组件主题参数全部取「*ThemeData」形态（Flutter 3.41+ 的命名），
  ///   与工程的 3.47 SDK 一致；组件默认值仍保留 M3 语义，
  ///   这里只覆写 M3E 有明确规定的部分。
  /// * 颜色一律取自 ColorScheme，绝不硬编码；动态取色 / 换种子色时，
  ///   所有主题数据随 ColorScheme 一起重新推导，全 App 即时响应。
  static ThemeData buildTheme(ColorScheme scheme) {
    // 页内路由转场（M3E 的缩放 + 圆角形变）
    final M3EPageTransitions pageTransitions = M3EPageTransitions();

    // 强调字重叠在 M3 默认字阶上（保留默认字号 / 行高基线）。
    // 字阶的字号由 typography 决定，文字颜色随亮度取 white / black。
    final Typography typography = Typography.material2021(
      platform: TargetPlatform.android,
      colorScheme: scheme,
    );
    final TextTheme baseText =
        scheme.brightness == Brightness.dark
            ? typography.white
            : typography.black;

    final WidgetStateProperty<TextStyle?> labelStyleAll =
        WidgetStatePropertyAll<TextStyle?>(
      baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );

    return ThemeData(
      // Flutter 3.16 起 useMaterial3 默认为 true，这里显式写出以表达意图
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.adaptivePlatformDensity,

      // M3E 页面转场：缩放 + 圆角形变（覆盖默认的滑动转场）
      pageTransitionsTheme: pageTransitions,

      // 状态水波：M3 的 InkSparkle（替代旧版圆斑水波）
      splashFactory: InkSparkle.splashFactory,

      // 文字：M3E emphasized type styles（标题更重，正文不动）
      textTheme: TextTheme(
        displayLarge: M3EType.emphasize(baseText.displayLarge,
            weight: FontWeight.w800),
        displayMedium: M3EType.emphasize(baseText.displayMedium,
            weight: FontWeight.w700),
        displaySmall: M3EType.emphasize(baseText.displaySmall,
            weight: FontWeight.w700),
        headlineLarge: M3EType.emphasize(baseText.headlineLarge,
            weight: FontWeight.w800),
        headlineMedium: M3EType.emphasize(baseText.headlineMedium,
            weight: FontWeight.w700),
        headlineSmall: M3EType.emphasize(baseText.headlineSmall,
            weight: FontWeight.w700),
        titleLarge: M3EType.emphasize(baseText.titleLarge,
            weight: FontWeight.w600),
        titleMedium: M3EType.emphasize(baseText.titleMedium,
            weight: FontWeight.w600),
        titleSmall: M3EType.emphasize(baseText.titleSmall,
            weight: FontWeight.w600),
        // body / label 保持 M3 基线字重，避免正文变「吼」
        bodyLarge: baseText.bodyLarge,
        bodyMedium: baseText.bodyMedium,
        bodySmall: baseText.bodySmall,
        labelLarge: M3EType.emphasize(baseText.labelLarge,
            weight: FontWeight.w600),
        labelMedium: baseText.labelMedium,
        labelSmall: baseText.labelSmall,
      ),

      // ------------------------------------------------ 形状（M3E）
      // 卡片：medium 12（信息密集组件不上大圆角）
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(M3EShape.medium),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      // 对话框：extra large 28
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(M3EShape.extraLarge),
        ),
      ),
      // 底部弹窗：28 圆角 + 拖动手柄
      bottomSheetTheme: BottomSheetThemeData(
        modalBackgroundColor: scheme.surfaceContainerHigh,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      // 菜单：medium 12
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(M3EShape.medium),
            ),
          ),
        ),
      ),
      // SnackBar：small 8，M3E 里 snackbar 用较小圆角 + 悬浮
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: baseText.bodyMedium?.copyWith(
          color: scheme.onSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(M3EShape.small),
        ),
      ),
      // chips：small 8（M3E 明确 chips 用 small）
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(M3EShape.small),
        ),
        // 选中态用 secondaryContainer（容器化强调）
        selectedColor: scheme.secondaryContainer,
        secondarySelectedColor: scheme.secondaryContainer,
        checkmarkColor: scheme.onSecondaryContainer,
        labelStyle: baseText.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: baseText.labelLarge?.copyWith(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),

      // 按钮：M3E 全部映射到 full（胶囊）
      filledButtonTheme: FilledButtonThemeData(
        style: _buttonStyle(labelStyleAll),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _buttonStyle(labelStyleAll),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _buttonStyle(labelStyleAll),
      ),
      // 分段按钮：medium 12（不是胶囊）
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(M3EShape.medium),
            ),
          ),
        ),
      ),

      // ------------------------------------------------ 导航（M3E）
      // 手机底部栏：tonal 底色 + 胶囊指示器
      navigationBarTheme: NavigationBarThemeData(
        height: 80,
        elevation: 0,
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
          (Set<WidgetState> states) {
            final bool selected = states.contains(WidgetState.selected);
            return baseText.labelMedium?.copyWith(
              color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : null,
            );
          },
        ),
      ),
      // 平板侧栏：胶囊指示器
      navigationRailTheme: NavigationRailThemeData(
        elevation: 0,
        useIndicator: true,
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        selectedIconTheme: IconThemeData(color: scheme.onSurface),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: baseText.labelMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: baseText.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      // 顶部栏：M3E tonal app bar —— 滚动后浮起一层 surfaceContainerHigh
      appBarTheme: AppBarThemeData(
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: M3EType.emphasize(baseText.titleLarge,
            weight: FontWeight.w700),
        actionsIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),

      // 搜索框：M3E full 胶囊（SearchBarThemeData 的字段是 WidgetStateProperty 型）
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll<double?>(0),
        backgroundColor: WidgetStatePropertyAll<Color?>(
          scheme.surfaceContainerHigh,
        ),
        shape: const WidgetStatePropertyAll<OutlinedBorder?>(StadiumBorder()),
        hintStyle: WidgetStatePropertyAll<TextStyle?>(
          baseText.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          baseText.bodyLarge?.copyWith(color: scheme.onSurface),
        ),
      ),

      // 输入框：filled 8 / outlined 4（M3E 保持克制的小圆角）
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        // filled 输入框的「描边」其实是一条看不见的框，圆角 8
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(M3EShape.small),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(M3EShape.small),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(M3EShape.small),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        // 弹窗里的 outlined 输入框保持描边（outlineBorder 是 BorderSide，
        // 不是 InputBorder —— 描边宽度 / 颜色在这里给）
        outlineBorder: BorderSide(color: scheme.outline),
      ),

      // 列表：M3E 圆角容器（圆角由分组卡片负责，列表本身不加圆角；
      // 这里只收紧选中态与高度）
      listTileTheme: ListTileThemeData(
        minVerticalPadding: 8,
        minLeadingWidth: 40,
        selectedColor: scheme.secondaryContainer,
        selectedTileColor: scheme.surfaceContainerHigh,
      ),

      // 角标：错误容器色
      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.error,
        textColor: scheme.onError,
      ),

      // 进度：主色 + M3E 稍粗一档的描边
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
        strokeWidth: 4,
      ),

      // 分割线：M3 的 outlineVariant
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // 工具提示：M3E tonal 容器
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(M3EShape.extraSmall),
        ),
        textStyle: baseText.labelMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
    );
  }

  /// 三种按钮共用的 M3E 样式：full 胶囊 + emphasized label（w600）。
  /// 颜色交给各按钮的 M3 默认 state 解析（primary / surfaceContainerHigh /
  /// error 等），这里只改形状与文字，避免硬编码把主题锁死。
  static ButtonStyle _buttonStyle(WidgetStateProperty<TextStyle?> label) {
    return ButtonStyle(
      shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
      textStyle: label,
    );
  }

  /// 统一反馈入口：MD3 风格 Toast（浮动 SnackBar）。
  /// JSBridge 的 `lemonlite.showToast` 也走这里，保证宿主与小程序反馈一致。
  ///
  /// 该用哪个 ScaffoldMessenger 取决于**谁在最上面**：
  ///   * 小程序是覆盖在路由之上的一个层（Overlay），前台且没有路由压在它上面时，
  ///     必须用小程序层的 messenger —— 宿主层的 SnackBar 会被覆盖层挡住；
  ///   * 一旦有路由压在小程序之上（例如从悬浮菜单进入权限管理），
  ///     就得换回宿主层，否则 SnackBar 会被那个页面挡住。
  /// SnackBar 是由 Scaffold 渲染的，而路由栈顶上那个 Scaffold 属于宿主 messenger，
  /// 所以这个判断用 `canPop()`（栈里是否还有别的路由）就够准确。
  static void showToast(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 2),
  }) {
    final NavigatorState? navigator = lemonNavigatorKey.currentState;
    final bool miniappOnTop =
        miniappForegroundActive && !(navigator?.canPop() ?? false);
    final ScaffoldMessengerState? messenger = miniappOnTop
        ? (lemonMiniappMessengerKey.currentState ??
              lemonScaffoldMessengerKey.currentState)
        : lemonScaffoldMessengerKey.currentState;
    final String text = message.trim();
    if (messenger == null || text.isEmpty) return;

    // 用「非空的错误配色」这个局部变量承接：
    // Dart 的类型提升只认局部变量的 null 检查，不会因为另一个 bool 为 true 就把
    // ColorScheme? 提升成 ColorScheme，所以这里不能直接写 scheme.onErrorContainer。
    final ColorScheme? errorScheme = (isError && currentColorScheme != null)
        ? currentColorScheme
        : null;

    // 连续提示时不要排队，直接替换，避免 Toast 堆叠
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: <Widget>[
            if (errorScheme != null) ...<Widget>[
              Icon(
                Icons.error_outline,
                size: 20,
                color: errorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                text,
                style: errorScheme == null
                    ? null
                    : TextStyle(color: errorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: duration,
        backgroundColor: errorScheme?.errorContainer,
        margin: const EdgeInsets.all(16),
      ),
    );
  }
}

// ============================================================
// M3 Expressive 页面转场
//
// 这里做过一次**为了流畅度**的重写，值得记一下为什么：
//
// 上一版是「整页缩放 + 逐帧变化的圆角裁剪 + 淡入」，
// 视觉上确实像 M3E 的 shape morph，但代价是每一帧都要：
//   1. 用一个逐帧变化的圆角去 ClipRRect 整屏（要做路径裁剪）；
//   2. Transform.scale 整屏（缩放值在变，光栅缓存失效，整屏重画）；
//   3. FadeTransition 再套一层透明度。
// 中端手机上导航一次就掉十几帧 —— 用户的感觉就是「点一下卡一下」。
//
// 现在只做**合成器友好**的两件事：位移（Transform.translate）与透明度。
// 这两者都是 GPU 层的合成操作，不触发重绘，帧率能稳住 60/120。
// 圆角形变交给 Android 自己的容器转场（系统级，比我们在 Dart 层算快得多）。
// ============================================================

class M3EPageTransitions extends PageTransitionsTheme {
  M3EPageTransitions()
      : super(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: _M3EAndroidBuilder(),
            // 非 Android 保持系统默认（缩放 / 滑动 / iOS 横推）
            TargetPlatform.iOS: PredictiveBackPageTransitionsBuilder(),
            TargetPlatform.macOS: PredictiveBackPageTransitionsBuilder(),
            TargetPlatform.windows: PredictiveBackPageTransitionsBuilder(),
            TargetPlatform.linux: PredictiveBackPageTransitionsBuilder(),
          },
        );
}

/// Android：手势返回用系统的 predictive back；普通导航用「右滑 + 淡入」
class _M3EAndroidBuilder extends PageTransitionsBuilder {
  const _M3EAndroidBuilder();

  @override
  Duration get transitionDuration => M3EMotion.standard;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 手势返回时走系统 predictive back（能跟手），普通导航走自定义转场
    if (route.popGestureInProgress) {
      return const PredictiveBackPageTransitionsBuilder().buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }

    // 位移用带过冲的空间弹簧（0.3,0,0.2,1.5）：会先冲过目标再回弹一点点，
    // 这是 M3E「express」的辨识度所在，而位移过冲只是多几像素的平移，不花钱。
    final Animation<double> slideCurve = CurvedAnimation(
      parent: animation,
      curve: M3EMotion.springIn,
      reverseCurve: M3EMotion.springOut,
    );
    // 透明度不过冲（>1 会被裁掉，<0 会闪黑），且只在前 40% 走完
    final Animation<double> fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
      reverseCurve: const Interval(0.0, 0.4, curve: Curves.easeIn),
    );

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.045, 0),
        end: Offset.zero,
      ).animate(slideCurve),
      child: FadeTransition(opacity: fade, child: child),
    );
  }
}
