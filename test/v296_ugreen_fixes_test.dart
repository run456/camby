import 'package:flutter_test/flutter_test.dart';
import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:camby/watch_history.dart';

/// v2.0.96 三处真机回归的守卫：
///  1. 绿联把每季登记成**同名** Series 时，季选择不能消失；
///  2. 「只看 1 分钟却记成 12 分钟」——续播定位不能被算成观看时长；
///  3. 列表接口不下发 ImageTags 时，封面仍要能显示。

MediaItem _series(String id, String name, {int childCount = 10}) => MediaItem(
  id: id,
  name: name,
  type: MediaType.series,
  overview: '',
  colors: const [],
  childCount: childCount,
);

MediaItem _episode(String id, {required int season, required int ep}) =>
    MediaItem(
      id: id,
      name: 'S${season}E$ep',
      type: MediaType.episode,
      overview: '',
      colors: const [],
      seasonNumber: season,
      episodeNumber: ep,
    );

void main() {
  group('同名兄弟季（绿联每季一条 Series，名字不带季号）', () {
    final items = <MediaItem>[
      _series('s1', '瑞克和莫蒂'),
      _series('s2', '瑞克和莫蒂'),
      _series('s3', '瑞克和莫蒂'),
      _series('other', '其它剧'),
    ];

    test('siblingSeriesCandidates 能找出同名兄弟（不要求季号）', () {
      final cur = items.first;
      final cands = siblingSeriesCandidates(cur, items);
      expect(cands.map((e) => e.id), ['s2', 's3']);
      // 基名不同的不并
      expect(cands.any((e) => e.id == 'other'), isFalse);
    });

    test('旧逻辑（按名字取季号）对同名 Series 全部失效 —— 这就是「没有季选择」', () {
      // 文档化旧行为：这正是 v2.0.96 漏掉的那一类
      final groups = siblingSeasonGroups(items.first, items);
      expect(groups, isEmpty);
      expect(seasonFromSeriesName('瑞克和莫蒂'), isNull);
    });

    test('带季号的名字仍走老路（不能被新逻辑改坏）', () {
      final list = <MediaItem>[
        _series('a', '某剧 第1季'),
        _series('b', '某剧 第2季'),
      ];
      final groups = siblingSeasonGroups(list.first, list);
      expect(groups.map((g) => g.index), [2]);
    });

    test('分集自带季号 → 反推出真正的季号，季列表才对', () {
      final eps = <MediaItem>[
        _episode('e1', season: 5, ep: 1),
        _episode('e2', season: 5, ep: 2),
      ];
      final g = seasonGroups(eps);
      expect(g.length, 1);
      expect(g.first.index, 5);
      expect(g.first.episodes.length, 2);
    });
  });

  group('观看时长：续播 12 分钟只看 1 分钟不能记成 12 分钟', () {
    const tick = 10000000; // 1 秒

    test('优先采用播放器实测的 watchedSeconds', () {
      final m = resolveWatchMinutes(
        positionTicks: 13 * 60 * tick, // 结束位置 13:00
        startTicks: 0, // 老 bug：起播位置没传下来
        elapsedMinutes: 1,
        runtimeMinutes: 45,
        watchedSeconds: 60,
      );
      expect(m, closeTo(1.0, 0.01));
    });

    test('没有实测值时，用墙钟封顶兜住续播/拖动造成的虚高', () {
      final m = resolveWatchMinutes(
        positionTicks: 13 * 60 * tick,
        startTicks: 0,
        elapsedMinutes: 1,
        runtimeMinutes: 45,
      );
      // 1 分钟封顶 + 1 分钟抖动，绝不能是 13
      expect(m, lessThanOrEqualTo(2.0));
    });

    test('正常连续播放仍按位置差记（不会反过来少算）', () {
      final m = resolveWatchMinutes(
        positionTicks: 600 * tick,
        startTicks: 0,
        elapsedMinutes: 10,
        runtimeMinutes: 45,
      );
      expect(m, closeTo(10.0, 0.01));
    });

    test('按片长封顶，避免超出正片长度', () {
      final m = resolveWatchMinutes(
        positionTicks: 99 * 60 * tick,
        startTicks: 0,
        elapsedMinutes: 99,
        runtimeMinutes: 45,
      );
      expect(m, 45);
    });
  });

  group('封面地址：绿联列表不下发 ImageTags 也要有图', () {
    test('整块 ImageTags 缺失 → 仍然按 id 请求 Primary', () {
      final u = EmbyServer.primaryImageUrl(
        assetUrl: 'http://192.168.5.29:8096',
        token: 'tok',
        id: 'abc',
        tag: null,
        tagMapPresent: false,
      );
      expect(u, contains('/Items/abc/Images/Primary'));
      expect(u, isNot(contains('tag=')));
    });

    test('有 Primary tag → 带上 tag（吃服务端缓存）', () {
      final u = EmbyServer.primaryImageUrl(
        assetUrl: 'http://h',
        token: 't',
        id: 'abc',
        tag: 'TAG123',
        tagMapPresent: true,
      );
      expect(u, contains('tag=TAG123'));
    });

    test('明确「有 ImageTags 但没有 Primary」→ 不发无谓请求', () {
      final u = EmbyServer.primaryImageUrl(
        assetUrl: 'http://h',
        token: 't',
        id: 'abc',
        tag: null,
        tagMapPresent: true,
      );
      expect(u, isNull);
    });

    test('id / 服务端地址为空时返回 null', () {
      expect(
        EmbyServer.primaryImageUrl(
          assetUrl: '',
          token: 't',
          id: 'abc',
          tag: null,
          tagMapPresent: false,
        ),
        isNull,
      );
      expect(
        EmbyServer.primaryImageUrl(
          assetUrl: 'http://h',
          token: 't',
          id: '',
          tag: null,
          tagMapPresent: false,
        ),
        isNull,
      );
    });
  });
}
