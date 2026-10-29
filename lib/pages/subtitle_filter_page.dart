import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/media_poster.dart';

/// 字幕筛选页：本地筛选含中文字幕的条目（数据来自内存全量 items）
class SubtitleFilterPage extends StatefulWidget {
  const SubtitleFilterPage({
    super.key,
    required this.state,
    required this.onOpenDetail,
    this.chineseOnly = true,
  });

  final AppState state;
  final OpenDetail onOpenDetail;
  final bool chineseOnly;

  @override
  State<SubtitleFilterPage> createState() => _SubtitleFilterPageState();
}

class _SubtitleFilterPageState extends State<SubtitleFilterPage> {
  late List<MediaItem> _items;
  int _sort = 0; // 0 最近添加 1 评分 2 年份

  @override
  void initState() {
    super.initState();
    _compute();
  }

  void _compute() {
    final list = widget.state.items.where(itemHasChineseSubtitle).toList();
    switch (_sort) {
      case 1:
        list.sort((a, b) => b.rating.compareTo(a.rating));
        break;
      case 2:
        list.sort((a, b) => b.year.compareTo(a.year));
        break;
      default:
        list.sort((a, b) => a.addedDaysAgo.compareTo(b.addedDaysAgo));
    }
    _items = list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Row(
                children: [
                  GlassIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    size: 38,
                    iconSize: 15,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.subtitles_rounded,
                              size: 16,
                              color: Color(0xFF9CC2FF),
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              '中文字幕',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '共 ${_items.length} 部 · 来自本地媒体库',
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
            ),
            // 排序
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  _sortChip('最近添加', 0),
                  const SizedBox(width: 8),
                  _sortChip('评分', 1),
                  const SizedBox(width: 8),
                  _sortChip('年份', 2),
                ],
              ),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.subtitles_off_rounded,
                            size: 44,
                            color: AppColors.muted.withOpacity(0.5),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '没有检测到中文字幕',
                            style: TextStyle(
                              fontSize: 13.5,
                              color: AppColors.muted,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '仅统计服务器已入库的字幕轨（外挂/内嵌）',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 11,
                            mainAxisSpacing: 16,
                            childAspectRatio: 0.55,
                          ),
                      itemCount: _items.length,
                      itemBuilder: (c, i) => PosterCard(
                        item: _items[i],
                        width: double.infinity,
                        heroTag: 'subs-${_items[i].id}',
                        onTap: () => widget.onOpenDetail(
                          _items[i],
                          heroTag: 'subs-${_items[i].id}',
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sortChip(String label, int idx) {
    final on = _sort == idx;
    return LiquidPress(
      radius: 999,
      scale: 0.95,
      onTap: () => setState(() {
        _sort = idx;
        _compute();
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: on
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x3D4F8CFF), Color(0x1A5F8CFF)],
                )
              : null,
          color: on ? null : Colors.white.withOpacity(0.05),
          border: Border.all(
            color: on
                ? const Color(0x884F8CFF)
                : Colors.white.withOpacity(0.12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            color: on ? const Color(0xFFCFE0FF) : AppColors.muted,
          ),
        ),
      ),
    );
  }
}
