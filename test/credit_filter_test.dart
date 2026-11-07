import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/tag_page.dart';
import 'package:camby/widgets/media_filter_sheet.dart';

/// v2.0.55 回归：导演 / 制造商独立成行 + 点击筛选 + 筛选面板分组。
///
/// 详情页那一条「拆行 + 真实点击」放在 detail_info_regression_test.dart，
/// 这里覆盖公共筛选模型、抽屉与全库聚合页。
void main() {
  MediaItem mk(
    String id, {
    String director = '',
    String studio = '',
    List<String> tags = const [],
    String seriesName = '',
  }) =>
      MediaItem(
        id: id,
        name: '影片 $id',
        type: MediaType.movie,
        overview: '简介',
        colors: const [Color(0xFF3366CC), Color(0xFF101010)],
        director: director,
        studio: studio,
        tags: tags,
        seriesName: seriesName,
      );

  final items = [
    mk('a', director: '陈叙', studio: 'IDEA POCKET', tags: ['科幻'], seriesName: '甜蜜风暴'),
    mk('b', director: ' 陈叙 ', studio: 'MOODYZ', tags: ['剧情'], seriesName: '甜蜜风暴'),
    mk('c', director: '林越', studio: 'idea pocket', tags: ['科幻'], seriesName: '深海'),
    mk('d'), // 两个字段都空，任何一组筛选都不应命中
  ];

  group('MediaFilter：导演 / 制造商条件', () {
    // apply() 会按年份排序，而 Dart 的 List.sort 不稳定；这里只关心命中集合
    test('按导演筛选，trim + 忽略大小写', () {
      final f = MediaFilter(directors: {'陈叙'});
      expect(f.apply(items).map((e) => e.id), unorderedEquals(['a', 'b']));
    });

    test('按制造商筛选，忽略大小写', () {
      final f = MediaFilter(studios: {'IDEA POCKET'});
      expect(f.apply(items).map((e) => e.id), unorderedEquals(['a', 'c']));
    });

    test('导演 + 制造商是「组间且」，组内多选是「或」', () {
      final f = MediaFilter(
        directors: {'陈叙', '林越'},
        studios: {'IDEA POCKET'},
      );
      expect(f.apply(items).map((e) => e.id), unorderedEquals(['a', 'c']));
    });

    test('按系列筛选，trim + 忽略大小写', () {
      expect(MediaFilter(series: {'甜蜜风暴'}).apply(items).map((e) => e.id),
          unorderedEquals(['a', 'b']));
      expect(MediaFilter(series: {' 深海 '}).apply(items).map((e) => e.id),
          unorderedEquals(['c']));
      // 组内多选是「或」，组间与导演是「且」
      expect(
        MediaFilter(series: {'甜蜜风暴', '深海'}).apply(items).map((e) => e.id),
        unorderedEquals(['a', 'b', 'c']),
      );
    });

    test('空 seriesName 条目在任何系列筛选下都不命中', () {
      expect(MediaFilter(series: {'甜蜜风暴'}).keeps(items[3]), isFalse);
    });

    test('空值条目在任何一组筛选下都不命中', () {
      expect(MediaFilter(directors: {'陈叙'}).keeps(items[3]), isFalse);
      expect(MediaFilter(studios: {'IDEA POCKET'}).keeps(items[3]), isFalse);
      expect(MediaFilter().keeps(items[3]), isTrue);
    });

    test('activeCount / clearConditions / applyResult 都带上新条件', () {
      final f = MediaFilter(
        tags: {'科幻'},
        directors: {'陈叙'},
        studios: {'IDEA POCKET'},
        series: {'甜蜜风暴'},
        cnOnly: true,
      );
      expect(f.activeCount, 5);

      f.applyResult(
        const MediaFilterResult(
          sort: 2,
          desc: [true, false, true, true, true],
          res: {},
          cnOnly: false,
          tags: {},
          directors: {'林越'},
          studios: {'MOODYZ'},
          series: {'深海'},
        ),
      );
      expect(f.directors, {'林越'});
      expect(f.studios, {'MOODYZ'});
      expect(f.series, {'深海'});
      expect(f.activeCount, 3);

      f.clearConditions();
      expect(f.activeCount, 0);
      expect(f.keeps(items[3]), isTrue);
    });

    test('计数只统计非空名字', () {
      final d = MediaFilter.directorCountsOf(items);
      final s = MediaFilter.studioCountsOf(items);
      final se = MediaFilter.seriesCountsOf(items);
      expect(d.containsKey(''), isFalse);
      expect(s.containsKey(''), isFalse);
      expect(se.containsKey(''), isFalse);
      expect(d['陈叙'], 2); // ' 陈叙 ' 已 trim 成同一个 key
      expect(d['林越'], 1);
      expect(s['IDEA POCKET'], 1);
      expect(se['甜蜜风暴'], 2);
      expect(se['深海'], 1);
    });
  });

  group('筛选抽屉：导演 / 制造商分组', () {
    testWidgets('抽屉出现两个分组且可多选提交', (tester) async {
      // 抽屉里的 ListView 是懒构建的；默认 800×600 测试屏放不下排序 +
      // 分辨率 + 字幕 + 导演/制造商 + 标签，给足高度让分组都进视口。
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      late BuildContext sheetContext;
      MediaFilterResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                sheetContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final pending = showMediaFilterSheet(
        sheetContext,
        filter: MediaFilter(),
        source: items,
      ).then((v) => result = v);
      await tester.pumpAndSettle();

      // 分组标题 + 具体名字的 chip 都要在抽屉里
      expect(find.text('导演'), findsOneWidget);
      expect(find.text('制造商'), findsOneWidget);
      expect(find.text('陈叙'), findsOneWidget);
      expect(find.text('林越'), findsOneWidget);
      expect(find.text('IDEA POCKET'), findsOneWidget);

      // 点一个导演 chip，再应用
      await tester.tap(find.text('陈叙'));
      await tester.pump();
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      await pending;

      expect(result, isNotNull);
      expect(result!.directors, {'陈叙'});
      expect(result!.studios, isEmpty);
    });

    testWidgets('抽屉出现「系列」分组，且命中数<8 的标签/系列选项不显示', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      // 8 部带「常见」标签 +「大系」系列（命中 8，应显示）；
      // 1 部带「冷门」标签 +「小系」系列（命中 1，应隐藏）。
      final big = <MediaItem>[
        for (var i = 0; i < 8; i++)
          mk('x$i', tags: ['常见'], seriesName: '大系'),
        mk('y1', tags: ['冷门'], seriesName: '小系'),
      ];

      late BuildContext sheetContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                sheetContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      // 抽屉内部 chip 较多，pumpAndSettle 在该配置下不收敛，改用显式帧推进
      showMediaFilterSheet(sheetContext, filter: MediaFilter(), source: big);
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // 分组标题 + 高频选项都出现
      expect(find.text('系列'), findsOneWidget);
      expect(find.text('大系'), findsOneWidget); // 命中 8 -> 显示
      expect(find.text('常见'), findsOneWidget); // 命中 8 -> 显示
      // 低频选项被阈值过滤掉
      expect(find.text('冷门'), findsNothing); // 命中 1 -> 隐藏
      expect(find.text('小系'), findsNothing); // 命中 1 -> 隐藏
    });
  });

  group('TagPage 三种聚合模式', () {
    AppState stateWith(List<MediaItem> list) {
      final s = AppState();
      s.installTestItems(list);
      return s;
    }

    Future<void> pumpPage(
      WidgetTester tester,
      String value,
      TagPageMode mode,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TagPage(
            tag: value,
            mode: mode,
            state: stateWith(items),
            onOpenDetail: (_, {heroTag}) {},
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('director 模式列出同导演影片', (tester) async {
      await pumpPage(tester, '陈叙', TagPageMode.director);
      expect(find.text('导演 · 陈叙'), findsOneWidget);
      expect(find.text('影片 a'), findsOneWidget);
      expect(find.text('影片 b'), findsOneWidget);
      expect(find.text('影片 c'), findsNothing);
      expect(find.text('2 部'), findsOneWidget);
    });

    testWidgets('studio 模式列出同制造商影片（忽略大小写）', (tester) async {
      await pumpPage(tester, 'IDEA POCKET', TagPageMode.studio);
      expect(find.text('制造商 · IDEA POCKET'), findsOneWidget);
      expect(find.text('影片 a'), findsOneWidget);
      expect(find.text('影片 c'), findsOneWidget);
      expect(find.text('影片 b'), findsNothing);
    });

    testWidgets('tag 模式保持原有标签语义', (tester) async {
      await pumpPage(tester, '科幻', TagPageMode.tag);
      expect(find.text('#科幻'), findsOneWidget);
      expect(find.text('影片 a'), findsOneWidget);
      expect(find.text('影片 c'), findsOneWidget);
      expect(find.text('影片 b'), findsNothing);
    });
  });
}
