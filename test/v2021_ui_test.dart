import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/stats_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.21 实测反馈守卫（统计页部分）：
/// 「库存覆盖率」与「观看完成率」重复 —— 覆盖率数据并入完成率卡片，
/// 独立「库存覆盖率」卡片移除（手机/平板共用同一 children 列表，一处生效）。
void main() {
  testWidgets('统计页：库存覆盖率卡片移除，观看完成率卡片保留（v2.0.21）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppState.disablePersistence = true;
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: StatsPage(state: state)),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(tester.takeException(), isNull);
    // 观看完成率卡片保留（覆盖率数据并入其中）
    expect(find.text('观看完成率'), findsOneWidget);
    // 滚到底：独立「库存覆盖率」卡片不应再出现，「数据质量」仍收尾
    // （长列表懒加载，底部卡片需滚动构建后才能断言）
    await tester.scrollUntilVisible(
      find.text('数据质量'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('库存覆盖率'), findsNothing);
    expect(find.text('数据质量'), findsOneWidget);
  });

  test('demoStats 覆盖率字段仍可计算（并入卡片后数据不丢）', () {
    final stats = LibraryStats.compute(demoLibrary);
    expect(stats.watchCoverage, greaterThanOrEqualTo(0));
    expect(stats.watchCoverage, lessThanOrEqualTo(1));
    expect(stats.watchedCount, greaterThanOrEqualTo(0));
  });
}
