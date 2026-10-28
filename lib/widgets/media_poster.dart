import 'package:flutter/material.dart';

import '../models.dart';
import 'cached_image.dart';
import 'poster_hero.dart';
import '../theme.dart';

/// 海报 / 剧照：有真实图片地址时加载网络图，否则渲染渐变占位
class MediaPoster extends StatelessWidget {
  const MediaPoster({
    super.key,
    required this.item,
    this.height = 150,
    this.radius = 14,
    this.width,
    this.showTitle = true,
    this.backdrop = false,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  final MediaItem item;
  final double height;
  final double radius;
  final double? width;
  final bool showTitle;
  final bool backdrop;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = backdrop ? item.backdropUrl : item.posterUrl;
    final br = borderRadius ?? BorderRadius.circular(radius);

    return ClipRRect(
      borderRadius: br,
      child: LayoutBuilder(
        builder: (c, cons) {
          final w = width ?? (cons.maxWidth.isFinite ? cons.maxWidth : 400);
          final dpr = MediaQuery.of(context).devicePixelRatio;
          // 按「逻辑宽度 × 屏幕像素比」解码，避免高 DPI 屏幕上缩略图发虚
          final cacheW = (w * dpr).clamp(160, 1200).round();
          return SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: item.colors,
                      ),
                    ),
                  ),
                ),
                if (url != null)
                  Positioned.fill(
                    child: CachedImage(
                      url: url,
                      fit: fit,
                      memWidth: cacheW,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                if (showTitle)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: height * 0.5,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.55),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (showTitle)
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 统一的海报卡片：今日推荐 / 继续观看 / 最近添加共用，保证样式一致
class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.item,
    this.width = 104,
    this.onTap,
    this.showReason = false,
    this.showProgress = false,
    this.showResBadge = false,
    this.showCnBadge = false,
    this.heroTag,
  });

  final MediaItem item;
  final double width;
  final VoidCallback? onTap;
  final bool showReason;
  final bool showProgress;

  /// 左上角显示分辨率（媒体库筛选场景用，替代默认 4K 金标）
  final bool showResBadge;

  /// 右上角显示「中字」绿标（有中文字幕轨时）
  final bool showCnBadge;

  /// 传入后启用「封面 → 详情」共享元素放大（同一屏需保证 tag 唯一）
  final String? heroTag;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _down = false;

  void _setDown(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final progress = widget.showProgress ? item.resumeProgress : null;
    // 网格滚动时避免每张卡片的渐变/角标/进度条反复重绘
    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        child: AnimatedScale(
          scale: _down ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: SizedBox(
            width: widget.width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (c, cons) {
                    final w = cons.maxWidth.isFinite
                        ? cons.maxWidth
                        : (widget.width.isFinite ? widget.width : 104.0);
                    final poster = MediaPoster(
                      item: item,
                      height: w * 1.45,
                      showTitle: false,
                    );
                    return Stack(
                      children: [
                        if (widget.heroTag != null)
                          PosterHero(
                            tag: widget.heroTag!,
                            url: item.posterUrl,
                            memWidth: 900,
                            child: poster,
                          )
                        else
                          poster,
                        if (widget.showResBadge &&
                            item.resolutionKnown &&
                            item.videoHeight > 0)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: ChipLabel(
                              resolutionBucket(item),
                              small: true,
                            ),
                          )
                        else if (item.isTrue4K)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: ChipLabel('4K', small: true, gold: true),
                          ),
                        if (widget.showCnBadge && itemHasChineseSubtitle(item))
                          Positioned(
                            top: 6,
                            right: 6,
                            child: ChipLabel('中字', small: true, cyan: true),
                          ),
                        if (progress != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
                              backgroundColor: Colors.white.withOpacity(0.18),
                              valueColor: const AlwaysStoppedAnimation(
                                AppColors.accent,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE2EAF8),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (item.rating > 0) ...[
                      const Icon(
                        Icons.star_rounded,
                        size: 11,
                        color: AppColors.warn,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        item.rating.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.warn,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (item.year > 0)
                      Text(
                        '${item.year}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.muted,
                        ),
                      ),
                    const Spacer(),
                    if (progress != null)
                      Text(
                        '剩 ${(item.runtimeMin * (1 - progress)).round()} 分钟',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.muted,
                        ),
                      ),
                  ],
                ),
                if (widget.showReason && item.reason != null)
                  Container(
                    margin: const EdgeInsets.only(top: 3),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x1F38E8C8),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0x4038E8C8)),
                    ),
                    child: Text(
                      item.reason!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
