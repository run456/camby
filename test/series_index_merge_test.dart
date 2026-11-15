import 'package:flutter_test/flutter_test.dart';
import 'package:camby/models.dart';

/// A2（v2.0.98）：绿联影视中心把每一季登记成独立的 Series，导致媒体库网格、
/// 搜索、系列 tab 里「同一部剧」被拆成多个卡片。修复用展示层合并
/// [mergeSiblingSeriesItems]（不影响 [AppState.items] 原始数据）：按基名归组、
/// 取最早一季作代表、名字改回基名、集数累加。
MediaItem series(String id, String name, {int childCount = 0}) => MediaItem(
      id: id,
      name: name,
      type: MediaType.series,
      overview: '',
      colors: const [],
      childCount: childCount,
    );

MediaItem movie(String id, String name) => MediaItem(
      id: id,
      name: name,
      type: MediaType.movie,
      overview: '',
      colors: const [],
    );

void main() {
  group('mergeSiblingSeriesItems：同基名 Series 折叠', () {
    test('傲骨贤妻 第1~3季 折叠成一条，名字回到基名，集数累加', () {
      final items = [
        series('s1', '傲骨贤妻', childCount: 23),
        series('s2', '傲骨贤妻 第2季', childCount: 22),
        series('s3', '傲骨贤妻 第3季', childCount: 21),
      ];
      final out = mergeSiblingSeriesItems(items);
      expect(out.length, 1);
      expect(out.first.name, '傲骨贤妻');
      // 裸名（第1季）作代表：childCount 应是三季之和
      expect(out.first.id, 's1');
      expect(out.first.childCount, 23 + 22 + 21);
    });

    test('带 Season / Sxx 后缀的不同写法按基名归并', () {
      final items = [
        series('a', 'The Office Season 2', childCount: 1),
        series('b', 'The Office S01', childCount: 1),
      ];
      final out = mergeSiblingSeriesItems(items);
      expect(out.length, 1);
      expect(out.first.name, 'The Office');
    });

    test('不同剧之间不误合并（基名必须完全一致）', () {
      final items = [
        series('x', '傲骨贤妻', childCount: 1),
        series('y', '傲骨贤妻外传', childCount: 1),
        series('z', '傲骨贤妻 第2季', childCount: 1),
      ];
      final out = mergeSiblingSeriesItems(items);
      // 外传基名不同，应保留为独立条目 → 2 条
      expect(out.length, 2);
    });

    test('非剧集条目原样保留', () {
      final items = [
        movie('m1', '盗梦空间'),
        series('s1', '西部世界 第1季', childCount: 10),
        series('s2', '西部世界 第2季', childCount: 10),
      ];
      final out = mergeSiblingSeriesItems(items);
      expect(out.length, 2);
      expect(out.any((e) => e.id == 'm1'), isTrue);
    });

    test('单条 Series 无兄弟时不改动', () {
      final items = [series('solo', '大明王朝1566', childCount: 46)];
      final out = mergeSiblingSeriesItems(items);
      expect(out.length, 1);
      expect(out.first.name, '大明王朝1566');
    });

    test('空基名（整名就是季后缀）的条目不并入，原样返回', () {
      final items = [series('q', '第5季', childCount: 1)];
      final out = mergeSiblingSeriesItems(items);
      expect(out.length, 1);
      expect(out.first.name, '第5季');
    });
  });

  group('seasonFromSeriesName 兜底（裸名不再静默返回 null 已收敛）', () {
    test('标准剧集名正确取季号', () {
      expect(seasonFromSeriesName('瑞克和莫蒂 第5季'), 5);
      expect(seasonFromSeriesName('From Season 2'), 2);
      expect(seasonFromSeriesName('某剧 S03'), 3);
    });
    test('纯剧名无季后缀返回 null（标准 Emby 剧名本就无后缀）', () {
      expect(seasonFromSeriesName('梦魇绝镇'), isNull);
    });
  });
}
