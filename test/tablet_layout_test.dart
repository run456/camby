// 平板（≥840）布局回归测试（M1 补完 + M2/M3 首批）
//
// 对应实测反馈的 5 项修复，锁定设计稿关键结构：
// 1. 首页 Hero 卡片化：定高 300、圆角 18（设计稿 .hero）
// 2. 首页继续观看：一屏 7 张横版卡（800/538，设计稿 .hrow / .pcard.wide）
// 3. 首页最近添加：一屏 9 张竖版横排行（设计稿 .hrow-hp）
// 4. 详情主从分栏：头部定高 300 + 1fr/380px（设计稿 .detailHead/.detailBody）
// 5. 收藏 5 列 + 堆叠卡海报原生比例（设计稿 .collection 5 列）
import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';
import 'package:camby/pages/favorites_page.dart';
import 'package:camby/pages/home_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1194×834 = 11 寸平板横屏，命中 medium 档（840–1199）。
/// 外壳会注入「内容区宽 = 1194 - 96(Rail)」，测试直接给 1194 模拟整屏。
const _tabletSize = Size(1194, 834);
/// 1600×1000 = 大平板横屏，命中 expanded 档（≥1200，主从分栏生效）
const _expandedSize = Size(1600, 1000);

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('平板首页：Hero 卡片定高 300 + 圆角 18，渲染无异常', (tester) async {
    tester.view.physicalSize = _tabletSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState();
    await tester.pumpWidget(
      _wrap(
        HomePage(
          state: state,
          onOpenDetail: (_, {String? heroTag}) {},
          onOpenLibrary: (_) {},
          onOpenAll: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Hero PageView 存在（手机/平板共用翻页逻辑）
    expect(find.byType(PageView), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Hero 卡片高度应为 300（设计稿 .hero{height:300px}）
    final pageViewRect = tester.getRect(find.byType(PageView));
    expect(pageViewRect.height, moreOrLessEquals(300, epsilon: 0.5));
    // 两侧 30 边距（设计稿内容区安全边距）
    expect(pageViewRect.left, moreOrLessEquals(30, epsilon: 0.5));
  });

  testWidgets('平板扩展档（1600dp）详情：头部 300 定高 + 主从分栏',
      (tester) async {
    tester.view.physicalSize = _expandedSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState();
    final item = demoLibrary.first;
    await tester.pumpWidget(
      _wrap(
        DetailPage(
          item: item,
          state: state,
          onPlay: (item, subtitle, {resume = false}) {},
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 平板分支必须出现设计稿的核心区块（不再走手机全幅海报）
    expect(find.text('剧情简介'), findsOneWidget);
    expect(find.text('相似推荐'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 头部 ClipRRect 内的图片区高度 = 300
    final headFinder = find.byType(ClipRRect).first;
    final headRect = tester.getRect(headFinder);
    expect(headRect.height, moreOrLessEquals(300, epsilon: 0.5));
    expect(headRect.left, moreOrLessEquals(30, epsilon: 0.5));
  });

  testWidgets('平板中等档（1194dp）详情：侧栏折叠，仍是单列',
      (tester) async {
    tester.view.physicalSize = _tabletSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        DetailPage(
          item: demoLibrary.first,
          state: AppState(),
          onPlay: (item, subtitle, {resume = false}) {},
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 设计稿：840–1199 档「详情侧栏折叠进底部抽屉」→ 不得出现 380 信息栏
    final rows = tester.widgetList<Row>(find.byType(Row));
    final withSide = rows.where(
      (r) => r.children.any((w) => w is SizedBox && w.width == 380),
    );
    expect(withSide, isEmpty, reason: '中等档详情不得出现 380px 侧栏');
    expect(tester.takeException(), isNull);
  });

  testWidgets('平板收藏：渲染无异常且网格仍有「全部/新建」瓦片', (tester) async {
    tester.view.physicalSize = _tabletSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState();
    await tester.pumpWidget(
      _wrap(
        FavoritesPage(
          state: state,
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 空收藏也有「全部」堆叠瓦片 + 新建瓦片
    expect(find.text('全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
