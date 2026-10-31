import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

/// 数据总结：液态玻璃风格
/// A 本地库聚合（精确） + B Playback Reporting / 活动日志（真实行为）
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.state});
  final AppState state;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// 每日观看时长：插件逐日数据优先，否则用活动日志配对时长补 30 天序列
  static List<DailyPlayback> _buildDaily(
    PlaybackReport? playback,
    ActivitySummary? activity,
  ) {
    if (playback != null && playback.daily.isNotEmpty) return playback.daily;
    final dm = activity?.dailyMinutes;
    if (dm == null || dm.isEmpty) return const [];
    final now = DateTime.now();
    return List.generate(30, (i) {
      final d = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: 29 - i));
      final k =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      return DailyPlayback(date: d, minutes: dm[k] ?? 0, plays: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 840;
    final stats = widget.state.stats;
    final playback = widget.state.playback;
    final activity = widget.state.activity;
    final items = widget.state.items;
    final top = MediaQuery.of(context).padding.top;
    final hpad = wide ? 24.0 : 14.0;

    // 常看作品：优先活动日志的条目级次数，其次 UserData.PlayCount
    // v1.7.72：库列表没有的条目先反查服务器片名（activityItemNames），
    // 仍查不到的显示「库外影片」（多半已从服务器删除），不再显示裸 Id
    final itemById = {for (final e in items) e.id: e};
    final resolvedNames = widget.state.activityItemNames;
    final topWatched = <(String, int)>[];
    if (activity != null && activity.itemPlays.isNotEmpty) {
      final entries = activity.itemPlays.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in entries.take(5)) {
        final nm =
            itemById[e.key]?.name ??
            resolvedNames[e.key] ??
            '库外影片（已删除）';
        topWatched.add((nm, e.value));
      }
    } else {
      final mostPlayed = items.where((e) => e.userPlayCount > 0).toList()
        ..sort((a, b) => b.userPlayCount.compareTo(a.userPlayCount));
      for (final e in mostPlayed.take(5)) {
        topWatched.add((e.name, e.userPlayCount));
      }
    }

    // 时段：活动日志优先，其次本地最后播放时间
    var hourBuckets = stats.hourBuckets;
    if (activity != null) {
      final ab = activity.hourBuckets;
      if (ab.fold<int>(0, (a, b) => a + b) > 0) hourBuckets = ab;
    }

    return Stack(
      children: [
        const Positioned.fill(child: _LiquidBackground()),
        Container(color: Colors.black.withOpacity(0.2)),
        ListView(
          padding: EdgeInsets.fromLTRB(hpad, top + 10, hpad, 150),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Text('数据总结', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.state.demoMode
                          ? '演示数据 · 连接 Emby 后显示真实统计'
                          : widget.state.sourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── 概览 ──
            const _SectionHead('概览 · 一屏看全局'),
            _OverviewGrid(stats: stats, playback: playback, activity: activity),
            const SizedBox(height: 10),

            // 完成率 + 最近播放 10 部
            _SectionCard(
              title: '观看完成率',
              child: _CompletionCard(
                stats: stats,
                recent: widget.state.recentPlayedItems,
              ),
            ),
            const SizedBox(height: 10),

            // 偏好演员
            _SectionCard(
              title: '偏好演员',
              badge: const _SourceBadge(text: '已看加权', ab: true),
              child: _TopPeople(people: stats.topPeople, unit: '次'),
            ),
            const SizedBox(height: 10),

            // 演员影片 Top（紧随偏好演员）
            _SectionCard(
              title: '演员影片 Top',
              badge: const _SourceBadge(text: '按参演影片数'),
              child: _TopPeople(people: stats.topCast, unit: '部'),
            ),
            const SizedBox(height: 10),

            // 标签
            _SectionCard(
              title: '标签分布',
              badge: _SourceBadge(text: '${stats.tagSource} 字段'),
              child: _TagBars(dist: stats.tagDistribution),
            ),
            const SizedBox(height: 10),
            _SectionCard(
              title: '热门标签',
              child: _TagCloud(tags: stats.tagCounts),
            ),
            const SizedBox(height: 10),

            // 画质规格：8 项双排
            _SectionCard(
              title: '画质规格构成',
              child: _QualityChips(
                res4k: stats.res4kPct,
                res1080: stats.res1080Pct,
                res720: stats.res720Pct,
                res480: stats.res480Pct,
                hdr: stats.hdrPct,
                dv: stats.dvPct,
                atmos: stats.atmosPct,
                hevc: stats.hevcPct,
              ),
            ),
            const SizedBox(height: 10),

            _SectionCard(
              title: '入库时间趋势（近 12 月）',
              child: _TrendBars(trend: stats.addedTrend),
            ),
            const SizedBox(height: 12),

            // ── 观看行为（无分区标题）──
            _SectionCard(
              title: '每日观看时长（近 30 天）',
              badge: _SourceBadge(
                text: playback != null
                    ? 'B 插件'
                    : (activity != null ? '活动日志' : '无数据'),
                ab: playback != null || activity != null,
              ),
              child: _DailyBars(
                daily: _buildDaily(playback, activity),
                playsOverride: playback?.totalPlays ?? activity?.total,
              ),
            ),
            const SizedBox(height: 10),
            _SectionCard(
              title: '播放时段统计',
              badge: _SourceBadge(text: activity != null ? '活动日志' : '本地近似'),
              child: _HourBars(buckets: hourBuckets),
            ),
            const SizedBox(height: 10),
            _SectionCard(
              title: '最常看作品 Top',
              badge: _SourceBadge(text: activity != null ? '活动日志' : '播放次数'),
              child: _TopItems(entries: topWatched),
            ),
            const SizedBox(height: 12),

            // ── 续看清单（无分区标题）──
            if (widget.state.continueWatching.isNotEmpty)
              _SectionCard(
                title: '续看未完成清单',
                child: _ContinueList(
                  items: widget.state.continueWatching.take(5).toList(),
                ),
              ),
            const SizedBox(height: 10),

            // ── 库存覆盖率 ──
            _SectionCard(
              title: '库存覆盖率',
              child: _CoverageGauge(
                rate: stats.watchCoverage,
                watched: stats.watchedCount,
                total: items.length,
              ),
            ),
            const SizedBox(height: 10),

            // ── 数据质量（最后）──
            _SectionCard(
              title: '数据质量',
              child: _QualityRow(
                missingPoster: stats.missingPoster,
                missingOverview: stats.missingOverview,
                posterTitles: stats.missingPosterTitles,
                overviewTitles: stats.missingOverviewTitles,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 来源小标签
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.text, this.ab = false});
  final String text;
  final bool ab;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: ab
            ? const LinearGradient(
                colors: [Color(0x4D4F8CFF), Color(0x407B5CFF)],
              )
            : const LinearGradient(
                colors: [Color(0x33FFFFFF), Color(0x14FFFFFF)],
              ),
        border: Border.all(color: Colors.white.withOpacity(0.20), width: 1),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFFD8E2FB),
        ),
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 2, 3, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          color: Color(0xFFD3DDF7),
        ),
      ),
    );
  }
}

/// 液态背景：流动彩色光斑
class _LiquidBackground extends StatefulWidget {
  const _LiquidBackground();

  @override
  State<_LiquidBackground> createState() => _LiquidBackgroundState();
}

class _LiquidBackgroundState extends State<_LiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  static const _blobs = [
    (
      Color(0xFF2F6BFF),
      Color(0xFF1B3FD8),
      Offset(0.05, 0.02),
      340.0,
      0.0,
      42.0,
    ),
    (
      Color(0xFF8A5CFF),
      Color(0xFF4A2BB8),
      Offset(0.95, 0.28),
      320.0,
      1.7,
      52.0,
    ),
    (
      Color(0xFF00D4C8),
      Color(0xFF0A6B8A),
      Offset(0.02, 0.62),
      300.0,
      3.6,
      46.0,
    ),
    (
      Color(0xFFFF5FA2),
      Color(0xFF7B1E6A),
      Offset(0.98, 0.85),
      280.0,
      5.1,
      60.0,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 26))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Container(
      color: AppColors.bg,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value * 2 * math.pi;
          return Stack(
            children: [
              for (final b in _blobs)
                Positioned(
                  left:
                      b.$3.dx * size.width -
                      b.$4 / 2 +
                      math.sin(t + b.$5) * b.$6,
                  top:
                      b.$3.dy * size.height -
                      b.$4 / 2 +
                      math.cos(t * 0.8 + b.$5) * b.$6 * 0.7,
                  child: Container(
                    width: b.$4,
                    height: b.$4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [b.$1.withOpacity(0.5), b.$2.withOpacity(0.0)],
                        stops: const [0.0, 1.0],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.badge});
  final String title;
  final Widget child;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Glass(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      radius: 18,
      blur: 20,
      tint: 0.08,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (badge != null) badge!,
            ],
          ),
          const SizedBox(height: 9),
          child,
        ],
      ),
    );
  }
}

/// 概览：影片 / 剧集 / 库内总时长 / 收藏
///       真实观看 / 真实播放次数 / 已看 / 完成率
class _OverviewGrid extends StatelessWidget {
  const _OverviewGrid({
    required this.stats,
    required this.playback,
    required this.activity,
  });
  final LibraryStats stats;
  final PlaybackReport? playback;
  final ActivitySummary? activity;

  static const _cardH = 58.0;

  @override
  Widget build(BuildContext context) {
    final p = playback;
    // 三级兜底：插件 → 活动日志配对时长 → 已看内容总时长
    final hours =
        p?.totalHours ??
        ((activity != null && activity!.totalMinutes > 0)
            ? activity!.totalHours
            : (stats.watchedHours > 0 ? stats.watchedHours.toDouble() : null));
    final realHours = hours == null
        ? '—'
        : '${hours.toStringAsFixed(hours >= 10 ? 0 : 1)}h';
    final fromReal =
        p != null || (activity != null && activity!.totalMinutes > 0);
    final plays = p?.totalPlays ?? activity?.total;
    final realPlays = plays == null ? '—' : '$plays';

    final rows = <List<(String, String, Color)>>[
      [
        ('影片', '${stats.movieCount}', AppColors.ink),
        ('剧集', '${stats.seriesCount}', AppColors.ink),
        ('库内总时长', '${stats.totalLibraryHours}h', AppColors.ink),
        ('收藏', '${stats.favoriteCount}', AppColors.ink),
      ],
      [
        (
          '真实观看',
          realHours,
          hours == null
              ? AppColors.muted
              : (fromReal ? AppColors.cyan : AppColors.ink),
        ),
        ('真实播放次数', realPlays, plays == null ? AppColors.muted : AppColors.cyan),
        ('已看', '${stats.watchedCount}', AppColors.ink),
        ('完成率', '${(stats.completionRate * 100).round()}%', AppColors.accent),
      ],
    ];

    return Column(
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 8),
          SizedBox(
            height: _cardH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < rows[r].length; i++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i == 3 ? 0 : 8),
                      child: Glass(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 7,
                        ),
                        radius: 15,
                        blur: 18,
                        tint: 0.08,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    rows[r][i].$2,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      color: rows[r][i].$3,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              rows[r][i].$1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 8.5,
                                color: AppColors.muted,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 完成率 + 最近播放 10 部（含完成度）
class _CompletionCard extends StatelessWidget {
  const _CompletionCard({required this.stats, required this.recent});
  final LibraryStats stats;
  final List<MediaItem> recent;

  @override
  Widget build(BuildContext context) {
    // 优先使用服务端 DatePlayed 倒序的最近播放，其次回退本地最后播放时间
    final List<(String, double)> list = recent.isNotEmpty
        ? recent
              .map(
                (e) => (e.name, e.userPlayed ? 1.0 : (e.resumeProgress ?? 0)),
              )
              .toList()
        : stats.recentPlayed
              .map((e) => (e['name'] as String, e['pct'] as double))
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              height: 72,
              width: 72,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: stats.completionRate,
                    strokeWidth: 7,
                    backgroundColor: Colors.white.withOpacity(0.1),
                    valueColor: const AlwaysStoppedAnimation(AppColors.cyan),
                  ),
                  Text(
                    '${(stats.completionRate * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '库内已看完影片占比\n按底部播放进度 / 已看标记计算',
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
        if (list.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(height: 1, color: Colors.white.withOpacity(0.07)),
          const SizedBox(height: 8),
          const Text(
            '最近播放 10 部',
            style: TextStyle(fontSize: 10, color: AppColors.muted),
          ),
          const SizedBox(height: 6),
          ...list.map((e) {
            final pct = (e.$2 * 100).round();
            final done = pct >= 90;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    done
                        ? Icons.check_circle_rounded
                        : Icons.play_circle_outline_rounded,
                    size: 12.5,
                    color: done ? AppColors.cyan : AppColors.muted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      e.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFFD2DEFA),
                      ),
                    ),
                  ),
                  Text(
                    '$pct%',
                    style: const TextStyle(fontSize: 9, color: AppColors.muted),
                  ),
                ],
              ),
            );
          }),
        ] else
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '服务端暂无播放记录',
              style: TextStyle(fontSize: 10.5, color: AppColors.muted),
            ),
          ),
      ],
    );
  }
}

/// 标签分布
class _TagBars extends StatelessWidget {
  const _TagBars({required this.dist});
  final Map<String, double> dist;

  @override
  Widget build(BuildContext context) {
    if (dist.isEmpty)
      return const Text(
        '暂无标签数据',
        style: TextStyle(fontSize: 11, color: AppColors.muted),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: dist.entries.map((e) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      e.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFD2DEFA),
                      ),
                    ),
                  ),
                  Text(
                    '${(e.value * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 9.5,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: e.value,
                  minHeight: 5,
                  backgroundColor: Colors.white.withOpacity(0.1),
                  valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _TagCloud extends StatelessWidget {
  const _TagCloud({required this.tags});
  final Map<String, int> tags;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty)
      return const Text(
        '暂无标签数据',
        style: TextStyle(fontSize: 11, color: AppColors.muted),
      );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tags.entries.map((e) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: LinearGradient(
              colors: [
                Colors.white.withOpacity(0.14),
                Colors.white.withOpacity(0.04),
              ],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.16), width: 1),
          ),
          child: Text.rich(
            TextSpan(
              text: e.key,
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xFFE3EAFF),
                fontWeight: FontWeight.w600,
              ),
              children: [
                TextSpan(
                  text: ' ${e.value}',
                  style: const TextStyle(fontSize: 9, color: AppColors.muted),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 画质规格：8 项，双排 4 列
class _QualityChips extends StatelessWidget {
  const _QualityChips({
    required this.res4k,
    required this.res1080,
    required this.res720,
    required this.res480,
    required this.hdr,
    required this.dv,
    required this.atmos,
    required this.hevc,
  });
  final double res4k, res1080, res720, res480, hdr, dv, atmos, hevc;

  @override
  Widget build(BuildContext context) {
    final chips = [
      ('4K', res4k),
      ('1080P', res1080),
      ('720P', res720),
      ('480P', res480),
      ('HDR', hdr),
      ('杜比视界', dv),
      ('全景声', atmos),
      ('HEVC', hevc),
    ];
    final rows = [chips.sublist(0, 4), chips.sublist(4, 8)];
    return Column(
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 7),
          Row(
            children: [
              for (var i = 0; i < rows[r].length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i == 3 ? 0 : 7),
                    child: Container(
                      height: 46,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withOpacity(0.12),
                            Colors.white.withOpacity(0.04),
                          ],
                        ),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.14),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${(rows[r][i].$2 * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: AppColors.ink,
                              ),
                            ),
                          ),
                          const SizedBox(height: 1),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              rows[r][i].$1,
                              style: const TextStyle(
                                fontSize: 9,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 库存覆盖率
class _CoverageGauge extends StatelessWidget {
  const _CoverageGauge({
    required this.rate,
    required this.watched,
    required this.total,
  });
  final double rate;
  final int watched;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          height: 72,
          width: 72,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: rate,
                strokeWidth: 7,
                backgroundColor: Colors.white.withOpacity(0.1),
                valueColor: const AlwaysStoppedAnimation(AppColors.secondary),
              ),
              Text(
                '${(rate * 100).round()}%',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 10.5,
                color: AppColors.muted,
                height: 1.6,
              ),
              children: [
                const TextSpan(text: '已看 '),
                TextSpan(
                  text: '$watched',
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ' / 库内 '),
                TextSpan(
                  text: '$total',
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ' 部\n还有 '),
                TextSpan(
                  text: '${total - watched} 部',
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ' 未看'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TopPeople extends StatelessWidget {
  const _TopPeople({required this.people, this.unit = '次'});
  final List<Map<String, dynamic>> people;
  final String unit;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty)
      return const Text(
        '暂无数据',
        style: TextStyle(fontSize: 11, color: AppColors.muted),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: people.map((p) {
        final w = ((p['weight'] as num?) ?? 0).toDouble();
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.ctaGradient,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.22),
                    width: 1,
                  ),
                ),
                child: Center(
                  child: Text(
                    (p['name'] as String).isNotEmpty
                        ? (p['name'] as String)[0]
                        : '?',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 84,
                child: Text(
                  p['name'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: w,
                    minHeight: 5,
                    backgroundColor: Colors.white.withOpacity(0.1),
                    valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                  ),
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  '${p['count']} $unit',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 9.5, color: AppColors.muted),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// 最常看作品 Top（活动日志条目级 / PlayCount）
class _TopItems extends StatelessWidget {
  const _TopItems({required this.entries});
  final List<(String, int)> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Text(
        '暂无播放记录（服务端未记录播放次数）',
        style: TextStyle(fontSize: 11, color: AppColors.muted),
      );
    }
    return Column(
      children: entries.map((e) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.ctaGradient,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.22),
                    width: 1,
                  ),
                ),
                child: Center(
                  child: Text(
                    e.$1.isNotEmpty ? e.$1[0] : '?',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${e.$2} 次',
                style: const TextStyle(fontSize: 9.5, color: AppColors.muted),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// 续看未完成清单
class _ContinueList extends StatelessWidget {
  const _ContinueList({required this.items});
  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: items.map((e) {
        final pct = ((e.resumeProgress ?? 0) * 100).round();
        final sub = e.seasonNumber != null
            ? 'S${e.seasonNumber}${e.episodeNumber != null ? ' · E${e.episodeNumber}' : ''}'
            : '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFC55A), Color(0xFFFF8A4C)],
                  ),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.22),
                    width: 1,
                  ),
                ),
                child: Center(
                  child: Text(
                    '$pct%',
                    style: const TextStyle(
                      fontSize: 7.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                sub,
                style: const TextStyle(fontSize: 9.5, color: AppColors.muted),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// 每日观看时长（B 插件真实数据）
class _DailyBars extends StatelessWidget {
  const _DailyBars({required this.daily, this.playsOverride});
  final List<DailyPlayback> daily;
  final int? playsOverride;

  @override
  Widget build(BuildContext context) {
    if (daily.isEmpty) {
      return const Text(
        '暂无每日观看数据（插件与活动日志均未返回）',
        style: TextStyle(fontSize: 11, color: AppColors.muted, height: 1.5),
      );
    }
    final maxMin = daily.fold<double>(
      1,
      (a, b) => b.minutes > a ? b.minutes : a,
    );
    final totalMin = daily.fold<double>(0, (a, b) => a + b.minutes);
    final totalPlays =
        playsOverride ?? daily.fold<int>(0, (a, b) => a + b.plays);
    final hours = totalMin / 60;
    final hasData = totalMin > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '合计 ${hours.toStringAsFixed(hours >= 10 ? 0 : (hours >= 1 ? 1 : 2))} 小时 · $totalPlays 次播放',
          style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: hasData
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: daily.map((d) {
                    final h = (d.minutes / maxMin) * 50;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Container(
                          height: h <= 1 ? 2 : h,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            gradient: AppColors.ctaGradient,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                )
              : Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white.withOpacity(0.04),
                  ),
                  child: const Text(
                    '近 30 天无观看时长记录',
                    style: TextStyle(fontSize: 10, color: AppColors.muted),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 播放时段统计：12 档（每 2 小时）
class _HourBars extends StatelessWidget {
  const _HourBars({required this.buckets});
  final List<int> buckets;

  static String _label(int i) {
    final s = i * 2;
    return '${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final total = buckets.fold<int>(0, (a, b) => a + b);
    if (total == 0) {
      return const Text(
        '暂无播放时段数据',
        style: TextStyle(fontSize: 11, color: AppColors.muted),
      );
    }
    final max = buckets.fold<int>(1, (a, b) => b > a ? b : a);
    final peak = buckets.indexOf(max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '共 $total 次播放 · 高峰 ${_label(peak)}:00–${(_label(peak).isEmpty ? '' : (peak * 2 + 2).toString().padLeft(2, '0'))}:00',
          style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(buckets.length, (i) {
              final h = (buckets[i] / max) * 52;
              final isPeak = i == peak;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Container(
                    height: h <= 1 ? 2 : h,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: isPeak ? AppColors.ctaGradient : null,
                      color: isPeak
                          ? null
                          : AppColors.primary.withOpacity(0.35),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: List.generate(buckets.length, (i) {
            return Expanded(
              child: Text(
                _label(i),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 7, color: AppColors.muted),
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// 入库趋势
class _TrendBars extends StatelessWidget {
  const _TrendBars({required this.trend});
  final List<double> trend;

  @override
  Widget build(BuildContext context) {
    if (trend.isEmpty)
      return const Text(
        '暂无趋势数据',
        style: TextStyle(fontSize: 11, color: AppColors.muted),
      );
    final max = trend.fold<double>(1, (a, b) => b > a ? b : a);
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '每月新增入库条目数（电影 + 剧集）',
          style: TextStyle(
            fontSize: 9.5,
            color: AppColors.muted.withOpacity(0.9),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 72,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(trend.length, (i) {
              final v = trend[i];
              final h = max == 0 ? 0.0 : (v / max) * 58;
              final m = DateTime(
                now.year,
                now.month - (trend.length - 1 - i),
              ).month;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: h <= 1 ? 2 : h,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          gradient: AppColors.ctaGradient,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$m',
                        style: const TextStyle(
                          fontSize: 7.5,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.missingPoster,
    required this.missingOverview,
    required this.posterTitles,
    required this.overviewTitles,
  });
  final int missingPoster;
  final int missingOverview;
  final List<String> posterTitles;
  final List<String> overviewTitles;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _stat('缺海报', missingPoster),
            const SizedBox(width: 14),
            _stat('缺简介', missingOverview),
          ],
        ),
        if (posterTitles.isNotEmpty) ...[
          const SizedBox(height: 9),
          const Text(
            '缺海报',
            style: TextStyle(fontSize: 9.5, color: AppColors.muted),
          ),
          const SizedBox(height: 4),
          ...posterTitles.map(_title),
        ],
        if (overviewTitles.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            '缺简介',
            style: TextStyle(fontSize: 9.5, color: AppColors.muted),
          ),
          const SizedBox(height: 4),
          ...overviewTitles.map(_title),
        ],
      ],
    );
  }

  Widget _stat(String label, int count) {
    final ok = count == 0;
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle_rounded : Icons.warning_rounded,
          size: 14,
          color: ok ? AppColors.cyan : AppColors.warn,
        ),
        const SizedBox(width: 5),
        Text(
          '$label $count 部',
          style: const TextStyle(fontSize: 10.5, color: Color(0xFFD2DEFA)),
        ),
      ],
    );
  }

  Widget _title(String name) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 3,
            decoration: const BoxDecoration(
              color: AppColors.muted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Color(0xFFC3D3EE)),
            ),
          ),
        ],
      ),
    );
  }
}
