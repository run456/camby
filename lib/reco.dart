import 'dart:math' as math;

import 'models.dart';

/// 首页「每日推荐」的算法内核。
///
/// 抽成纯函数是为了能被单测覆盖：页面只负责种子、持久化与动画，
/// 「谁该上首页」这件事全部在这里决定，改权重不必碰 UI。
///
/// 规则（与 v1.7.30 定稿一致）：
/// 1. 候选池 = 全库，排除已看完（Emby Played 或本地进度 ≥ 90%）
/// 2. 权重 = 评分/10×3 + 没看过 2 + 30 天内新增 1.5 + 4K/HDR/DV 0.5
///          + 已收藏 0.5 + 随机抖动 ±0.8
/// 3. 排除最近已推的 30 条，避免「换一批」换回旧片
/// 4. 多样性：同系列只留一部，同主类型一批最多 2 部
class RecoEngine {
  const RecoEngine._();

  /// 一轮推荐的条目数（= 首页顶部 PageView 的页数）
  static const int count = 6;

  /// 「最近已推」保留条数
  static const int recentLimit = 30;

  /// 同主类型在一批里最多出现的次数
  static const int genreCap = 2;

  /// 本轮随机种子 = 日期基数 + 手动偏移。
  ///
  /// 天数从 2025-01-01 起算，乘 100000 后与手动 seed 相加 ——
  /// 于是「同一天同一批」稳定、「跨天自动换」、「点一次换一批只动后 5 位」。
  static int activeSeed(DateTime now, int manualSeed) {
    final today = DateTime(now.year, now.month, now.day);
    final day = today.difference(DateTime(2025, 1, 1)).inDays;
    return day * 100000 + manualSeed;
  }

  /// 是否算「已看完」：服务端标了 Played，或本地进度到 90% 以上
  static bool isFinished(MediaItem i) =>
      i.userPlayed || (i.resumeProgress ?? 0) >= 0.9;

  /// 单条目的推荐权重（量纲对齐 0~3 分）
  static double weight(MediaItem i, math.Random rnd) {
    // 无评分的老片按 5 分中性处理，避免 0/10 让它永远垫底
    final rating = i.rating > 0 ? i.rating : 5.0;
    var w = rating / 10.0 * 3.0;
    if (!isFinished(i)) w += 2.0;
    if (i.addedDaysAgo < 30) w += 1.5;
    if (i.isTrue4K || i.isHdr || i.hasDolbyVision) w += 0.5;
    if (i.userFavorite) w += 0.5;
    w += (rnd.nextDouble() - 0.5) * 1.6; // ±0.8
    return w;
  }

  /// 挑一轮推荐。
  ///
  /// [recent] 是「最近已推」{id: 时间戳}，[seed] 用 [activeSeed] 算出的种子。
  /// 候选不够时逐级放宽：先放回已推、再放回已看完，保证首页不空。
  static List<MediaItem> pick(
    List<MediaItem> source, {
    required Map<String, int> recent,
    required int seed,
    int take = count,
  }) {
    if (source.isEmpty) return const <MediaItem>[];

    final recentSorted = recent.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final excluded =
        recentSorted.take(recentLimit).map((e) => e.key).toSet();

    final unplayed = source.where((i) => !isFinished(i)).toList();
    final fresh = unplayed.where((i) => !excluded.contains(i.id)).toList();

    List<MediaItem> pool;
    if (fresh.length >= take) {
      pool = fresh;
    } else if (unplayed.length >= take) {
      pool = unplayed; // 片库偏小：允许重复推旧片，但不能推已看完
    } else {
      pool = source.toList(); // 极小片库：连已看完的也放回来
    }

    final rnd = math.Random(seed);
    final scored = pool
        .map((i) => MapEntry<MediaItem, double>(i, weight(i, rnd)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return dedupe(scored.map((e) => e.key).toList(), take);
  }

  /// 多样性约束：同系列（剧集/续集）只留一部，同主类型一批最多 [genreCap] 部。
  /// [ordered] 需按权重从高到低传入，方法按此顺序保序挑选。
  static List<MediaItem> dedupe(List<MediaItem> ordered, [int take = count]) {
    final seenSeries = <String>{};
    final genreCount = <String, int>{};
    final out = <MediaItem>[];
    final skipped = <MediaItem>[];
    for (final i in ordered) {
      if (out.length >= take) break;
      final sKey = i.seriesId ?? i.id;
      if (seenSeries.contains(sKey)) {
        skipped.add(i);
        continue;
      }
      final g = i.genres.isNotEmpty ? i.genres.first : '';
      final used = genreCount[g] ?? 0;
      if (g.isNotEmpty && used >= genreCap) {
        skipped.add(i);
        continue;
      }
      seenSeries.add(sKey);
      genreCount[g] = used + 1;
      out.add(i);
    }
    // 类型配额卡住导致凑不满时，用被跳过的条目补位（仍按权重序）。
    // 但「同系列只留一部」不放宽：一个系列霸屏比少两张更难看。
    for (final i in skipped) {
      if (out.length >= take) break;
      if (out.any((e) => e.id == i.id)) continue;
      final sKey = i.seriesId ?? i.id;
      if (seenSeries.contains(sKey)) continue;
      seenSeries.add(sKey);
      out.add(i);
    }
    return out;
  }
}
