// 播放行 + 系列占位 回归测试（v2.0.43）。
//
// 三件事要钉住：
// 1. 播放按钮从底部悬浮栏移到「剧情简介」上方（不再压住简介卡片）；
// 2. 有字幕时，字幕选择紧贴在播放按钮右侧；
// 3. 没有系列时，仍显示「系列」这一格，值为「无」。
import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/status_bar_blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: child),
);

/// 字幕轨（label 由 language + codec 拼出来，测试直接引用它，不硬编码文案）
const _track = SubtitleTrackInfo(index: 0, language: 'chi', codec: 'ass');

MediaItem _movie({bool withSeries = false, bool withSubs = false}) => MediaItem(
  id: 'macc-play-1',
  name: 'SAME-008 テスト',
  type: MediaType.movie,
  overview: '剧情简介正文，用来验证播放按钮排在它上面。',
  colors: const [Color(0xFF204A80), Color(0xFF0C1524)],
  genres: const ['剧情'],
  year: 2022,
  runtimeMin: 112,
  seriesName: withSeries ? 'Alma Mater' : '',
  subtitles: withSubs ? const [_track] : const [],
  backdrops: const ['https://example.invalid/b0.jpg'],
);

Future<void> _pump(WidgetTester tester, MediaItem item) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _wrap(
      DetailPage(
        item: item,
        state: AppState(),
        onPlay: (i, s, {resume = false}) {},
        onPlayPart: (i, p) {},
        onOpenDetail: (_, {String? heroTag}) {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('播放按钮排在「剧情简介」之上，且底部不再有悬浮播放条', (tester) async {
    await _pump(tester, _movie());

    final play = find.text('立即播放');
    expect(play, findsOneWidget, reason: '应有播放按钮');

    // 播放行在简介卡片之前
    expect(
      tester.getTopLeft(play).dy,
      lessThan(tester.getTopLeft(find.text('剧情简介')).dy),
      reason: '播放按钮应位于剧情简介上方',
    );

    // 底部悬浮播放条已移除（不再有那条常驻模糊带）
    expect(
      find.byType(BottomBarBlur),
      findsNothing,
      reason: '底部播放条已删除，不应再有 BottomBarBlur',
    );
  });

  testWidgets('有字幕时，字幕选择贴在播放按钮右侧', (tester) async {
    await _pump(tester, _movie(withSubs: true));

    final play = find.text('立即播放');
    final sub = find.text(_track.label);
    expect(sub, findsOneWidget, reason: '应显示当前字幕名: ${_track.label}');

    expect(
      tester.getTopLeft(sub).dx,
      greaterThan(tester.getTopLeft(play).dx),
      reason: '字幕选择应在播放按钮右边',
    );
    // 同一行：垂直中心接近
    final dyDiff = (tester.getCenter(sub).dy - tester.getCenter(play).dy).abs();
    expect(dyDiff, lessThan(6), reason: '字幕与播放按钮应同一行');
  });

  testWidgets('没有系列时，仍显示「系列」标题并标为「无」', (tester) async {
    await _pump(tester, _movie());

    final label = find.text('系列');
    expect(label, findsOneWidget, reason: '系列标题应始终显示');
    expect(
      find.text('无'),
      findsOneWidget,
      reason: '没有系列时应显示「无」而不是留空',
    );
    expect(
      tester.getTopLeft(find.text('无')).dy,
      greaterThan(tester.getTopLeft(label).dy),
      reason: '「无」应在「系列」标题下方',
    );
  });

  testWidgets('有系列时，显示系列名而不是「无」', (tester) async {
    await _pump(tester, _movie(withSeries: true));

    expect(find.text('Alma Mater'), findsOneWidget);
    expect(find.text('无'), findsNothing);
  });
}
