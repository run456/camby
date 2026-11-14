import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../layout.dart';
import '../theme.dart';
import '../watch_history.dart';
import '../widgets/cached_image.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_toast.dart';
import '../widgets/haptics.dart';
import '../widgets/liquid_press.dart';

/// 统计页的两个视图。v2.0.86 用户确认：默认落「日历」，底部导航一个像素不动。
enum StatsMode { calendar, insight }

/// 与 `LibraryIndexSegment` 同款的低干扰双分段，日历页与洞察页共用。
class StatsModeSegment extends StatelessWidget {
  const StatsModeSegment({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final StatsMode mode;
  final ValueChanged<StatsMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        children: [
          for (final m in StatsMode.values) Expanded(child: _item(m)),
        ],
      ),
    );
  }

  Widget _item(StatsMode m) {
    final on = m == mode;
    return LiquidPress(
      radius: 999,
      scale: 0.96,
      onTap: () {
        AppHaptics.light();
        onChanged(m);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: on
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x38FFFFFF), Color(0x14FFFFFF)],
                )
              : null,
          border: Border.all(
            color: on ? Colors.white.withOpacity(0.26) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              m == StatsMode.calendar
                  ? Icons.calendar_month_outlined
                  : Icons.insights_outlined,
              size: 13,
              color: on ? Colors.white : Colors.white.withOpacity(0.55),
            ),
            const SizedBox(width: 5),
            Text(
              m == StatsMode.calendar ? '观影日历' : '数据洞察',
              style: TextStyle(
                fontSize: 12,
                fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                color: on ? Colors.white : Colors.white.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 观影日历：把「按日聚合的分钟数」升级成「那天看了什么、看到哪里」。
class WatchCalendarView extends StatefulWidget {
  const WatchCalendarView({
    super.key,
    required this.state,
    required this.onModeChanged,
  });

  final AppState state;
  final ValueChanged<StatsMode> onModeChanged;

  @override
  State<WatchCalendarView> createState() => _WatchCalendarViewState();
}

class _WatchCalendarViewState extends State<WatchCalendarView> {
  late DateTime _month;
  DateTime? _selected;
  bool _busy = false;
  final GlobalKey _shareKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month, 1);
    _selected = DateTime(now.year, now.month, now.day);
  }

  void _shiftMonth(int delta) {
    AppHaptics.light();
    setState(() {
      _month = DateTime(_month.year, _month.month + delta, 1);
      _selected = null;
    });
  }

  void _goThisMonth() {
    final now = DateTime.now();
    setState(() {
      _month = DateTime(now.year, now.month, 1);
      _selected = DateTime(now.year, now.month, now.day);
    });
  }

  Future<void> _backfill() async {
    if (_busy) return;
    setState(() => _busy = true);
    final n = await widget.state.backfillWatchHistory();
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(
      context,
      n > 0 ? '已回填 $n 条历史观看（按片长估算）' : '没有可回填的历史观看记录',
    );
  }

  /// 把「本月海报墙」这张已经挂在屏幕上的卡片直接截成 PNG 分享。
  /// 分享按钮就在卡片里，所以点得到时它必然已经绘制过，不会出现空白图。
  Future<void> _sharePosterWall(MonthSummary sum) async {
    try {
      final obj = _shareKey.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) {
        showToast(context, '月报卡片还没准备好，稍后再试');
        return;
      }
      final image = await obj.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        showToast(context, '月报生成失败');
        return;
      }
      final bytes = data.buffer.asUint8List();
      final name = 'camby-${sum.year}-${sum.month.toString().padLeft(2, '0')}-月报.png';
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(bytes, name: name, mimeType: 'image/png'),
          ],
          subject: '${sum.year} 年 ${sum.month} 月 · 我的观影月报',
        ),
      );
    } catch (e) {
      if (mounted) showToast(context, '分享失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = context.isTablet;
    final top = MediaQuery.of(context).padding.top;
    final hpad = wide ? 24.0 : 14.0;
    final events = widget.state.watchEvents;
    final cal = WatchCalendar(events);
    final sum = cal.month(_month.year, _month.month);

    final header = _header(wide);
    final calendarCard = _calendarCard(cal);
    final summaryCard = _summaryCard(sum);
    final dayCard = _dayCard(cal);
    final posterCard = _posterWall(events, sum);

    final sections = <Widget>[
      header,
      const SizedBox(height: 12),
      if (wide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                children: [
                  calendarCard,
                  const SizedBox(height: 12),
                  summaryCard,
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                children: [
                  dayCard,
                  const SizedBox(height: 12),
                  posterCard,
                ],
              ),
            ),
          ],
        )
      else ...[
        calendarCard,
        const SizedBox(height: 12),
        summaryCard,
        const SizedBox(height: 12),
        dayCard,
        const SizedBox(height: 12),
        posterCard,
      ],
      const SizedBox(height: 12),
      _footnote(),
      // 首次同步入口：整份事件流为空、或用户从未做过回填时都给一次机会。
      if (!widget.state.watchBackfillDone && widget.state.server != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _SyncCard(busy: _busy, onSync: _backfill),
        ),
      const SizedBox(height: 140),
    ];

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(hpad, top + 10, hpad, 0),
      itemCount: sections.length,
      itemBuilder: (ctx, i) => sections[i],
    );
  }

  Widget _header(bool wide) {
    final label = widget.state.demoMode
        ? '演示数据 · 连接 Emby 后显示真实观影记录'
        : widget.state.sourceLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.calendar_month_outlined,
              size: 20,
              color: AppColors.ink,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '观影日历',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: wide ? 320 : double.infinity,
          child: StatsModeSegment(
            mode: StatsMode.calendar,
            onChanged: widget.onModeChanged,
          ),
        ),
      ],
    );
  }

  Widget _monthNav(MonthSummary sum) {
    return Row(
      children: [
        _NavBtn(icon: Icons.chevron_left_rounded, onTap: () => _shiftMonth(-1)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${_month.year} 年 ${_month.month} 月',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
        ),
        if (sum.badge != MonthBadge.none)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: AppColors.secondary.withOpacity(0.20),
              border: Border.all(color: AppColors.secondary.withOpacity(0.55)),
            ),
            child: Text(
              '${monthBadgeIcon(sum.badge)} ${monthBadgeLabel(sum.badge, streak: sum.bestStreak)}',
              style: const TextStyle(fontSize: 10, color: Color(0xFFD8CCFF)),
            ),
          ),
        const SizedBox(width: 8),
        _NavBtn(icon: Icons.chevron_right_rounded, onTap: () => _shiftMonth(1)),
      ],
    );
  }

  Widget _calendarCard(WatchCalendar cal) {
    final first = DateTime(_month.year, _month.month, 1);
    final leading = first.weekday - 1; // 周一开头
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final rows = ((leading + days) / 7).ceil();
    final nowKey = watchDayKey(DateTime.now());

    return Glass(
      radius: 18,
      blur: 20,
      tint: 0.08,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _monthNav(cal.month(_month.year, _month.month)),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Center(
                    child: Text(
                      w,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (var r = 0; r < rows; r++) ...[
            if (r > 0) const SizedBox(height: 4),
            Row(
              children: [
                for (var c = 0; c < 7; c++) ...[
                  if (c > 0) const SizedBox(width: 4),
                  Expanded(
                    child: () {
                      final idx = r * 7 + c;
                      final day = idx - leading + 1;
                      if (day < 1 || day > days) {
                        return const SizedBox(height: 42);
                      }
                      final date = DateTime(_month.year, _month.month, day);
                      return _dayCell(date, cal, nowKey);
                    }(),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              const Text(
                '颜色越亮，当天看得越久',
                style: TextStyle(fontSize: 9.5, color: AppColors.muted),
              ),
              const Spacer(),
              LiquidPress(
                radius: 13,
                onTap: _goThisMonth,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: Colors.white.withOpacity(0.18)),
                  ),
                  child: const Text(
                    '回到本月',
                    style: TextStyle(fontSize: 10, color: AppColors.muted),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayCell(DateTime date, WatchCalendar cal, String nowKey) {
    final key = watchDayKey(date);
    final mins = cal.minutesOn(date);
    final count = cal.countOn(date);
    final has = count > 0;
    final on = _selected != null && watchDayKey(_selected!) == key;
    final today = key == nowKey;
    final intensity = mins <= 0 ? 0.20 : (mins / 180).clamp(0.28, 1.0);

    return LiquidPress(
      radius: 12,
      scale: 0.94,
      onTap: () {
        AppHaptics.light();
        setState(() => _selected = date);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: has
              ? AppColors.primary.withOpacity(0.10 + 0.32 * intensity)
              : (on ? Colors.white.withOpacity(0.08) : Colors.transparent),
          border: Border.all(
            color: on
                ? AppColors.accent
                : today
                    ? Colors.white.withOpacity(0.42)
                    : Colors.white.withOpacity(0.07),
            width: on ? 1.4 : 0.8,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: has ? FontWeight.w800 : FontWeight.w500,
                color: has ? Colors.white : AppColors.muted,
              ),
            ),
            const SizedBox(height: 3),
            if (has)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < count.clamp(1, 3); i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Container(
                      width: 3.5,
                      height: 3.5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent.withOpacity(0.55 + 0.45 * intensity),
                      ),
                    ),
                  ],
                ],
              )
            else
              const SizedBox(height: 3.5),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(MonthSummary sum) {
    return Glass(
      radius: 18,
      blur: 20,
      tint: 0.08,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '月度概览',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Metric('观看时长', _hours(sum.minutes), AppColors.primary),
              _Metric('观看天数', '${sum.activeDays} 天', AppColors.secondary),
              _Metric('电影', '${sum.movies} 部', AppColors.cyan),
              _Metric('剧集', '${sum.episodes} 集', AppColors.warn),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            sum.isEmpty
                ? '这个月还没有观影记录。选一个有颜色的日子，或翻到上个月的日历看看。'
                : '本月共 ${sum.titles} 部作品 · 最长连续 ${sum.bestStreak} 天 · ${monthBadgeLabel(sum.badge, streak: sum.bestStreak)}',
            style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  static String _hours(double minutes) {
    if (minutes < 60) return '${minutes.round()} 分';
    return '${(minutes / 60).toStringAsFixed(1)} 小时';
  }

  Widget _dayCard(WatchCalendar cal) {
    final d = _selected;
    final list = d == null ? const <WatchEvent>[] : cal.eventsOn(d);
    final title = d == null
        ? '单日明细'
        : '${d.month} 月 ${d.day} 日 · 看了什么';
    return Glass(
      radius: 18,
      blur: 20,
      tint: 0.08,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
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
              if (list.isNotEmpty)
                Text(
                  '${list.length} 次观看',
                  style: const TextStyle(fontSize: 10, color: AppColors.muted),
                ),
            ],
          ),
          const SizedBox(height: 9),
          if (d == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  '点日历里的任意一天，看那天看了什么、看到哪里',
                  style: TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ),
            )
          else if (list.isEmpty)
            SizedBox(
              height: 240,
              child: EmptyState(
                icon: Icons.event_busy_outlined,
                title: '这天没有观影记录',
                reason: '换一天看看，或者先同步一次服务器上的历史观看记录。',
                primaryLabel:
                    widget.state.watchBackfillDone ? null : '同步历史观看',
                onPrimary: widget.state.watchBackfillDone ? null : _backfill,
              ),
            )
          else
            for (var i = 0; i < list.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _EventRow(e: list[i]),
            ],
        ],
      ),
    );
  }

  Widget _posterWall(List<WatchEvent> events, MonthSummary sum) {
    final posters = <WatchEvent>[];
    final seen = <String>{};
    final prefix =
        '${sum.year.toString().padLeft(4, '0')}-${sum.month.toString().padLeft(2, '0')}-';
    for (final e in events) {
      if (!e.date.startsWith(prefix)) continue;
      if (!seen.add(e.itemId)) continue;
      posters.add(e);
      if (posters.length >= 6) break;
    }

    return Glass(
      radius: 18,
      blur: 20,
      tint: 0.08,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '本月海报墙',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              LiquidPress(
                radius: 14,
                onTap: () => _sharePosterWall(sum),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: AppColors.ctaGradient,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.ios_share_rounded, size: 12, color: Colors.white),
                      SizedBox(width: 5),
                      Text(
                        '分享月报',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 分享截的就是这张卡片；按钮在卡片上方，所以点得到时它已绘制。
          RepaintBoundary(
            key: _shareKey,
            child: _PosterWallCard(
              year: sum.year,
              month: sum.month,
              summary: sum,
              events: posters,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '分享图按当前海报墙生成；海报来自媒体库，未缓存时会显示占位色块。',
            style: TextStyle(fontSize: 9.5, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _footnote() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '数据口径：本机播放记录（精确）→ 服务器活动日志明细 → 历史观看回填（按片长估算）。'
        '标「估算」的记录只有最后观看日期，时长仅供参考。',
        style: TextStyle(fontSize: 10, color: AppColors.muted, height: 1.5),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  const _NavBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => LiquidPress(
    radius: 15,
    onTap: onTap,
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Icon(icon, size: 17, color: AppColors.ink),
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.color);
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(fontSize: 9.5, color: AppColors.muted),
        ),
      ],
    ),
  );
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.e});
  final WatchEvent e;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withOpacity(0.045),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: SizedBox(
              width: 34,
              height: 50,
              child: CachedImage(
                url: e.posterUrl,
                memWidth: 68,
                fallbackLabel: e.name,
                errorWidget: Container(
                  color: AppColors.secondary.withOpacity(0.22),
                  child: const Icon(
                    Icons.movie_outlined,
                    size: 15,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: e.progress.clamp(0.0, 1.0).toDouble(),
                    minHeight: 3,
                    backgroundColor: Colors.white.withOpacity(0.10),
                    valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${e.progressLabel} · ${e.minutes > 0 ? '${e.minutes.round()} 分钟' : '时长未知'}',
                  style: const TextStyle(fontSize: 10, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: e.isEstimated
                  ? AppColors.warn.withOpacity(0.16)
                  : AppColors.primary.withOpacity(0.16),
            ),
            child: Text(
              e.isEstimated ? '估算' : watchSourceLabel(e.source),
              style: TextStyle(
                fontSize: 9,
                color: e.isEstimated ? AppColors.warn : const Color(0xFFA9C4FF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分享出去的月报卡片（P0 只做「海报墙」版式）。
class _PosterWallCard extends StatelessWidget {
  const _PosterWallCard({
    required this.year,
    required this.month,
    required this.summary,
    required this.events,
  });

  final int year;
  final int month;
  final MonthSummary summary;
  final List<WatchEvent> events;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF16223C), Color(0xFF0B1120)],
        ),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month_outlined, size: 14, color: AppColors.accent),
              const SizedBox(width: 6),
              Text(
                '$year 年 $month 月 · 观影月报',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${(summary.minutes / 60).toStringAsFixed(1)} 小时 · '
            '${summary.activeDays} 天 · ${summary.titles} 部作品 · '
            '${monthBadgeLabel(summary.badge, streak: summary.bestStreak)}',
            style: const TextStyle(fontSize: 10, color: Color(0xFF9FB0CC)),
          ),
          const SizedBox(height: 12),
          if (events.isEmpty)
            Container(
              height: 96,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: Colors.white.withOpacity(0.05),
              ),
              child: const Text(
                '这个月还没有观影记录',
                style: TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            )
          else
          // 最多 6 张，手工排 3 列：不引入 GridView + shrinkWrap 的长列表红线。
            for (var row = 0; row < (events.length / 3).ceil(); row++) ...[
              if (row > 0) const SizedBox(height: 7),
              Row(
                children: [
                  for (var c = 0; c < 3; c++) ...[
                    if (c > 0) const SizedBox(width: 7),
                    Expanded(
                      child: () {
                        final idx = row * 3 + c;
                        if (idx >= events.length) {
                          return const AspectRatio(
                            aspectRatio: 0.68,
                            child: SizedBox.shrink(),
                          );
                        }
                        return AspectRatio(
                          aspectRatio: 0.68,
                          child: _posterTile(events[idx]),
                        );
                      }(),
                    ),
                  ],
                ],
              ),
            ],
          const SizedBox(height: 10),
          const Row(
            children: [
              Spacer(),
              Text(
                'Camby · 我的观影日历',
                style: TextStyle(fontSize: 9, color: AppColors.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _posterTile(WatchEvent e) => ClipRRect(
    borderRadius: BorderRadius.circular(7),
    child: Stack(
      fit: StackFit.expand,
      children: [
        CachedImage(
          url: e.posterUrl,
          memWidth: 120,
          fallbackLabel: e.name,
          errorWidget: Container(color: const Color(0xFF243352)),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(5, 12, 5, 5),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xDD06080E)],
              ),
            ),
            child: Text(
              e.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 8.5,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.busy, required this.onSync});
  final bool busy;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 18,
    blur: 20,
    tint: 0.08,
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '同步以前看过的片子',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          '首次可同步最近一年服务器标记为「已看」的记录，按片长估算观看时长，'
          '并在日历里标注「估算」。已经存在的本机记录不会被覆盖。',
          style: TextStyle(fontSize: 10.5, color: AppColors.muted, height: 1.5),
        ),
        const SizedBox(height: 10),
        LiquidPress(
          radius: 14,
          onTap: busy ? null : onSync,
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: AppColors.ctaGradient,
            ),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      '同步最近一年',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ],
    ),
  );
}
