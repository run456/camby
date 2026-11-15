import 'package:camby/app_state.dart';
import 'package:camby/pages/detail_page.dart';
import 'package:camby/pages/favorites_page.dart';
import 'package:camby/pages/home_page.dart';
import 'package:camby/pages/library_page.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:camby/theme.dart';
import 'package:camby/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.98：浅色主题的视觉验收基线。
///
/// 这套截图不是「好看」的验收，而是**漏改检测**：浅色下所有依赖
/// `Colors.white.withOpacity(...)` 的层级、所有硬编码的深色底、
/// 所有白字压白底，都会在图上直接暴露成一坨看不见的东西。
///
/// 只跑 golden、不断言具体像素 —— 每次重生成后人工看一眼。
///
/// 注：首页的背景渐变与筛选 chip 数量取自「每日推荐」，推荐片按日期分桶；
/// 跨天再跑时 light_home.png 可能失配（是基线过期，不是 UI 回归），
/// 用 `flutter test --update-goldens test/light_theme_golden_test.dart` 重录即可。
void main() {
  setUp(() {
    // 设置页 / ThemeController 都会读 SharedPreferences，测试环境必须给个假实现。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppColors.apply(dark: false);
    ThemeController.instance.debugReset(mode: ThemeMode.light);
  });

  tearDown(() {
    // 复位，避免污染同进程内其他测试。
    AppColors.apply(dark: true);
    ThemeController.instance.debugReset();
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.build(dark: false), home: page),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('浅色 · 首页', (tester) async {
    final state = AppState();
    await pumpPage(
      tester,
      HomePage(
        state: state,
        onOpenDetail: (_, {String? heroTag}) {},
        onOpenLibrary: (_) {},
        onOpenRecent: () {},
        onOpenContinue: () {},
      ),
    );
    await expectLater(
      find.byType(HomePage),
      matchesGoldenFile('goldens/light_home.png'),
    );
  });

  testWidgets('浅色 · 媒体库', (tester) async {
    final state = AppState();
    await pumpPage(
      tester,
      LibraryPage(state: state, onOpenDetail: (_, {String? heroTag}) {}),
    );
    await expectLater(
      find.byType(LibraryPage),
      matchesGoldenFile('goldens/light_library.png'),
    );
  });

  testWidgets('浅色 · 收藏', (tester) async {
    final state = AppState();
    for (final f in state.items.take(4)) {
      await state.toggleFavorite(f);
    }
    await pumpPage(
      tester,
      FavoritesPage(state: state, onOpenDetail: (_, {String? heroTag}) {}),
    );
    await expectLater(
      find.byType(FavoritesPage),
      matchesGoldenFile('goldens/light_favorites.png'),
    );
  });

  testWidgets('浅色 · 详情页', (tester) async {
    final state = AppState();
    final item = state.items.first;
    await pumpPage(
      tester,
      DetailPage(
        item: item,
        state: state,
        onPlay: (_, __, {bool resume = true}) {},
        onPlayPart: (_, __) {},
        onOpenDetail: (_, {String? heroTag}) {},
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(
      find.byType(DetailPage),
      matchesGoldenFile('goldens/light_detail.png'),
    );
  });

  testWidgets('浅色 · 我的（含外观开关）', (tester) async {
    final state = AppState();
    await pumpPage(
      tester,
      SettingsPage(
        state: state,
        onTabChanged: (_) {},
        onOpenDetail: (_, {String? heroTag}) {},
      ),
    );
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/light_settings.png'),
    );
  });
}
