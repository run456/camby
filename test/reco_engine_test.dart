import 'dart:math';
import 'dart:ui' show Color;

import 'package:camby/models.dart';
import 'package:camby/reco.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首页「每日推荐」算法回归：权重、排除、多样性、种子稳定性
void main() {
  MediaItem mk(
    String id, {
    double rating = 7.0,
    String genre = '剧情',
    bool played = false,
    double? progress,
    int addedDaysAgo = 200,
    bool fav = false,
    int height = 1080,
    bool hdr = false,
    String? seriesId,
    int year = 2020,
  }) {
    return MediaItem(
      id: id,
      name: '片$id',
      overview: '',
      colors: const [Color(0xFF101820), Color(0xFF203040)],
      type: MediaType.movie,
      rating: rating,
      genres: [genre],
      year: year,
      videoHeight: height,
      isHdr: hdr,
      userPlayed: played,
      resumeProgress: progress,
      addedDaysAgo: addedDaysAgo,
      userFavorite: fav,
      seriesId: seriesId,
    );
  }

  List<MediaItem> library(int n, {String genre = '剧情'}) =>
      List.generate(n, (i) => mk('m$i', genre: genre, rating: 6.0 + i % 4));

  group('种子', () {
    final day1 = DateTime(2026, 10, 30, 9);
    final day1Later = DateTime(2026, 10, 30, 23, 59);
    final day2 = DateTime(2026, 10, 31, 0, 1);

    test('同一天内任何时刻种子相同', () {
      expect(
        RecoEngine.activeSeed(day1, 3),
        RecoEngine.activeSeed(day1Later, 3),
      );
    });

    test('跨天种子必定不同', () {
      expect(
        RecoEngine.activeSeed(day1, 3),
        isNot(RecoEngine.activeSeed(day2, 3)),
      );
    });

    test('手动换一批只动后 5 位，不破坏当天基数', () {
      final a = RecoEngine.activeSeed(day1, 0);
      final b = RecoEngine.activeSeed(day1, 1);
      expect(b - a, 1);
      expect(b ~/ 100000, a ~/ 100000);
    });
  });

  group('已看完判定', () {
    test('Emby 标 Played 算看完', () {
      expect(RecoEngine.isFinished(mk('a', played: true)), isTrue);
    });
    test('进度 90% 以上算看完', () {
      expect(RecoEngine.isFinished(mk('a', progress: 0.95)), isTrue);
    });
    test('看到一半不算', () {
      expect(RecoEngine.isFinished(mk('a', progress: 0.5)), isFalse);
    });
  });

  group('权重', () {
    test('4K/HDR 比同条件 1080p 高', () {
      final rnd1 = _FixedRandom(0.5);
      final rnd2 = _FixedRandom(0.5);
      final sd = RecoEngine.weight(mk('a', height: 1080), rnd1);
      final uhd = RecoEngine.weight(
        mk('a', height: 2160, hdr: true),
        rnd2,
      );
      expect(uhd, greaterThan(sd));
    });

    test('收藏加权、已看完降权', () {
      final base = RecoEngine.weight(mk('a'), _FixedRandom(0.5));
      final fav = RecoEngine.weight(mk('a', fav: true), _FixedRandom(0.5));
      final done = RecoEngine.weight(mk('a', played: true), _FixedRandom(0.5));
      expect(fav, greaterThan(base));
      expect(done, lessThan(base));
    });
  });

  group('挑选', () {
    test('已看完不进候选', () {
      final src = [
        for (var i = 0; i < 40; i++) mk('m$i', played: i < 20),
      ];
      final got = RecoEngine.pick(src, recent: const {}, seed: 1);
      expect(got.length, 6);
      expect(got.any((e) => e.userPlayed), isFalse);
    });

    test('最近已推的 30 条被排除', () {
      final src = library(60);
      final recent = <String, int>{
        for (var i = 0; i < 30; i++) 'm$i': 1000 + i,
      };
      final got = RecoEngine.pick(src, recent: recent, seed: 7);
      expect(got.length, 6);
      for (final e in got) {
        expect(recent.containsKey(e.id), isFalse, reason: '${e.id} 不该再出现');
      }
    });

    test('同种子结果完全一致（重启可复现）', () {
      final src = library(50);
      final a = RecoEngine.pick(src, recent: const {}, seed: 12345);
      final b = RecoEngine.pick(src, recent: const {}, seed: 12345);
      expect(a.map((e) => e.id).toList(), b.map((e) => e.id).toList());
    });

    test('换种子后至少换掉一半', () {
      final src = library(50);
      final a = RecoEngine.pick(src, recent: const {}, seed: 100).map((e) => e.id);
      final b = RecoEngine.pick(src, recent: const {}, seed: 101).map((e) => e.id);
      final overlap = a.toSet().intersection(b.toSet()).length;
      expect(overlap, lessThanOrEqualTo(3), reason: '换一批应整批不同');
    });

    test('全库单一类型时靠补位凑满 6 部', () {
      final src = List.generate(40, (i) => mk('m$i', genre: '剧情', rating: 9.9));
      final got = RecoEngine.pick(src, recent: const {}, seed: 42);
      expect(got.length, 6);
    });

    test('多类型混合时各类不超过 2 部', () {
      final src = <MediaItem>[
        for (var i = 0; i < 10; i++) mk('a$i', genre: '动作', rating: 9.9),
        for (var i = 0; i < 10; i++) mk('b$i', genre: '剧情', rating: 8.0),
        for (var i = 0; i < 10; i++) mk('c$i', genre: '喜剧', rating: 7.0),
      ];
      final got = RecoEngine.pick(src, recent: const {}, seed: 5);
      final count = <String, int>{};
      for (final e in got) {
        count[e.genres.first] = (count[e.genres.first] ?? 0) + 1;
      }
      expect(count.values.every((v) => v <= 2), isTrue, reason: '$count');
    });

    test('同系列只留一部', () {
      final src = <MediaItem>[
        for (var i = 0; i < 6; i++)
          mk('s$i', seriesId: 'series-X', rating: 9.9),
        for (var i = 0; i < 20; i++) mk('n$i', rating: 6.0),
      ];
      final got = RecoEngine.pick(src, recent: const {}, seed: 3);
      final seriesCount = got.where((e) => e.seriesId == 'series-X').length;
      expect(seriesCount, lessThanOrEqualTo(1));
    });

    test('片库不足 6 部时全给', () {
      final src = library(4);
      final got = RecoEngine.pick(src, recent: const {}, seed: 1);
      expect(got.length, 4);
    });

    test('空库不崩', () {
      expect(RecoEngine.pick(const [], recent: const {}, seed: 1), isEmpty);
    });

    test('冷启动可复现：先记旧批再换种子，重算能还原同一批', () {
      final src = library(50);
      // 第一轮
      final first = RecoEngine.pick(src, recent: const {}, seed: 10);
      // 换一批：旧批进 recent，种子 +1
      final recent = <String, int>{for (final e in first) e.id: 1};
      final second = RecoEngine.pick(src, recent: recent, seed: 11);
      // 模拟重启：同一份 recent + 同一 seed 重算 → 必须一模一样
      final again = RecoEngine.pick(
        src,
        recent: Map<String, int>.from(recent),
        seed: 11,
      );
      expect(
        second.map((e) => e.id).toList(),
        again.map((e) => e.id).toList(),
      );
      // 且第二批与第一批完全不重叠
      expect(
        first.map((e) => e.id).toSet()
            .intersection(second.map((e) => e.id).toSet()),
        isEmpty,
      );
    });
  });
  _tasteTests();
}

/// 固定返回值的 Random，用来消掉权重里的抖动，只比较确定性部分
class _FixedRandom implements Random {
  _FixedRandom(this.v);
  final double v;

  @override
  double nextDouble() => v;

  @override
  int nextInt(int max) => (v * max).floor().clamp(0, max - 1);

  @override
  bool nextBool() => v >= 0.5;
}

// ---------------------------------------------------------------------------
// v1.7.41 追加：设置页「推荐」分栏的口味开关
// ---------------------------------------------------------------------------
void _tasteTests() {
  MediaItem mk(String id, {bool played = false, double rating = 7.0}) =>
      MediaItem(
        id: id,
        name: id,
        overview: '',
        colors: const [Color(0xFF101820), Color(0xFF203040)],
        type: MediaType.movie,
        rating: rating,
        genres: const ['剧情'],
        userPlayed: played,
      );

  group('推荐口味开关', () {
    test('关掉「排除已看完」后已看完的也能进推荐', () {
      final src = [
        for (var i = 0; i < 20; i++) mk('d$i', played: true, rating: 9.9),
        for (var i = 0; i < 6; i++) mk('u$i', rating: 3.0),
      ];
      final got = RecoEngine.pick(
        src,
        recent: const {},
        seed: 1,
        excludeFinished: false,
      );
      expect(got.any((e) => e.userPlayed), isTrue);
      expect(got.length, 6);
    });

    test('关掉时仍默认排除时已看完一个不进', () {
      final src = [
        for (var i = 0; i < 20; i++) mk('d$i', played: true, rating: 9.9),
        for (var i = 0; i < 20; i++) mk('u$i', rating: 5.0),
      ];
      final got = RecoEngine.pick(src, recent: const {}, seed: 1);
      expect(got.any((e) => e.userPlayed), isFalse);
    });

    test('关掉「优先没看过」后同分同条件下权重靠评分决定', () {
      final a = RecoEngine.weight(
        mk('a', played: true, rating: 8.0),
        _FixedRandom(0.5),
        preferFresh: false,
      );
      final b = RecoEngine.weight(
        mk('b', played: false, rating: 8.0),
        _FixedRandom(0.5),
        preferFresh: false,
      );
      expect(a, b, reason: '关掉后看没看过不再加分');
    });
  });
}
