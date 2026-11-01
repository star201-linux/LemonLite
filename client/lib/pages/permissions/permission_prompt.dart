// lib/pages/permissions/permission_prompt.dart
//
// 权限确认弹窗（这一版权限模型的核心）。
//
// 规则只有一条：**没问过就必须问**。
// 受控权限第一次被调用时，宿主弹窗让用户选「允许 / 拒绝」，然后把选择落盘；
// 之后同一个小程序再调这个权限就不再打断。用户的选择随时可以在
// 「设置 → 应用 → 权限管理器」里改回「询问」，那之后就重新开始问。
//
// 弹窗的形态（这一版按需求重做）：
//   /小程序图标/                        ← 顶部的应用图标
//   允许 xx 使用 xx 权限吗？             ← 一句话标题
//   允许 / 拒绝                          ← 两个按钮
//   [✓] 仅本次生效                       ← 复选框，**默认选中**
//
// 「仅本次生效」默认选中意味着：直接点「允许」不会留下任何持久记录，
// 下次调用照问。要让它长期生效，用户必须**主动取消勾选**。
// 这是刻意的默认值 —— 权限弹窗最容易被当成拦路虎，手一快点掉「允许」，
// 而这个决定会一直生效；默认不记住就把长期授权变成一个有意识的选择。
//
// 为什么把弹窗逻辑单独放一个服务，而不是写在桥接层里：
//   1. **串行化**：对话框是模态的，同时弹两个会让人不知道在答哪一个。
//      所有弹窗走同一个队列，一次只显示一个。
//   2. **去重**：同一个小程序在同一瞬间可能连着调两次同一个权限，
//      那应该共用同一个弹窗与同一个答案，而不是让用户答两遍。
//   3. 桥接层要能在测试里被注入一个"假弹窗"，否则每条断言都要起一个真实的 Widget 树。
//
// 两条触发路径：
//   * [ensure]          —— 单个权限被调用时（兜底，保证"绝不静默放行"）
//   * [requestDeclared] —— 打开小程序时按 index.json 里的声明批量确认一次

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/autotest.dart';
import '../../core/globals.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/services/application_registry.dart';
import '../../data/services/permission_service.dart';
import '../../theme/app_theme.dart';
import '../home/widgets/app_icon.dart';
import 'widgets/permission_chips.dart';

class PermissionPromptService {
  PermissionPromptService._();

  static final PermissionPromptService instance = PermissionPromptService._();

  /// 正在弹的弹窗：key = `appId|permissionId`，value = 共享的答案
  final Map<String, Future<PermissionAnswer>> _inFlight =
      <String, Future<PermissionAnswer>>{};

  /// 弹窗队列（保证同一时刻只有一个对话框）
  Future<void> _queue = Future<void>.value();

  /// 已经弹过几次（自检日志用）
  int _shownCount = 0;

  /// 对话框自己的截图边界（自检用）。
  /// 只框住对话框而不是整屏：它是纯 Flutter 图层，截图一定成功。
  final GlobalKey _dialogBoundaryKey = GlobalKey();

  int get shownCount => _shownCount;

  // ------------------------------------------------- WebView 权限请求入口

  /// 网页（小程序）发起浏览器权限请求时，逐个权限问用户，返回**被允许的集合**。
  ///
  /// 这是 `onPermissionRequest` 的落地实现：调用方（miniapp_page）把 Chromium
  /// 的资源列表翻译成框架权限后交给这里，我们保证每一项都经过用户本人同意 ——
  /// 「仅本次生效」的那次同意同样只对当前这次请求有效（它不会落盘，
  /// 下次 getUserMedia 还会再问）。
  ///
  /// 之所以**逐项**问而不是合成一个弹窗：摄像头与麦克风是两项独立的能力，
  /// 用户完全可能只想给麦克风。合成一个「允许/拒绝」会强迫他全给或全不给。
  Future<Set<MiniappPermission>> ensureAll(
    String appId,
    Iterable<MiniappPermission> permissions, {
    String? appName,
  }) async {
    final Set<MiniappPermission> granted = <MiniappPermission>{};
    for (final MiniappPermission permission in permissions) {
      final PermissionAnswer answer = await ensure(
        appId,
        permission,
        appName: appName,
      );
      if (answer.allowed) granted.add(permission);
    }
    return granted;
  }

  /// 纯函数：从"声明过的权限"里挑出还需要问的。
  ///
  /// 输出顺序固定按 [MiniappPermission.values] 走，而不是按 index.json 的书写顺序 ——
  /// 弹窗里的条目顺序稳定，用户第二次看到同样的清单不会觉得界面在乱跳。
  static List<MiniappPermission> pendingDeclared({
    required String appId,
    required Iterable<MiniappPermission> declared,
    PermissionService? service,
  }) {
    final PermissionService svc = service ?? PermissionService.instance;
    final Set<MiniappPermission> wanted = declared.toSet();
    return MiniappPermission.values
        .where(
          (MiniappPermission p) =>
              wanted.contains(p) &&
              svc.decisionOf(appId, p) == PermissionDecision.ask,
        )
        .toList(growable: false);
  }

  // ------------------------------------------------------------ 单权限入口

  /// 保证某个权限有一个明确的用户决定。返回用户的答案。
  ///
  /// * 已允许 → 直接放行；
  /// * 已拒绝 → 直接拒绝；
  /// * 未决定 → 排队弹窗（同一个 key 的并发请求共用一次弹窗）。
  Future<PermissionAnswer> ensure(
    String appId,
    MiniappPermission permission, {
    String? appName,
  }) {
    final PermissionDecision decided = PermissionService.instance.decisionOf(
      appId,
      permission,
    );
    if (decided == PermissionDecision.granted) {
      return Future<PermissionAnswer>.value(PermissionAnswer.allowAlways);
    }
    if (decided == PermissionDecision.denied) {
      return Future<PermissionAnswer>.value(PermissionAnswer.denyAlways);
    }

    final String key = '$appId|${permission.id}';
    final Future<PermissionAnswer>? running = _inFlight[key];
    if (running != null) return running;

    final Future<PermissionAnswer> future = _serialize(
      () => _askSingle(appId, appName ?? appId, permission),
    );
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<PermissionAnswer> _askSingle(
    String appId,
    String appName,
    MiniappPermission permission,
  ) async {
    // 排到队时可能已经被别的路径问过了（批量弹窗 / 另一次调用）
    final PermissionDecision decided = PermissionService.instance.decisionOf(
      appId,
      permission,
    );
    if (decided != PermissionDecision.ask) {
      return decided == PermissionDecision.granted
          ? PermissionAnswer.allowAlways
          : PermissionAnswer.denyAlways;
    }

    final BuildContext? context = _overlayContext();
    if (context == null) {
      // 拿不到可以弹窗的地方：**拒绝**（fail closed），并且不写决定 ——
      // 下次有界面时还能正常询问，而不是被这次意外永久拒绝。
      await autotestLog('弹窗无法显示（无可用 Navigator），${permission.id} 本次按拒绝处理');
      AppTheme.showToast('无法弹出权限确认，本次调用已拒绝', isError: true);
      return PermissionAnswer.denyOnce;
    }

    await autotestLog('弹出权限确认：$appId / ${permission.id}（$appName）');
    if (!context.mounted) return PermissionAnswer.denyOnce;
    final Future<PermissionAnswer?> pending = showDialog<PermissionAnswer>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext ctx) => RepaintBoundary(
        key: _dialogBoundaryKey,
        child: _singleDialog(ctx, appId, appName, permission),
      ),
    );
    final PermissionAnswer? answer = await _resolveAnswer(
      context,
      pending,
      permission,
      batch: false,
    );

    if (answer == null) {
      // 蒙层关闭 = 本次拒绝，但**不写决定**：下次调用还会问。
      await autotestLog('权限确认被关闭：${permission.id} → 本次拒绝（不落盘）');
      return PermissionAnswer.denyOnce;
    }

    // 只有勾掉「仅本次生效」才落盘
    if (answer.remember) {
      await PermissionService.instance.setDecision(
        appId,
        permission,
        answer.allowed ? PermissionDecision.granted : PermissionDecision.denied,
      );
      await autotestLog(
        '权限确认结果：${permission.id} → ${answer.allowed ? "允许" : "拒绝"}（已落盘，长期生效）',
      );
    } else {
      await autotestLog(
        '权限确认结果：${permission.id} → ${answer.allowed ? "允许" : "拒绝"}（仅本次，不落盘）',
      );
    }
    return answer;
  }

  // ------------------------------------------------------------ 批量入口

  /// 打开小程序时，按 index.json 里声明的权限一次性确认。
  ///
  /// 声明过的权限合并成一个弹窗，是为了让"用户要答几次"变成常数 1，
  /// 而不是随着小程序用了多少 API 增长。没声明的权限仍然走 [ensure] 兜底。
  Future<void> requestDeclared({
    required String appId,
    required String appName,
    required List<MiniappPermission> declared,
  }) async {
    if (declared.isEmpty) return;
    final List<MiniappPermission> pending = pendingDeclared(
      appId: appId,
      declared: declared,
    );
    if (pending.isEmpty) return;

    await _serialize(() async {
      // 排队期间可能已经问过一部分
      final List<MiniappPermission> stillPending = pendingDeclared(
        appId: appId,
        declared: pending,
      );
      if (stillPending.isEmpty) return;

      final BuildContext? context = _overlayContext();
      if (context == null) {
        // 弹不出来就什么都不写：真正用到时 ensure 会再问一次（不静默放行）
        await autotestLog('批量权限弹窗无法显示，推迟到实际调用时再问');
        return;
      }

      await autotestLog(
        '弹出批量权限确认：$appId → ${stillPending.map((MiniappPermission p) => p.id).join(",")}',
      );
      if (!context.mounted) return;
      final Future<PermissionAnswer?> pendingAnswer =
          showDialog<PermissionAnswer>(
        context: context,
        barrierDismissible: true,
        builder: (BuildContext ctx) => RepaintBoundary(
          key: _dialogBoundaryKey,
          child: _batchDialog(ctx, appId, appName, stillPending),
        ),
      );
      final PermissionAnswer? answer = await _resolveAnswer(
        context,
        pendingAnswer,
        stillPending.first,
        batch: true,
      );

      if (answer == null) {
        await autotestLog('批量权限确认被关闭：不落盘，稍后按需再问');
        return;
      }
      if (!answer.remember) {
        // 仅本次：声明过的这批权限一个都不落盘，之后逐项再问
        await autotestLog('批量权限确认：仅本次生效，不落盘');
        return;
      }
      for (final MiniappPermission p in stillPending) {
        await PermissionService.instance.setDecision(
          appId,
          p,
          answer.allowed ? PermissionDecision.granted : PermissionDecision.denied,
        );
      }
      await autotestLog(
        '批量权限确认结果：${stillPending.length} 项 → ${answer.allowed ? "全部允许" : "全部拒绝"}（已落盘）',
      );
    });
  }

  // ------------------------------------------------------------ 弹窗呈现

  /// 自检模式下由程序回答：**先把真实弹窗渲染出来并截图**，再用
  /// `Navigator.pop` 走和用户点按钮完全相同的路径结束它。
  Future<PermissionAnswer?> _resolveAnswer(
    BuildContext context,
    Future<PermissionAnswer?> pending,
    MiniappPermission permission, {
    required bool batch,
  }) async {
    _shownCount++;
    if (!autotestEnabled) return pending;

    final int index = _shownCount;
    // 等两帧以上再截图：对话框的入场动画约 150ms
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await autotestCapture(
      'prompt-$index-${batch ? "batch" : permission.id}',
      boundaryKey: _dialogBoundaryKey,
    );
    if (context.mounted) {
      // 自检也走「仅本次」路径（remember: false），
      // 于是它验证的正是默认那条分支，而不是一个用户很难触发的分支。
      Navigator.of(context).pop(
        PermissionAnswer(allowed: autotestAllows, remember: false),
      );
    }
    final PermissionAnswer? answer = await pending;
    await autotestLog(
      '自检：弹窗 #$index 由程序回答 → ${answer?.allowed == true ? "允许" : "拒绝"}'
      '（LEMONLITE_AUTOTEST_ANSWER=$kAutotestAnswer）',
    );
    return answer;
  }

  /// 单个权限的确认弹窗。
  ///
  /// 布局按需求：图标 → 「允许 xx 使用 xx 权限吗？」 → 允许/拒绝 → 仅本次生效。
  Widget _singleDialog(
    BuildContext context,
    String appId,
    String appName,
    MiniappPermission permission,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return _PromptDialog(
      appId: appId,
      appName: appName,
      title: '允许「$appName」使用${permission.label}权限吗？',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(permission.description, style: theme.textTheme.bodyMedium),
          if (permission.needsSystemSettings) ...<Widget>[
            const SizedBox(height: 10),
            const _SystemSettingsHint(),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                '风险等级',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              PermissionRiskChip(risk: permission.risk, compact: true),
            ],
          ),
        ],
      ),
    );
  }

  /// 批量确认弹窗（打开小程序时按声明一次性问）。
  ///
  /// 形态与单个弹窗一致 —— 同样的图标、同样的一句话标题、同样的复选框，
  /// 只是把「哪一项权限」换成一份清单，避免用户面对两种风格的权限询问。
  Widget _batchDialog(
    BuildContext context,
    String appId,
    String appName,
    List<MiniappPermission> permissions,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return _PromptDialog(
      appId: appId,
      appName: appName,
      title: permissions.length == 1
          ? '允许「$appName」使用${permissions.first.label}权限吗？'
          : '允许「$appName」使用以下 ${permissions.length} 项权限吗？',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '这些权限来自小程序在市场数据（index.json）里的声明。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (final MiniappPermission p in permissions)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(p.icon),
              title: Row(
                children: <Widget>[
                  Flexible(child: Text(p.label)),
                  const SizedBox(width: 8),
                  PermissionRiskChip(risk: p.risk, compact: true),
                ],
              ),
              subtitle: Text(
                p.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 工具

  /// 弹窗要挂在**最上层**：小程序是 Navigator Overlay 上的一个层，
  /// 用 Navigator 自己的 Overlay context 才能让对话框盖在它上面。
  BuildContext? _overlayContext() =>
      lemonNavigatorKey.currentState?.overlay?.context;

  /// 串行化：把任务接到队列尾部，保证同一时刻只有一个对话框。
  Future<T> _serialize<T>(Future<T> Function() task) {
    final Completer<T> completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await task());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}

/// 权限弹窗的共用外壳：图标 + 标题 + 正文 + 两个按钮 + 「仅本次生效」。
///
/// 抽出来是因为单个权限与批量声明要走**完全一样的形态** ——
/// 用户不该因为触发路径不同就面对两种风格的权限询问。
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.appId,
    required this.appName,
    required this.title,
    required this.body,
  });

  final String appId;
  final String appName;

  final String title;
  final Widget body;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  /// 「仅本次生效」—— **默认选中**。
  /// 选中 = 只对这一次调用有效，不写任何持久记录。
  bool _onceOnly = true;

  void _answer(bool allowed) {
    Navigator.of(context).pop(
      PermissionAnswer(allowed: allowed, remember: !_onceOnly),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return AlertDialog(
      icon: _AppAvatar(appId: widget.appId, name: widget.appName),
      title: Text(widget.title, textAlign: TextAlign.center),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              widget.body,
              const Divider(height: 24),
              // 整行可点：只让那个小方块可点的话，命中区域太小了
              InkWell(
                onTap: () => setState(() => _onceOnly = !_onceOnly),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Checkbox(
                        value: _onceOnly,
                        onChanged: (bool? value) =>
                            setState(() => _onceOnly = value ?? true),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('仅本次生效', style: theme.textTheme.bodyMedium),
                            Text(
                              _onceOnly
                                  ? '不记住这次选择，下次用到时会再问你'
                                  : '记住这次选择，之后不再询问（可在应用管理里修改）',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => _answer(false),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: () => _answer(true),
          child: const Text('允许'),
        ),
      ],
    );
  }
}

/// 弹窗顶部的小程序图标：有图标就用图标，没有就用名称首字生成占位图标。
class _AppAvatar extends StatelessWidget {
  const _AppAvatar({required this.appId, required this.name});

  final String appId;
  final String name;

  @override
  Widget build(BuildContext context) {
    // 应用管理里登记过就带上图标地址，否则 AppIcon 自己会退化成一个首字占位图
    final String? iconUrl = ApplicationRegistry.instance.byId(appId)?.icon;
    return AppIcon(name: name, iconUrl: iconUrl, size: 56);
  }
}

/// 提醒用户「应用内授权」之外还有一层「Android 运行时权限」。
///
/// 不写的话用户会以为点「允许」就完事了，然后在真正调用时失败得莫名其妙 ——
/// 摄像头与麦克风都需要系统层再给一次。这里必须说清楚，
/// 否则那是最难排查的一类故障：弹窗点了允许，画面却一直是黑的。
class _SystemSettingsHint extends StatelessWidget {
  const _SystemSettingsHint();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.settings_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '这一项还需要 Android 的系统权限。你在这里允许之后，'
              '系统会再问一次；如果之前拒绝过且勾了「不再询问」，'
              '就只能去「应用管理 → 权限」里跳转系统设置打开。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
