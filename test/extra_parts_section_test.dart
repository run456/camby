// 「视频」板块回归测试（v2.0.41：预告片 + 额外部分合并为一行）。
//
// 手机与平板两套布局都要渲染出来，且位置在「剧照」之前
// （顺序：信息区 → 视频（预告/分段/花絮）→ 剧照）。
import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: child),
);

/// 带「额外部分」的样例影片（模拟 -Cd1 / -Cd2 分段）
MediaItem _movieWithParts() => MediaItem(
  id: 'demo-cd',
  name: 'DV-1242',
  type: MediaType.movie,
  overview: '带两个分段的样例影片',
  colors: const [Color(0xFF204A80), Color(0xFF0C1524)],
  genres: const ['剧情'],
  backdrops: const ['https://example.invalid/b0.jpg'],
  extraParts: const [
    MediaExtraPart(id: 'src-cd1', name: 'DV-1242-Cd1', height: 1080),
    MediaExtraPart(id: 'src-cd2', name: 'DV-1242-Cd2', height: 1080),
  ],
);

void main() {
  for (final (label, size) in <(String, Size)>[
    ('手机', const Size(430, 932)),
    ('平板', const Size(1194, 834)),
    ('大平板', const Size(1600, 1000)),
  ]) {
    testWidgets('$label 详情页：片段渲染在「视频」板块内，且位于剧照之前', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wrap(
          DetailPage(
            item: _movieWithParts(),
            state: AppState(),
            onPlay: (item, subtitle, {resume = false}) {},
            onPlayPart: (item, part) {},
            onOpenDetail: (_, {String? heroTag}) {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 板块标题 + 数量（分段的来源角标是「分段」）
      final title = find.text('视频');
      expect(title, findsOneWidget, reason: '$label 应出现「视频」板块');
      expect(find.text('2 个'), findsOneWidget);
      expect(
        find.text('分段'),
        findsWidgets,
        reason: '$label 分段卡片应带「分段」角标',
      );
      expect(
        find.text('DV-1242-Cd2'),
        findsOneWidget,
        reason: '$label 应列出 cd2',
      );

      // 位置：额外部分在剧照之前
      final stills = find.text('剧照');
      if (tester.any(stills)) {
        expect(
          tester.getTopLeft(title).dy,
          lessThan(tester.getTopLeft(stills).dy),
          reason: '$label 视频板块应排在剧照之前',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
