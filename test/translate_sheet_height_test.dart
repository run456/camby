import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/lara/translate_cache.dart';
import 'package:camby/lara/translate_sheet.dart';

/// v2.0.53 回归：翻译弹层应按内容自适应高度，短原文 / 未翻译时译文卡片
/// 下方不能留大块空白。
///
/// 背景：此前 `_TranslateSheet` 用 `SizedBox(height: panelH)` 把面板钉死在
/// `clamp(屏幕可用高 - 24, 300, 620)`（手机上恒为 620），内容却按自然高度
/// 从上往下排，短原文时面板比内容多出约 150px、译文卡片下方留白约 210px。改为
/// `ConstrainedBox(maxHeight:)` + `Column(mainAxisSize: min)` + `Flexible`，
/// 面板按内容收缩，仅内容超高时受上限约束并滚动。
void main() {
  Future<void> openSheet(
    WidgetTester tester, {
    required String original,
    CachedTranslation? existing,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                key: const Key('open'),
                onPressed: () => showTranslateSheet(
                  ctx,
                  itemId: 'm1',
                  field: 'overview',
                  original: original,
                  existing: existing,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  testWidgets('短原文：译文卡片下方不留大块空白', (tester) async {
    await openSheet(tester, original: 'SSIS-602 昨日我家に入った強盗犯はリス トラされ、借金にまみれ');

    final panel = tester.getRect(find.byType(BackdropFilter));
    final hint = tester.getRect(find.text('点击上方「翻译」生成译文'));
    final gap = panel.bottom - hint.bottom;

    // 63px 是正常内边距（译文卡片 padding 14 + 滚动区底部 padding 18 等），
    // 修复前因面板被钉死在 620，此处约 210px。
    expect(gap, lessThan(90), reason: '译文卡片到面板底部不应出现多余留白（修复前约 210px）');
    expect(panel.height, lessThan(560), reason: '短原文时面板应收缩到约 472，不应仍占满 620');
  });

  testWidgets('有译文时面板自动长高，但仍不超过上限 620', (tester) async {
    await openSheet(
      tester,
      original: '原文',
      existing: CachedTranslation(
        text: '这是一段已缓存的译文。' * 20,
        meta: const {'style': 'faithful', 'detectedSource': 'ja'},
      ),
    );

    final panel = tester.getRect(find.byType(BackdropFilter));
    expect(panel.height, greaterThan(520), reason: '有译文时面板应随内容自动长高（短原文时约 472）');
    expect(
      panel.height,
      lessThanOrEqualTo(621),
      reason: '内容再长也不能超过 maxPanelH（620）',
    );
    expect(find.text('确认并缓存'), findsOneWidget, reason: '有译文时操作按钮应可见');
  });

  testWidgets('超长译文：面板受上限约束且内容可滚动', (tester) async {
    await openSheet(
      tester,
      original: '原文',
      existing: CachedTranslation(
        text: '很长的译文内容。' * 200,
        meta: const {'style': 'faithful', 'detectedSource': 'ja'},
      ),
    );

    final panel = tester.getRect(find.byType(BackdropFilter));
    expect(
      panel.height,
      lessThanOrEqualTo(621),
      reason: '超长内容时面板必须停在 maxPanelH，由内部滚动承接',
    );
    expect(
      find.byType(SingleChildScrollView),
      findsWidgets,
      reason: '超出上限时内容必须可滚动',
    );
  });
}
