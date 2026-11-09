library;

import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';

/// 质感包 · 内容形状骨架（v2.0.64）
///
/// 设计约束（见《质感包前后对比稿》06 实现规格）：
///  · 纯 `LinearGradient`，不引入任何实时模糊 / 滤镜组件（静态浮层才用）；
///  · 扫光由 [ShimmerScope] 用**单个** AnimationController 在父级画一层，
///    不给每张卡片各建一个控制器，也不让卡片子树跟着每帧重建；
///  · 与 `PosterBox` 共用圆角档位 [AppRadii.md]，不另起一套视觉语言；
///  · 图片加载中的单张占位用静态渐变（零动画），整页 / 切库首屏才挂扫光。

/// 一块低饱和渐变骨架。尺寸由调用方给定（或放在 Positioned.fill 里）。
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = AppRadii.md,
    this.label,
    this.gradient,
  });

  final double? width;
  final double? height;
  final double radius;
  final Gradient? gradient;

  /// 失败保底：图片 404 时在骨架上显示片名，卡片仍可点开详情。
  final String? label;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: gradient ?? SkeletonColors.gradient,
        ),
        child: SizedBox(
          width: width,
          height: height,
          child: label == null
              ? null
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      label!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0x99C3D3EE),
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 海报卡片骨架：海报形状 + 标题条 + 年份条，按真实版式占位。
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key, this.radius = AppRadii.md});

  final double radius;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 海报区吃掉剩余高度，而不是按宽度反推 1:1.45 —— 后者在矮卡片
        // （详情页分集骨架 height=150）里会向下溢出近 100px。
        Expanded(
          child: SizedBox.expand(
            child: SkeletonBox(radius: radius),
          ),
        ),
        const SizedBox(height: 6),
        FractionallySizedBox(
          widthFactor: 0.92,
          child: SkeletonBox(
            height: 9,
            radius: AppRadii.sm,
            gradient: SkeletonColors.bar,
          ),
        ),
        const SizedBox(height: 5),
        FractionallySizedBox(
          widthFactor: 0.48,
          child: SkeletonBox(
            height: 7,
            radius: AppRadii.sm,
            gradient: SkeletonColors.bar,
          ),
        ),
      ],
    );
  }
}

/// 单个父级驱动的低速扫光。
///
/// [child] 是同一个 widget 实例，AnimatedBuilder 只重建扫光层；
/// 卡片子树不会跟着每帧 rebuild。整体再包 RepaintBoundary 隔离重绘。
class ShimmerScope extends StatefulWidget {
  const ShimmerScope({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  State<ShimmerScope> createState() => _ShimmerScopeState();
}

class _ShimmerScopeState extends State<ShimmerScope>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _syncController();
  }

  @override
  void didUpdateWidget(ShimmerScope old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled) _syncController();
  }

  void _syncController() {
    if (widget.enabled && _controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: AppMotion.shimmer,
      )..repeat();
    } else if (!widget.enabled && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return RepaintBoundary(child: widget.child);
    return RepaintBoundary(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, cons) {
            final w = cons.maxWidth.isFinite ? cons.maxWidth : 400.0;
            const band = 0.42;
            return Stack(
              children: [
                widget.child,
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: c,
                      builder: (_, __) {
                        final left = -w * band + c.value * w * (1 + band * 2);
                        return Stack(
                          children: [
                            Positioned(
                              left: left,
                              top: 0,
                              bottom: 0,
                              width: w * band,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [
                                      Colors.transparent,
                                      Color(0x0DFFFFFF),
                                      Color(0x14FFFFFF),
                                      Color(0x0DFFFFFF),
                                      Colors.transparent,
                                    ],
                                    stops: [0.0, 0.35, 0.5, 0.65, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 媒体库 / 收藏网格首屏骨架（9 张带形状的卡片）。
///
/// 必须放在**有界高度**的盒子里（例如 `SizedBox(height: 480)`），
/// 因为 GridView.builder 不能直接在 SliverToBoxAdapter 里取无限高。
class LibrarySkeleton extends StatelessWidget {
  const LibrarySkeleton({
    super.key,
    this.itemCount = 9,
    this.shimmer = true,
  });

  final int itemCount;
  final bool shimmer;

  @override
  Widget build(BuildContext context) {
    return ShimmerScope(
      enabled: shimmer,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          // 列数继续走断点，平板不会被拉成超大卡片。
          crossAxisCount: context.mediaGridColumns,
          crossAxisSpacing: 10,
          mainAxisSpacing: 14,
          childAspectRatio: 0.55,
        ),
        itemCount: itemCount,
        itemBuilder: (_, __) => const SkeletonCard(),
      ),
    );
  }
}

/// 横向列表骨架：首页媒体库行 / 详情页分集与推荐首帧。
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({
    super.key,
    this.itemCount = 4,
    this.cardWidth = 104,
    this.height = 190,
    this.shimmer = true,
  });

  final int itemCount;
  final double cardWidth;
  final double height;
  final bool shimmer;

  @override
  Widget build(BuildContext context) {
    return ShimmerScope(
      enabled: shimmer,
      child: SizedBox(
        height: height,
        // 固定数量的静态占位：用 children 而不是 builder，
        // 既不给滚动路径加 itemBuilder，也不会被「横向 3 项 = 混排」的
        // 详情页回归守卫误判成一个真实内容行。
        child: ListView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (var i = 0; i < itemCount; i++)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: SizedBox(width: cardWidth, child: const SkeletonCard()),
              ),
          ],
        ),
      ),
    );
  }
}
