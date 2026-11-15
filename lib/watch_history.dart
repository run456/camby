import 'dart:math' as math;

/// v2.0.86：观影日历的数据层。
///
/// 以前统计页只有「按日聚合的分钟数」，能画柱状图，但回答不了
/// 「10 月我看了什么」—— 因为一次观看从来没有被存成一条带日期的事件。
/// 这里把观看记录统一成 [WatchEvent]，并用 [WatchCalendar] 做月历聚合。
///
/// 刻意不 import models.dart：models.dart 里的 ActivitySummary 要引用
/// WatchEvent，避免循环依赖，本文件只依赖 dart:math。

/// 事件来源。UI 上必须标出来，因为「估算」和「精确」不能混为一谈。
enum WatchSource { local, activity, imported }

String watchSourceLabel(WatchSource s) => switch (s) {
  WatchSource.local => '本机记录',
  WatchSource.activity => '活动日志',
  WatchSource.imported => '历史估算',
};

/// 海报墙角标用的紧凑时长文案（v2.0.101）。
///
/// 0 / 负数 / 非有限值都表示「有记录但推算不出时长」，返回空串让角标不出现，
/// 不写「0 分钟」这种假信息。历史回填是按片长估的，加 `~` 前缀和日历脚注
/// 「时长仅供参考」的口径保持一致。
String formatWatchMinutes(double minutes, {bool estimated = false}) {
  if (minutes <= 0 || !minutes.isFinite) return '';
  final m = minutes.round();
  final h = m ~/ 60;
  final mm = m % 60;
  final label = m < 60 ? '$m 分钟' : (mm == 0 ? '$h 小时' : '$h 小时 $mm 分');
  return estimated ? '~$label' : label;
}

/// 按月按片聚合观看时长（v2.0.101，海报墙角标用）。
///
/// 必须在**完整月事件**上算：海报墙只取前 6 张，但同一部片这个月可能看了
/// 好几次，只取海报对应的那一条会把后面的都漏掉。只要有一次是历史估算，
/// 整部片的时长就标成估算，不把「精确」和「按片长估的」混成一个数。
({Map<String, double> minutes, Map<String, bool> estimated})
    aggregateMonthWatchMinutes(List<WatchEvent> events, String monthPrefix) {
  final minutes = <String, double>{};
  final estimated = <String, bool>{};
  for (final e in events) {
    if (!e.date.startsWith(monthPrefix)) continue;
    minutes[e.itemId] = (minutes[e.itemId] ?? 0) + e.minutes;
    estimated[e.itemId] = (estimated[e.itemId] ?? false) || e.isEstimated;
  }
  return (minutes: minutes, estimated: estimated);
}

/// 一次观看 = 一条事件。
class WatchEvent {
  const WatchEvent({
    required this.itemId,
    required this.name,
    required this.date,
    this.minutes = 0,
    this.startAt,
    this.progress = 0,
    this.source = WatchSource.local,
    this.isEpisode = false,
    this.posterUrl,
    this.serverId,
  });

  final String itemId;
  final String name;

  /// yyyy-MM-dd（本地日期，跨时区不做换算）
  final String date;

  /// 本次观看分钟数；0 表示「有记录但无法推算时长」
  final double minutes;

  /// 起播时刻（用于深夜徽章与单日排序）
  final DateTime? startAt;

  /// 本次结束时的观看进度 0..1
  final double progress;
  final WatchSource source;
  final bool isEpisode;
  final String? posterUrl;

  /// v2.0.99：归属的服务器 profile id（null = 演示模式 / 升级前的老记录）。
  ///
  /// 以前没有这个字段，A 服务器的本机记录在切到 B 之后仍会出现在日历里 ——
  /// 因为所有服务器的事件共用一份 watch_events_json，取数时又不过滤。
  final String? serverId;

  DateTime get day {
    final p = date.split('-');
    if (p.length != 3) return DateTime(1970);
    return DateTime(
      int.tryParse(p[0]) ?? 1970,
      int.tryParse(p[1]) ?? 1,
      int.tryParse(p[2]) ?? 1,
    );
  }

  bool get isEstimated => source == WatchSource.imported;

  String get progressLabel {
    if (minutes <= 0 && progress <= 0) return '看过';
    if (progress >= 0.97) return '已看完';
    final pct = (progress * 100).round();
    return pct > 0 ? '看到 $pct%' : '看了 ${minutes.round()} 分钟';
  }

  WatchEvent copyWith({
    String? name,
    String? posterUrl,
    double? minutes,
    double? progress,
    WatchSource? source,
    bool? isEpisode,
    String? serverId,
  }) => WatchEvent(
    itemId: itemId,
    name: name ?? this.name,
    date: date,
    minutes: minutes ?? this.minutes,
    startAt: startAt,
    progress: progress ?? this.progress,
    source: source ?? this.source,
    isEpisode: isEpisode ?? this.isEpisode,
    posterUrl: posterUrl ?? this.posterUrl,
    serverId: serverId ?? this.serverId,
  );

  Map<String, dynamic> toJson() => {
    'id': itemId,
    'n': name,
    'd': date,
    'm': minutes,
    't': startAt?.millisecondsSinceEpoch,
    'p': progress,
    's': source.index,
    'e': isEpisode,
    'u': posterUrl,
    if (serverId != null) 'sid': serverId,
  };

  factory WatchEvent.fromJson(Map<String, dynamic> j) => WatchEvent(
    itemId: (j['id'] ?? '').toString(),
    name: (j['n'] ?? '').toString(),
    date: (j['d'] ?? '').toString(),
    minutes: (j['m'] as num?)?.toDouble() ?? 0,
    startAt: j['t'] is int
        ? DateTime.fromMillisecondsSinceEpoch(j['t'] as int)
        : null,
    progress: ((j['p'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0).toDouble(),
    source: _safeSource(j['s']),
    isEpisode: j['e'] == true,
    posterUrl: j['u'] as String?,
    serverId: j['sid'] as String?,
  );
}

/// 老缓存 / 手工数据里的下标可能越界，绝不让一条脏数据把整页日历打崩。
WatchSource _safeSource(dynamic v) {
  final i = (v as num?)?.toInt() ?? 0;
  return (i >= 0 && i < WatchSource.values.length)
      ? WatchSource.values[i]
      : WatchSource.local;
}

/// yyyy-MM-dd
String watchDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

bool isWatchDayKey(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);

/// 播放器进度 tick（100ns）与本地会话推算观看分钟数。
///
/// 优先级：
///  1. [watchedSeconds]：播放器侧实测的「本次播放中位置向前推进的秒数」，
///     天然扣掉暂停、缓冲、拖动与续播定位 —— 最准（v2.0.96 起由播放页累加）；
///  2. 「结束位置 − 起播位置」的 tick 差：扣掉了暂停，但**续播/拖动会虚高**
///     （从 12:00 续播只看 1 分钟，旧算法会记成 12 分钟）；
///  3. 墙钟时长兜底。
///
/// 第 2 条另有**墙钟封顶**（+1 分钟抖动）：真实观看不可能超过「进了播放页
/// 到退出」的时长很多，超过就说明中间有大跳变，按墙钟计。
double resolveWatchMinutes({
  required int positionTicks,
  required int startTicks,
  required int elapsedMinutes,
  required int runtimeMinutes,
  double? watchedSeconds,
}) {
  if (watchedSeconds != null && watchedSeconds > 0.5) {
    var m = watchedSeconds / 60.0;
    if (runtimeMinutes > 0 && m > runtimeMinutes)
      return runtimeMinutes.toDouble();
    return m;
  }
  final advanced = (positionTicks - startTicks) / 10000000.0 / 60.0;
  var m = advanced > 0.5 ? advanced : elapsedMinutes.toDouble();
  if (elapsedMinutes > 0) {
    final cap = elapsedMinutes + 1.0;
    if (m > cap) m = cap;
  }
  if (m < 0) m = 0;
  if (runtimeMinutes > 0 && m > runtimeMinutes) m = runtimeMinutes.toDouble();
  return m;
}

/// 由结束位置与片长推算观看进度（0..1）。
double resolveWatchProgress(int positionTicks, int runtimeMinutes) {
  if (runtimeMinutes <= 0 || positionTicks <= 0) return 0;
  final total = runtimeMinutes * 60 * 10000000.0;
  return (positionTicks / total).clamp(0.0, 1.0).toDouble();
}

/// 升级迁移：把没有服务器归属的老事件归给 [serverId]。
///
/// v2.0.98 及以前没有 serverId 字段，老事件无法追溯原始归属；
/// 归给当前服务器虽然不完美，但好过继续让 A 的记录出现在 B 的日历里。
List<WatchEvent> assignServerToOrphans(
  Iterable<WatchEvent> events,
  String? serverId,
) {
  if (serverId == null || serverId.isEmpty) return events.toList();
  return events
      .map((e) => e.serverId == null ? e.copyWith(serverId: serverId) : e)
      .toList();
}

/// 去重口径：同一台服务器、同一天、同一部片只算一次。
/// v2.0.99 加上服务器前缀 —— 以前 A/B 两台服务器的同片同日记录会互相吞掉。
String watchEventKey(WatchEvent e) =>
    '${e.serverId ?? ''}|${e.date}|${e.itemId}';

/// 本地精确事件 + 活动日志明细合并去重。
///
/// 同一天同一部片看多次是合法的（会留下多条），这里只去掉「本机已记过、
/// 活动日志又记了一遍」的重复；本地数据优先，因为它的进度最准。
List<WatchEvent> mergeWatchEvents({
  required List<WatchEvent> local,
  required List<WatchEvent> activity,
  Map<String, String> names = const {},
}) {
  final out = <WatchEvent>[...local];
  final seen = <String>{for (final e in local) watchEventKey(e)};
  for (final e in activity) {
    final k = watchEventKey(e);
    if (seen.contains(k)) continue;
    seen.add(k);
    final nm = e.name.isNotEmpty ? e.name : (names[e.itemId] ?? '库外影片');
    out.add(e.name == nm ? e : e.copyWith(name: nm));
  }
  out.sort((a, b) {
    final c = b.date.compareTo(a.date);
    if (c != 0) return c;
    return (b.startAt?.millisecondsSinceEpoch ?? 0).compareTo(
      a.startAt?.millisecondsSinceEpoch ?? 0,
    );
  });
  return out;
}

/// 历史回填的输入种子：只带最少字段，避免把 MediaItem 拖进纯数据层。
class HistorySeed {
  const HistorySeed({
    required this.id,
    required this.name,
    required this.when,
    required this.minutes,
    this.isEpisode = false,
    this.posterUrl,
    this.serverId,
  });

  final String id;
  final String name;
  final DateTime when;
  final double minutes;
  final bool isEpisode;
  final String? posterUrl;
  final String? serverId;
}

/// 最近 [days] 天的已看历史 → 估算事件。
///
/// 服务器只给「最后一次播放时间」和「是否已看」，没有逐次记录，所以
/// 一条历史只能生成一条事件，时长按片长估算，并统一标成 imported。
const int kWatchBackfillDays = 365;

List<WatchEvent> eventsFromHistory(
  Iterable<HistorySeed> seeds, {
  DateTime? now,
  int days = kWatchBackfillDays,
}) {
  final anchor = now ?? DateTime.now();
  final cutoff = anchor.subtract(Duration(days: days));
  final out = <WatchEvent>[];
  for (final s in seeds) {
    if (s.when.isAfter(anchor) || s.when.isBefore(cutoff)) continue;
    if (s.id.isEmpty) continue;
    out.add(
      WatchEvent(
        itemId: s.id,
        name: s.name,
        date: watchDayKey(s.when),
        minutes: s.minutes,
        startAt: s.when,
        progress: 1,
        source: WatchSource.imported,
        isEpisode: s.isEpisode,
        posterUrl: s.posterUrl,
        serverId: s.serverId,
      ),
    );
  }
  return out;
}

/// 月度徽章。只做「能从现有数据算出来」的，不引入服务器排播信息。
enum MonthBadge { none, kickoff, streak, marathon, explorer, nightOwl }

String monthBadgeLabel(MonthBadge b, {int streak = 0}) => switch (b) {
  MonthBadge.none => '本月还没开张',
  MonthBadge.kickoff => '本月开张',
  MonthBadge.streak => '连续 $streak 天',
  MonthBadge.marathon => '单日马拉松',
  MonthBadge.explorer => '阅片达人',
  MonthBadge.nightOwl => '深夜场常客',
};

String monthBadgeIcon(MonthBadge b) => switch (b) {
  MonthBadge.none => '○',
  MonthBadge.kickoff => '◈',
  MonthBadge.streak => '✦',
  MonthBadge.marathon => '◆',
  MonthBadge.explorer => '★',
  MonthBadge.nightOwl => '☾',
};

class MonthSummary {
  const MonthSummary({
    required this.year,
    required this.month,
    required this.minutes,
    required this.activeDays,
    required this.movies,
    required this.episodes,
    required this.titles,
    required this.bestStreak,
    required this.badge,
    required this.topDayMinutes,
    this.topDay,
  });

  final int year;
  final int month;
  final double minutes;
  final int activeDays;
  final int movies;
  final int episodes;

  /// 去重后的作品数
  final int titles;
  final int bestStreak;
  final MonthBadge badge;
  final double topDayMinutes;
  final DateTime? topDay;

  double get hours => minutes / 60;
  bool get isEmpty => activeDays == 0;
}

/// 月历索引：按日分组，供日历格子、单日明细、月度概览共用一份计算结果。
class WatchCalendar {
  WatchCalendar(Iterable<WatchEvent> events) {
    for (final e in events) {
      if (!isWatchDayKey(e.date)) continue;
      _byDay.putIfAbsent(e.date, () => <WatchEvent>[]).add(e);
    }
    for (final list in _byDay.values) {
      list.sort(
        (a, b) => (b.startAt?.millisecondsSinceEpoch ?? 0).compareTo(
          a.startAt?.millisecondsSinceEpoch ?? 0,
        ),
      );
    }
  }

  final Map<String, List<WatchEvent>> _byDay = <String, List<WatchEvent>>{};

  List<WatchEvent> eventsOn(DateTime day) =>
      List<WatchEvent>.unmodifiable(_byDay[watchDayKey(day)] ?? const []);

  double minutesOn(DateTime day) => (_byDay[watchDayKey(day)] ?? const [])
      .fold<double>(0, (a, e) => a + e.minutes);

  int countOn(DateTime day) => (_byDay[watchDayKey(day)] ?? const []).length;

  bool get isEmpty => _byDay.isEmpty;

  /// 有记录的最早 / 最晚日期，用于「翻月」按钮的可用范围提示。
  DateTime? get firstDay =>
      _byDay.keys.isEmpty ? null : (_byDay.keys.toList()..sort()).first.dayOf();
  DateTime? get lastDay =>
      _byDay.keys.isEmpty ? null : (_byDay.keys.toList()..sort()).last.dayOf();

  MonthSummary month(int year, int month) {
    final prefix =
        '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}-';
    final evs = <WatchEvent>[];
    _byDay.forEach((k, v) {
      if (k.startsWith(prefix)) evs.addAll(v);
    });

    double mins = 0;
    var movies = 0;
    var episodes = 0;
    var nights = 0;
    final titles = <String>{};
    final active = <int>{};
    final perDay = <int, double>{};
    for (final e in evs) {
      mins += e.minutes;
      titles.add(e.itemId);
      if (e.isEpisode) {
        episodes++;
      } else {
        movies++;
      }
      final d = int.tryParse(e.date.substring(8)) ?? 0;
      active.add(d);
      perDay[d] = (perDay[d] ?? 0) + e.minutes;
      if (e.startAt != null && e.startAt!.hour >= 22) nights++;
    }

    var streak = 0;
    var best = 0;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    for (var d = 1; d <= daysInMonth; d++) {
      if (active.contains(d)) {
        streak++;
        best = math.max(best, streak);
      } else {
        streak = 0;
      }
    }

    var topMinutes = 0.0;
    DateTime? topDay;
    perDay.forEach((d, m) {
      if (m > topMinutes) {
        topMinutes = m;
        topDay = DateTime(year, month, d);
      }
    });

    final badge = evs.isEmpty
        ? MonthBadge.none
        : best >= 7
        ? MonthBadge.streak
        : topMinutes >= 180
        ? MonthBadge.marathon
        : titles.length >= 10
        ? MonthBadge.explorer
        : nights >= 3
        ? MonthBadge.nightOwl
        : MonthBadge.kickoff;

    return MonthSummary(
      year: year,
      month: month,
      minutes: mins,
      activeDays: active.length,
      movies: movies,
      episodes: episodes,
      titles: titles.length,
      bestStreak: best,
      badge: badge,
      topDayMinutes: topMinutes,
      topDay: topDay,
    );
  }
}

extension _DayKeyX on String {
  DateTime dayOf() {
    final p = split('-');
    return DateTime(
      int.tryParse(p[0]) ?? 1970,
      p.length > 1 ? int.tryParse(p[1]) ?? 1 : 1,
      p.length > 2 ? int.tryParse(p[2]) ?? 1 : 1,
    );
  }
}
