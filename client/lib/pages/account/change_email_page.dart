
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/account_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/loading.dart';
import 'email_code_button.dart';

class ChangeEmailPage extends StatefulWidget {
  const ChangeEmailPage({super.key, required this.currentEmail});

  /// 当前绑定的邮箱（只读展示，让人确认「我在改哪个账号」）
  final String currentEmail;

  static Route<bool> route(String currentEmail) => MaterialPageRoute<bool>(
    builder: (BuildContext context) =>
        ChangeEmailPage(currentEmail: currentEmail),
  );

  @override
  State<ChangeEmailPage> createState() => _ChangeEmailPageState();
}

class _ChangeEmailPageState extends State<ChangeEmailPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 密码/邮箱变了要重新判断「获取验证码」能不能点
    _email.addListener(_onInputChanged);
    _password.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  bool get _newEmailValid =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(_email.text.trim()) &&
      _email.text.trim().toLowerCase() != widget.currentEmail.toLowerCase();

  /// 发码前提：新邮箱格式正确且不等于旧邮箱，并且已经填了当前密码
  bool get _canSendCode => _newEmailValid && _password.text.isNotEmpty;

  Future<EmailCodeSent> _requestCode() {
    return context.read<AccountService>().sendChangeEmailCode(
      email: _email.text,
      password: _password.text,
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await context.read<AccountService>().changeEmail(
        email: _email.text,
        password: _password.text,
        code: _code.text,
      );
      if (!mounted) return;
      AppTheme.showToast('邮箱已更换，其它设备需要重新登录');
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
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('更换邮箱')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            // ------------------------------------------------ 当前邮箱
            Card.outlined(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.alternate_email),
                title: const Text('当前绑定'),
                subtitle: Text(widget.currentEmail),
                trailing: Chip(
                  label: const Text('已绑定'),
                  labelStyle: Theme.of(context).textTheme.labelSmall,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ------------------------------------------------ 新邮箱
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const <String>[AutofillHints.email],
              decoration: const InputDecoration(
                labelText: '新邮箱',
                prefixIcon: Icon(Icons.mark_email_read_outlined),
                border: OutlineInputBorder(),
                helperText: '验证码会发到这个地址',
              ),
              validator: (String? v) {
                final String s = (v ?? '').trim();
                if (s.isEmpty) return '请输入新邮箱';
                if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(s)) {
                  return '邮箱格式不正确';
                }
                if (s.toLowerCase() == widget.currentEmail.toLowerCase()) {
                  return '新邮箱不能和当前邮箱相同';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // ------------------------------------------------ 当前密码
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: const <String>[AutofillHints.password],
              decoration: InputDecoration(
                labelText: '当前密码',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                helperText: '证明是本人在操作',
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
              validator: (String? v) => (v ?? '').isEmpty ? '请输入当前密码' : null,
            ),
            const SizedBox(height: 16),

            // ------------------------------------------------ 验证码
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextFormField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '新邮箱验证码',
                      prefixIcon: Icon(Icons.pin_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (String? v) {
                      final String s = (v ?? '').trim();
                      if (!RegExp(r'^\d{4,8}$').hasMatch(s)) {
                        return '请输入验证码';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                EmailCodeButton(
                  request: _requestCode,
                  enabled: _canSendCode,
                  onSent: (EmailCodeSent sent) {
                    AppTheme.showToast('验证码已发送到 ${sent.email}');
                  },
                  onError: (AccountException e) {
                    setState(() => _error = e.message);
                  },
                ),
              ],
            ),

            if (_error != null) ...<Widget>[
              const SizedBox(height: 14),
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

            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: M3ELoadingIndicator(),
                    )
                  : const Text('确认更换'),
            ),

            const SizedBox(height: 14),
            Text(
              '换绑成功后：\n'
              '· 旧邮箱立刻不能再用于登录或找回密码\n'
              '· 其它设备会被退出登录，需要重新登录\n'
              '· 之后登录可以用新邮箱或用户名',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
