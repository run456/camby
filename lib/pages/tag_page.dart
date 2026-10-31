import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/media_poster.dart';
import '../widgets/sort_chip_row.dart';

/// 标签筛选页：列出包含该标签（或分辨率）的影片
///
/// v1.7.72：与「中文字幕」页统一——同款 年份/标题/评分 排序胶囊，
/// 点选倒序、再点同字段切正序。
class TagPage extends StatefulWidget {
  const TagPage({
    super.key,
    required this.tag,
    required this.state,
    required this.onOpenDetail,
  });

  final String tag;
  final AppState state;
  final OpenDetail onOpenDetail;

  @override
  State<TagPage> createState() => _TagPageState();
}

class _TagPageState extends State<TagPage> {
  SortField _field = SortField.year;
  bool _asc = false; // 默认倒序（新年份在前）

  static final RegExp _res = RegExp(r'^(2160|1080|720|480|360)[pP]$');

  List<MediaItem> get _items {
    final tag = widget.tag;
    final key = tag.trim().toUpperCase();
    final isRes = _res.hasMatch(tag.trim());
    final list = widget.state.items.where((e) {
      if (isRes) {
        if (!e.resolutionKnown) return false;
        final r = e.isTrue4K ? '2160P' : '${e.videoHeight}P';
        return r == key;
      }
      // 标签/类型比较统一去空格 + 忽略大小写，避免 NFO 里多余空格导致查不到
      bool hit(String v) => v.trim().toUpperCase() == key;
      return e.tags.any(hit) || e.genres.any(hit);
    }).toList();
    sortItemsBy(list, _field, _asc);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(14, top + 8, 16, 8),
            child: Row(
              children: [
                LiquidPress(
                  onTap: () => Navigator.of(context).pop(),
                  radius: 19,
                  semanticLabel: '返回',
                  child: ClipOval(
                    // 真磨砂玻璃：与各页顶栏圆钮统一
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withOpacity(0.20),
                              Colors.white.withOpacity(0.06),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.24),
                          ),
                        ),
                        child: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '#${widget.tag}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${items.length} 部',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
          SortChipRow(
            field: _field,
            ascending: _asc,
            onChanged: (f, asc) => setState(() {
              _field = f;
              _asc = asc;
            }),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      '没有相关影片',
                      style: TextStyle(fontSize: 13, color: AppColors.muted),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 11,
                          mainAxisSpacing: 16,
                          childAspectRatio: 0.53,
                        ),
                    itemCount: items.length,
                    itemBuilder: (c, i) => PosterCard(
                      item: items[i],
                      width: double.infinity,
                      heroTag: 'tag-${widget.tag}-${items[i].id}',
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.onOpenDetail(
                          items[i],
                          heroTag: 'tag-${widget.tag}-${items[i].id}',
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
