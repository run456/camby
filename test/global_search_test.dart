// v2.0.68 全局搜索入口回归
//
// 双击当前 Tab 唤起搜索、以及「我的」页右上角搜索按钮均已取消：
// 搜索升为一级 Tab（index 2），全局只剩「点搜索 Tab」一条路径。
// 这里锁住「旧手势不会再偷偷回来」与「单击切 Tab 行为不变」。
import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/main.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('双击当前 Tab 不再有特殊行为：两次点击都只是普通切换', (tester) async {
    var onChange = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: GlassNavBar(
            index: 0,
            onChanged: (_) => onChange++,
          ),
        ),
      ),
    );
    await tester.pump();

    // 双击首页（当前所在，index=0）
    await tester.tap(find.text('首页'));
    await tester.tap(find.text('首页'));
    await tester.pump();

    expect(onChange, 2, reason: '双击手势已取消，每次点按都走普通 onChanged');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击其它 Tab 只切换一次，不触发任何额外动作', (tester) async {
    var onChange = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: GlassNavBar(
            index: 0,
            onChanged: (_) => onChange++,
          ),
        ),
      ),
    );
    await tester.pump();

    // 未选中项只剩图标（无文字），用空心图标定位
    await tester.tap(find.byIcon(Icons.search_outlined));
    await tester.pump();

    expect(onChange, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「我的」页不再有右上角搜索按钮', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppState.disablePersistence = true;
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          onTabChanged: (_) {},
          state: state,
          onOpenDetail: (MediaItem item, {String? heroTag}) {},
        ),
      ),
    );
    // 等 _s 异步加载（加载前是 loading 占位）；
    // 用 pump 循环而非 pumpAndSettle：本页有持续动画帧，settle 会超时
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.byIcon(Icons.search_rounded), findsNothing);
    expect(find.byIcon(Icons.search_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('搜索页已是一级 Tab，且只在首次进入时自动聚焦', () {
    final main = File('lib/main.dart').readAsStringSync();
    final search = File('lib/pages/search_page.dart').readAsStringSync();

    expect(main.contains('SearchPage('), isTrue);
    expect(main.contains('active: _tab == 2'), isTrue);
    expect(main.contains('FavoritesPage('), isFalse);
    expect(main.contains('_searchRoute('), isFalse);

    expect(search.contains('final bool active;'), isTrue);
    expect(search.contains('_focusedOnce'), isTrue);
    expect(search.contains('didUpdateWidget(SearchPage oldWidget)'), isTrue);
    expect(search.contains("_focus.requestFocus()"), isTrue);
    // 旧的 initState 无条件聚焦必须移除，否则冷启动就弹键盘。
    expect(search.contains('super.initState();\n    _focus.requestFocus();'),
        isFalse);
    // 「取消 / pop」是路由页语义，作为 Tab 后必须移除。
    expect(search.contains("Navigator.of(context).pop()"), isFalse);
    // 底部给 280dp 悬浮导航留避让。
    expect(search.contains('EdgeInsets.fromLTRB(16, 4, 16, 88)'), isTrue);
  });
}
