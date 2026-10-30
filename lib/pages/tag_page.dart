import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/media_poster.dart';

/// 标签筛选页：列出包含该标签（或分辨率）的影片
class TagPage extends StatelessWidget {
  const TagPage({
    super.key,
    required this.tag,
    required this.state,
    required this.onOpenDetail,
  });

  final String tag;
  final AppState state;
  final OpenDetail onOpenDetail;

  static final RegExp _res = RegExp(r'^(2160|1080|720|480|360)[pP]$');

  List<MediaItem> get _items {
    final key = tag.trim().toUpperCase();
    final isRes = _res.hasMatch(tag.trim());
    return state.items.where((e) {
      if (isRes) {
        if (!e.resolutionKnown) return false;
        final r = e.isTrue4K ? '2160P' : '${e.videoHeight}P';
        return r == key;
      }
      // 标签/类型比较统一去空格 + 忽略大小写，避免 NFO 里多余空格导致查不到
      bool hit(String v) => v.trim().toUpperCase() == key;
      return e.tags.any(hit) || e.genres.any(hit);
    }).toList();
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
                    '#$tag',
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
                      heroTag: 'tag-${tag}-${items[i].id}',
                      onTap: () {
                        Navigator.of(context).pop();
                        onOpenDetail(
                          items[i],
                          heroTag: 'tag-${tag}-${items[i].id}',
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
