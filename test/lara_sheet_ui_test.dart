import 'dart:io';

import 'package:camby/lara/translate_sheet.dart';
import 'package:camby/widgets/glass_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.49 UI 回归：弹层「黄色双下划线」根因 + 翻译弹层外观。
///
/// 背景：PageRouteBuilder / showDialog 的页面挂在 Navigator Overlay 上，不继承
/// 主页 Scaffold 的 Material。缺 Material 祖先时，WidgetsApp 的兜底
/// DefaultTextStyle（debugLabel: "fallback style; consider putting your text
/// in a Material"，黄色双下划线）会 merge 进每个 Text —— Text 自带 style 只能
/// 覆盖颜色/字号，盖不掉 decoration，于是整屏文字都带黄线。
void main() {
  TextStyle styleOf(WidgetTester tester, String text) =>
      DefaultTextStyle.of(tester.element(find.text(text))).style;

  testWidgets('GlassPanelRoute 自带 Material → 面板文字无黄色下划线',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).push<void>(
                    GlassPanelRoute<void>(
                      builder: (_) =>
                          const Center(child: Text('面板文字')),
                    ),
                  );
                },
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(find.text('面板文字'), findsOneWidget);
    final s = styleOf(tester, '面板文字');
    expect(s.decoration, isNot(TextDecoration.underline),
        reason: '缺 Material 时 WidgetsApp 兜底样式是黄色双下划线');
    expect(s.decorationColor, isNot(const Color(0xFFFFFF00)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('翻译弹层：GlassPanel 实心卡片 + 定高 + 无黄线 + 无布局异常',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () {
                  showTranslateSheet<void>(
                    ctx,
                    itemId: 'm1',
                    field: 'title',
                    original: 'Hello world',
                  );
                },
                child: const Text('打开翻译'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开翻译'));
    await tester.pumpAndSettle();

    // 之前是裸 Column：没有卡片容器，详情页文字会从半透明背景后透出来
    expect(find.byType(GlassPanel), findsOneWidget);
    expect(find.text('Lara 翻译'), findsOneWidget);
    expect(find.text('自动检测源语言 · 译为中文'), findsOneWidget);
    expect(find.text('原文'), findsOneWidget);
    expect(find.text('译文（中文）'), findsOneWidget);
    expect(find.text('翻译'), findsWidgets);

    final s = styleOf(tester, '原文');
    expect(s.decoration, isNot(TextDecoration.underline));
    expect(s.decorationColor, isNot(const Color(0xFFFFFF00)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('翻译弹层开启真正的液态玻璃磨砂（BackdropFilter）', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () {
                  showTranslateSheet<void>(
                    ctx,
                    itemId: 'm1',
                    field: 'title',
                    original: 'Hello world',
                  );
                },
                child: const Text('打开翻译'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开翻译'));
    await tester.pumpAndSettle();

    // 真正的 frosted / liquid glass：GlassPanel(blur:true) 必须渲染出
    // BackdropFilter；否则只是高不透明纯色卡片，谈不上「玻璃」。
    expect(find.byType(BackdropFilter), findsWidgets,
        reason: '翻译弹层未开启背景磨砂，仍是纯色卡片');
    // 非模糊路径用普通 Container，不应出现——这里只验证模糊路径确实存在
    expect(tester.takeException(), isNull);
  });

  group('源码守卫（v2.0.49 UI 修复）', () {
    test('剧照查看器补 Material，且页码与图片同组居中', () {
      final src = File('lib/pages/detail_page.dart').readAsStringSync();
      final start = src.indexOf('void _showBackdrops');
      final end = src.indexOf('/// 「视频」板块', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final seg = src.substring(start, end);
      expect(seg.contains('Material('), isTrue,
          reason: 'showDialog 的裸 GestureDetector 缺 Material 会导致黄线');
      expect(seg.contains('SizedBox.expand'), isTrue,
          reason: '需保证点按空白仍可关闭');
      expect(seg.contains('Column('), isTrue,
          reason: '页码与图片区同组居中，不再固定在屏幕顶端');
      expect(seg.contains("top: MediaQuery.of(ctx).padding.top"), isFalse,
          reason: '旧版页码固定在屏幕最顶部，离图片太远');
    });

    test('手机布局标题旁挂了翻译按钮（封面用圆底变体）', () {
      final src = File('lib/pages/detail_page.dart').readAsStringSync();
      const anchor = '// 标题压在封面上';
      final idx = src.indexOf(anchor);
      expect(idx, greaterThan(-1), reason: '手机标题锚点应存在');
      // 源码缩进较深，窗口取 2600 字符以覆盖整个标题 Row
      final seg = src.substring(idx, idx + 2600);
      expect(seg.contains('_translateButton('), isTrue,
          reason: '手机标题必须与平板 banner 一样带翻译按钮');
      expect(seg.contains('onBanner: true'), isTrue,
          reason: '压在封面上的按钮需深色圆底才看得清');
      // 平板 banner 的标题按钮也换成同一变体
      expect(src.contains('item.name, onBanner: true'), isTrue);
    });

    test('标题 banner 按钮走 LiquidPress（可点，且不引入多余模糊层）', () {
      final src = File('lib/pages/detail_page.dart').readAsStringSync();
      final start = src.indexOf('Widget _translateButton(');
      final end = src.indexOf('void _onStateChanged', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final seg = src.substring(start, end);
      // 新实现：onBanner 分支用 LiquidPress 圆钮（顶部圆钮同款，已验证可点），
      // 且不复用 _RoundBtn（后者自带 BackdropFilter，会凭空多一层实时模糊、
      // 破坏「顶栏 3 圆钮」的模糊计数与滚动降级）。
      expect(seg.contains('return LiquidPress('), isTrue,
          reason: '标题 banner 按钮应走可点的 LiquidPress');
      expect(seg.contains('_RoundBtn('), isFalse,
          reason: '标题按钮不应复用带模糊的 _RoundBtn，避免新增模糊层');
      // 旧实现：Tooltip 内部的 opaque GestureDetector 只认 onLongPress，
      // 会吞掉短按 → 按钮「按不了」。
      expect(
        seg.contains('Tooltip(\n        message: tip,\n        child: GestureDetector('),
        isFalse,
        reason: 'Tooltip 内部的 opaque GestureDetector 会吞掉标题按钮的短按',
      );
    });
  });
}
