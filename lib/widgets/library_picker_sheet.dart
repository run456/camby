import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'cached_image.dart';
import 'liquid_press.dart';

/// 媒体库选择弹窗（v2.0.97 · 设计稿 P0）。
///
/// 为什么要换掉横滑 chip：库一多就成了一条没有尽头的横滑带 —— 看不到总数、
/// 不知道划到哪、想找第 8 个库要反复来回甩，选中的 chip 还会被滑出视野。
/// 这里按设计稿落成「2 列分类弹窗」：
///  · 顶部：标题「我的媒体」+「共 N 个」+ 关闭；
///  · 首行跨 2 列：「全部影片」大卡，永远排第一；
///  · 虚拟库区：最近添加 / 继续观看，虚线边框 + 时钟 / 播放图标；
///  · 真实库区：2 列铺开，左侧库名 + 数量，右侧 3 张海报倾斜拼贴；
///  · 库数 > 12 时顶部出现搜索框，按名称实时过滤。
///
/// **零新增请求**：v2.0.103 起优先用调用方传入的 [posters]（来自
/// `AppState.viewPosterUrls()`，复用首页按库预览缓存里「最近入库」的影片），
/// 没有再退回本地按 `parentId` 匹配；取不到才用「库名首字 + 双色渐变」兜底。
/// 这样做是因为标准 Emby 的条目 ParentId 常指向库内文件夹而非 UserView，
/// 旧版因此全部退化成「本 / 在」这样的首字卡片。同一个库永远同一个主色。
Future<LibraryPick?> showLibraryPickerSheet(
  BuildContext context, {
  required List<LibraryView> views,
  required List<MediaItem> items,
  required String? selectedId,
  required int recentCount,
  required int continueCount,
  Map<String, List<String>> posters = const {},
  Map<String, int> counts = const {},
}) {
  return showModalBottomSheet<LibraryPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => _LibraryPickerSheet(
      views: views,
      items: items,
      selectedId: selectedId,
      recentCount: recentCount,
      continueCount: continueCount,
      posters: posters,
      counts: counts,
    ),
  );
}

/// 选择结果。[viewId] 为 null 表示「全部影片」。
class LibraryPick {
  const LibraryPick(this.viewId);
  final String? viewId;
}

/// 库名 → 主色（按名字哈希，稳定不变）。
///
/// 设计稿给的是一组「内容型」配色：电影灰绿 / 电视深灰 / 综艺蓝 / 纪实银 /
/// 国产蓝灰 / 欧美棕 / 日韩墨绿。这里不猜语义（库名里未必有类型词），
/// 只保证「同名同色、不同名尽量不同色」。
const List<List<Color>> _kViewAccents = [
  [Color(0xFF3F6B5E), Color(0xFF1F3B34)], // 灰绿
  [Color(0xFF4A5568), Color(0xFF232B38)], // 深灰
  [Color(0xFF3C5FA8), Color(0xFF1E2F58)], // 综艺蓝
  [Color(0xFF6B7280), Color(0xFF343A45)], // 纪实银
  [Color(0xFF46648C), Color(0xFF243449)], // 国产蓝灰
  [Color(0xFF7A5A3A), Color(0xFF3D2C1C)], // 欧美棕
  [Color(0xFF2F6B5A), Color(0xFF163329)], // 日韩墨绿
];

List<Color> viewAccent(String name) {
  var h = 0;
  for (final c in name.runes) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _kViewAccents[h % _kViewAccents.length];
}

/// 库里前 N 张海报（已缓存地址优先）。零请求，纯本地过滤。
List<String> posterPreviews(
  List<MediaItem> items,
  String viewId, {
  int limit = 3,
}) {
  final out = <String>[];
  for (final e in items) {
    if (e.parentId != viewId) continue;
    final u = e.posterUrl;
    if (u == null || u.isEmpty) continue;
    out.add(u);
    if (out.length >= limit) break;
  }
  return out;
}

/// 每个库的条目数（本地过滤，未加载到的库返回 0）。
int viewItemCount(List<MediaItem> items, String viewId) {
  var n = 0;
  for (final e in items) {
    if (e.parentId == viewId) n++;
  }
  return n;
}

class _LibraryPickerSheet extends StatefulWidget {
  const _LibraryPickerSheet({
    required this.views,
    required this.items,
    required this.selectedId,
    required this.recentCount,
    required this.continueCount,
    required this.posters,
    required this.counts,
  });

  final List<LibraryView> views;
  final List<MediaItem> items;
  final String? selectedId;
  final int recentCount;
  final int continueCount;

  /// viewId → 该库最近影片的海报 URL（父级预热后传入）。
  final Map<String, List<String>> posters;

  /// viewId → 该库条目数（只报真实数，0 时卡片显示「—」）。
  final Map<String, int> counts;

  @override
  State<_LibraryPickerSheet> createState() => _LibraryPickerSheetState();
}

class _LibraryPickerSheetState extends State<_LibraryPickerSheet> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<LibraryView> get _filtered {
    if (_q.trim().isEmpty) return widget.views;
    final q = _q.trim().toLowerCase();
    return widget.views.where((v) => v.name.toLowerCase().contains(q)).toList();
  }

  void _pick(String? id) => Navigator.pop(context, LibraryPick(id));

  @override
  Widget build(BuildContext context) {
    final views = _filtered;
    final total = widget.views.length + 2; // 含两个虚拟库
    return FractionallySizedBox(
      // 设计稿：弹窗占屏 88%
      heightFactor: 0.88,
      child: Glass(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        radius: 26,
        blur: 26,
        tint: 0.14,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            // 拖动条
            Padding(
              padding: const EdgeInsets.only(top: 9, bottom: 4),
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: AppColors.w.withValues(alpha: 0.22),
                ),
              ),
            ),
            // 头部
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 10, 2),
              child: Row(
                children: [
                  Text(
                    '我的媒体',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '共 $total 个 · ${widget.views.length} 个服务器库',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  GlassIconButton(
                    icon: Icons.close_rounded,
                    size: 34,
                    iconSize: 16,
                    onTap: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // 搜索：库多到一屏放不下时才有意义
            if (widget.views.length > 12)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppColors.w.withValues(alpha: 0.06),
                    border: Border.all(
                      color: AppColors.w.withValues(alpha: 0.10),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _search,
                          onChanged: (v) => setState(() => _q = v),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.ink,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: '搜索媒体库',
                            hintStyle: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (c, cons) {
                  const pad = 16.0;
                  const gap = 10.0;
                  final cardW = (cons.maxWidth - pad * 2 - gap) / 2;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(pad, 10, pad, 22),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      // 全部影片：跨 2 列，永远第一
                      _AllCard(
                        count: widget.items.length,
                        selected: widget.selectedId == null,
                        onTap: () => _pick(null),
                      ),
                      const _SectionLabel('虚拟媒体库', hint: 'Camby 生成'),
                      Row(
                        children: [
                          SizedBox(
                            width: cardW,
                            child: _ViewCard(
                              name: '最近添加',
                              count: widget.recentCount,
                              icon: Icons.schedule_rounded,
                              virtual: true,
                              selected: widget.selectedId == kRecentViewId,
                              onTap: () => _pick(kRecentViewId),
                            ),
                          ),
                          const SizedBox(width: gap),
                          SizedBox(
                            width: cardW,
                            child: _ViewCard(
                              name: '继续观看',
                              count: widget.continueCount,
                              icon: Icons.play_circle_outline_rounded,
                              virtual: true,
                              selected: widget.selectedId == kContinueViewId,
                              onTap: () => _pick(kContinueViewId),
                            ),
                          ),
                        ],
                      ),
                      if (widget.views.isNotEmpty) ...[
                        const _SectionLabel('服务器媒体库', hint: 'Emby / 绿联'),
                        Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final v in views)
                              SizedBox(
                                width: cardW,
                                child: _ViewCard(
                                  name: v.name,
                                  count:
                                      widget.counts[v.id] ??
                                      viewItemCount(widget.items, v.id),
                                  previews:
                                      widget.posters[v.id] ??
                                      posterPreviews(widget.items, v.id),
                                  accent: viewAccent(v.name),
                                  selected: widget.selectedId == v.id,
                                  onTap: () => _pick(v.id),
                                ),
                              ),
                          ],
                        ),
                        if (views.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '没有匹配「$_q」的媒体库',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                      ],
                    ],
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.hint});
  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.ink,
              letterSpacing: 0.2,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 7),
            Text(
              hint!,
              style: TextStyle(
                fontSize: 10,
                color: AppColors.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「全部影片」大卡：跨 2 列，横版。
class _AllCard extends StatelessWidget {
  const _AllCard({
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      radius: 16,
      scale: 0.985,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: selected
                ? const [Color(0x4D4F8CFF), Color(0x337B5CFF)]
                : const [Color(0x1FFFFFFF), Color(0x0DFFFFFF)],
          ),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.55)
                : AppColors.w.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                gradient: AppColors.ctaGradient,
              ),
              child: const Icon(
                Icons.grid_view_rounded,
                size: 19,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '全部影片',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count 部 · 跨所有媒体库',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const Spacer(),
            if (selected)
              Icon(
                Icons.check_circle_rounded,
                size: 19,
                color: AppColors.accent,
              ),
          ],
        ),
      ),
    );
  }
}

/// 分类卡：左侧库名 + 数量，右侧 3 张倾斜海报（或渐变兜底）。
class _ViewCard extends StatelessWidget {
  const _ViewCard({
    required this.name,
    required this.count,
    required this.selected,
    required this.onTap,
    this.icon,
    this.virtual = false,
    this.previews = const [],
    this.accent,
  });

  final String name;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// 虚拟库：虚线边框 + 图标，明确区别于服务器库。
  final bool virtual;
  final List<String> previews;
  final List<Color>? accent;

  @override
  Widget build(BuildContext context) {
    final colors = accent ?? viewAccent(name);
    return LiquidPress(
      radius: 16,
      scale: 0.97,
      onTap: onTap,
      child: Container(
        height: 96,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(colors[0], Colors.white, 0.06)!, colors[1]],
          ),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.75)
                : AppColors.w.withValues(alpha: virtual ? 0.16 : 0.10),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    count > 0 ? '$count 部' : '—',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.w.withValues(alpha: 0.66),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // 右侧内容区：虚拟库给图标，真实库给海报拼贴
            SizedBox(
              width: 56,
              height: 74,
              child: virtual
                  ? Center(
                      child: Icon(
                        icon ?? Icons.folder_outlined,
                        size: 26,
                        color: AppColors.w.withValues(alpha: 0.82),
                      ),
                    )
                  : _Collage(previews: previews, name: name, colors: colors),
            ),
          ],
        ),
      ),
    );
  }
}

/// v2.0.103：右侧「图标」换成该库最近影片的一张完整海报。
///
/// 旧实现是 3 张 34×60 小图倾斜叠放 —— 互相遮挡、上下裁切，而且只要
/// parentId 匹配不上就直接退化成「本 / 在」这类库名首字。现在按 2:3
/// 原生比例铺一张，不旋转不裁切；contain 留出的边用该库主色填充。
class _Collage extends StatelessWidget {
  const _Collage({
    required this.previews,
    required this.name,
    required this.colors,
  });

  final List<String> previews;
  final String name;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    if (previews.isEmpty) {
      return Center(
        child: Text(
          name.isEmpty ? '?' : name.substring(0, 1),
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            color: AppColors.w.withValues(alpha: 0.42),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 72,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colors[0], colors[1]],
            ),
          ),
          child: CachedImage(
            url: previews.first,
            fit: BoxFit.contain,
            memWidth: 240,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }
}
