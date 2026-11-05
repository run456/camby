import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';
import 'package:camby/widgets/glass_sheet.dart';

/// flutter test 跑在桌面宿主上，path_provider 的原生通道没有实现，
/// 把用到的 `getApplicationDocumentsDirectory` 通道方法 mock 成系统临时目录。
const _ppChannel = MethodChannel('plugins.flutter.io/path_provider');

/// v2.0.51 回归：详情页「标题旁翻译按钮」在手机布局下点击应弹出翻译弹层。
///
/// 背景：v2.0.49 / v2.0.50 两次「修」过这个按钮，但都只做源码层面的替换与守卫，
/// 没在测试里真正 tap 验证。v2.0.51 之前该按钮在手机布局下点不动——根因是 banner 用
/// `ListView` 垂直排列「海报 + Transform.translate(内容)」，Transform 只改视觉位置、
/// 不改布局槽位，命中测试按布局位置把按钮区域判给下层海报，事件到不了按钮。改用 Stack
/// 重叠后，标题块位于绘制上层，按钮可被点击（与平板 _tabletBanner 一致）。
///
/// 注意：`_openTranslate` 会先 `LaraTranslateCache.load`（真实文件 I/O）。桌面宿主的
/// testWidgets 在 FakeAsync 下会让文件 I/O 挂起，因此把「点击 + 等待弹层」包在
/// `tester.runAsync` 里，让真实异步 I/O 在 FakeAsync 之外完成。
void main() {
  late final Directory docsDir;
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = Directory.systemTemp.createTempSync('camby_lara_docs');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ppChannel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          return docsDir.path;
        default:
          return null;
      }
    });
  });

  Future<void> pumpDetail(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    // 强制手机布局（width < 840），复现用户截图场景
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final item = MediaItem(
      id: 'm1',
      name: 'IPZ-964 調教されたアイドル',
      type: MediaType.movie,
      overview: '一段用于翻译测试的简介原文。',
      colors: [const Color(0xFF3366CC), const Color(0xFF101010)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: item,
          onPlay: (_, _, {bool resume = false}) {},
          onPlayPart: (_, _) {},
          state: AppState(),
          onOpenDetail: (_, {heroTag}) {},
        ),
      ),
    );
    // DetailPage 有持续动画定时器，pumpAndSettle 会超时，手动 pump
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 点击翻译按钮并等待弹层出现。
  /// 路线：在 runAsync（真实异步区）里 tap，让 `_openTranslate` 中的文件 I/O
  /// （LaraTranslateCache.load）能在 FakeAsync 之外完成；route 被 push 后回到
  /// FakeAsync，用固定帧 pump 让 route 的过渡动画把 _TranslateSheet（GlassPanel）
  /// 渲染出来。不能用 pumpAndSettle：详情页有持续动画会一直不收敛。
  Future<void> tapAndExpectSheet(WidgetTester tester, Finder btn) async {
    await tester.runAsync(() async {
      await tester.tap(btn, warnIfMissed: true);
      // 给真实文件 I/O 一点时间完成
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(GlassPanel).evaluate().isNotEmpty) return;
    }
    throw Exception('翻译弹层（GlassPanel）未出现');
  }

  testWidgets('手机布局：点击标题旁翻译按钮 → 弹出翻译弹层（GlassPanel）',
      (tester) async {
    await pumpDetail(tester);

    final icons = find.byIcon(Icons.translate_rounded);
    expect(icons, findsWidgets, reason: '应至少存在一个翻译按钮');
    // 树序：标题按钮（onBanner，Stack 叠层里）在前，简介按钮在后
    final titleBtn = icons.at(0);

    // 点击前不应有任何 GlassPanel 弹层
    expect(find.byType(GlassPanel), findsNothing,
        reason: '点击前页面不应有 GlassPanel 弹层');

    await tapAndExpectSheet(tester, titleBtn);

    expect(find.byType(GlassPanel), findsWidgets,
        reason: '点击标题旁翻译按钮必须弹出翻译弹层（GlassPanel）');
  });

  testWidgets('手机布局：点击简介旁翻译按钮（回归）也应弹出弹层', (tester) async {
    await pumpDetail(tester);

    final icons = find.byIcon(Icons.translate_rounded);
    // 简介按钮在树序靠后
    final overviewBtn = icons.at(icons.evaluate().length - 1);

    await tapAndExpectSheet(tester, overviewBtn);

    expect(find.byType(GlassPanel), findsWidgets,
        reason: '点击简介旁翻译按钮也应弹出翻译弹层（GlassPanel）');
  });
}
