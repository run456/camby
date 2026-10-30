import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/glass_toast.dart';
import '../widgets/media_poster.dart';

/// 媒体库：排序与筛选收进「两个入口 + 一个底部抽屉」
///  · 顶栏排序按钮：直接显示当前字段 + 方向箭头
///  · 顶栏漏斗按钮：角标 = 激活筛选数
///  · 抽屉内：排序（5 字段 × 升/降）、分辨率多选、中文字幕开关、标签多选
///  · 应用后在媒体库行下方显示摘要条，单条可移除、一键清空
///  · 组内「或」、组间「且」；点「应用」才重算列表（_compute 缓存机制不变）
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.onOpenDetail,
    required this.state,
  });

  final OpenDetail onOpenDetail;
  final AppState state;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const _sortNames = ['创建日期', '发行日期', '标题', '播放时长', '评分'];

  /// 每个排序字段的默认方向（true = 降序）
  static const _defaultDesc = [true, true, false, true, true];
  static const _resBuckets = ['2160P', '1080P', '720P', '480P', '未知'];

  int _sort = 1; // 默认发行日期
  late List<bool> _desc;

  // 筛选条件（组内或、组间且）
  final Set<String> _resFilters = {};
  bool _cnOnly = false;
  final Set<String> _tagFilters = {};

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

  int get _activeCount =>
      _resFilters.length + (_cnOnly ? 1 : 0) + _tagFilters.length;

  void _clearFilters() {
    _resFilters.clear();
    _cnOnly = false;
    _tagFilters.clear();
  }

  /// 只在筛选/排序/数据变化时重算一次
  List<MediaItem> _compute(String key) {
    if (key == _cacheKey) return _cached;
    final list = List<MediaItem>.from(_source);

    // 筛选：组内或、组间且
    if (_resFilters.isNotEmpty) {
      list.retainWhere((e) => _resFilters.contains(resolutionBucket(e)));
    }
    if (_cnOnly) list.retainWhere(itemHasChineseSubtitle);
    if (_tagFilters.isNotEmpty) {
      list.retainWhere((e) => e.tags.any(_tagFilters.contains));
    }

    // 排序：字段 + 各自记忆的方向
    final d = _desc[_sort] ? -1 : 1;
    switch (_sort) {
      case 0: // 创建日期：addedDaysAgo 越小越新
        list.sort((a, b) => d * a.addedDaysAgo.compareTo(b.addedDaysAgo));
      case 1:
        list.sort((a, b) => d * a.year.compareTo(b.year));
      case 2:
        list.sort((a, b) => d * a.name.compareTo(b.name));
      case 3:
        list.sort((a, b) => d * a.runtimeMin.compareTo(b.runtimeMin));
      case 4:
        list.sort((a, b) => d * a.rating.compareTo(b.rating));
    }
    _cached = list;
    _cacheKey = key;
    return list;
  }

  /// 各分组选项 + 命中数（基于当前媒体库原始数据，进抽屉时算一次）
  Map<String, int> _countsOf(String Function(MediaItem) keyOf) {
    final m = <String, int>{};
    for (final e in _source) {
      final k = keyOf(e);
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  Map<String, int> get _resCounts => _countsOf(resolutionBucket);

  Map<String, int> get _tagCounts {
    final m = <String, int>{};
    for (final e in _source) {
      for (final t in e.tags) {
        m[t] = (m[t] ?? 0) + 1;
      }
    }
    return m;
  }

  // ---------------- 抽屉 ----------------

  Future<void> _openSheet() async {
    final result = await showModalBottomSheet<LibraryFilterResult>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => LibraryFilterSheet(
        sort: _sort,
        desc: List<bool>.from(_desc),
        resFilters: Set<String>.from(_resFilters),
        cnOnly: _cnOnly,
        tagFilters: Set<String>.from(_tagFilters),
        resCounts: _resCounts,
        tagCounts: _tagCounts,
        total: _source.length,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _sort = result.sort;
      _desc = result.desc;
      _resFilters
        ..clear()
        ..addAll(result.resFilters);
      _cnOnly = result.cnOnly;
      _tagFilters
        ..clear()
        ..addAll(result.tagFilters);
      _cacheKey = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final wide = MediaQuery.of(context).size.width >= 840;
    final key =
        '${state.selectedViewId}|$_sort|${_desc.join()}|${_resFilters.join()}'
        '|$_cnOnly|${_tagFilters.join()}'
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
                          // 排序 + 筛选共用一个入口：方向箭头 + 当前字段 + 筛选条件数角标
                          // （原来这里还有一个漏斗按钮，点开的是同一个抽屉，纯重复）
                          _TopBtn(
                            onTap: _openSheet,
                            badge: _activeCount,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _desc[_sort] ? '↓' : '↑',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.primary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _sortNames[_sort],
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
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
            if (list.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 24,
                  ),
                  child: Center(
                    child: Column(
                      children: [
                        const Icon(
                          Icons.movie_outlined,
                          size: 34,
                          color: AppColors.muted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _viewLoading ? '正在加载媒体库…' : '该筛选条件下没有条目',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
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
                    crossAxisCount: wide ? 6 : 3,
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

/// 底部抽屉结果
class LibraryFilterResult {
  const LibraryFilterResult({
    required this.sort,
    required this.desc,
    required this.resFilters,
    required this.cnOnly,
    required this.tagFilters,
  });

  final int sort;
  final List<bool> desc;
  final Set<String> resFilters;
  final bool cnOnly;
  final Set<String> tagFilters;
}

/// 排序与筛选抽屉：草稿态在内部编辑，点「应用」才提交
class LibraryFilterSheet extends StatefulWidget {
  const LibraryFilterSheet({
    super.key,
    required this.sort,
    required this.desc,
    required this.resFilters,
    required this.cnOnly,
    required this.tagFilters,
    required this.resCounts,
    required this.tagCounts,
    required this.total,
  });

  final int sort;
  final List<bool> desc;
  final Set<String> resFilters;
  final bool cnOnly;
  final Set<String> tagFilters;
  final Map<String, int> resCounts;
  final Map<String, int> tagCounts;
  final int total;

  @override
  State<LibraryFilterSheet> createState() => _LibraryFilterSheetState();
}

class _LibraryFilterSheetState extends State<LibraryFilterSheet> {
  static const _sortNames = ['创建日期', '发行日期', '标题', '播放时长', '评分'];
  static const _resBuckets = ['2160P', '1080P', '720P', '480P', '未知'];

  late int _sort;
  late List<bool> _desc;
  late Set<String> _res;
  late bool _cn;
  late Set<String> _tags;

  @override
  void initState() {
    super.initState();
    _sort = widget.sort;
    _desc = List<bool>.from(widget.desc);
    _res = Set<String>.from(widget.resFilters);
    _cn = widget.cnOnly;
    _tags = Set<String>.from(widget.tagFilters);
  }

  int get _activeCount => _res.length + (_cn ? 1 : 0) + _tags.length;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF171C27), Color(0xFF10141D)],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 9),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: Colors.white.withOpacity(0.22),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: Row(
                children: [
                  const Text(
                    '排序与筛选',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${widget.total} 项 · 已选 $_activeCount 个条件',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                shrinkWrap: true,
                children: [
                  _sectionTitle('排序方式', '点字段切换，右侧选升 / 降'),
                  ...List.generate(_sortNames.length, (i) {
                    final on = _sort == i;
                    return _SortRow(
                      name: _sortNames[i],
                      active: on,
                      desc: _desc[i],
                      onSelect: () => setState(() => _sort = i),
                      onDir: (v) => setState(() {
                        _desc[i] = v;
                        _sort = i;
                      }),
                    );
                  }),
                  _sectionTitle('分辨率', '多选 · 来自视频流真实高度'),
                  _chipWrap(
                    _resBuckets.map(
                      (b) => _fChip(
                        b,
                        count: widget.resCounts[b] ?? 0,
                        on: _res.contains(b),
                        onTap: () => setState(() {
                          _res.contains(b) ? _res.remove(b) : _res.add(b);
                        }),
                      ),
                    ),
                  ),
                  _sectionTitle('字幕', null),
                  _SwitchRow(
                    on: _cn,
                    onChanged: (v) => setState(() => _cn = v),
                  ),
                  _sectionTitle('标签', '多选 · 可滚动'),
                  _chipWrap(
                    (widget.tagCounts.keys.toList()..sort()).map(
                      (t) => _fChip(
                        t,
                        count: widget.tagCounts[t] ?? 0,
                        on: _tags.contains(t),
                        onTap: () => setState(() {
                          _tags.contains(t) ? _tags.remove(t) : _tags.add(t);
                        }),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
            // 底部操作栏：重置 + 应用
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Row(
                children: [
                  LiquidPress(
                    onTap: () => setState(() {
                      _res.clear();
                      _cn = false;
                      _tags.clear();
                    }),
                    radius: 14,
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.22),
                        ),
                      ),
                      child: const Center(
                        child: Text(
                          '重置',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LiquidPress(
                      onTap: () => Navigator.pop(
                        context,
                        LibraryFilterResult(
                          sort: _sort,
                          desc: _desc,
                          resFilters: _res,
                          cnOnly: _cn,
                          tagFilters: _tags,
                        ),
                      ),
                      radius: 14,
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF2F7FE8), Color(0xFF4F9CFF)],
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x592F7FE8),
                              blurRadius: 18,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            '应用筛选',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, String? hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              color: AppColors.muted,
            ),
          ),
          const Spacer(),
          if (hint != null)
            Text(
              hint,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: AppColors.muted.withOpacity(0.7),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chipWrap(Iterable<Widget> chips) {
    return Wrap(spacing: 7, runSpacing: 7, children: chips.toList());
  }

  Widget _fChip(
    String label, {
    required int count,
    required bool on,
    required VoidCallback onTap,
  }) {
    return LiquidPress(
      onTap: onTap,
      radius: 15,
      scale: 0.95,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: on ? const Color(0x334F8CFF) : Colors.white.withOpacity(0.06),
          border: Border.all(
            color: on
                ? const Color(0x874F8CFF)
                : Colors.white.withOpacity(0.10),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: on ? Colors.white : AppColors.muted,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: on
                    ? const Color(0xFFA9C4FF)
                    : AppColors.muted.withOpacity(0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 排序字段行：字段名 + 升/降分段
class _SortRow extends StatelessWidget {
  const _SortRow({
    required this.name,
    required this.active,
    required this.desc,
    required this.onSelect,
    required this.onDir,
  });

  final String name;
  final bool active;
  final bool desc;
  final VoidCallback onSelect;
  final ValueChanged<bool> onDir;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: LiquidPress(
        onTap: onSelect,
        radius: 13,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: active
                ? const Color(0x334F8CFF)
                : Colors.white.withOpacity(0.04),
            border: Border.all(
              color: active
                  ? const Color(0x874F8CFF)
                  : Colors.white.withOpacity(0.10),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w700,
                    color: active ? Colors.white : const Color(0xFFD5DEEF),
                  ),
                ),
              ),
              _dirSeg(!desc, '↑ 升', () => onDir(false)),
              const SizedBox(width: 3),
              _dirSeg(desc, '↓ 降', () => onDir(true)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dirSeg(bool on, String label, VoidCallback onTap) {
    return LiquidPress(
      onTap: onTap,
      radius: 7,
      scale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: on ? const Color(0x594F8CFF) : Colors.black.withOpacity(0.30),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: on ? const Color(0xFFCFE0FF) : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

/// 「仅看有中文字幕」开关行
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.on, required this.onChanged});
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '仅看有中文字幕',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '简体 / 繁体 / 中字外挂轨均计入',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: AppColors.muted.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
          LiquidPress(
            onTap: () => onChanged(!on),
            radius: 12,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 40,
              height: 23,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: on ? AppColors.primary : Colors.white.withOpacity(0.14),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.all(2.5),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
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
}

/// 顶栏玻璃按钮（排序 / 漏斗），带激活数角标
class _TopBtn extends StatelessWidget {
  const _TopBtn({required this.onTap, required this.child, this.badge = 0});
  final VoidCallback onTap;
  final Widget child;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        LiquidPress(
          onTap: onTap,
          radius: 19,
          scale: 0.92,
          child: ClipRRect(
            // 真磨砂玻璃：与首页胶囊（_Pill）、各页圆钮统一
            borderRadius: BorderRadius.circular(19),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(19),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.10),
                      Colors.white.withOpacity(0.04),
                    ],
                  ),
                  border: Border.all(color: Colors.white.withOpacity(0.16)),
                ),
                child: Center(child: child),
              ),
            ),
          ),
        ),
        if (badge > 0)
          Positioned(
            top: -5,
            right: -5,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16),
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.primary,
                border: Border.all(color: AppColors.bg, width: 2),
              ),
              child: Center(
                child: Text(
                  '$badge',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
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
          color: const Color(0x334F8CFF),
          border: Border.all(color: const Color(0x874F8CFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              group,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFA9C4FF).withOpacity(0.55),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFFA9C4FF),
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.close_rounded,
              size: 11,
              color: const Color(0xFFA9C4FF).withOpacity(0.7),
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
