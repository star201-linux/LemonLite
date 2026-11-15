// lib/pages/account/session_list_page.dart
//
// 「登录设备」二级页：当前设备 / 其它在线 / 历史登录。
//
// 为什么拆成二级页而不是把列表平铺在账号页：
//   * 在线会话可能很多（上限 20），历史记录更多，平铺会把真正的
//     「退出登录 / 注销账号」挤到看不见的地方；
//   * 历史记录是**只读的审计信息**，跟「在这里踢掉一台设备」是两种交互，
//     混在一起会让用户对着一堆已失效的行找按钮。
//
// 数据分两次取：/sessions（当前有效，用来踢人）与
// /sessions/history（全部记录，用来展示）。两者字段几乎一样，
// 但语义不同 —— 前者是「操作对象」，后者是「发生过什么」。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/account_service.dart';
import '../../theme/app_theme.dart';
import '../home/widgets/state_views.dart';

class SessionListPage extends StatefulWidget {
  const SessionListPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const SessionListPage(),
  );

  @override
  State<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends State<SessionListPage> {
  List<AccountSession>? _active;
  List<AccountSession>? _history;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final AccountService account = context.read<AccountService>();
    try {
      final List<List<AccountSession>> results =
          await Future.wait<List<AccountSession>>(
            <Future<List<AccountSession>>>[
              account.fetchSessions(),
              account.fetchSessionHistory(),
            ],
          );
      if (!mounted) return;
      setState(() {
        _active = results[0];
        _history = results[1];
        _loading = false;
      });
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取登录记录失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _revoke(AccountSession session) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('退出这台设备？'),
        content: Text(
          '「${session.device.isEmpty ? '未知设备' : session.device}」上的登录会立刻失效，'
          '需要重新输入密码。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await context.read<AccountService>().revokeSession(session.id);
      if (!mounted) return;
      AppTheme.showToast('已退出该设备');
      await _load();
    } on AccountException catch (e) {
      if (!mounted) return;
      AppTheme.showToast(e.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录设备'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _history == null) {
      return const LoadingView(message: '正在读取登录记录…');
    }
    if (_error != null) {
      return ErrorView(title: '读取登录记录失败', message: _error!, onRetry: _load);
    }

    final List<AccountSession> active = _active ?? const <AccountSession>[];
    final List<AccountSession> history = _history ?? const <AccountSession>[];
    AccountSession? current;
    for (final AccountSession s in active) {
      if (s.current) {
        current = s;
        break;
      }
    }
    final List<AccountSession> others = active
        .where((AccountSession s) => !s.current)
        .toList(growable: false);
    // 历史 = 不在「当前有效」里的那些。用 id 去重，避免同一条既算在线又算历史。
    final Set<String> activeIds = active
        .map((AccountSession s) => s.id)
        .toSet();
    final List<AccountSession> past = history
        .where((AccountSession s) => !activeIds.contains(s.id))
        .toList(growable: false);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          if (current != null) ...<Widget>[
            _sectionTitle(context, '当前设备'),
            Card.outlined(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: _tile(context, current, showRevoke: false),
            ),
            const SizedBox(height: 8),
          ],

          _sectionTitle(context, '其它在线设备'),
          if (others.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('除了这台设备，没有别处登录。'),
            )
          else
            Card.outlined(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < others.length; i++) ...<Widget>[
                    if (i > 0)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    _tile(context, others[i], showRevoke: true),
                  ],
                ],
              ),
            ),

          const SizedBox(height: 20),
          _sectionTitle(context, '历史登录'),
          if (past.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('还没有历史记录。'),
            )
          else
            Card.outlined(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < past.length; i++) ...<Widget>[
                    if (i > 0)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    _tile(
                      context,
                      past[i],
                      showRevoke: false,
                      historical: true,
                    ),
                  ],
                ],
              ),
            ),

          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '历史登录保留最近 100 条，用于「上周那次登录是不是我」这类核对。'
              '被撤销或已过期的记录不能再用来登录。',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    AccountSession s, {
    required bool showRevoke,
    bool historical = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Widget> badges = <Widget>[
      if (s.current)
        _badge(
          context,
          '当前设备',
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
        )
      else if (historical && s.revoked)
        _badge(
          context,
          '已退出',
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        )
      else if (historical && s.expired)
        _badge(
          context,
          '已过期',
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        )
      else if (historical)
        _badge(
          context,
          '离线',
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
    ];

    return ListTile(
      leading: Icon(
        s.current
            ? Icons.smartphone
            : historical
            ? Icons.history
            : Icons.devices_other,
        color: s.current ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              s.device.isEmpty ? '未知设备' : s.device,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (badges.isNotEmpty) ...<Widget>[
            const SizedBox(width: 8),
            ...badges,
          ],
        ],
      ),
      subtitle: Text(
        <String>[
          if (s.ip.isNotEmpty) s.ip,
          if (historical && s.createdAt.isNotEmpty)
            '登录 ${_shortDate(s.createdAt)}',
          if (s.lastSeenAt.isNotEmpty) '最近 ${_shortDate(s.lastSeenAt)}',
        ].join(' · '),
        style: Theme.of(context).textTheme.labelSmall,
      ),
      trailing: showRevoke
          ? IconButton(
              tooltip: '退出这台设备',
              icon: const Icon(Icons.logout),
              onPressed: () => _revoke(s),
            )
          : null,
    );
  }

  Widget _badge(BuildContext context, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }

  static String _shortDate(String raw) {
    final String s = raw.trim();
    if (s.length >= 16) return s.substring(0, 16);
    return s;
  }
}
