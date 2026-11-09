import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/actor_index_page.dart';
import 'package:camby/pages/favorites_page.dart';
import 'package:camby/pages/library_page.dart';
import 'package:camby/pages/person_page.dart';
import 'package:camby/pages/series_index_page.dart';
import 'package:camby/pages/tag_page.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/library_index_segment.dart';

/// v2.0.60 设计稿方案 A 回归：媒体库二级分段（影片 / 演员 / 系列）。
/// 覆盖聚合去重、A1+A2 两档过滤、搜索、排序、点击复用 PersonPage / TagPage，
/// 并锁死「底部导航没有加第 6 个 Tab」。
void main() {
  MediaItem mk(
    String id, {
    List<CastMember> people = const [],
    String seriesName = '',
    int? dateCreatedMs,
  }) =>
      MediaItem(
        id: id,
        name: '影片 $id',
        type: MediaType.movie,
        overview: '简介',
        colors: const [Color(0xFF3366CC), Color(0xFF101010)],
        people: people,
        seriesName: seriesName,
        dateCreatedMs: dateCreatedMs,
      );

  // 葵(3 部，有头像) / 山田(1 部，无头像) / 小松(1 部，有头像) / 无名(1 部，无头像)
  final items = <MediaItem>[
    mk(
      'a',
      people: const [
        CastMember(name: '葵こはる', id: 'p1', imageTag: 't1'),
        CastMember(name: '山田万次郎', id: 'p2'),
      ],
      seriesName: '彼女の姉貴とイケナ関係',
      dateCreatedMs: 100,
    ),
    mk(
      'b',
      people: const [
        CastMember(name: '葵こはる', id: 'p1', imageTag: 't1'),
        CastMember(name: '小松空', id: 'p3', imageTag: 't3'),
      ],
      seriesName: '彼女の姉貴とイケナ関係',
      dateCreatedMs: 300,
    ),
    mk(
      'c',
      people: const [CastMember(name: '葵こはる', id: 'p1', imageTag: 't1')],
      seriesName: '深海',
      dateCreatedMs: 200,
    ),
    mk(
      'd',
      people: const [CastMember(name: '无名演员', id: 'p4')],
      dateCreatedMs: 50,
    ),
  ];

  AppState stateWith() {
    final s = AppState();
    s.installTestItems(items);
    return s;
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: page),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpActors(WidgetTester tester) => pumpPage(
        tester,
        ActorIndexPage(
          state: stateWith(),
          onOpenDetail: (_, {String? heroTag}) {},
          tab: LibraryIndexTab.actors,
          onTabChanged: (_) {},
        ),
      );

  Future<void> pumpSeries(WidgetTester tester) => pumpPage(
        tester,
        SeriesIndexPage(
          state: stateWith(),
          onOpenDetail: (_, {String? heroTag}) {},
          tab: LibraryIndexTab.series,
          onTabChanged: (_) {},
        ),
      );

  // 分段切换只验证页面类型与控件，用空数据避开影片分支 PosterCard 网格
  // 在测试视口下的既有布局溢出（与 v2.0.60 分段逻辑无关）。
  Future<void> pumpLibrary(WidgetTester tester) => pumpPage(
        tester,
        LibraryPage(
          state: AppState()..installTestItems(const []),
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      );

  /// 精确定位分段控件里的文字，避开同名的页面标题 / 统计文本。
  Finder segmentLabel(String label) => find.descendant(
        of: find.byType(LibraryIndexSegment),
        matching: find.text(label),
      );

  /// 只匹配 Text widget，避开搜索框的 EditableText（find.text 会同时命中）。
  Finder plainText(String s) => find.byWidgetPredicate(
        (w) => w is Text && w.data == s,
      );

  // ---------------- 源码守卫 ----------------

  group('设计稿约束', () {
    test('底部导航仍是 5 个 Tab，没有硬加第 6 个', () {
      final main = File('lib/main.dart').readAsStringSync();
      final block =
          RegExp(r'static const _items = \[([\s\S]*?)\];')
              .firstMatch(main)
              ?.group(1) ??
              '';
      expect('(Icons.'.allMatches(block).length, 5,
          reason: '演员 / 系列必须收进媒体库二级分段，不占一级导航');
      expect(block.contains("'演员'"), isFalse);
      expect(block.contains("'系列'"), isFalse);
    });

    test('媒体库接入三个分段视图，且演员页同时提供 A1 / A2', () {
      final lib = File('lib/pages/library_page.dart').readAsStringSync();
      expect(lib.contains('LibraryIndexSegment'), isTrue);
      expect(lib.contains('ActorIndexPage'), isTrue);
      expect(lib.contains('SeriesIndexPage'), isTrue);
      final actors =
          File('lib/pages/actor_index_page.dart').readAsStringSync();
      expect(actors.contains('imageTag!.isNotEmpty'), isTrue,
          reason: 'A2：有头像近似女演员');
      expect(actors.contains('const labels = [\'全部\', \'女演员\', \'已收藏\']'),
          isTrue, reason: 'A1 与 A2 应可随时切换，而不是写死过滤');
      final series =
          File('lib/pages/series_index_page.dart').readAsStringSync();
      expect(series.contains('TagPageMode.series'), isTrue);
    });
  });

  // ---------------- 演员总览 ----------------

  group('演员总览', () {
    testWidgets('聚合去重 + 参演数，默认按参演最多排序', (tester) async {
      await pumpActors(tester);
      expect(find.text('演员 · 共 4 位 · 已收藏 0 位'), findsOneWidget);
      expect(find.text('葵こはる'), findsOneWidget);
      expect(find.text('3 部'), findsOneWidget);
      expect(find.text('山田万次郎'), findsOneWidget);
      expect(find.text('小松空'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('女演员档（A2）只显示有头像的，全部档（A1）不过滤',
        (tester) async {
      await pumpActors(tester);
      await tester.tap(find.text('女演员'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('葵こはる'), findsOneWidget);
      expect(find.text('小松空'), findsOneWidget);
      expect(find.text('山田万次郎'), findsNothing);
      expect(find.text('无名演员'), findsNothing);

      await tester.tap(find.text('全部'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('山田万次郎'), findsOneWidget);
      expect(find.text('无名演员'), findsOneWidget);
    });

    testWidgets('已收藏档空态 + 搜索按名字过滤', (tester) async {
      await pumpActors(tester);
      await tester.tap(find.text('已收藏'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('还没有收藏演员'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), '葵');
      await tester.pump();
      expect(find.text('葵こはる'), findsOneWidget);
      expect(find.text('小松空'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('排序可切换，点演员卡片复用 PersonPage', (tester) async {
      await pumpActors(tester);
      await tester.tap(find.text('名字 A–Z'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('actor-index-grid')), findsOneWidget);

      await tester.tap(find.text('葵こはる'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(PersonPage), findsOneWidget,
          reason: '点演员应打开已有演员详情页，而不是新建一套');
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------- 系列总览 ----------------

  group('系列总览', () {
    testWidgets('聚合系列名与部数，长名完整显示', (tester) async {
      await pumpSeries(tester);
      expect(find.text('系列 · 共 2 个 · 4 部影片'), findsOneWidget);
      expect(find.text('彼女の姉貴とイケナ関係'), findsOneWidget);
      expect(find.text('2 部影片'), findsOneWidget);
      expect(find.text('深海'), findsOneWidget);
      expect(find.text('1 部影片'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索 + 点系列打开 series 模式聚合页', (tester) async {
      await pumpSeries(tester);
      await tester.enterText(find.byType(TextField), '深海');
      await tester.pump();
      expect(plainText('彼女の姉貴とイケナ関係'), findsNothing);
      expect(plainText('深海'), findsOneWidget);

      await tester.tap(plainText('深海'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(TagPage), findsOneWidget);
      expect(find.text('系列 · 深海'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------- 分段切换 ----------------

  group('媒体库二级分段', () {
    testWidgets('v2.0.68：影片 / 演员 / 系列 / 收藏 4 类可切换', (tester) async {
      await pumpLibrary(tester);
      expect(find.byType(LibraryIndexSegment), findsOneWidget);
      for (final label in ['影片', '演员', '系列', '收藏']) {
        expect(segmentLabel(label), findsOneWidget, reason: '缺少第 4 类 $label');
      }

      await tester.tap(segmentLabel('演员'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ActorIndexPage), findsOneWidget);
      expect(find.text('演员 · 共 0 位 · 已收藏 0 位'), findsOneWidget);

      await tester.tap(segmentLabel('系列'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SeriesIndexPage), findsOneWidget);
      expect(find.text('系列 · 共 0 个 · 0 部影片'), findsOneWidget);

      await tester.tap(segmentLabel('收藏'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FavoritesPage), findsOneWidget,
          reason: '收藏并入媒体库第 4 类');
      expect(segmentLabel('收藏'), findsOneWidget);
      expect(find.text('影片收藏'), findsOneWidget);

      await tester.tap(segmentLabel('影片'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ActorIndexPage), findsNothing);
      expect(find.byType(SeriesIndexPage), findsNothing);
      expect(find.byType(FavoritesPage), findsNothing);
      expect(find.byType(LibraryIndexSegment), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
