import 'package:camby/app_state.dart';
import 'package:camby/pages/stats_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.22 统计页两项反馈：
/// ① 观看完成率卡片顶部的重复 7% 环（「库内已看完影片占比」）移除，只保留「已看/库内」环
/// ② 「偏好演员」标题行的「已看加权」胶囊改为「?」按钮，点击弹出计算口径说明
///
/// v2.0.23：弹窗改为液态玻璃（Glass）。
/// v2.0.25：说明口径改为「继续观看」（续播进度 1%~99%），移除本地累计 15 分钟规则。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState state;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.disablePersistence = true;
    state = AppState();
  });

  Future<void> pumpStats(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: StatsPage(state: state))),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets('顶部重复环已移除，独立「库存覆盖率」文案不再出现', (tester) async {
    await pumpStats(tester);
    // 原顶部环的说明文案应消失
    expect(find.text('库内已看完影片占比'), findsNothing);
    // 完成率卡片仍在（已看/库内口径）
    expect(find.text('观看完成率'), findsOneWidget);
    // 已看/库内 文案保留
    expect(find.textContaining('已看'), findsWidgets);
  });

  testWidgets('偏好演员：「已看加权」改为「?」按钮，点击弹液态玻璃说明', (tester) async {
    await pumpStats(tester);
    // 旧胶囊文案消失
    expect(find.text('已看加权'), findsNothing);
    // 出现「?」按钮
    final q = find.text('?');
    expect(q, findsWidgets);
    // 点击弹出说明（统计页有持续动画，用定长 pump 代替 pumpAndSettle）
    await tester.tap(q.first);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    // 弹窗标题与口径文案（v2.0.25：「继续观看」口径）
    expect(find.text('偏好演员 · 计算说明'), findsOneWidget);
    expect(find.textContaining('什么叫「继续观看」'), findsOneWidget);
    expect(find.textContaining('1%～99%'), findsOneWidget);
    // 液态玻璃弹窗（Glass 自带 BackdropFilter 模糊）
    expect(find.byType(Glass), findsWidgets);
    // 关闭弹窗
    await tester.tap(find.text('知道了'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('偏好演员 · 计算说明'), findsNothing);
  });
}
