import 'package:camby/app_state.dart';
import 'package:camby/main.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/search_page.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('双击当前 Tab 唤起搜索：onSearch 触发且不再切换', (tester) async {
    var onChange = 0;
    var onSearch = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: GlassNavBar(
            index: 0,
            onChanged: (_) => onChange++,
            onSearch: () => onSearch++,
          ),
        ),
      ),
    );
    await tester.pump();

    // 双击首页（当前所在，index=0）
    await tester.tap(find.text('首页'));
    await tester.tap(find.text('首页'));
    await tester.pump();

    expect(onSearch, 1, reason: '双击当前 Tab 应触发一次搜索');
    expect(onChange, 1, reason: '第二次点击不应再次切换 Tab');
  });

  testWidgets('点击其它 Tab 只切换、不唤醒搜索', (tester) async {
    var onChange = 0;
    var onSearch = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: GlassNavBar(
            index: 0,
            onChanged: (_) => onChange++,
            onSearch: () => onSearch++,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('收藏'));
    await tester.pump();

    expect(onChange, 1);
    expect(onSearch, 0, reason: '点不同 Tab 只切换，不触发搜索');
  });

  testWidgets('「我的」页右上角搜索按钮：点按唤起搜索页', (tester) async {
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
    // 等 _s 异步加载（加载前显示 loading，不渲染搜索按钮）；
    // 用 pump 循环而非 pumpAndSettle：本页有持续动画帧，settle 会超时
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search_rounded));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.byType(SearchPage), findsOneWidget,
        reason: '「我的」页搜索按钮应打开 SearchPage');
  });
}
