import 'package:camby/app_state.dart';
import 'package:camby/pages/favorites_page.dart';
import 'package:camby/pages/home_page.dart';
import 'package:camby/pages/library_page.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:camby/pages/stats_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 五个主标签页的渲染冒烟（v1.7.46）
///
/// 教训来源：v1.7.42 清了设置页的死键，但 Widget 树还在读 → `null as int`
/// → 「我的」页整页崩掉，而当时 97 个测试全绿，因为它们都没真正构建过这一页。
/// 所以这里把每个 Tab 都单独 build 一遍，任何未捕获异常都算失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState state;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.disablePersistence = true;
    state = AppState();
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: page)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final err = tester.takeException();
    expect(err, isNull, reason: '页面渲染异常：$err');
  }

  testWidgets('首页', (t) async {
    await pumpPage(
      t,
      HomePage(
        state: state,
        onOpenDetail: (_, {String? heroTag}) {},
        onOpenLibrary: (_) {},
        onOpenAll: () {},
      ),
    );
  });

  testWidgets('媒体库', (t) async {
    await pumpPage(t, LibraryPage(state: state, onOpenDetail: (_, {String? heroTag}) {}));
  });

  testWidgets('收藏', (t) async {
    await pumpPage(t, FavoritesPage(state: state, onOpenDetail: (_, {String? heroTag}) {}));
  });

  testWidgets('数据', (t) async {
    await pumpPage(t, StatsPage(state: state));
  });

  testWidgets('我的（设置）', (t) async {
    await pumpPage(t, SettingsPage(state: state, onTabChanged: (_) {}));
  });
}
