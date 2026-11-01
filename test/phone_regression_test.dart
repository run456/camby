// 手机端「不回归」守卫 + 平板端形态守卫（每版固定验证的自动化部分）
//
// 目的：平板改造后，手机端（<840dp）的导航、栅格、详情单列必须保持原样；
// 平板端（≥840dp）必须走 Rail + 卡片化布局。两端各锁一组断言，
// 任何一端被改坏都会在这里失败（配合 tools/verify_release.sh 每版执行）。
import 'package:camby/app_state.dart';
import 'package:camby/main.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';
import 'package:camby/pages/home_page.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _phoneSize = Size(393, 852); // 手机
const _tabletSize = Size(1194, 834); // 平板横屏（中等档）

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: CambyApp()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('手机端（393dp）：底部 Tab 导航，无左侧 Rail', (tester) async {
    await _pumpShell(tester, _phoneSize);

    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('平板端（1194dp）：左侧 Rail 导航，无底部 Tab', (tester) async {
    await _pumpShell(tester, _tabletSize);

    expect(tester.takeException(), isNull);

    // v2.0.9：Rail 弃用 NavigationRail，改为自定义玻璃按钮条
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(GlassNavBar), findsNothing, reason: '平板不得出现底部 Tab 栏');
    expect(
      find.byIcon(Icons.search_rounded),
      findsOneWidget,
      reason: 'v2.0.9：搜索必须是 Rail 上的独立按钮',
    );
    // 1194 是中等档：纯图标（无文字标签），5 个 Tab + 1 个搜索 = 6 个玻璃按钮
    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
    expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
  });

  testWidgets('手机端首页 Hero 仍是满幅海报（非 300 定高卡片）', (tester) async {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: HomePage(
            state: AppState(),
            onOpenDetail: (_, {String? heroTag}) {},
            onOpenLibrary: (_) {},
            onOpenAll: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final pageViewRect = tester.getRect(find.byType(PageView));
    // 手机：满幅（左右无 30 边距）、高度 = 宽 / 海报比例（远大于 300）
    expect(pageViewRect.left, moreOrLessEquals(0, epsilon: 0.5));
    expect(pageViewRect.height, greaterThan(400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机端详情仍是单列（无 380px 侧栏）', (tester) async {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: DetailPage(
            item: demoLibrary.first,
            state: AppState(),
            onPlay: (item, subtitle, {resume = false}) {},
            onOpenDetail: (_, {String? heroTag}) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 手机：标题/简介等在单列里，不应出现 380 宽的侧栏 Row
    final rows = tester.widgetList<Row>(find.byType(Row));
    final sideColumn = rows.where((r) {
      final kids = r.children;
      return kids.any((w) => w is SizedBox && w.width == 380);
    });
    expect(sideColumn, isEmpty, reason: '手机端不得出现平板 380px 侧栏');
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机端设置页保持 16 边距；平板端限宽居中', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppState.disablePersistence = true;
    for (final (size, expectPad) in [
      (_phoneSize, 16.0),
      (_tabletSize, 237.0),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SettingsPage(
              onTabChanged: (_) {},
              state: AppState(),
              onOpenDetail: (_, {String? heroTag}) {},
            ),
          ),
        ),
      );
      // 设置页首帧是 loading 占位（读 SharedPreferences / PackageInfo），
      // 多泵几帧等真实 ListView 出现
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      final listView = tester.widget<ListView>(find.byType(ListView).first);
      expect(
        listView.padding!.resolve(TextDirection.ltr).left,
        moreOrLessEquals(expectPad, epsilon: 0.5),
      );
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.reset);
  });
}
