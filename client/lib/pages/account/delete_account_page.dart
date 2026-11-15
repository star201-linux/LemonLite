// lib/pages/account/delete_account_page.dart
//
// 「注销账号」页。
//
// 这不是一个 confirm() 就能过的操作，所以单独成页，把三件事摊开：
//   1. **会发生什么**：账号、头像、私有数据、登录状态全没，不可恢复；
//   2. **什么时候发生**：按服务端面板设置的冷静期（N 天）到期删除，
//      期间可以登录回来撤销 —— 冷静期长度由服务端下发，客户端不写死；
//   3. **怎么证明是本人**：输入当前密码。
//
// 提交成功后账号进入冷静期：回到账号页会看到「将于 X 删除」的横幅，
// 点一下就能撤销。只有冷静期为 0（申请即删除）时才清掉本地登录态。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/account_service.dart';
import '../../theme/loading.dart';

class DeleteAccountPage extends StatefulWidget {
  const DeleteAccountPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const DeleteAccountPage(),
  );

  @override
  State<DeleteAccountPage> createState() => _DeleteAccountPageState();
}

class _DeleteAccountPageState extends State<DeleteAccountPage> {
  final TextEditingController _password = TextEditingController();

  bool _acknowledged = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// 冷静期（天）。先从服务端策略拿；拿不到时按 7 天显示并注明「以实际为准」。
  int _delayDays = 7;
  bool _configLoaded = false;

  @override
  void initState() {
    super.initState();
    _password.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadConfig());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadConfig() async {
    final AccountService account = context.read<AccountService>();
    // force: 冷静期可能在面板上刚改过，用缓存值会显示错的天数
    final AuthServerConfig config = await account.loadAuthConfig(force: true);
    if (!mounted) return;
    setState(() {
      _delayDays = config.deleteDelayDays;
      _configLoaded = true;
    });
  }

  bool get _canSubmit => _acknowledged && _password.text.isNotEmpty && !_busy;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final AccountDeletion? deletion = await context
          .read<AccountService>()
          .requestAccountDeletion(password: _password.text);
      if (!mounted) return;
      await _showResult(deletion);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showResult(AccountDeletion? deletion) async {
    final bool immediate = deletion == null;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => AlertDialog(
        icon: Icon(
          immediate ? Icons.delete_forever : Icons.schedule,
          color: Theme.of(ctx).colorScheme.error,
        ),
        title: Text(immediate ? '账号已删除' : '注销申请已提交'),
        content: Text(
          immediate
              ? '这个账号和它的数据已经删除，无法恢复。'
              : '账号将在 ${deletion.daysLeft} 天后（${_shortDate(deletion.scheduledAt)}）删除。\n\n'
                    '在这之前，账号页顶部会显示「已申请注销」，点一下就能撤销。',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static String _shortDate(String raw) {
    final String s = raw.trim();
    if (s.length >= 16) return s.substring(0, 16);
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String name = context.watch<AccountService>().profile?.username ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('注销账号')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          // ------------------------------------------------ 说明
          Card(
            color: scheme.errorContainer,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.warning_amber_rounded,
                        color: scheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '这是一次不可逆的操作',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _delayDays == 0
                        ? '提交后账号会立刻被删除，没有反悔的余地。'
                        : '提交后账号会进入 $_delayDays 天冷静期，'
                              '到期自动删除。期间重新登录可以撤销。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                      height: 1.6,
                    ),
                  ),
                  if (!_configLoaded) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      '（冷静期以服务端当前设置为准）',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),
          Text('会被删除的内容', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const _Bullet('账号信息：用户名、邮箱、头像、注册记录'),
          const _Bullet('服务器上的私有数据（userdata 目录）'),
          const _Bullet('所有设备上的登录状态'),
          const _Bullet('本机缓存的市场数据（退出登录时清空）'),
          const SizedBox(height: 4),
          Text(
            '已安装的小程序与本机存储不在此列 —— 它们是这台设备上的东西，'
            '可以在「应用管理」和「设置 → 存储」里单独清理。',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),

          const SizedBox(height: 24),
          TextField(
            controller: _password,
            obscureText: _obscure,
            autofillHints: const <String>[AutofillHints.password],
            decoration: InputDecoration(
              labelText: '当前密码',
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder(),
              helperText: name.isEmpty ? '证明是本人操作' : '确认要注销「$name」',
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),

          const SizedBox(height: 8),
          CheckboxListTile(
            value: _acknowledged,
            onChanged: (bool? v) => setState(() => _acknowledged = v == true),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              '我已了解注销后数据无法恢复',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),

          if (_error != null) ...<Widget>[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              ],
            ),
          ],

          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: _canSubmit ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: M3ELoadingIndicator(),
                  )
                : Text(_delayDays == 0 ? '立即注销' : '申请注销'),
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8, left: 4),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
