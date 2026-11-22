// lib/pages/account/account_page.dart
//
// 「设置 → 账号管理」。
//
// 核心约定：**未登录不阻塞任何功能**。
//   未登录时这一页只显示「登录 / 注册」两个入口，返回键直接回设置；
//   市场浏览、小程序运行、权限管理、存储管理全都不需要账号。
//
// 登录后这一页分成几块：
//   1. 资料（头像 / 用户名 / 邮箱 —— 邮箱只能走独立页换绑）
//   2. 安全（改密码）
//   3. 登录设备（二级页：当前 / 其它在线 / 历史登录）
//   4. 退出登录
//   5. 注销账号（冷静期 + 可撤销）
//
// 被申请注销的账号会在顶部出现一条横幅：说明还有几天删除，并给撤销入口。

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/account_service.dart';
import '../../theme/app_theme.dart';
import 'avatar_cropper.dart';
import 'change_email_page.dart';
import 'delete_account_page.dart';
import 'email_code_button.dart';
import 'session_list_page.dart';
import '../../theme/loading.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const AccountPage(),
  );

  @override
  Widget build(BuildContext context) {
    final AccountService account = context.watch<AccountService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('账号管理'),
        actions: <Widget>[
          if (!account.isLoggedIn)
            TextButton(
              onPressed: () => Navigator.of(context).push(RegisterPage.route()),
              child: const Text('注册'),
            ),
        ],
      ),
      body: account.isLoggedIn ? const _LoggedInView() : const _LoggedOutView(),
    );
  }
}

// ================================================================ 未登录

class _LoggedOutView extends StatelessWidget {
  const _LoggedOutView();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        const SizedBox(height: 24),
        Icon(
          Icons.account_circle_outlined,
          size: 88,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text('还没有登录', style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '登录后可以在多台设备间同步账号资料与头像。\n'
            '浏览市场、打开小程序、管理权限都不需要登录。',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).push(RegisterPage.route()),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('注册新账号'),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(LoginPage.route()),
            icon: const Icon(Icons.login),
            label: const Text('已有账号，登录'),
          ),
        ),
      ],
    );
  }
}

// ================================================================ 已登录

class _LoggedInView extends StatefulWidget {
  const _LoggedInView();

  @override
  State<_LoggedInView> createState() => _LoggedInViewState();
}

class _LoggedInViewState extends State<_LoggedInView> {
  Uint8List? _avatarBytes;
  String _avatarVersion = '';

  /// 正在补拉资料（只在本地没有资料缓存时发生）
  bool _loadingProfile = false;

  String? _profileError;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
    if (context.read<AccountService>().profile == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureProfile());
    }
  }

  /// 补拉资料。失败就落到「加载失败 + 重试」，不再无限转圈。
  Future<void> _ensureProfile() async {
    if (!mounted || _loadingProfile) return;
    setState(() {
      _loadingProfile = true;
      _profileError = null;
    });
    try {
      await context.read<AccountService>().refreshProfile();
      if (!mounted) return;
      _avatarVersion = '';
      await _loadAvatar();
    } on AccountException catch (e) {
      // 401 已由 AccountService 统一处理（清登录态 + 弹「已下线」），
      // 页面会自己切到未登录视图，这里不必再提示。
      if (!mounted || e.code == 'unauthorized') return;
      setState(() => _profileError = e.message);
    } finally {
      if (mounted) setState(() => _loadingProfile = false);
    }
  }

  Future<void> _loadAvatar() async {
    final AccountService account = context.read<AccountService>();
    final AccountProfile? profile = account.profile;
    // 版本没变就不重复下载（头像地址本身带 ?v=，但字节缓存是我们自己管的）
    if (profile == null || profile.avatarVersion == _avatarVersion) return;
    final Uint8List? bytes = await account.downloadAvatar();
    if (!mounted) return;
    setState(() {
      _avatarBytes = bytes;
      _avatarVersion = profile.avatarVersion;
    });
  }

  /// 选图 → 裁剪 → 上传
  Future<void> _pickAndUploadAvatar() async {
    final AccountService account = context.read<AccountService>();
    try {
      // file_picker 12 的 API：pickFile 返回单个 PlatformFile，
      // 不再有 FilePickerResult 那层包装。
      final PlatformFile? picked = await FilePicker.pickFile(
        type: FileType.image,
        dialogTitle: '选择头像图片',
      );
      if (picked == null) return;

      // 新版用 readAsBytes() 取内容（withData 已 deprecated）
      final Uint8List raw = await picked.readAsBytes();
      if (raw.isEmpty) {
        AppTheme.showToast('读取图片失败', isError: true);
        return;
      }
      if (!mounted) return;

      final AvatarCropResult? cropped = await AvatarCropper.show(
        context,
        imageBytes: raw,
      );
      if (cropped == null) return;

      await account.uploadAvatar(cropped.pngBytes);
      if (!mounted) return;
      AppTheme.showToast('头像已更新');
      // 重新下载（版本戳变了，_loadAvatar 会真的去拉）
      _avatarVersion = '';
      await _loadAvatar();
    } on AccountException catch (e) {
      if (!mounted) return;
      AppTheme.showToast(e.message, isError: true);
    } catch (e) {
      if (!mounted) return;
      AppTheme.showToast('上传失败：$e', isError: true);
    }
  }

  Future<void> _removeAvatar() async {
    final AccountService account = context.read<AccountService>();
    try {
      await account.deleteAvatar();
      if (!mounted) return;
      setState(() {
        _avatarBytes = null;
        _avatarVersion = '';
      });
      AppTheme.showToast('头像已移除');
    } on AccountException catch (e) {
      if (!mounted) return;
      AppTheme.showToast(e.message, isError: true);
    }
  }

  /// 撤销注销申请（冷静期内）
  Future<void> _cancelDeletion() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('撤销注销申请？'),
        content: const Text('账号会恢复正常，原定的删除不会执行。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('撤销注销'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AccountService>().cancelAccountDeletion();
      if (!mounted) return;
      AppTheme.showToast('已撤销注销申请');
    } on AccountException catch (e) {
      if (!mounted) return;
      AppTheme.showToast(e.message, isError: true);
    }
  }

  Future<void> _editProfile() async {
    final AccountProfile? profile = context.read<AccountService>().profile;
    if (profile == null) return;
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext ctx) => EditProfilePage(profile: profile),
      ),
    );
    if (changed == true && mounted) {
      _avatarVersion = ''; // 可能改了头像，重新拉
      await _loadAvatar();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AccountService account = context.watch<AccountService>();
    final AccountProfile? profile = account.profile;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    if (profile == null) {
      // 有 token 但还没拿到资料：正在拉就转圈，拉失败就给出重试入口。
      // 以前这里无条件转圈，token 被服务端作废时会**永远**转下去。
      final String? error = _profileError;
      if (error != null) return _profileErrorView(context, error);
      return const Center(child: M3ELoadingIndicator());
    }

    return RefreshIndicator(
      onRefresh: () async {
        await account.refreshProfile(silent: true);
        await _loadAvatar();
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          // ------------------------------------------------ 注销中的横幅
          if (profile.deletion != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Card(
                color: scheme.errorContainer,
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.schedule,
                            size: 20,
                            color: scheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '账号已申请注销',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(color: scheme.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        profile.deletion!.daysLeft > 0
                            ? '将在 ${profile.deletion!.daysLeft} 天后'
                                  '（${_shortDate(profile.deletion!.scheduledAt)}）删除。'
                                  '在这之前撤销申请，账号会恢复原样。'
                            : '已到期，正在等待服务端清理。撤销申请可以立刻恢复。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                          height: 1.5,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _cancelDeletion,
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.onErrorContainer,
                          ),
                          child: const Text('撤销注销'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ------------------------------------------------ 资料卡
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Row(
              children: <Widget>[
                _avatar(context, profile),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        profile.username,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        profile.email,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'ID ${profile.id}'
                        '${profile.createdAt == null ? '' : ' · 注册于 ${_shortDate(profile.createdAt!)}'}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ------------------------------------------------ 头像操作
          _section(context, '头像', <Widget>[
            ListTile(
              leading: const Icon(Icons.add_a_photo_outlined),
              title: const Text('从相册选择'),
              subtitle: const Text('选完可以缩放、拖动裁成正方形'),
              onTap: _pickAndUploadAvatar,
            ),
            if (profile.hasAvatar) ...<Widget>[
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text('移除头像', style: TextStyle(color: scheme.error)),
                subtitle: const Text('回到用户名首字占位图'),
                onTap: _removeAvatar,
              ),
            ],
          ]),

          // ------------------------------------------------ 资料
          _section(context, '资料', <Widget>[
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('编辑资料'),
              subtitle: const Text('用户名'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editProfile,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: const Text('邮箱'),
              subtitle: Text(profile.email),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final bool? changed = await Navigator.of(
                  context,
                ).push(ChangeEmailPage.route(profile.email));
                if (changed == true && mounted) {
                  AppTheme.showToast('邮箱已更换');
                }
              },
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('修改密码'),
              subtitle: const Text('改完后其它设备会被退出登录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context).push(ChangePasswordPage.route()),
            ),
          ]),

          // ------------------------------------------------ 登录设备
          _section(context, '登录设备', <Widget>[
            ListTile(
              leading: const Icon(Icons.devices_other),
              title: const Text('登录设备'),
              subtitle: const Text('查看当前设备、其它在线设备与历史登录记录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(SessionListPage.route()),
            ),
          ]),

          // ------------------------------------------------ 退出
          _section(context, '会话', <Widget>[
            ListTile(
              leading: Icon(Icons.logout, color: scheme.error),
              title: Text('退出登录', style: TextStyle(color: scheme.error)),
              subtitle: const Text('只退出这台设备'),
              onTap: () => _logout(context, all: false),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: Icon(Icons.phonelink_erase, color: scheme.error),
              title: Text('退出所有设备', style: TextStyle(color: scheme.error)),
              subtitle: const Text('怀疑账号被盗时使用'),
              onTap: () => _logout(context, all: true),
            ),
          ]),

          // ------------------------------------------------ 注销账号
          _section(context, '注销账号', <Widget>[
            ListTile(
              leading: Icon(Icons.delete_forever, color: scheme.error),
              title: Text('注销账号', style: TextStyle(color: scheme.error)),
              subtitle: const Text('冷静期内可撤销，到期后数据不可恢复'),
              onTap: () =>
                  Navigator.of(context).push(DeleteAccountPage.route()),
            ),
          ]),

          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '登录状态保存在本机。退出登录会同时通知服务器撤销这台设备的凭证，'
              '即使凭证被复制走也会立刻失效。',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileErrorView(BuildContext context, String message) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('加载账号资料失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonal(
              onPressed: _loadingProfile ? null : _ensureProfile,
              child: _loadingProfile
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: M3ELoadingIndicator(),
                    )
                  : const Text('重试'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _logout(context, all: false),
              child: const Text('退出登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(BuildContext context, AccountProfile profile) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primaryContainer,
      ),
      clipBehavior: Clip.antiAlias,
      child: _avatarBytes != null
          ? Image.memory(
              _avatarBytes!,
              fit: BoxFit.cover,
              // 下载失败时退回占位图，而不是显示一个破图
              errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                  _initialAvatar(context, profile, scheme),
            )
          : _initialAvatar(context, profile, scheme),
    );
  }

  Widget _initialAvatar(
    BuildContext context,
    AccountProfile profile,
    ColorScheme scheme,
  ) {
    return Center(
      child: Text(
        profile.initial,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(color: scheme.onPrimaryContainer),
      ),
    );
  }

  Future<void> _logout(BuildContext context, {required bool all}) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(all ? '退出所有设备？' : '退出登录？'),
        content: Text(all ? '所有设备上的登录都会失效，需要重新输入密码。' : '这台设备上的登录会失效，其它设备不受影响。'),
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
    if (ok != true || !context.mounted) return;

    final AccountService account = context.read<AccountService>();
    if (all) {
      await account.logoutAll();
    } else {
      await account.logout();
    }
    if (!context.mounted) return;
    AppTheme.showToast('已退出登录');
  }

  /// `2026-10-18 12:34:56.000` → `2026-10-18 12:34`
  ///
  /// 服务端返回的是 MySQL 的 DATETIME 字符串（没有时区后缀，按 UTC 存）。
  /// 这里只做字符串截断，不做时区换算 —— 登录设备列表里的时间
  /// 差几个小时不影响「这台是不是我」的判断，而引入时区换算
  /// 反而会多一个出错点（服务端与本机时区都不确定）。
  static String _shortDate(String raw) {
    final String s = raw.trim();
    if (s.length >= 16) return s.substring(0, 16);
    return s;
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

// ================================================================ 登录页

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const LoginPage(),
  );

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _obscure = true;
  String? _error;

  /// 这台服务器是否要求登录验证码。
  /// 初值 false 只是「还没拉到配置」时的保守值 —— 拉不到也不会挡住登录，
  /// 真正的判定在服务端（会回 `code_required`，那时再把输入框展开）。
  bool _codeRequired = false;

  @override
  void initState() {
    super.initState();
    // 首帧之后再拉配置：拿 InheritedWidget 要在 build 之后才稳。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final AuthServerConfig cfg = await context
          .read<AccountService>()
          .loadAuthConfig();
      if (!mounted) return;
      setState(() => _codeRequired = cfg.loginCode);
    });
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final AccountService account = context.read<AccountService>();
    setState(() => _error = null);

    try {
      await account.login(
        account: _account.text,
        password: _password.text,
        code: _codeRequired ? _code.text : null,
        device: AccountService.describeDevice(),
      );
      if (!mounted) return;
      AppTheme.showToast('登录成功');
      Navigator.of(context).pop();
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        // 服务端说「要验证码」：说明配置拉的时机不对（或刚被打开），
        // 这里把输入框展开，用户点一下「获取验证码」就能继续。
        if (e.code == 'code_required') _codeRequired = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool busy = context.watch<AccountService>().busy;

    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            TextFormField(
              controller: _account,
              decoration: const InputDecoration(
                labelText: '用户名或邮箱',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
              autocorrect: false,
              validator: (String? v) =>
                  (v == null || v.trim().isEmpty) ? '请输入用户名或邮箱' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onFieldSubmitted: (_) => _submit(),
              validator: (String? v) =>
                  (v == null || v.isEmpty) ? '请输入密码' : null,
            ),

            // ---- 登录验证码（服务端开了才出现）
            if (_codeRequired) ...<Widget>[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(
                        labelText: '邮箱验证码',
                        prefixIcon: Icon(Icons.mark_email_read_outlined),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      validator: (String? v) {
                        if (!_codeRequired) return null;
                        final String s = (v ?? '').trim();
                        if (s.isEmpty) return '请先获取邮箱验证码';
                        if (!RegExp(r'^\d{4,8}$').hasMatch(s)) return '验证码是纯数字';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 只有账号和密码都填了才让点：服务端要先核对密码才发信
                  ListenableBuilder(
                    listenable: Listenable.merge(<Listenable>[
                      _account,
                      _password,
                    ]),
                    builder: (BuildContext ctx, Widget? child) {
                      return EmailCodeButton(
                        enabled:
                            _account.text.trim().isNotEmpty &&
                            _password.text.isNotEmpty,
                        request: () =>
                            context.read<AccountService>().sendLoginCode(
                              account: _account.text,
                              password: _password.text,
                            ),
                        onSent: (EmailCodeSent sent) {
                          AppTheme.showToast('验证码已发送到 ${sent.email}');
                        },
                        onError: (AccountException e) =>
                            setState(() => _error = e.message),
                      );
                    },
                  ),
                ],
              ),
            ],

            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy ? null : _submit,
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: M3ELoadingIndicator(),
                    )
                  : const Text('登录'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pushReplacement(RegisterPage.route()),
              child: const Text('还没有账号？去注册'),
            ),
          ],
        ),
      ),
    );
  }
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const RegisterPage(),
  );

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  static final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  bool _obscure = true;
  bool _busy = false;
  String? _error;

  /// 服务端是否要求注册验证码（默认 true，拉到 /api/auth/config 后以其为准）。
  /// 内网部署可能根本发不出邮件，这时服务端会把它关掉，客户端得跟着变。
  bool _codeRequired = true;

  /// 服务端邮件通道是否就绪（没配好时注册必然失败，提前告诉用户）
  bool _mailReady = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final AuthServerConfig cfg = await context
          .read<AccountService>()
          .loadAuthConfig();
      if (!mounted) return;
      setState(() {
        _codeRequired = cfg.registerCode;
        _mailReady = cfg.mailReady;
      });
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _emailText => _email.text.trim();

  bool get _emailLooksValid => _emailPattern.hasMatch(_emailText);

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final AccountService account = context.read<AccountService>();
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await account.register(
        username: _username.text,
        email: _emailText,
        password: _password.text,
        // 服务端关了注册验证码时不带 code（服务端也会忽略它）
        code: _codeRequired ? _code.text : '',
        device: AccountService.describeDevice(),
      );
      if (!mounted) return;
      AppTheme.showToast('注册成功，已登录');
      Navigator.of(context).pop();
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      // 验证码类错误：把输入框的光标放回去，用户直接改就行
      if (e.isCodeError) {
        _code.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _code.text.length,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('注册')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: '用户名',
                helperText: '3~32 个字符，可用中文、字母、数字、下划线、点、连字符',
                prefixIcon: Icon(Icons.badge_outlined),
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
              autocorrect: false,
              validator: (String? v) {
                final String s = (v ?? '').trim();
                if (s.length < 3) return '用户名至少 3 个字符';
                if (s.length > 32) return '用户名最多 32 个字符';
                if (RegExp(r'^\d+$').hasMatch(s)) return '用户名不能是纯数字';
                if (!RegExp(r'^[\p{L}\p{N}_.-]+$', unicode: true).hasMatch(s)) {
                  return '只能包含中文、字母、数字、下划线、连字符和点';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _email,
              decoration: const InputDecoration(
                labelText: '邮箱',
                prefixIcon: Icon(Icons.alternate_email),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              onChanged: (_) {
                // 只用来刷新「获取验证码」按钮的可用状态
                setState(() {});
              },
              validator: (String? v) {
                final String s = (v ?? '').trim();
                if (s.isEmpty) return '请输入邮箱';
                if (!_emailPattern.hasMatch(s)) return '邮箱格式不正确';
                return null;
              },
            ),
            if (_codeRequired) ...<Widget>[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(
                        labelText: '邮箱验证码',
                        prefixIcon: Icon(Icons.mark_email_read_outlined),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      textInputAction: TextInputAction.next,
                      validator: (String? v) {
                        if (!_codeRequired) return null;
                        final String s = (v ?? '').trim();
                        if (s.isEmpty) return '请输入邮箱收到的验证码';
                        if (!RegExp(r'^\d{4,8}$').hasMatch(s)) return '验证码是纯数字';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  EmailCodeButton(
                    // 邮箱没填对就不发请求：省一次无谓往返
                    enabled: _emailLooksValid,
                    request: () => context.read<AccountService>().sendEmailCode(
                      email: _emailText,
                    ),
                    onSent: (EmailCodeSent sent) {
                      AppTheme.showToast('验证码已发送，请查收 ${sent.email}');
                    },
                    onError: (AccountException e) =>
                        setState(() => _error = e.message),
                  ),
                ],
              ),
              // 服务端邮件没配好时，注册一定失败 —— 提前说，别让用户白等
              if (!_mailReady) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '服务端邮件通道未配置，验证码发不出来（管理员请检查 MAIL_DRIVER）',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 8),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '密码',
                helperText: '至少 8 位',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              textInputAction: TextInputAction.next,
              validator: (String? v) {
                if ((v ?? '').length < 8) return '密码至少 8 位';
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirm,
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: '确认密码',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
              ),
              onFieldSubmitted: (_) => _submit(),
              validator: (String? v) =>
                  v != _password.text ? '两次输入的密码不一致' : null,
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: M3ELoadingIndicator(),
                    )
                  : const Text('注册并登录'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pushReplacement(LoginPage.route()),
              child: const Text('已有账号？去登录'),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================ 编辑资料

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key, required this.profile});

  final AccountProfile profile;

  static Route<void> route(AccountProfile profile) => MaterialPageRoute<void>(
    builder: (BuildContext context) => EditProfilePage(profile: profile),
  );

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _username = TextEditingController(
    text: widget.profile.username,
  );

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final AccountService account = context.read<AccountService>();
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final String name = _username.text.trim();
      await account.updateProfile(
        username: name != widget.profile.username ? name : null,
      );
      if (!mounted) return;
      AppTheme.showToast('资料已更新');
      Navigator.of(context).pop(true);
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑资料'),
        actions: <Widget>[
          TextButton(onPressed: _busy ? null : _save, child: const Text('保存')),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: '用户名',
                prefixIcon: Icon(Icons.badge_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (String? v) {
                final String s = (v ?? '').trim();
                if (s.length < 3 || s.length > 32) return '用户名需要 3~32 个字符';
                if (RegExp(r'^\d+$').hasMatch(s)) return '用户名不能是纯数字';
                if (!RegExp(r'^[\p{L}\p{N}_.-]+$', unicode: true).hasMatch(s)) {
                  return '只能包含中文、字母、数字、下划线、连字符和点';
                }
                if (s == widget.profile.username) return null;
                return null;
              },
            ),
            const SizedBox(height: 20),
            // 邮箱不在这个表单里改：它是账号的根凭证，必须走独立流程
            //（当前密码 + 新邮箱验证码）。这里只给一个入口，避免用户在
            // 「编辑资料」里找不到它。
            Card.outlined(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: const Icon(Icons.alternate_email),
                title: const Text('邮箱'),
                subtitle: Text(widget.profile.email),
                trailing: const Text('更换'),
                onTap: () async {
                  final NavigatorState navigator = Navigator.of(context);
                  final bool? changed = await navigator.push(
                    ChangeEmailPage.route(widget.profile.email),
                  );
                  if (changed == true && mounted) {
                    // 换完邮箱这个页面上的旧地址已经过期，直接退出回账号页
                    navigator.pop(true);
                  }
                },
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              '用户名可以随时改，改动后所有设备上显示的都是新名字。'
              '邮箱与账号强绑定，更换需要验证当前密码和新邮箱验证码。',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================ 改密码

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const ChangePasswordPage(),
  );

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final TextEditingController _old = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await context.read<AccountService>().changePassword(
        oldPassword: _old.text,
        newPassword: _next.text,
      );
      if (!mounted) return;
      AppTheme.showToast('密码已修改，其它设备已退出');
      Navigator.of(context).pop();
    } on AccountException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('修改密码')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            TextFormField(
              controller: _old,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '当前密码',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (String? v) => (v ?? '').isEmpty ? '请输入当前密码' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _next,
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: '新密码',
                helperText: '至少 8 位，且不能和当前密码相同',
                prefixIcon: Icon(Icons.lock_reset),
                border: OutlineInputBorder(),
              ),
              validator: (String? v) {
                if ((v ?? '').length < 8) return '新密码至少 8 位';
                if (v == _old.text) return '新密码不能和当前密码相同';
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirm,
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: '确认新密码',
                prefixIcon: Icon(Icons.lock_reset),
                border: OutlineInputBorder(),
              ),
              onFieldSubmitted: (_) => _submit(),
              validator: (String? v) => v != _next.text ? '两次输入不一致' : null,
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: M3ELoadingIndicator(),
                    )
                  : const Text('修改密码'),
            ),
            const SizedBox(height: 12),
            Text(
              '修改成功后，除当前设备外的所有登录都会失效。',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
