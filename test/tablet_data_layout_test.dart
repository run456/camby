// v2.0.104：平板「数据」tab 统一布局守卫。
//
// 用户明确选择「等宽双列 · 按行对齐 · 等高拉伸填满」。本测试锁定：
// 1. 两个子页共用 equalHeightRow（IntrinsicHeight + Row stretch + 两 Expanded）；
// 2. 洞察页卡片两两打包成行、概览平板下拆两张半幅组卡，日历页两行按行配对；
// 3. 两页底部留白统一引用 kFloatingNavInset，手机布局零漂移；
// 4. 平板宽度下两页都能渲染、IntrinsicHeight 拉伸不抛溢出异常。
import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/pages/stats_page.dart';
import 'package:camby/widgets/tablet_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.disablePersistence = true;
  });

  group('共享等宽双列行组件', () {
    testWidgets('equalHeightRow = IntrinsicHeight + Row(stretch) + 两 Expanded',
        (tester) async {
      expect(kTabletColumnGap, 14.0);
      expect(kFloatingNavInset, 150.0);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => equalHeightRow(
              ctx,
              const Text('L'),
              const Text('R'),
            ),
          ),
        ),
      ));

      expect(find.byType(IntrinsicHeight), findsOneWidget);
      final r = tester.widget<Row>(find.byType(Row));
      expect(r.crossAxisAlignment, CrossAxisAlignment.stretch);
      expect(r.children.length, 3);
      expect(r.children[0], isA<Expanded>());
      expect(r.children[1], isA<SizedBox>());
      expect(r.children[2], isA<Expanded>());
    });
  });

  group('源码守卫', () {
    test('stats_page：卡片两两打包成行 + 概览半幅 + 底部常量，懒构造保留', () {
      final s = File('lib/pages/stats_page.dart').readAsStringSync();
      // 守卫要求保留的懒构造骨架
      expect(s.contains('final cells = <_StatCell>['), isTrue);
      expect(s.contains('itemBuilder: (ctx, i) => rows[i](ctx)'), isTrue);
      expect(s.contains('List<WidgetBuilder> _tabletColumns('), isTrue);
      expect(s.contains('if (c.spacer) continue'), isTrue);
      expect(s.contains('if (w is SizedBox) continue'), isFalse);
      // 新布局
      expect(s.contains('equalHeightRow(context, left(context), right?.call(context))'), isTrue);
      expect(s.contains('half: 0'), isTrue);
      expect(s.contains('half: 1'), isTrue);
      expect(s.contains('static const _halfCardH = 78.0'), isTrue);
      expect(s.contains('bare: true'), isTrue);
      expect(s.contains('kFloatingNavInset'), isTrue);
    });

    test('watch_calendar_page：两行按行配对 + 卡内守卫不被动 + 底部常量', () {
      final s = File('lib/pages/watch_calendar_page.dart').readAsStringSync();
      expect(s.contains('equalHeightRow(context, calendarCard, dayCard)'), isTrue);
      expect(s.contains('equalHeightRow(context, summaryCard, posterCard)'), isTrue);
      expect(s.contains('kFloatingNavInset'), isTrue);
      // 卡内实现绝不能因布局重构被改动
      expect(s.contains('RepaintBoundary('), isTrue);
      expect(s.contains('toImage(pixelRatio: 3.0)'), isTrue);
      expect(s.contains('memWidth: 1200'), isTrue);
      expect(s.contains('memWidth: 480'), isFalse);
      expect(s.contains('posterUrlAtWidth(e.posterUrl, 1200)'), isTrue);
    });
  });

  group('平板渲染', () {
    testWidgets('横屏平板下洞察页与日历页都不溢出、不抛异常', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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
      // 默认落观影日历：日历+当日、概览+海报墙 两行等高。
      expect(find.byType(IntrinsicHeight), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      // 切到数据洞察：概览两张半幅卡 + 其余卡片两两成行。
      await tester.tap(find.text('数据洞察'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(find.byType(IntrinsicHeight), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
