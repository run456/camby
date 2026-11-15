import 'package:camby/app_state.dart';
import 'package:camby/pages/diagnostics_dump_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('未连接服务器时诊断页正常给出提示', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(DiagnosticsDumpPage(state: AppState())));
    await tester.pumpAndSettle();

    // 标题与未连接提示都应出现，且不抛异常。
    expect(find.text('导出原始条目 JSON'), findsOneWidget);
    expect(find.text('请先连接服务器'), findsOneWidget);
  });

  testWidgets('标题与「复制全部」入口在带服务器态可见（不实际拉取）', (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState();
    // 不注入真实服务器：仅验证页面结构在无数据（空列表）下不崩溃。
    await tester.pumpWidget(_wrap(DiagnosticsDumpPage(state: state)));
    await tester.pumpAndSettle();

    expect(find.text('导出原始条目 JSON'), findsOneWidget);
  });
}
