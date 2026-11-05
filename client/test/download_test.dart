// test/download_test.dart
//
// 下载管理的纯逻辑测试。
//
// 这里只测**不碰平台通道**的部分：文件名推断/清洗、记录序列化、状态映射、
// 下载子目录清洗。真正的下载走系统 DownloadManager，单元测试环境里没有，
// 必须在真机上验（见 docs §15.17）—— 也正因为这样，"哪些名字能被写进
// 公共下载目录"这条安全边界必须在纯函数层被钉死。

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/services/download_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('文件名推断', () {
    test('网页给的名字优先', () {
      expect(
        DownloadService.deriveFileName(
          suggested: '发票.pdf',
          contentDisposition: 'attachment; filename="a.pdf"',
          url: 'https://example.com/b.pdf',
        ),
        '发票.pdf',
      );
    });

    test('没有 suggest 时读 Content-Disposition（支持 RFC 5987）', () {
      expect(
        DownloadService.deriveFileName(
          contentDisposition:
              "attachment; filename*=UTF-8''%E5%8F%91%E7%A5%A8.pdf",
          url: 'https://example.com/download?id=1',
        ),
        '发票.pdf',
      );
      expect(
        DownloadService.deriveFileName(
          contentDisposition: 'attachment; filename="report 2026.csv"',
          url: 'https://example.com/download',
        ),
        'report 2026.csv',
      );
    });

    test('只有 URL 时用最后一段，并解码百分号', () {
      expect(
        DownloadService.deriveFileName(
          url: 'https://example.com/files/%E6%A0%87%E9%A2%98.txt?x=1',
        ),
        '标题.txt',
      );
    });

    test('URL 没有可用名字时按 MIME 补时间戳名字', () {
      final String name = DownloadService.deriveFileName(
        url: 'https://example.com/api/export',
        mimeType: 'text/csv',
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      // URL 最后一段没有扩展名时按 MIME 补一个
      expect(name, 'export.csv');
      // 连 URL 里都没有可用名字（只有主机）才用时间戳兜底
      expect(
        DownloadService.deriveFileName(
          url: 'https://example.com/',
          mimeType: 'application/pdf',
          now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
        'download-1700000000000.pdf',
      );
    });

    test('名字里的路径分隔符被替换，不会写出子目录', () {
      expect(
        DownloadService.deriveFileName(
          suggested: '../../etc/passwd',
          url: 'https://example.com/download',
        ),
        'passwd',
      );
      expect(DownloadService.sanitizeFileName('a/b\\c.txt'), 'a_b_c.txt');
    });

    test('控制字符与前导点被清掉（不在下载目录里制造隐藏文件）', () {
      expect(DownloadService.sanitizeFileName('.hidden'), 'hidden');
      expect(DownloadService.sanitizeFileName('a\u0000b.txt'), 'ab.txt');
    });

    test('超长名字截断但保留扩展名', () {
      final String name = DownloadService.sanitizeFileName('${'x' * 300}.pdf');
      expect(name.length, 200);
      expect(name.endsWith('.pdf'), isTrue);
    });
  });

  group('下载记录', () {
    DownloadTask makeTask() => DownloadTask(
      id: 7,
      url: 'https://example.com/a.pdf',
      fileName: 'a.pdf',
      subDir: 'LemonLite',
      mimeType: 'application/pdf',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      status: DownloadStatus.running,
      bytesReceived: 512,
      bytesTotal: 1024,
    );

    test('JSON 往返不丢字段', () {
      final DownloadTask task = makeTask();
      final DownloadTask? back = DownloadTask.fromJson(task.toJson());
      expect(back, isNotNull);
      expect(back!.id, task.id);
      expect(back.url, task.url);
      expect(back.fileName, task.fileName);
      expect(back.subDir, task.subDir);
      expect(back.status, DownloadStatus.running);
      expect(back.bytesReceived, 512);
      expect(back.bytesTotal, 1024);
      expect(back.createdAt, task.createdAt);
    });

    test('缺 id / url 的记录丢弃（打不开也删不掉）', () {
      expect(
        DownloadTask.fromJson(<String, dynamic>{'id': 0, 'url': 'https://a'}),
        isNull,
      );
      expect(DownloadTask.fromJson(<String, dynamic>{'id': 3}), isNull);
    });

    test('进度与大小文案', () {
      final DownloadTask task = makeTask();
      expect(task.progress, 0.5);
      expect(task.relativePath, 'LemonLite/a.pdf');
      expect(task.sizeLabel, contains('/'));
      // 总大小未知时进度条走不确定态
      final DownloadTask unknown = task.copyWith(bytesTotal: 0);
      expect(unknown.progress, isNull);
    });

    test('状态解析宽松：未知状态按失败处理', () {
      expect(DownloadStatus.parse('running'), DownloadStatus.running);
      expect(DownloadStatus.parse('SUCCESS'), DownloadStatus.success);
      expect(DownloadStatus.parse('nonsense'), DownloadStatus.failed);
      expect(DownloadStatus.parse(null), DownloadStatus.failed);
      expect(DownloadStatus.success.isActive, isFalse);
      expect(DownloadStatus.pending.isActive, isTrue);
    });
  });

  group('下载子目录', () {
    test('清洗路径穿越与绝对路径', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsService settings = await SettingsService.init();
      DownloadService.init();
      await DownloadService.instance.setSubDir('../../etc/passwd');
      expect(settings.readRaw('download.subdir'), 'etc/passwd');
      await DownloadService.instance.setSubDir('/LemonLite/');
      expect(DownloadService.instance.subDir, 'LemonLite');
      expect(DownloadService.instance.directoryLabel, 'Download/LemonLite');
    });
  });
}
