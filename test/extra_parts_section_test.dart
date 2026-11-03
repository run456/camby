// 「额外部分」栏目回归测试：手机与平板两套布局都要渲染出来，
// 且位置在「剧照」之前（与 Emby 网页版一致：预告片 → 额外部分 → 剧照）。
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
    testWidgets('$label 详情页：有额外部分时显示栏目，且位于剧照之前', (tester) async {
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

      // 栏目标题 + 数量
      final title = find.text('额外部分');
      expect(title, findsOneWidget, reason: '$label 应出现「额外部分」栏目');
      expect(find.text('2 个'), findsOneWidget);

      // 位置：额外部分在剧照之前
      final stills = find.text('剧照');
      if (tester.any(stills)) {
        expect(
          tester.getTopLeft(title).dy,
          lessThan(tester.getTopLeft(stills).dy),
          reason: '$label 额外部分应排在剧照之前',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
