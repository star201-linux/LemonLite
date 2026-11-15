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
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:lemonlite/pages/account/session_offline_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    test('toJson 能原样回环（本地资料缓存靠它）', () {
      final AccountProfile p = parse(<String, dynamic>{
        'id': 7,
        'username': '张三',
        'email': 'a@b.com',
        'avatarUrl': 'https://x/a.png',
        'avatarVersion': '1700000000',
        'createdAt': '2026-10-18 12:00:00.000',
        'createdIp': '1.2.3.4',
      });
      final AccountProfile back = parse(p.toJson());
      expect(back.id, p.id);
      expect(back.username, p.username);
      expect(back.email, p.email);
      expect(back.avatarUrl, p.avatarUrl);
      expect(back.avatarVersion, p.avatarVersion);
      expect(back.createdAt, p.createdAt);
      expect(back.createdIp, p.createdIp);
    });
  });

  // ========================================================== 登录态与「被下线」

  group('启动恢复与被下线', () {
    late SettingsService settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      settings = await SettingsService.init();
    });

    test('没有 token 时是未登录，且不残留上一个账号的资料', () async {
      await settings.writeRaw(
        'account.profile',
        '{"id":1,"username":"ghost","email":"g@x.com"}',
      );
      await AccountService.instance.init(settings);
      expect(AccountService.instance.isLoggedIn, isFalse);
      expect(AccountService.instance.profile, isNull);
    });

    test('有 token 时从缓存恢复资料（打开账号页不用先转圈）', () async {
      await settings.writeRaw('account.token', 'lmn_cached');
      await settings.writeRaw(
        'account.profile',
        '{"id":9,"username":"缓存用户","email":"c@x.com","avatarVersion":"1"}',
      );
      await AccountService.instance.init(settings);
      expect(AccountService.instance.isLoggedIn, isTrue);
      expect(AccountService.instance.profile?.username, '缓存用户');
      expect(AccountService.instance.profile?.id, 9);
    });

    test('缓存是坏 JSON 时当作没有资料，但登录态仍恢复', () async {
      await settings.writeRaw('account.token', 'lmn_cached');
      await settings.writeRaw('account.profile', '{ 不是 json');
      await AccountService.instance.init(settings);
      expect(AccountService.instance.isLoggedIn, isTrue);
      expect(AccountService.instance.profile, isNull);
    });

    test('401：清登录态 + 留下「已下线」提示，且只消费一次', () async {
      await settings.writeRaw('account.token', 'lmn_revoked');
      await settings.writeRaw(
        'account.profile',
        '{"id":3,"username":"被踢的","email":"k@x.com"}',
      );
      await AccountService.instance.init(settings);
      expect(AccountService.instance.hasOfflineNotice, isFalse);

      await AccountService.instance.handleUnauthorized('登录已失效，请重新登录');

      expect(AccountService.instance.isLoggedIn, isFalse);
      expect(AccountService.instance.profile, isNull);
      expect(settings.readRaw('account.token'), isNull, reason: '本地 token 要一起删');
      expect(settings.readRaw('account.profile'), isNull, reason: '资料缓存也要删');

      expect(AccountService.instance.hasOfflineNotice, isTrue);
      final String? reason = AccountService.instance.takeOfflineNotice();
      expect(reason, contains('登录已失效'));
      expect(reason, contains('被踢的'), reason: '提示里要带上是哪个账号，便于确认');

      expect(AccountService.instance.hasOfflineNotice, isFalse);
      expect(
        AccountService.instance.takeOfflineNotice(),
        isNull,
        reason: '提示只能消费一次，否则每 rebuild 一次就弹一次窗',
      );
    });

    test('重复的 401 不会重新记提示（并发请求只有一个弹窗）', () async {
      await settings.writeRaw('account.token', 'lmn_revoked');
      await AccountService.instance.init(settings);

      await AccountService.instance.handleUnauthorized('登录已失效');
      expect(AccountService.instance.takeOfflineNotice(), isNotNull);

      await AccountService.instance.handleUnauthorized('登录已失效');
      expect(
        AccountService.instance.hasOfflineNotice,
        isFalse,
        reason: '第二个 401 到达时已经不是登录态了，不该再记一条',
      );
    });

    test('未登录时的 401 不产生提示', () async {
      await AccountService.instance.init(settings);
      await AccountService.instance.handleUnauthorized('登录已失效');
      expect(AccountService.instance.hasOfflineNotice, isFalse);
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
    });

    test('缺字段时用默认值，不抛异常', () {
      final EmailCodeSent r = EmailCodeSent.fromJson(<String, dynamic>{});
      expect(r.cooldown, 60);
      expect(r.expiresIn, 600);
      expect(r.email, '');
    });

    test('即使服务端多给了 debugCode 也不会被当成字段（接口不该带验证码）', () {
      final EmailCodeSent r = EmailCodeSent.fromJson(<String, dynamic>{
        'debugCode': '123456',
      });
      // 模型里根本没有这个字段：验证码只在服务端日志里，客户端拿不到也不该拿
      expect(r.email, '');
      expect(r.cooldown, 60);
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

  // ========================================================== 「已下线」弹窗

  group('SessionOfflineDialog', () {
    Future<void> open(WidgetTester tester, {String reason = ''}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    await SessionOfflineDialog.show(ctx, reason: reason);
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
    }

    testWidgets('说明「是怎么下线的」，并给出两个出口', (WidgetTester tester) async {
      await open(tester, reason: '登录已失效，请重新登录');
      expect(find.text('账号已下线'), findsOneWidget);
      expect(find.textContaining('被管理员下线'), findsOneWidget);
      expect(find.text('登录已失效，请重新登录'), findsOneWidget);
      expect(find.text('知道了'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
    });

    testWidgets('「知道了」关掉弹窗且不跳转', (WidgetTester tester) async {
      await open(tester);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('账号已下线'), findsNothing);
    });

    testWidgets('「去登录」返回 true（由外壳去 push 登录页）', (WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    result = await SessionOfflineDialog.show(ctx, reason: '');
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('去登录'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.text('账号已下线'), findsNothing);
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
