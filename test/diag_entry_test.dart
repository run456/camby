// 诊断入口可见性回归测试。
//
// 背景：手机与平板两套布局曾各写一份条件，平板那份是旧逻辑「有预告片就隐藏」，
// 于是「额外部分取不到」时诊断入口跟着消失，无法排查。现在统一为
// `_showDiagEntry`：预告片或额外部分任一缺失就显示。
//
// 这里锁定 4 种组合 × 三档屏幕，防止再次回归。
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

MediaItem _movie({bool withTrailer = false, bool withExtra = false}) =>
    MediaItem(
      id: 'macc-diag-1',
      name: '诊断样例',
      type: MediaType.movie,
      overview: '样例',
      colors: const [Color(0xFF204A80), Color(0xFF0C1524)],
      genres: const ['剧情'],
      trailerUrls: withTrailer ? const ['https://example.invalid/t'] : const [],
      extraParts: withExtra
          ? const [MediaExtraPart(id: 'src-2', name: '样例-Cd2')]
          : const [],
    );

void main() {
  for (final (label, size) in <(String, Size)>[
    ('手机', const Size(430, 932)),
    ('平板', const Size(1194, 834)),
    ('大平板', const Size(1600, 1000)),
  ]) {
    for (final (caseName, trailer, extra) in <(String, bool, bool)>[
      ('两者都没有', false, false),
      ('只有预告片', true, false),
      ('只有额外部分', false, true),
    ]) {
      testWidgets('$label / $caseName → 诊断入口可见', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrap(
            DetailPage(
              item: _movie(withTrailer: trailer, withExtra: extra),
              state: AppState(),
              onPlay: (item, subtitle, {resume = false}) {},
              onPlayPart: (item, part) {},
              onOpenDetail: (_, {String? heroTag}) {},
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        // 入口在页面底部，先滚到底
        await tester.dragUntilVisible(
          find.text('相似推荐'),
          find.byType(ListView).first,
          const Offset(0, -400),
          maxIteration: 40,
        );
        await tester.pump();

        expect(
          find.text('没看到预告片/额外部分？点此诊断'),
          findsOneWidget,
          reason: '$label / $caseName 应显示诊断入口',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$label / 两者都有 → 诊断入口隐藏', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wrap(
          DetailPage(
            item: _movie(withTrailer: true, withExtra: true),
            state: AppState(),
            onPlay: (item, subtitle, {resume = false}) {},
            onPlayPart: (item, part) {},
            onOpenDetail: (_, {String? heroTag}) {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.dragUntilVisible(
        find.text('相似推荐'),
        find.byType(ListView).first,
        const Offset(0, -400),
        maxIteration: 40,
      );
      await tester.pump();

      expect(
        find.text('没看到预告片/额外部分？点此诊断'),
        findsNothing,
        reason: '$label 两者齐全时不该再打扰',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
