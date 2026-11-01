// lib/pages/account/email_code_button.dart
//
// 「获取验证码」按钮：注册页与登录页共用。
//
// 抽出来的理由不是省几行，而是**倒计时这件小事必须只有一份实现**：
// 按钮自己维护冷却（秒数来自服务端响应），父页面只在拿到结果时
// 做两件事 —— 填框（开发模式的 debugCode）和提示发到了哪个邮箱。
//
// 固定宽度也是刻意的：按钮会在「获取验证码」和「42s 后重发」之间切换文案，
// 自适应宽度会让旁边那个输入框跟着抖一下。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/services/account_service.dart';

class EmailCodeButton extends StatefulWidget {
  const EmailCodeButton({
    super.key,
    required this.request,
    required this.onSent,
    required this.onError,
    this.enabled = true,
    this.width = 112,
  });

  /// 真正发码的动作（注册用 /api/auth/email-code，登录用 /api/auth/login-code）
  final Future<EmailCodeSent> Function() request;

  /// 发送成功：父页面用来提示「发到 xxx」以及自动填入 debugCode
  final void Function(EmailCodeSent sent) onSent;

  /// 发送失败
  final void Function(AccountException error) onError;

  /// 父页面的前置条件是否满足（例如注册页要求邮箱格式正确、
  /// 登录页要求账号密码已填 —— 服务端要先核对密码才发信）
  final bool enabled;

  final double width;

  @override
  State<EmailCodeButton> createState() => _EmailCodeButtonState();
}

class _EmailCodeButtonState extends State<EmailCodeButton> {
  bool _sending = false;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _cooldown = seconds > 0 ? seconds : 0);
    if (_cooldown == 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _cooldown -= 1;
        if (_cooldown <= 0) {
          _cooldown = 0;
          timer.cancel();
        }
      });
    });
  }

  Future<void> _fire() async {
    if (_sending || _cooldown > 0 || !widget.enabled) return;
    setState(() => _sending = true);
    try {
      final EmailCodeSent sent = await widget.request();
      if (!mounted) return;
      _startCountdown(sent.cooldown);
      widget.onSent(sent);
    } on AccountException catch (e) {
      if (!mounted) return;
      widget.onError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool disabled = _sending || _cooldown > 0 || !widget.enabled;
    return SizedBox(
      width: widget.width,
      height: 56,
      child: OutlinedButton(
        onPressed: disabled ? null : _fire,
        child: _sending
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                _cooldown > 0 ? '${_cooldown}s 后重发' : '获取验证码',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
      ),
    );
  }
}
