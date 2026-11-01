// test/account_test.dart
//
// 账号模型与错误映射 + 响应式布局断点的单元测试。
//
// 这些不测网络（那需要真起服务端，见 server/test/api.test.mjs），
// 只测「数据怎么解释」与「什么条件下算平板」——
// 这两块错了，界面会以一种很难查的方式不工作。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/app.dart';
import 'package:lemonlite/data/services/account_service.dart';

void main() {
  // ========================================================== 用户资料模型

  group('AccountProfile', () {
    AccountProfile parse(Map<String, dynamic> json) =>
        AccountProfile.fromJson(json);

    test('解析完整响应', () {
      final AccountProfile p = parse(<String, dynamic>{
        'id': 7,
        'username': '张三',
        'email': 'a@b.com',
        'avatarUrl': 'https://x/api/upload/avatar/7?v=123',
        'avatarVersion': '123',
        'createdAt': '2026-10-18 12:00:00.000',
        'createdIp': '192.168.1.5',
      });
      expect(p.id, 7);
      expect(p.username, '张三');
      expect(p.email, 'a@b.com');
      expect(p.hasAvatar, isTrue);
      expect(p.avatarVersion, '123');
      expect(p.createdIp, '192.168.1.5');
    });

    test('没有头像时 hasAvatar=false', () {
      final AccountProfile p = parse(<String, dynamic>{
        'id': 1,
        'username': 'u',
        'email': 'e@x.com',
        'avatarUrl': '',
        'avatarVersion': '',
      });
      expect(p.hasAvatar, isFalse);
    });

    test('缺字段不会崩，用空值兜底', () {
      final AccountProfile p = parse(<String, dynamic>{});
      expect(p.id, 0);
      expect(p.username, '');
      expect(p.email, '');
      expect(p.hasAvatar, isFalse);
    });

    test('首字占位：中文取一个字，emoji 不会被切成半个码元', () {
      expect(parse(<String, dynamic>{'username': '张三'}).initial, '张');
      expect(parse(<String, dynamic>{'username': 'alice'}).initial, 'a');
      // 代理对（emoji）必须完整取出来
      expect(parse(<String, dynamic>{'username': '😀x'}).initial, '😀');
      // 空用户名退回 ?
      expect(parse(<String, dynamic>{'username': '   '}).initial, '?');
    });

    test('copyWith 只改指定字段', () {
      final AccountProfile p = parse(<String, dynamic>{
        'id': 1,
        'username': 'old',
        'email': 'e@x.com',
      });
      final AccountProfile q = p.copyWith(username: 'new');
      expect(q.username, 'new');
      expect(q.email, 'e@x.com');
      expect(q.id, 1);
    });
  });

  // ========================================================== 会话模型

  group('AccountSession', () {
    test('current 标记只认 true', () {
      final AccountSession s = AccountSession.fromJson(<String, dynamic>{
        'id': 'abcdef0123456789',
        'current': true,
        'ip': '1.2.3.4',
        'device': 'Xiaomi 14',
      });
      expect(s.current, isTrue);
      expect(s.id.length, 16);
      expect(s.device, 'Xiaomi 14');
    });

    test('缺字段时 current=false，不会误标成当前设备', () {
      final AccountSession s = AccountSession.fromJson(<String, dynamic>{});
      expect(s.current, isFalse);
      expect(s.id, '');
    });
  });

  // ========================================================== 服务端策略

  group('AuthServerConfig 解析', () {
    test('开关取值与默认值', () {
      final AuthServerConfig on = AuthServerConfig.fromJson(<String, dynamic>{
        'registerCode': true,
        'loginCode': true,
        'mailReady': true,
        'mailDriver': 'smtp',
        'codeCooldown': 30,
        'codeTtl': 300,
        'tokenTtl': 'never',
      });
      expect(on.registerCode, isTrue);
      expect(on.loginCode, isTrue);
      expect(on.codeCooldown, 30);
      expect(on.tokenNeverExpires, isTrue);

      // 服务端没给字段时：注册要验证码、登录不要（与 .env.example 默认一致）
      final AuthServerConfig off = AuthServerConfig.fromJson(<String, dynamic>{});
      expect(off.registerCode, isTrue);
      expect(off.loginCode, isFalse);
      expect(off.mailReady, isTrue);
      expect(off.codeCooldown, 60);
      expect(off.tokenNeverExpires, isTrue);
    });

    test('有限有效期时 tokenNeverExpires 为 false', () {
      final AuthServerConfig cfg =
          AuthServerConfig.fromJson(<String, dynamic>{'tokenTtl': '7d'});
      expect(cfg.tokenNeverExpires, isFalse);
    });
  });

  // ========================================================== 验证码响应

  group('EmailCodeSent 解析', () {
    test('完整响应', () {
      final EmailCodeSent r = EmailCodeSent.fromJson(<String, dynamic>{
        'sent': true,
        'email': 'a@b.com',
        'cooldown': 45,
        'expiresIn': 300,
        'driver': 'smtp',
      });
      expect(r.email, 'a@b.com');
      expect(r.cooldown, 45, reason: '冷却时间要跟服务端走，不能写死 60');
      expect(r.expiresIn, 300);
      expect(r.driver, 'smtp');
      expect(r.debugCode, isNull);
    });

    test('缺字段时用默认值，不抛异常', () {
      final EmailCodeSent r = EmailCodeSent.fromJson(<String, dynamic>{});
      expect(r.cooldown, 60);
      expect(r.expiresIn, 600);
      expect(r.email, '');
      expect(r.debugCode, isNull);
    });

    test('开发模式带回的 debugCode 会被解析出来', () {
      final EmailCodeSent r = EmailCodeSent.fromJson(<String, dynamic>{
        'debugCode': '123456',
      });
      expect(r.debugCode, '123456');
    });
  });

  // ========================================================== 错误映射

  group('AccountException 的字段归类', () {
    test('用户名错误能被 UI 定位到用户名输入框', () {
      expect(
        const AccountException('username_taken', '占用').isUsernameError,
        isTrue,
      );
      expect(
        const AccountException('invalid_username', '格式').isUsernameError,
        isTrue,
      );
      expect(
        const AccountException('email_taken', '占用').isUsernameError,
        isFalse,
      );
    });

    test('邮箱错误', () {
      expect(
        const AccountException('email_taken', '占用').isEmailError,
        isTrue,
      );
      expect(
        const AccountException('invalid_email', '格式').isEmailError,
        isTrue,
      );
    });

    test('密码错误（含「旧密码不对」）', () {
      for (final String code in <String>[
        'weak_password',
        'invalid_password',
        'wrong_password',
        'same_password',
      ]) {
        expect(
          AccountException(code, 'x').isPasswordError,
          isTrue,
          reason: '$code 应归为密码错误',
        );
      }
      expect(
        const AccountException('network', 'x').isPasswordError,
        isFalse,
      );
    });

    test('验证码错误', () {
      for (final String code in <String>[
        'invalid_code',
        'code_expired',
        'code_missing',
        'code_required',
        'code_locked',
      ]) {
        expect(
          AccountException(code, 'x').isCodeError,
          isTrue,
          reason: '$code 应归为验证码错误',
        );
      }
      expect(const AccountException('email_taken', 'x').isCodeError, isFalse);
    });

    test('一个错误不会同时归到两个字段', () {
      for (final AccountException e in <AccountException>[
        const AccountException('username_taken', 'x'),
        const AccountException('email_taken', 'x'),
        const AccountException('invalid_code', 'x'),
      ]) {
        expect(
          <bool>[
            e.isUsernameError,
            e.isEmailError,
            e.isPasswordError,
            e.isCodeError,
          ].where((bool v) => v).length,
          1,
          reason: '${e.code} 被归到了多个输入框',
        );
      }
    });
  });

  // ========================================================== 布局断点

  group('手机 / 平板判定（最短边 dp >= 600）', () {
    test('阈值常量是 600dp', () {
      expect(kTabletMinShortestSide, 600);
    });

    test('常见设备尺寸的预期分类', () {
      // 这批断言直接表达产品意图，不依赖 Flutter 的 MediaQuery 实现细节
      const Map<String, Size> devices = <String, Size>{
        'Pixel 7（竖）': Size(412, 915),
        'Pixel 7（横）': Size(915, 412),
        'iPhone 15 Pro': Size(393, 852),
        '小折叠外屏': Size(340, 340),
        'iPad mini（竖）': Size(744, 1133),
        'iPad Air（横）': Size(1180, 820),
        '平板分屏（窄）': Size(700, 900),
      };
      // 与 useWideLayout 的实现保持一致：shortestSide >= 600
      final Map<String, bool> expected = <String, bool>{
        'Pixel 7（竖）': false,
        'Pixel 7（横）': false, // 横屏手机宽度 915 但最短边 412 → 仍是手机
        'iPhone 15 Pro': false,
        '小折叠外屏': false,
        'iPad mini（竖）': true,
        'iPad Air（横）': true,
        '平板分屏（窄）': true,
      };
      devices.forEach((String name, Size size) {
        final bool wide = size.shortestSide >= kTabletMinShortestSide;
        expect(wide, expected[name], reason: '$name 的判定不对');
      });
    });

    test('横屏手机不会被误判成平板（这是选最短边而不是宽度的理由）', () {
      const Size landscapePhone = Size(915, 412);
      expect(landscapePhone.width >= 600, isTrue, reason: '宽度确实超了');
      expect(landscapePhone.shortestSide >= 600, isFalse, reason: '最短边没超');
    });
  });

  // ========================================================== 设备描述

  group('AccountService.describeDevice', () {
    test('返回非空字符串（登录时会作为 device 上报）', () {
      final String d = AccountService.describeDevice();
      expect(d.trim(), isNotEmpty);
      // 不该是「空 / null」这类会让服务端存下无意义数据的值
      expect(d, isNot('null'));
      expect(d.length, lessThanOrEqualTo(128));
    });
  });
}
