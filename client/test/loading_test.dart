
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/theme/loading.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

void main() {
  testWidgets('手机上默认 48，跟随父级紧约束，行内 18', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const M3ELoadingIndicator(),
              SizedBox(
                width: 20,
                height: 20,
                child: const M3ELoadingIndicator(),
              ),
              const M3ELoadingIndicator.inline(),
              const M3ELoadingIndicator(size: 32),
            ],
          ),
        ),
      ),
    );

    // 量外层（可见尺寸）：底层固定 48 渲染，由 FittedBox 缩放到目标尺寸
    final Finder indicators = find.byType(M3ELoadingIndicator);
    expect(indicators, findsNWidgets(4));
    expect(tester.getSize(indicators.at(0)).width, 48);
    expect(tester.getSize(indicators.at(1)).width, 20);
    expect(tester.getSize(indicators.at(2)).width, 18);
    expect(tester.getSize(indicators.at(3)).width, 32);
  });

  testWidgets('手表（shortestSide < 320）默认降到 32，线性条变细', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(300, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              M3ELoadingIndicator(),
              M3ELinearProgressIndicator(value: 0.5),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(M3ELoadingIndicator)).width, 32);
    expect(
      tester.getSize(find.byType(ExpressiveLinearProgressIndicator)).height,
      6,
    );
  });

  testWidgets('线性条默认高度 8，值原样传给底层', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: M3ELinearProgressIndicator(value: 0.42),
          ),
        ),
      ),
    );
    final ExpressiveLinearProgressIndicator bar = tester
        .widget<ExpressiveLinearProgressIndicator>(
          find.byType(ExpressiveLinearProgressIndicator),
        );
    expect(bar.value, 0.42);
    expect(
      tester.getSize(find.byType(ExpressiveLinearProgressIndicator)).height,
      8,
    );
  });
}
