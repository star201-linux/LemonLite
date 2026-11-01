// test/run_log_test.dart
//
// 运行日志缓冲区的单元测试。
//
// 这块的用途是「用户报障时把日志发回来」，所以两个属性最重要：
//   1. **有上限** —— 否则一个跑很久的小程序能把内存吃光
//   2. **脱敏** —— 导出文件会被贴到聊天窗口里，绝不能带 token

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/core/run_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    RunLog.instance.clear();
  });

  group('基本记录', () {
    test('记录后能读出来，且顺序保持', () {
      RunLog.instance.info('A', '第一条');
      RunLog.instance.warn('B', '第二条');
      RunLog.instance.error('C', '第三条');

      final List<LogEntry> e = RunLog.instance.entries;
      expect(e, hasLength(3));
      expect(e[0].message, '第一条');
      expect(e[1].level, LogLevel.warn);
      expect(e[2].level, LogLevel.error);
      expect(e[2].tag, 'C');
    });

    test('formatted 含时间、级别与 tag', () {
      RunLog.instance.info('Bridge', 'setTitle');
      final String line = RunLog.instance.entries.single.formatted;
      expect(line, contains('[I]'));
      expect(line, contains('[Bridge]'));
      expect(line, contains('setTitle'));
      // 时间形如 12:34:56.789
      expect(RegExp(r'\d{2}:\d{2}:\d{2}\.\d{3}').hasMatch(line), isTrue);
    });

    test('clear 之后为空', () {
      RunLog.instance.info('A', 'x');
      expect(RunLog.instance.isEmpty, isFalse);
      RunLog.instance.clear();
      expect(RunLog.instance.isEmpty, isTrue);
      expect(RunLog.instance.length, 0);
    });
  });

  group('容量上限', () {
    test('超过 maxEntries 后丢掉最旧的，长度不会无限增长', () {
      // 写 maxEntries + 300 条
      for (int i = 0; i < RunLog.maxEntries + 300; i++) {
        RunLog.instance.info('T', 'line $i');
      }
      final int len = RunLog.instance.length;
      expect(len, lessThanOrEqualTo(RunLog.maxEntries));
      // 丢掉的是最旧的：最后一条一定还在
      expect(RunLog.instance.entries.last.message, contains('line ${RunLog.maxEntries + 299}'));
      // 第 0 条已经被淘汰
      expect(
        RunLog.instance.entries.any((LogEntry e) => e.message == 'line 0'),
        isFalse,
      );
    });

    test('一次砍掉 10% 而不是逐条 removeAt(0)', () {
      for (int i = 0; i < RunLog.maxEntries + 1; i++) {
        RunLog.instance.info('T', 'l$i');
      }
      // 触发一次裁剪后，长度应该明显低于上限（不是刚好 maxEntries）
      expect(
        RunLog.instance.length,
        lessThan(RunLog.maxEntries),
        reason: '应该是批量裁剪，不是每条都搬移列表',
      );
    });
  });

  group('脱敏', () {
    /// 通过 add 走一遍 _redact
    String redacted(String input) {
      RunLog.instance.clear();
      RunLog.instance.info('T', input);
      return RunLog.instance.entries.single.message;
    }

    test('Bearer token 被打码', () {
      final String out = redacted('Authorization: Bearer abcdefgh12345678');
      expect(out, isNot(contains('abcdefgh12345678')));
      expect(out, contains('***'));
    });

    test('token=/password= 形式被打码', () {
      expect(redacted('token=supersecretvalue'), isNot(contains('supersecretvalue')));
      expect(redacted('password: hunter2hunter2'), isNot(contains('hunter2hunter2')));
      expect(redacted('api_key=abcdef123456'), isNot(contains('abcdef123456')));
    });

    test('本服务的 lmn_ token 被打码', () {
      final String out = redacted('登录成功 token=lmn_AbCdEfGhIjKlMnOpQrStUvWx');
      expect(out, isNot(contains('AbCdEfGhIjKlMnOpQrStUvWx')));
    });

    test('三段式 JWT 被打码', () {
      final String out = redacted(
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
      );
      expect(out, isNot(contains('dozjgNryP4J3jVmNHl0w5N')));
    });

    test('普通内容不被误伤', () {
      const String msg = '加载完成：file:///data/user/0/com.lemonlite/files/x/index.html';
      expect(redacted(msg), msg);
      expect(redacted('打开小程序 lemonlite.demo（当前运行 1 个）'),
          '打开小程序 lemonlite.demo（当前运行 1 个）');
    });
  });

  group('监听器', () {
    test('add 会通知监听器', () {
      int calls = 0;
      void listener() => calls++;
      RunLog.instance.addListener(listener);
      addTearDown(() => RunLog.instance.removeListener(listener));

      RunLog.instance.info('A', 'x');
      expect(calls, 1);
      RunLog.instance.info('A', 'y');
      expect(calls, 2);
    });

    test('removeListener 之后不再通知', () {
      int calls = 0;
      void listener() => calls++;
      RunLog.instance.addListener(listener);
      RunLog.instance.info('A', 'x');
      RunLog.instance.removeListener(listener);
      RunLog.instance.info('A', 'y');
      expect(calls, 1);
    });
  });

  group('LogEntry 序列化', () {
    test('toJson 字段齐全（导出 JSON 用）', () {
      final LogEntry e = LogEntry(
        at: DateTime(2026, 10, 18, 12, 34, 56, 789),
        tag: 'Bridge',
        message: 'hello',
        level: LogLevel.warn,
      );
      final Map<String, dynamic> j = e.toJson();
      expect(j['tag'], 'Bridge');
      expect(j['msg'], 'hello');
      expect(j['lvl'], 'warn');
      expect(j['t'], contains('2026-10-18'));
    });
  });
}
