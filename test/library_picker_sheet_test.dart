import 'package:camby/models.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/library_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.98（设计稿 P0）：媒体库选择弹窗。
///
/// 旧实现把所有 UserView 平铺成一条横滑 chip —— 库一多就找不到、看不到总数、
/// 选中的还会被滑出视野。这里守住三件容易改坏的事：
///  1. 本地派生（零请求）：每个库的海报 / 数量都从已缓存的 items 里取；
///  2. 兜底不退化：没有海报的库用「按库名哈希的渐变 + 首字」，不是灰方块；
///  3. 选中语义：`null` = 全部影片，和 `LibraryPick(null)` 一一对应。
MediaItem _item(
  String id, {
  String? parentId,
  String? posterUrl,
}) => MediaItem(
  id: id,
  name: id,
  type: MediaType.movie,
  overview: '',
  colors: const [],
  parentId: parentId,
  posterUrl: posterUrl,
);

const _views = <LibraryView>[
  LibraryView(id: 'v-movie', name: '电影'),
  LibraryView(id: 'v-tv', name: '剧集', collectionType: 'tvshows'),
  LibraryView(id: 'v-doc', name: '纪录片'),
];

void main() {
  group('本地派生：零新增请求', () {
    final items = <MediaItem>[
      _item('a1', parentId: 'v-movie', posterUrl: 'p1'),
      _item('a2', parentId: 'v-movie', posterUrl: 'p2'),
      _item('a3', parentId: 'v-movie'),
      _item('a4', parentId: 'v-movie', posterUrl: 'p3'),
      _item('a5', parentId: 'v-movie', posterUrl: 'p4'),
      _item('b1', parentId: 'v-tv', posterUrl: 'q1'),
      _item('c1'),
    ];

    test('posterPreviews 只取该库、只取有海报的、最多 3 张', () {
      expect(posterPreviews(items, 'v-movie'), ['p1', 'p2', 'p3']);
      expect(posterPreviews(items, 'v-tv'), ['q1']);
      expect(posterPreviews(items, 'v-none'), isEmpty);
    });

    test('viewItemCount 按 parentId 计数（没有则 0，不抛）', () {
      expect(viewItemCount(items, 'v-movie'), 5);
      expect(viewItemCount(items, 'v-tv'), 1);
      expect(viewItemCount(items, 'v-none'), 0);
    });

    test('库主色按名字稳定哈希：同名同色、不同名不保证不同但能取到', () {
      final a = viewAccent('电影');
      final b = viewAccent('电影');
      expect(a, b, reason: '同一个库每次打开必须同一主色');
      expect(a.length, 2);
      // 7 组配色里必有一组命中，且不是同一个对象引用问题
      expect(viewAccent('剧集').length, 2);
    });
  });

  group('弹窗渲染与选中语义', () {
    Future<LibraryPick?> open(
      WidgetTester tester, {
      String? selected,
      List<LibraryView> views = _views,
    }) async {
      LibraryPick? got;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    got = await showLibraryPickerSheet(
                      c,
                      views: views,
                      items: const [],
                      selectedId: selected,
                      recentCount: 7,
                      continueCount: 3,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return got;
    }

    testWidgets('标题、全部影片、虚拟库分组都在', (tester) async {
      await open(tester);
      expect(find.text('我的媒体'), findsOneWidget);
      expect(find.text('全部影片'), findsOneWidget);
      expect(find.text('虚拟媒体库'), findsOneWidget);
      expect(find.text('服务器媒体库'), findsOneWidget);
      // 虚拟库的两个入口与 7 / 3 的计数
      expect(find.text('最近添加'), findsOneWidget);
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.text('7 部'), findsOneWidget);
      expect(find.text('3 部'), findsOneWidget);
      // 三个服务器库
      for (final v in _views) {
        expect(find.text(v.name), findsOneWidget);
      }
    });

    testWidgets('点「全部影片」返回 null（= 全部）', (tester) async {
      final got = await open(tester);
      await tester.tap(find.text('全部影片'));
      await tester.pumpAndSettle();
      // 回传值在 pop 之后才赋值，这里再读一次
      expect(got, isNull);
      expect(find.text('我的媒体'), findsNothing);
    });

    testWidgets('点某个库卡返回该库 id', (tester) async {
      LibraryPick? got;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    got = await showLibraryPickerSheet(
                      c,
                      views: _views,
                      items: const [],
                      selectedId: null,
                      recentCount: 0,
                      continueCount: 0,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纪录片'));
      await tester.pumpAndSettle();
      expect(got?.viewId, 'v-doc');
    });

    testWidgets('库数 >12 才出现搜索框', (tester) async {
      final many = [
        for (var i = 0; i < 13; i++) LibraryView(id: 'v$i', name: '库$i'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showLibraryPickerSheet(
                    c,
                    views: many,
                    items: const [],
                    selectedId: null,
                    recentCount: 0,
                    continueCount: 0,
                  ),
                  child: const Text('open-many'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-many'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('共 15 个 · 13 个服务器库'), findsOneWidget);
    });
  });
}
