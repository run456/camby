import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../layout.dart';
import '../widgets/glass_toast.dart';
import '../widgets/library_index_segment.dart';
import '../widgets/media_filter_sheet.dart';
import '../widgets/media_poster.dart';
import '../widgets/empty_state.dart';
import '../widgets/skeleton.dart';
import 'actor_index_page.dart';
import 'favorites_page.dart';
import 'series_index_page.dart';

/// 媒体库：排序与筛选收进「两个入口 + 一个底部抽屉」
///  · 顶栏排序按钮：直接显示当前字段 + 方向箭头
///  · 顶栏漏斗按钮：角标 = 激活筛选数
///  · 抽屉内：排序（5 字段 × 升/降）、分辨率多选、中文字幕开关、导演/制造商
///    多选、标签多选（v2.0.55）
///  · 应用后在媒体库行下方显示摘要条，单条可移除、一键清空
///  · 组内「或」、组间「且」；点「应用」才重算列表（_compute 缓存机制不变）
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.onOpenDetail,
    required this.state,
    this.onGoSettings,
  });

  final OpenDetail onOpenDetail;
  final AppState state;

  /// v2.0.64：空态「去连接服务器」的真实跳转（由 main 切到「我的」Tab）。
  final VoidCallback? onGoSettings;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  /// 每个排序字段的默认方向（true = 降序）
  static const _defaultDesc = [true, true, false, true, true];
  static const _resBuckets = ['2160P', '1080P', '720P', '480P', '未知'];

  // v2.0.60：媒体库二级浏览维度；v2.0.68 扩为 4 类（影片 / 演员 / 系列 /
  // 收藏）。默认影片，该分支完全沿用下方原有 CustomScrollView，布局零漂移。
  LibraryIndexTab _indexTab = LibraryIndexTab.movies;

  int _sort = 1; // 默认发行日期
  late List<bool> _desc;

  // 筛选条件（组内或、组间且）
  final Set<String> _resFilters = {};
  bool _cnOnly = false;
  final Set<String> _tagFilters = {};
  // v2.0.55：导演 / 制造商与标签同为「组内或、组间且」
  final Set<String> _directorFilters = {};
  final Set<String> _studioFilters = {};
  // v2.0.57：系列（来自 SeriesName）
  final Set<String> _seriesFilters = {};

  bool _viewLoading = false;
  List<MediaItem>? _viewItems;

  // 缓存：避免每帧对上千条重新排序
  List<MediaItem> _cached = const [];
  String _cacheKey = '';

  @override
  void initState() {
    super.initState();
    _desc = List<bool>.from(_defaultDesc);
    widget.state.addListener(_onStateChanged);
    _loadView(reset: true);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    _cacheKey = '';
    _loadView(reset: false);
    setState(() {});
  }

  void _setIndexTab(LibraryIndexTab t) {
    if (_indexTab == t) return;
    setState(() => _indexTab = t);
  }

  Future<void> _loadView({required bool reset}) async {
    final state = widget.state;
    final vid = state.selectedViewId;
    if (vid == null || state.demoMode) {
      _viewItems = null;
      return;
    }
    LibraryView? view;
    for (final v in state.views) {
      if (v.id == vid) view = v;
    }
    if (view == null) {
      _viewItems = null;
      return;
    }
    if (!reset && _viewItems != null) return;
    setState(() => _viewLoading = true);
    try {
      final list = await state.itemsForView(view);
      if (mounted) setState(() => _viewItems = list);
    } catch (_) {
      if (mounted) setState(() => _viewItems = null);
    }
    if (mounted) setState(() => _viewLoading = false);
  }

  List<MediaItem> get _source => _viewItems ?? widget.state.items;

  /// 下拉刷新：与首页同一套动作（拉条目 + 视图 + 写缓存），
  /// 用 toast 明确告诉用户同步了多少项
  Future<void> _onRefresh() async {
    final n = await widget.state.refresh();
    if (!mounted) return;
    showToast(context, n >= 0 ? '已同步 $n 项' : '刷新失败，请检查网络或服务器地址');
  }

  // ---------------- 条件管理 ----------------

  void _clearFilters() {
    _resFilters.clear();
    _cnOnly = false;
    _tagFilters.clear();
    _directorFilters.clear();
    _studioFilters.clear();
    _seriesFilters.clear();
  }

  /// 只在筛选/排序/数据变化时重算一次（筛选与排序逻辑统一走 [MediaFilter]）
  List<MediaItem> _compute(String key) {
    if (key == _cacheKey) return _cached;
    _cached = _asFilter.apply(_source);
    _cacheKey = key;
    return _cached;
  }

  // ---------------- 抽屉 ----------------

  /// 把页面状态映射成公共筛选状态（抽屉与顶栏胶囊共用同一份定义）
  MediaFilter get _asFilter => MediaFilter(
    sort: _sort,
    desc: List<bool>.of(_desc),
    res: Set<String>.of(_resFilters),
    cnOnly: _cnOnly,
    tags: Set<String>.of(_tagFilters),
    directors: Set<String>.of(_directorFilters),
    studios: Set<String>.of(_studioFilters),
    series: Set<String>.of(_seriesFilters),
  );

  Future<void> _openSheet() async {
    final result = await showMediaFilterSheet(
      context,
      filter: _asFilter,
      source: _source,
    );
    if (result == null || !mounted) return;
    setState(() {
      _sort = result.sort;
      _desc = List<bool>.of(result.desc);
      _resFilters
        ..clear()
        ..addAll(result.res);
      _cnOnly = result.cnOnly;
      _tagFilters
        ..clear()
        ..addAll(result.tags);
      _directorFilters
        ..clear()
        ..addAll(result.directors);
      _studioFilters
        ..clear()
        ..addAll(result.studios);
      _seriesFilters
        ..clear()
        ..addAll(result.series);
      _cacheKey = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    // v2.0.60 设计稿方案 A：演员 / 系列收进媒体库二级分段；
    // v2.0.68：收藏也并入成为第 4 类，原一级收藏 Tab 换成搜索。
    // 四个索引页各自带标题栏、4 类分段与滚动体，底部导航一个像素都不动。
    if (_indexTab != LibraryIndexTab.movies) {
      if (_indexTab == LibraryIndexTab.favorites) {
        return FavoritesPage(
          state: state,
          onOpenDetail: widget.onOpenDetail,
          onIndexTabChanged: _setIndexTab,
          // 「去连接服务器」仍由 main 切到「我的」Tab。
          onSwitchTab: (_) => widget.onGoSettings?.call(),
        );
      }
      return _indexTab == LibraryIndexTab.actors
          ? ActorIndexPage(
              state: state,
              onOpenDetail: widget.onOpenDetail,
              tab: _indexTab,
              onTabChanged: _setIndexTab,
            )
          : SeriesIndexPage(
              state: state,
              onOpenDetail: widget.onOpenDetail,
              tab: _indexTab,
              onTabChanged: _setIndexTab,
            );
    }
    final wide = context.isTablet;
    final key =
        '${state.selectedViewId}|$_sort|${_desc.join()}|${_resFilters.join()}'
        '|$_cnOnly|${_tagFilters.join()}'
        '|${_directorFilters.join()}|${_studioFilters.join()}|${_seriesFilters.join()}'
        '|${_viewItems?.length ?? -1}|${state.items.length}';
    final list = _compute(key);
    final top = MediaQuery.of(context).padding.top;

    // 摘要条 chips（灰字标注所属组）
    final summary = <Widget>[];
    for (final r in _resBuckets) {
      if (_resFilters.contains(r)) {
        summary.add(
          _FilterChip(
            '分辨率',
            r,
            () => setState(() {
              _resFilters.remove(r);
              _cacheKey = '';
            }),
          ),
        );
      }
    }
    if (_cnOnly) {
      summary.add(
        _FilterChip(
          '字幕',
          '中文字幕',
          () => setState(() {
            _cnOnly = false;
            _cacheKey = '';
          }),
        ),
      );
    }
    for (final d in _directorFilters.toList()..sort()) {
      summary.add(
        _FilterChip(
          '导演',
          d,
          () => setState(() {
            _directorFilters.remove(d);
            _cacheKey = '';
          }),
        ),
      );
    }
    for (final s in _studioFilters.toList()..sort()) {
      summary.add(
        _FilterChip(
          '制造商',
          s,
          () => setState(() {
            _studioFilters.remove(s);
            _cacheKey = '';
          }),
        ),
      );
    }
    for (final t in _tagFilters.toList()..sort()) {
      summary.add(
        _FilterChip(
          '标签',
          t,
          () => setState(() {
            _tagFilters.remove(t);
            _cacheKey = '';
          }),
        ),
      );
    }
    for (final s in _seriesFilters.toList()..sort()) {
      summary.add(
        _FilterChip(
          '系列',
          s,
          () => setState(() {
            _seriesFilters.remove(s);
            _cacheKey = '';
          }),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: const Color(0xF2121828),
      onRefresh: _onRefresh,
      child: Container(
        color: AppColors.bg,
        child: CustomScrollView(
          // AlwaysScrollable：条目不足一屏时也能下拉刷新
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 24 : 16,
                  top + 12,
                  wide ? 24 : 16,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.grid_view_rounded,
                          size: 20,
                          color: AppColors.ink,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '媒体库',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.4,
                                ),
                              ),
                              Text(
                                state.demoMode
                                    ? '演示数据'
                                    : '${state.sourceLabel} · ${list.length} 项',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: AppColors.muted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        if (state.loading || _viewLoading)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          )
                        else ...[
                          // 排序 + 筛选共用一个入口（公共组件：媒体库 / 演员页 /
                          // 收藏夹三处必须是同一个控件）
                          MediaFilterButton(
                            filter: _asFilter,
                            onTap: _openSheet,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),
                    LibraryIndexSegment(
                      tab: LibraryIndexTab.movies,
                      onChanged: _setIndexTab,
                    ),
                    const SizedBox(height: 12),
                    // 媒体库分组
                    if (state.views.isNotEmpty)
                      SizedBox(
                        height: 34,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: state.views.length + 1,
                          itemBuilder: (c, i) {
                            final isAll = i == 0;
                            final v = isAll ? null : state.views[i - 1];
                            final sel = isAll
                                ? state.selectedViewId == null
                                : state.selectedViewId == v!.id;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: LiquidPress(
                                radius: 17,
                                scale: 0.95,
                                onTap: () {
                                  state.selectedViewId = isAll ? null : v!.id;
                                  _viewItems = null;
                                  _cacheKey = '';
                                  _loadView(reset: true);
                                },
                                child: _Chip(
                                  label: isAll ? '全部' : v!.name,
                                  selected: sel,
                                  icon: !isAll && v!.collectionType == 'tvshows'
                                      ? Icons.tv_outlined
                                      : Icons.movie_outlined,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    // 摘要条：有激活筛选才出现，单条可移除
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 26,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            ...summary.map(
                              (w) => Padding(
                                padding: const EdgeInsets.only(right: 7),
                                child: w,
                              ),
                            ),
                            const SizedBox(width: 2),
                            LiquidPress(
                              radius: 13,
                              onTap: () => setState(() {
                                _clearFilters();
                                _cacheKey = '';
                              }),
                              child: Container(
                                height: 26,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(13),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.22),
                                  ),
                                ),
                                child: const Center(
                                  child: Text(
                                    '清空',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.muted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                  ],
                ),
              ),
            ),
            // v2.0.64：首屏 / 切库先画出「要出现的内容形状」，而不是一个
            // 居中小转圈 + 大片空白。骨架高度固定，不参与滚动路径上的动画。
            if (state.loading || _viewLoading)
              const SliverToBoxAdapter(
                child: SizedBox(
                  height: 470,
                  child: LibrarySkeleton(),
                ),
              )
            else if (list.isEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 370,
                  child: EmptyState(
                    icon: Icons.movie_outlined,
                    title: '该筛选条件下没有条目',
                    reason: _asFilter.activeCount > 0
                        ? '当前 ${_asFilter.activeCount} 个筛选条件组合后没有匹配影片。'
                            '清掉条件就能看到完整媒体库。'
                        : (state.server == null
                            ? '还没有连接服务器。到「我的 → 我的服务器」添加后即可同步媒体库。'
                            : '服务器暂时没有返回影片，可以下拉刷新重试一次。'),
                    primaryLabel: _asFilter.activeCount > 0
                        ? '清除筛选'
                        : (state.server == null ? '去连接服务器' : '刷新媒体库'),
                    onPrimary: () {
                      if (_asFilter.activeCount > 0) {
                        setState(() {
                          _clearFilters();
                          _cacheKey = '';
                        });
                      } else if (state.server == null) {
                        widget.onGoSettings?.call();
                      } else {
                        _onRefresh();
                      }
                    },
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 24 : 16,
                  0,
                  wide ? 24 : 16,
                  120,
                ),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: context.mediaGridColumns,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.55,
                  ),
                  itemCount: list.length,
                  itemBuilder: (c, i) {
                    final e = list[i];
                    return PosterCard(
                      item: e,
                      width: double.infinity,
                      heroTag: 'lib-${e.id}',
                      onTap: () =>
                          widget.onOpenDetail(e, heroTag: 'lib-${e.id}'),
                      showProgress: true,
                      showResBadge: true,
                      showCnBadge: true,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 摘要条中的条件 chip：组名 + 值 + ✕
class _FilterChip extends StatelessWidget {
  const _FilterChip(this.group, this.value, this.onRemove);
  final String group;
  final String value;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onRemove,
      radius: 13,
      scale: 0.95,
      semanticLabel: '移除条件 $group $value',
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          color: const Color(0x3335E0C4),
          border: Border.all(color: const Color(0x8735E0C4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              group,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF8FF5E2).withOpacity(0.55),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF8FF5E2),
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.close_rounded,
              size: 11,
              color: const Color(0xFF8FF5E2).withOpacity(0.7),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, this.icon});
  final String label;
  final bool selected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: selected
            ? const LinearGradient(
                colors: [AppColors.primary, AppColors.secondary],
              )
            : null,
        color: selected ? null : Colors.white.withOpacity(0.07),
        border: Border.all(
          color: selected ? Colors.transparent : Colors.white.withOpacity(0.12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 12,
              color: selected ? Colors.white : AppColors.muted,
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}
