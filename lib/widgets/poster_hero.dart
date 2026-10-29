import 'package:flutter/material.dart';

import 'cached_image.dart';

/// 封面共享元素：卡片 → 详情页头图的「就地放大」转场
///
/// 用自定义 flightShuttle 而不是默认 Hero：
/// 默认会在飞行中直接拉伸目标 child（圆角、渐隐蒙版都会跟着变形），
/// 这里改为「等尺寸裁切 + 圆角插值」，观感与 Yamby 一致。
class PosterHero extends StatelessWidget {
  const PosterHero({
    super.key,
    required this.tag,
    required this.url,
    required this.child,
    this.fromRadius = 14,
    this.memWidth = 900,
  });

  final String tag;
  final String? url;
  final Widget child;

  /// 源卡片的圆角（详情页目标固定 0）
  final double fromRadius;
  final int memWidth;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: tag,
      transitionOnUserGestures: true,
      flightShuttleBuilder: (ctx, anim, direction, fromCtx, toCtx) {
        final r = Tween<double>(
          begin: fromRadius,
          end: 0,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return AnimatedBuilder(
          animation: r,
          builder: (_, __) => ClipRRect(
            borderRadius: BorderRadius.circular(r.value),
            child: url == null
                ? const ColoredBox(color: Color(0xFF121826))
                : CachedImage(url: url, fit: BoxFit.cover, memWidth: memWidth),
          ),
        );
      },
      child: child,
    );
  }
}
