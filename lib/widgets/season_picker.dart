import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'liquid_press.dart';

/// 剧集「选集」面板（v2.0.92）。
///
/// 对齐绿联影视中心剧集页的交互：标题行「选集 · 共 N 集」，下面一行季标签
/// （第1季 / 第2季 / 第3季 / 第4季），再下面是**当前季**的集号网格 ——
/// 一格一个数字，看过的集打勾，看了一半的集保留进度条。
///
/// 这套面板只认数据、不认服务端：Emby / Jellyfin / 绿联影视中心喂进来的
/// 都是同一份 `List<MediaItem>`，按 [SeasonGroup] 分好季即可。剧集只有
/// 一季时**不显示季标签行**，直接就是集号网格，不浪费一行高度。
class SeasonPicker extends StatefulWidget {
  const SeasonPicker({
    super.key,
    required this.seasons,
    required this.onPlay,
    this.loading = false,
    this.initialSeason,
    this.onPlayNext,
    this.onLoadSeason,
  });

  /// 按季号升序排好的季列表（来自 `EmbyServer.seasons()`）
  final List<SeasonGroup> seasons;

  /// 点某一集：交给宿主起播（含续播定位）
  final ValueChanged<MediaItem> onPlay;

  /// 该剧还没有分集数据时显示占位
  final bool loading;

  /// 初始选中季（比如上次看到的那一季）
  final int? initialSeason;

  /// 「继续播放」入口：给出建议的下一集，为空则不显示
  final MediaItem? Function()? onPlayNext;

  /// 按需加载某一季的分集（v2.0.93）。
  ///
  /// 绿联把每一季登记成独立的 Series 条目，「同剧其它季」只有在用户点开
  /// 那个季标签时才需要拉分集 —— 一次进详情页就打 5、6 个请求并不划算。
  /// 返回 null 表示这个季确实没有分集。
  final Future<List<MediaItem>> Function(SeasonGroup group)? onLoadSeason;

  @override
  State<SeasonPicker> createState() => _SeasonPickerState();
}

class _SeasonPickerState extends State<SeasonPicker> {
  int _si = 0;
  bool _inited = false;

  /// 已按需拉到分集的季：季号 → 分组（覆盖 widget.seasons 里的同名项）
  final Map<int, SeasonGroup> _loaded = {};

  /// 正在拉取的季号
  int? _loadingIndex;

  /// 当前展示的季：优先用已加载的那份
  SeasonGroup get _current {
    final g = widget.seasons[_si];
    return _loaded[g.index] ?? g;
  }

  /// 集号网格一行放几个。窄屏 5 个（绿联原版也是 5~6 个），
  /// 宽屏交给 [LayoutBuilder] 按 64dp 一格自动算。
  static const double _cell = 46;
  static const double _gap = 8;

  @override
  void initState() {
    super.initState();
    _syncInitial();
  }

  @override
  void didUpdateWidget(covariant SeasonPicker old) {
    super.didUpdateWidget(old);
    // 首次拿到数据后定位到「上次观看那一季」，只做一次，之后用户点哪季是哪季
    if (!_inited && widget.seasons.isNotEmpty) _syncInitial();
    if (_si >= widget.seasons.length) {
      _si = widget.seasons.isEmpty ? 0 : widget.seasons.length - 1;
    }
  }

  void _syncInitial() {
    if (widget.seasons.isEmpty) return;
    final want = widget.initialSeason;
    var idx = 0;
    if (want != null) {
      final hit = widget.seasons.indexWhere((s) => s.index == want);
      if (hit >= 0) idx = hit;
    }
    _si = idx;
    _inited = true;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.seasons.isEmpty) {
      return Text(
        widget.loading ? '正在读取分集…' : '暂无分集信息',
        style: TextStyle(fontSize: 11.5, color: AppColors.muted),
      );
    }
    final s = _current;
    final total = widget.seasons.fold<int>(0, (a, g) {
      final got = _loaded[g.index] ?? g;
      return a + (got.hasEpisodes ? got.episodes.length : got.episodeCount);
    });
    final next = widget.onPlayNext?.call();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '选集',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(width: 8),
            if (total > 0)
              Text(
                '共 $total 集',
                style: TextStyle(fontSize: 10.5, color: AppColors.muted),
              ),
            const Spacer(),
            if (next != null && widget.onPlayNext != null)
              LiquidPress(
                radius: 999,
                scale: 0.95,
                onTap: () => widget.onPlay(next),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: AppColors.primary.withValues(alpha: 0.16),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.38),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_arrow_rounded,
                        size: 13,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '续看 ${episodeBadge(next)}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // 季标签行：只有一季时不显示，省一行高度
        if (widget.seasons.length > 1) ...[
          SizedBox(height: 30, child: _seasonTabs()),
          const SizedBox(height: 10),
        ],
        _episodeGrid(s),
      ],
    );
  }

  /// 切到第 [i] 季；该季还没分集就顺手拉一次。
  ///
  /// 「同剧其它季」在合并进来时只带季号与 Series id，分集要等真正点开
  /// 才请求 —— 绿联一部剧常有 5~8 条 Series，一次进详情页全打一遍太浪费。
  void _selectSeason(int i) {
    if (i == _si) return;
    setState(() => _si = i);
    final g = widget.seasons[i];
    final has = (_loaded[g.index] ?? g).hasEpisodes;
    if (has || widget.onLoadSeason == null) return;
    _loadSeason(g);
  }

  Future<void> _loadSeason(SeasonGroup g) async {
    if (_loadingIndex == g.index) return;
    setState(() => _loadingIndex = g.index);
    try {
      final list = await widget.onLoadSeason!(g);
      if (!mounted) return;
      setState(() {
        _loadingIndex = null;
        // 空列表也记下来：这样同一季不会被反复重拉，界面给「暂无分集」
        _loaded[g.index] = SeasonGroup(
          index: g.index,
          name: g.name,
          id: g.id,
          posterUrl: g.posterUrl,
          episodeCount: list.isEmpty ? g.episodeCount : list.length,
          episodes: list,
          seriesId: g.seriesId,
          seriesName: g.seriesName,
        );
      });
    } catch (_) {
      if (mounted) setState(() => _loadingIndex = null);
    }
  }

  /// 季标签行。
  ///
  /// 季数最多十几条，用 `Row` + 横向滚动一次性铺完即可 —— 既不需要虚拟滚动
  /// （`itemBuilder` 里 `setState` 会被性能审计判定为滚动期整页重建），
  /// 也不会为几个标签付 `ListView` 的额外开销。
  Widget _seasonTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < widget.seasons.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            _SeasonTab(
              group: widget.seasons[i],
              selected: i == _si,
              onTap: () => _selectSeason(i),
            ),
          ],
        ],
      ),
    );
  }

  Widget _episodeGrid(SeasonGroup s) {
    final eps = s.episodes;
    if (eps.isEmpty) {
      return Text(
        _loadingIndex == s.index ? '正在读取这一季…' : '这一季还没有分集数据',
        style: TextStyle(fontSize: 11.5, color: AppColors.muted),
      );
    }
    return LayoutBuilder(
      builder: (c, box) {
        // 每格 46 + 间距 8，按可用宽度算列数（最少 3 列，最多 8 列）
        final per = ((box.maxWidth + _gap) / (_cell + _gap)).floor();
        final cols = per.clamp(3, 8);
        // 集号是固定数量的等比格子，直接铺而不是 `GridView(shrinkWrap:)`
        // —— 后者会把整季格子一次性构建，且把滚动语义交给外层，长季会卡。
        final rows = <Widget>[];
        for (var i = 0; i < eps.length; i += cols) {
          rows.add(
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : _gap),
              child: Row(
                children: [
                  for (var j = i; j < i + cols && j < eps.length; j++) ...[
                    if (j > i) const SizedBox(width: _gap),
                    Expanded(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: _EpisodeCell(
                          episode: eps[j],
                          fallbackIndex: j,
                          onTap: () => widget.onPlay(eps[j]),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      },
    );
  }
}

/// 单集格子：集号居中，看过的右上角打勾，看了一半底部有进度条。
class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.episode,
    required this.onTap,
    this.fallbackIndex = 0,
  });

  final MediaItem episode;
  final VoidCallback onTap;
  final int fallbackIndex;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final num = e.episodeNumber ?? (fallbackIndex + 1);
    final progress = (e.resumeProgress ?? 0).clamp(0.0, 1.0);
    final partial = progress > 0.01 && !e.userPlayed;
    return LiquidPress(
      radius: 11,
      scale: 0.94,
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              color: AppColors.w.withValues(alpha: 0.07),
              border: Border.all(
                color: partial
                    ? AppColors.primary.withValues(alpha: 0.55)
                    : AppColors.w.withValues(alpha: 0.12),
              ),
            ),
            child: Center(
              child: Text(
                '$num',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: e.userPlayed
                      ? AppColors.muted
                      : const Color(0xFFE8EFFA),
                ),
              ),
            ),
          ),
          if (e.userPlayed)
            Positioned(
              right: 4,
              top: 3,
              child: Icon(
                Icons.check_rounded,
                size: 11,
                color: AppColors.cyan,
              ),
            ),
          if (partial)
            Positioned(
              left: 6,
              right: 6,
              bottom: 5,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  backgroundColor: AppColors.w.withValues(alpha: 0.14),
                  valueColor: AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个季标签：选中态走主色渐变，未选中是低填充 + 白 12% 描边。
///
/// 单独抽出来是因为它必须**自带**状态判断与回调（而不是在 `itemBuilder`
/// 里包一层 `setState`）——后者会被性能审计判定为滚动期整页重建。
class _SeasonTab extends StatelessWidget {
  const _SeasonTab({
    required this.group,
    required this.selected,
    required this.onTap,
  });

  final SeasonGroup group;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      radius: 9,
      scale: 0.95,
      enabled: !selected,
      onTap: selected ? null : onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          gradient: selected
              ? LinearGradient(
                  colors: [AppColors.primary, AppColors.secondary],
                )
              : null,
          color: selected ? null : AppColors.w.withValues(alpha: 0.06),
          border: selected
              ? null
              : Border.all(color: AppColors.w.withValues(alpha: 0.12)),
        ),
        child: Text(
          group.label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF93A8C6),
          ),
        ),
      ),
    );
  }
}
