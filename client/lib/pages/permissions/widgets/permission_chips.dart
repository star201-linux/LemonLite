// lib/pages/permissions/widgets/permission_chips.dart
//
// 权限相关的两个小标签：风险等级、用户的决定。
//
// 抽出来是因为它们现在有**三个**使用场景（权限管理、确认弹窗、应用详情页的权限清单），
// 复制三份必然会出现"某个地方忘了加新状态"这种不一致。

import 'package:flutter/material.dart';

import '../../../data/models/miniapp_permission.dart';

/// 风险等级标签：常规 / 敏感 / 高风险
class PermissionRiskChip extends StatelessWidget {
  const PermissionRiskChip({super.key, required this.risk, this.compact = false});

  final PermissionRisk risk;

  /// 紧凑模式：弹窗里一行放多个标签时用
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (risk) {
      PermissionRisk.normal => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      PermissionRisk.sensitive => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      PermissionRisk.dangerous => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        risk.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

/// 用户决定标签：询问 / 允许 / 拒绝
class PermissionDecisionChip extends StatelessWidget {
  const PermissionDecisionChip({super.key, required this.decision});

  final PermissionDecision decision;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground, IconData icon) = switch (decision) {
      PermissionDecision.ask => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.help_outline,
      ),
      PermissionDecision.granted => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_outline,
      ),
      PermissionDecision.denied => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.block_outlined,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Text(
            decision.label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}
