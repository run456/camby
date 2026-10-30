import 'package:camby/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动冒烟测试：App 至少要能渲染出首页内容，不能是纯黑
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('冷启动能进首页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const CambyApp());
    // 启动期间有各种异步初始化，多泵几帧
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.takeException(), isNull);
    // 底部 Tab 栏在就说明 AppShell 活着
    expect(find.text('首页'), findsWidgets);
  });
}
