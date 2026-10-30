import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'liquid_press.dart';

/// 「排序与筛选」的**唯一实现**：媒体库 / 演员页 / 收藏夹共用。
///
/// 之前媒体库有一套（`LibraryFilterSheet`），演员页与收藏夹各有简化版
/// （只有年代档，没有分辨率 / 字幕 / 标签），三处版式与能力都对不上。
/// 现在统一到这里：
/// - [MediaFilter]：筛选与排序状态（排序 5 字段 × 各自升降 + 分辨率 +
///   中文字幕 + 标签），页面直接 `filter.apply(items)` 拿结果
/// - [MediaFilterButton]：顶栏入口胶囊（↓ 发行日期 + 条件数角标）
/// - [showMediaFilterSheet]：底部抽屉，版式与媒体库完全一致
const List<String> mediaSortNames = ['创建日期', '发行日期', '标题', '播放时长', '评分'];

/// 分辨率分组（十进制口径，来自视频流真实高度）
const List<String> mediaResBuckets = ['2160P', '1080P', '720P', '480P', '未知'];

/// 抽屉返回结果（草稿态提交）
class MediaFilterResult {
  const MediaFilterResult({
    required this.sort,
    required this.desc,
    required this.res,
    required this.cnOnly,
    required this.tags,
  });

  final int sort;
  final List<bool> desc;
  final Set<String> res;
  final bool cnOnly;
  final Set<String> tags;
}

/// 筛选与排序状态。页面持有，抽屉里编辑草稿，点「应用筛选」才回写。
class MediaFilter {
  MediaFilter({
    this.sort = 1,
    List<bool>? desc,
    Set<String>? res,
    this.cnOnly = false,
    Set<String>? tags,
  }) : desc = desc ?? List<bool>.filled(mediaSortNames.length, true),
       res = res ?? <String>{},
       tags = tags ?? <String>{};

  /// 当前排序字段下标（见 [mediaSortNames]）
  int sort;

  /// 每个字段各自记一个方向：true = 降序
  List<bool> desc;

  final Set<String> res;
  bool cnOnly;
  final Set<String> tags;

  int get activeCount => res.length + (cnOnly ? 1 : 0) + tags.length;

  /// 顶栏胶囊上的文案：方向箭头 + 当前字段名
  String get summary => mediaSortNames[sort];
  String get arrow => desc[sort] ? '↓' : '↑';

  void applyResult(MediaFilterResult r) {
    sort = r.sort;
    desc = List<bool>.of(r.desc);
    res
      ..clear()
      ..addAll(r.res);
    cnOnly = r.cnOnly;
    tags
      ..clear()
      ..addAll(r.tags);
  }

  /// 只清条件，不动排序
  void clearConditions() {
    res.clear();
    cnOnly = false;
    tags.clear();
  }

  bool keeps(MediaItem e) {
    if (res.isNotEmpty && !res.contains(resolutionBucket(e))) return false;
    if (cnOnly && !itemHasChineseSubtitle(e)) return false;
    if (tags.isNotEmpty && !e.tags.any(tags.contains)) return false;
    return true;
  }

  /// 筛选 + 排序（返回新列表）
  List<MediaItem> apply(Iterable<MediaItem> items) {
    final list = items.where(keeps).toList();
    final d = desc[sort] ? -1 : 1;
    switch (sort) {
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
    return list;
  }

  /// 命中条数（只筛不排，抽屉里「共 N 项」用）
  int countOf(Iterable<MediaItem> items) => items.where(keeps).length;

  static Map<String, int> resCountsOf(Iterable<MediaItem> items) {
    final m = <String, int>{};
    for (final e in items) {
      final k = resolutionBucket(e);
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  static Map<String, int> tagCountsOf(Iterable<MediaItem> items) {
    final m = <String, int>{};
    for (final e in items) {
      for (final t in e.tags) {
        m[t] = (m[t] ?? 0) + 1;
      }
    }
    return m;
  }
}

/// 顶栏「排序与筛选」入口胶囊：真磨砂 + 方向箭头 + 字段名 + 条件数角标。
/// 媒体库 / 演员页 / 收藏夹三处必须是同一个控件。
class MediaFilterButton extends StatelessWidget {
  const MediaFilterButton({
    super.key,
    required this.filter,
    required this.onTap,
  });

  final MediaFilter filter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        LiquidPress(
          onTap: onTap,
          radius: 19,
          scale: 0.92,
          semanticLabel: '排序与筛选',
          child: ClipRRect(
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
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        filter.arrow,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        filter.summary,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (filter.activeCount > 0)
          Positioned(
            top: -5,
            right: -5,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16),
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.bg, width: 1.4),
              ),
              child: Center(
                child: Text(
                  '${filter.activeCount}',
                  style: const TextStyle(
                    fontSize: 9,
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

/// 弹出排序与筛选抽屉；取消返回 null
Future<MediaFilterResult?> showMediaFilterSheet(
  BuildContext context, {
  required MediaFilter filter,
  required Iterable<MediaItem> source,
}) {
  final items = source.toList();
  return showModalBottomSheet<MediaFilterResult>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _MediaFilterSheet(
      filter: filter,
      resCounts: MediaFilter.resCountsOf(items),
      tagCounts: MediaFilter.tagCountsOf(items),
      total: items.length,
    ),
  );
}

/// 抽屉：草稿态在内部编辑，点「应用筛选」才提交
class _MediaFilterSheet extends StatefulWidget {
  const _MediaFilterSheet({
    required this.filter,
    required this.resCounts,
    required this.tagCounts,
    required this.total,
  });

  final MediaFilter filter;
  final Map<String, int> resCounts;
  final Map<String, int> tagCounts;
  final int total;

  @override
  State<_MediaFilterSheet> createState() => _MediaFilterSheetState();
}

class _MediaFilterSheetState extends State<_MediaFilterSheet> {
  late int _sort;
  late List<bool> _desc;
  late Set<String> _res;
  late bool _cn;
  late Set<String> _tags;

  @override
  void initState() {
    super.initState();
    _sort = widget.filter.sort;
    _desc = List<bool>.of(widget.filter.desc);
    _res = Set<String>.of(widget.filter.res);
    _cn = widget.filter.cnOnly;
    _tags = Set<String>.of(widget.filter.tags);
  }

  int get _activeCount => _res.length + (_cn ? 1 : 0) + _tags.length;

  @override
  Widget build(BuildContext context) {
    final tags = widget.tagCounts.keys.toList()..sort();
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
                  ...List.generate(mediaSortNames.length, (i) {
                    return _SortRow(
                      name: mediaSortNames[i],
                      active: _sort == i,
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
                    mediaResBuckets.map(
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
                    tags.map(
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
            // 底部操作栏：重置 + 应用筛选
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
                        MediaFilterResult(
                          sort: _sort,
                          desc: _desc,
                          res: _res,
                          cnOnly: _cn,
                          tags: _tags,
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
                        child: const Center(
                          child: Text(
                            '应用筛选',
                            style: TextStyle(
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
            title,
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

/// 「仅看有中文字幕」开关行
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.on, required this.onChanged});

  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withOpacity(0.04),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '仅看有中文字幕',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '简体 / 繁体 / 中字外挂轨均计入',
                  style: TextStyle(fontSize: 10, color: AppColors.muted),
                ),
              ],
            ),
          ),
          Switch(value: on, onChanged: onChanged),
        ],
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
      padding: const EdgeInsets.only(bottom: 7),
      child: LiquidPress(
        onTap: onSelect,
        radius: 14,
        scale: 0.98,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: active
                ? const Color(0x264F8CFF)
                : Colors.white.withOpacity(0.04),
            border: Border.all(
              color: active
                  ? const Color(0x874F8CFF)
                  : Colors.white.withOpacity(0.10),
            ),
          ),
          child: Row(
            children: [
              Text(
                name,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.white : AppColors.muted,
                ),
              ),
              const Spacer(),
              _dirChip('升', active && !desc, () => onDir(false)),
              const SizedBox(width: 6),
              _dirChip('降', active && desc, () => onDir(true)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dirChip(String label, bool on, VoidCallback onTap) {
    return LiquidPress(
      onTap: onTap,
      radius: 11,
      scale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: on ? const Color(0x4D4F8CFF) : Colors.white.withOpacity(0.05),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: on ? Colors.white : AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
