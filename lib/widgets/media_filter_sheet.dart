import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'liquid_press.dart';

/// 媒体库 / 演员页 / 收藏夹共用的「排序与筛选」能力
///
/// 三处版式与交互必须一致（排序字段行 × 升/降 + 年代 chips +
/// 底部 重置 / 应用筛选），所以抽成公共文件：
/// - `showMediaFilterSheet`：弹出抽屉，返回 `(sortKey, desc, decade)`
/// - `filterByDecade` / `sortMedia`：纯函数，页面各自拼装筛选结果
const mediaSortNames = ['发行日期', '评分', '标题'];

/// 年代档位：0 不限 / 1 近 3 年 / 2 近 10 年 / 3 更早
const mediaDecadeNames = ['不限', '近 3 年', '近 10 年', '更早'];

/// 弹窗上方「共 N 项」：按草稿年代档位实时算，不依赖已应用的筛选
int countForDecade(Iterable<MediaItem> items, int decade) {
  final now = DateTime.now().year;
  return items.where((e) {
    final y = e.year;
    if (y <= 0) return true; // 没有年份信息不过滤
    return matchDecade(y, decade, now);
  }).length;
}

bool matchDecade(int year, int decade, int now) => switch (decade) {
  1 => now - year <= 3,
  2 => now - year <= 10,
  3 => now - year > 10,
  _ => true,
};

/// 按年代筛选 + 排序（纯函数，返回新列表）
List<MediaItem> applyMediaFilter(
  Iterable<MediaItem> items, {
  required int sortKey,
  required bool desc,
  required int decade,
}) {
  final now = DateTime.now().year;
  final kept = items.where((e) {
    final y = e.year;
    if (y <= 0) return true;
    return matchDecade(y, decade, now);
  }).toList();
  int cmp(MediaItem a, MediaItem b) => switch (sortKey) {
    1 => a.rating.compareTo(b.rating),
    2 => a.name.compareTo(b.name),
    _ => a.year.compareTo(b.year),
  };
  kept.sort(desc ? (a, b) => cmp(b, a) : cmp);
  return kept;
}

/// 当前筛选的简短摘要（显示在筛选按钮上）
String mediaFilterSummary(int sortKey, bool desc, int decade) {
  final parts = <String>[
    if (decade != 0) mediaDecadeNames[decade],
    '${mediaSortNames[sortKey]}${desc ? '↓' : '↑'}',
  ];
  return parts.isEmpty ? '筛选' : parts.join('·');
}

/// 弹出排序与筛选抽屉，返回 `(sortKey, desc, decade)`；取消返回 null
Future<(int, bool, int)?> showMediaFilterSheet(
  BuildContext context, {
  required int sortKey,
  required bool desc,
  required int decade,
  required int total,
}) {
  return showModalBottomSheet<(int, bool, int)>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _MediaFilterSheet(
      sortKey: sortKey,
      desc: desc,
      decade: decade,
      total: total,
    ),
  );
}

/// 草稿态在内部编辑，点「应用筛选」才提交
class _MediaFilterSheet extends StatefulWidget {
  const _MediaFilterSheet({
    required this.sortKey,
    required this.desc,
    required this.decade,
    required this.total,
  });

  final int sortKey;
  final bool desc;
  final int decade;
  final int total;

  @override
  State<_MediaFilterSheet> createState() => _MediaFilterSheetState();
}

class _MediaFilterSheetState extends State<_MediaFilterSheet> {
  late int _sortKey;
  late bool _desc;
  late int _decade;

  @override
  void initState() {
    super.initState();
    _sortKey = widget.sortKey;
    _desc = widget.desc;
    _decade = widget.decade;
  }

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
                    '共 ${widget.total} 项 · 已选 ${_decade == 0 ? 0 : 1} 个条件',
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
                    final on = _sortKey == i;
                    return _SortRow(
                      name: mediaSortNames[i],
                      active: on,
                      desc: _desc,
                      onSelect: () => setState(() => _sortKey = i),
                      onDir: (v) => setState(() {
                        _desc = v;
                        _sortKey = i;
                      }),
                    );
                  }),
                  _sectionTitle('年代', '单选'),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (var i = 0; i < mediaDecadeNames.length; i++)
                        _chip(
                          mediaDecadeNames[i],
                          on: _decade == i,
                          onTap: () => setState(() => _decade = i),
                        ),
                    ],
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
                      _decade = 0;
                      _sortKey = 0;
                      _desc = true;
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
                      onTap: () =>
                          Navigator.pop(context, (_sortKey, _desc, _decade)),
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

  Widget _chip(String label, {required bool on, required VoidCallback onTap}) {
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
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: on ? const Color(0xFFCFE0FF) : AppColors.muted,
            ),
          ),
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
