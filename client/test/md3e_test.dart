// test/md3e_test.dart
//
// MD3E 拦截器的纯函数部分：文档改写规则与注入内容。
//
// 这些断言看起来琐碎，但它们守的是三条容易回归的约定：
//   1. 注入必须发生在**作者样式之前**（否则首帧还是浏览器默认样式）；
//   2. 改写必须**幂等**（刷新 / 重载不能层层嵌套）；
//   3. 没有 <html> 的片段也要变成完整文档（否则拦截器等于没生效）。

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/theme/md3e_interceptor.dart';
import 'package:lemonlite/theme/md3e_styles.dart';

void main() {
  const Map<String, dynamic> payload = <String, dynamic>{
    'mode': 'light',
    'cssVariables': <String, String>{
      '--md-primary': '#6750a4',
      '--md-on-primary': '#ffffff',
    },
  };

  group('Md3eInterceptor.rewriteHtml', () {
    test('注入到 <head> 开头，位于作者样式之前', () {
      const String html =
          '<!DOCTYPE html><html><head><style>.a{color:red}</style></head>'
          '<body><button>Go</button></body></html>';
      final String out = Md3eInterceptor.rewriteHtml(html, payload);

      final int injected = out.indexOf('id="lemonlite-md3e"');
      final int authored = out.indexOf('.a{color:red}');
      expect(injected, greaterThan(0));
      expect(authored, greaterThan(injected));
      // 只插一次（DOM 脚本的 id 是 lemonlite-md3e-dom，不能用裸串统计）
      expect('id="lemonlite-md3e"'.allMatches(out).length, 1);
    });

    test('保留 <head> 上的属性，不重建标签', () {
      const String html = '<html><head lang="zh" data-x="1"></head><body></body></html>';
      final String out = Md3eInterceptor.rewriteHtml(html, payload);
      expect(out.contains('<head lang="zh" data-x="1"><style id="lemonlite-md3e"'), isTrue);
    });

    test('没有 <head> 时补一个', () {
      const String html = '<html><body><p>hi</p></body></html>';
      final String out = Md3eInterceptor.rewriteHtml(html, payload);
      expect(out.contains('<head><style id="lemonlite-md3e"'), isTrue);
      expect(out.indexOf('lemonlite-md3e'), lessThan(out.indexOf('<body>')));
    });

    test('HTML 片段会被包成完整文档', () {
      const String out = '<button>hi</button>';
      final String rewritten = Md3eInterceptor.rewriteHtml(out, payload);
      expect(rewritten.startsWith('<!DOCTYPE html>'), isTrue);
      expect(rewritten.contains('<head>'), isTrue);
      expect(rewritten.contains('<button>hi</button>'), isTrue);
    });

    test('幂等：已经注入过的文档原样返回', () {
      const String html =
          '<html><head><style id="lemonlite-md3e">x</style></head><body></body></html>';
      expect(Md3eInterceptor.rewriteHtml(html, payload), html);
    });

    test('主题变量被内联，首帧就用对颜色', () {
      final String out = Md3eInterceptor.rewriteHtml(
        '<html><head></head><body></body></html>',
        payload,
      );
      expect(out.contains('--md-primary:#6750a4'), isTrue);
      expect(out.contains('--md-on-primary:#ffffff'), isTrue);
    });

    test('DOM 拦截脚本跟着文档一起进去', () {
      final String out = Md3eInterceptor.rewriteHtml(
        '<html><head></head><body></body></html>',
        payload,
      );
      expect(out.contains('lemonlite-md3e-dom'), isTrue);
      expect(out.contains('__LEMONLITE_MD3E_DOM__'), isTrue);
      expect(out.contains('data-md3e-role'), isTrue);
    });
  });

  group('Md3eStyles.buildDomScript', () {
    test('覆盖原生控件角色，且带幂等标记', () {
      final String js = Md3eStyles.buildDomScript();
      for (final String role in <String>[
        'button',
        'field',
        'select',
        'checkbox',
        'radio',
        'range',
        'table',
        'expansion',
        'progress',
        'dialog',
      ]) {
        expect(js.contains("'$role'"), isTrue, reason: '缺少角色 $role');
      }
      expect(js.contains('__LEMONLITE_MD3E_DOM__'), isTrue);
      expect(js.contains('MutationObserver'), isTrue);
      expect(js.contains('data-md3e="off"'), isTrue);
    });

    test('CSS 为拦截后的元素准备了属性选择器规则', () {
      final String css = Md3eStyles.css;
      expect(css.contains('[data-md3e-role="button"]'), isTrue);
      expect(css.contains('[data-md3e-role="field"]'), isTrue);
      expect(css.contains('[data-md3e-role="checkbox"]:checked'), isTrue);
    });
  });
}
