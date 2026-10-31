import 'package:camby/models.dart';
import 'package:camby/pages/subtitle_filter_page.dart';
import 'package:camby/pages/tag_page.dart';
import 'package:camby/app_state.dart';
import 'package:camby/widgets/sort_chip_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem _m(String id, {int year = 2020, double rating = 7}) => MediaItem(
      id: id,
      name: '片$id',
      overview: '',
      colors: const [Color(0xFF101820), Color(0xFF203040)],
      type: MediaType.movie,
      year: year,
      rating: rating,
    );

void main() {
  // ── 纯逻辑：sortItemsBy 排序与方向翻转 ──
  test('年份倒序→点同字段切正序（sortItemsBy）', () {
    final items = [
      _m('a', year: 2020, rating: 7),
      _m('b', year: 2023, rating: 6),
      _m('c', year: 2021, rating: 8),
    ];
    sortItemsBy(items, SortField.year, false); // 倒序：新→旧
    expect(items.map((e) => e.year).toList(), [2023, 2021, 2020]);
    sortItemsBy(items, SortField.year, true); // 正序：旧→新
    expect(items.map((e) => e.year).toList(), [2020, 2021, 2023]);
    // 标题正序（片a < 片b < 片c）
    sortItemsBy(items, SortField.title, true);
    expect(items.map((e) => e.name).toList(), ['片a', '片b', '片c']);
    // 评分倒序
    sortItemsBy(items, SortField.rating, false);
    expect(items.map((e) => e.rating).toList(), [8.0, 7.0, 6.0]);
  });

  testWidgets('TagPage：显示 年份/标题/评分 排序行，点同字段出现 ↑', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: TagPage(tag: '科幻', state: state, onOpenDetail: (_, {heroTag}) {}),
      ),
    );
    await tester.pump();
    // 年份默认倒序 ↓；标题/评分未选中显示纯文字
    expect(find.text('年份 ↓'), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);
    expect(find.text('评分'), findsOneWidget);
    // 再点一次 → 切正序 ↑
    await tester.tap(find.text('年份 ↓'));
    await tester.pump();
    expect(find.text('年份 ↑'), findsOneWidget);
    // 换字段 → 默认倒序
    await tester.tap(find.text('标题'));
    await tester.pump();
    expect(find.text('标题 ↓'), findsOneWidget);
    expect(find.text('年份'), findsOneWidget); // 旧字段不再高亮
  });

  testWidgets('中文字幕页：排序行与标签页同款（年份/标题/评分）', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleFilterPage(
          state: state,
          onOpenDetail: (_, {heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('年份 ↓'), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);
    expect(find.text('评分'), findsOneWidget);
    // 旧字段「最近添加」已移除，所有标签页样式统一
    expect(find.text('最近添加'), findsNothing);
  });
}
