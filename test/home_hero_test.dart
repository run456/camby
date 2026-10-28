import 'package:camby/app_state.dart';
import 'package:camby/pages/home_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('首页 Hero：独立 notifier + 单层 ShaderMask 渲染正常', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: HomePage(
            state: state,
            onOpenDetail: (_, {String? heroTag}) {},
            onOpenLibrary: (_) {},
            onOpenAll: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);

    // 横滑一页：不应触发整页重建异常
    await tester.drag(find.byType(PageView), const Offset(-380, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
}
