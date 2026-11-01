// test/bundle_test.dart
//
// 模块 / 扩展的纯逻辑测试。
//
// 这里刻意只测**不碰文件系统**的部分（manifest 解析、URL 匹配、zip 解包校验、
// 注入脚本生成）。落盘那部分依赖 path_provider 的平台实现，
// 单元测试环境里拿不到，必须在真机上验 —— 所以把逻辑与副作用拆开，
// 让最容易出错的那一半能被自动覆盖。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/bridge/bundle_injector.dart';
import 'package:lemonlite/data/models/bundle_manifest.dart';
import 'package:lemonlite/data/repositories/bundle_repository.dart';

/// 造一个 zip 字节流
Uint8List makeZip(Map<String, String> files) {
  final Archive archive = Archive();
  files.forEach((String name, String content) {
    archive.addFile(ArchiveFile.string(name, content));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String manifestJson({
  String type = 'extension',
  String id = 'com.example.demo',
  String name = '示例',
  String version = '1.0.0',
  Map<String, Object?> extra = const <String, Object?>{},
}) {
  return jsonEncode(<String, Object?>{
    'type': type,
    'id': id,
    'name': name,
    'version': version,
    ...extra,
  });
}

void main() {
  group('manifest 解析', () {
    test('最小可用字段', () {
      final BundleManifest m = BundleManifest.parse(<String, dynamic>{
        'type': 'extension',
        'id': 'com.example.a',
        'name': '甲',
        'version': '1.0.0',
      });
      expect(m.type, BundleType.extension);
      expect(m.id, 'com.example.a');
      // matches 缺省 = 全部页面
      expect(m.matches, <String>['*']);
      // 缺省在页面脚本之后注入
      expect(m.runAt, BundleRunAt.documentEnd);
      expect(m.bridgeMethods, isEmpty);
    });

    test('id 会统一转小写', () {
      final BundleManifest m = BundleManifest.parse(<String, dynamic>{
        'type': 'module',
        'id': 'COM.Example.B',
        'name': '乙',
        'version': '0.1.0',
      });
      expect(m.id, 'com.example.b');
    });

    test('缺 type / name / version 都要报错', () {
      expect(
        () => BundleManifest.parse(<String, dynamic>{
          'id': 'a',
          'name': 'x',
          'version': '1',
        }),
        throwsA(isA<BundleManifestException>()),
      );
      expect(
        () => BundleManifest.parse(<String, dynamic>{
          'type': 'module',
          'id': 'a',
          'version': '1',
        }),
        throwsA(isA<BundleManifestException>()),
      );
      expect(
        () => BundleManifest.parse(<String, dynamic>{
          'type': 'module',
          'id': 'a',
          'name': 'x',
        }),
        throwsA(isA<BundleManifestException>()),
      );
    });

    test('非法 id 被拦下（路径穿越 / 符号开头 / 含空格）', () {
      for (final String bad in <String>[
        '../evil',
        '/abs',
        'a b',
        '-lead',
        '',
      ]) {
        expect(
          () => BundleManifest.parse(<String, dynamic>{
            'type': 'extension',
            'id': bad,
            'name': 'x',
            'version': '1',
          }),
          throwsA(isA<BundleManifestException>()),
          reason: 'id "$bad" 应该被拒绝',
        );
      }
    });

    test('模块的 bridge：解析、重名拦截、未知 action 拦截', () {
      final BundleManifest ok = BundleManifest.parse(<String, dynamic>{
        'type': 'module',
        'id': 'com.example.m',
        'name': '模块',
        'version': '1.0.0',
        'bridge': <Object?>[
          <String, Object?>{
            'name': 'fetchConfig',
            'action': 'http.get',
            'params': <String, Object?>{'url': 'https://example.com/c.json'},
          },
        ],
      });
      expect(ok.bridgeMethods, hasLength(1));
      expect(ok.bridgeMethods.first.action, 'http.get');
      expect(
        ok.bridgeMethods.first.params['url'],
        'https://example.com/c.json',
      );

      // 覆盖宿主内置 API
      expect(
        () => BundleManifest.parse(<String, dynamic>{
          'type': 'module',
          'id': 'm',
          'name': 'm',
          'version': '1',
          'bridge': <Object?>[
            <String, Object?>{'name': 'getTheme', 'action': 'const'},
          ],
        }),
        throwsA(isA<BundleManifestException>()),
      );

      // 宿主没实现的 action：装进去也是哑的，不如当场拦下
      expect(
        () => BundleManifest.parse(<String, dynamic>{
          'type': 'module',
          'id': 'm',
          'name': 'm',
          'version': '1',
          'bridge': <Object?>[
            <String, Object?>{'name': 'x', 'action': 'readContacts'},
          ],
        }),
        throwsA(isA<BundleManifestException>()),
      );
    });
  });

  group('URL 匹配', () {
    test('* 匹配一切', () {
      expect(matchesBundlePattern('https://a.com/x/y.html', '*'), isTrue);
    });

    test('无通配符 = 子串包含', () {
      expect(
        matchesBundlePattern(
          'https://a.com/apps/hello/index.html',
          'apps/hello',
        ),
        isTrue,
      );
      expect(
        matchesBundlePattern(
          'https://a.com/apps/other/index.html',
          'apps/hello',
        ),
        isFalse,
      );
    });

    test('通配符按顺序做分段匹配', () {
      expect(
        matchesBundlePattern('https://a.com/apps/hello/index.html', '*hello*'),
        isTrue,
      );
      expect(
        matchesBundlePattern(
          'https://a.com/apps/hello/index.html',
          'apps/hello/*',
        ),
        isTrue,
      );
      expect(
        matchesBundlePattern('https://b.com/apps/x/', '*apps/hello*'),
        isFalse,
      );
    });

    test('bundleMatchesUrl：本地 assets 只认通配全匹配', () {
      final BundleManifest all = BundleManifest.parse(<String, dynamic>{
        'type': 'extension',
        'id': 'a',
        'name': 'a',
        'version': '1',
      });
      expect(bundleMatchesUrl(all, null), isTrue);
      expect(bundleMatchesUrl(all, 'https://x/'), isTrue);

      final BundleManifest scoped = BundleManifest.parse(<String, dynamic>{
        'type': 'extension',
        'id': 'b',
        'name': 'b',
        'version': '1',
        'matches': <String>['*apps/hello*'],
      });
      // 本地 HTML 没有地址可匹配，只能声明成 *
      expect(bundleMatchesUrl(scoped, null), isFalse);
      expect(
        bundleMatchesUrl(scoped, 'https://x/apps/hello/index.html'),
        isTrue,
      );
    });
  });

  group('zip 解包', () {
    test('正常包：剥掉最外层目录，脚本被解析出来', () {
      final BundleArchive archive = BundleRepository.parseArchive(
        makeZip(<String, String>{
          'my-ext/lemonlite.json': manifestJson(),
          'my-ext/inject.js': 'console.log(1);',
          'my-ext/inject.css': 'body{color:red}',
        }),
        'my-ext.zip',
      );
      expect(archive.manifest.id, 'com.example.demo');
      expect(
        archive.files.keys,
        containsAll(<String>['lemonlite.json', 'inject.js', 'inject.css']),
      );
      // 最外层目录已经被剥掉
      expect(archive.files.containsKey('my-ext/inject.js'), isFalse);
    });

    test('根目录直接放 manifest 也可以', () {
      final BundleArchive archive = BundleRepository.parseArchive(
        makeZip(<String, String>{'lemonlite.json': manifestJson()}),
        'a.zip',
      );
      expect(archive.files.keys, <String>['lemonlite.json']);
    });

    test('Chrome 扩展 ZIP（manifest.json）不再被接受', () {
      final Map<String, Object?> chromeManifest = <String, Object?>{
        'manifest_version': 3,
        'name': 'Site Helper',
        'version': '2.1.0',
        'content_scripts': <Object?>[
          <String, Object?>{
            'matches': <String>['https://*.example.com/*'],
            'js': <String>['first.js'],
          },
        ],
      };
      expect(
        () => BundleRepository.parseArchive(
          makeZip(<String, String>{
            'chrome-ext/manifest.json': jsonEncode(chromeManifest),
            'chrome-ext/first.js': 'window.first = true;',
          }),
          'chrome-ext.zip',
        ),
        throwsA(isA<BundleException>()),
      );
    });

    test('找不到 manifest 要报错', () {
      expect(
        () => BundleRepository.parseArchive(
          makeZip(<String, String>{'readme.txt': 'hello'}),
          'a.zip',
        ),
        throwsA(isA<BundleException>()),
      );
    });

    test('路径穿越条目被拒绝', () {
      expect(
        () => BundleRepository.parseArchive(
          makeZip(<String, String>{
            'lemonlite.json': manifestJson(),
            '../escape.js': 'alert(1)',
          }),
          'a.zip',
        ),
        throwsA(isA<BundleException>()),
      );
    });

    test('裸 manifest.json 也能导入，但不能引用脚本文件', () {
      final BundleArchive ok = BundleRepository.parseArchive(
        Uint8List.fromList(utf8.encode(manifestJson())),
        'lemonlite.json',
      );
      expect(ok.manifest.name, '示例');

      expect(
        () => BundleRepository.parseArchive(
          Uint8List.fromList(
            utf8.encode(
              manifestJson(
                extra: <String, Object?>{
                  'js': <String>['a.js'],
                },
              ),
            ),
          ),
          'lemonlite.json',
        ),
        throwsA(isA<BundleException>()),
      );
    });

    test('不认识的后缀直接拒绝', () {
      expect(
        () => BundleRepository.parseArchive(
          Uint8List.fromList(<int>[1, 2, 3]),
          'demo.rar',
        ),
        throwsA(isA<BundleException>()),
      );
    });

    test('空文件被拒绝', () {
      expect(
        () => BundleRepository.parseArchive(Uint8List(0), 'a.zip'),
        throwsA(isA<BundleException>()),
      );
    });
  });

  group('注入脚本生成', () {
    BundlePayload payload({
      BundleType type = BundleType.extension,
      String css = '',
      String js = '',
      List<Map<String, Object?>> bridge = const <Map<String, Object?>>[],
    }) {
      final BundleManifest manifest = BundleManifest.parse(<String, dynamic>{
        'type': type.wireName,
        'id': 'com.example.t',
        'name': 'T',
        'version': '1.0.0',
        if (bridge.isNotEmpty) 'bridge': bridge,
      });
      return BundlePayload(manifest: manifest, css: css, js: js);
    }

    test('空列表返回空串，不生成无意义的 UserScript', () {
      expect(BundleInjector.buildScript(const <BundlePayload>[]), '');
    });

    test('css / js 都进脚本，且包在 IIFE 里', () {
      final String src = BundleInjector.buildScript(<BundlePayload>[
        payload(css: 'body{color:red}', js: 'var a = 1;'),
      ]);
      expect(src, contains('body{color:red}'));
      expect(src, contains('var a = 1;'));
      expect(src, contains('(function () {'));
      // 引号、换行必须被转义，不能把宿主的注入脚本写坏
      expect(src, contains(r'\n'));
    });

    test('模块声明的方法生成 lemonlite.<name>() 包装', () {
      final String src = BundleInjector.buildScript(<BundlePayload>[
        payload(
          type: BundleType.module,
          bridge: <Map<String, Object?>>[
            <String, Object?>{'name': 'ping', 'action': 'const'},
          ],
        ),
      ]);
      expect(src, contains('"ping"'));
      expect(src, contains('window.lemonlite.__invoke'));
    });

    test('按注入时机分组', () {
      final Map<BundleRunAt, List<BundlePayload>> grouped =
          BundleInjector.groupByRunAt(<BundlePayload>[payload()]);
      expect(grouped[BundleRunAt.documentEnd], hasLength(1));
      expect(grouped[BundleRunAt.documentStart], isEmpty);
    });

    test('包清单可被页面读取', () {
      final String src = BundleInjector.buildRegistryScript(<BundlePayload>[
        payload(js: 'x'),
      ]);
      expect(src, contains('__LEMONLITE_BUNDLES__'));
      expect(src, contains('com.example.t'));
    });
  });
}
