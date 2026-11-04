import 'package:flutter/material.dart';
import 'package:inspire_blur/inspire_blur.dart';

import '../theme.dart';

/// 底部渐进模糊带：状态栏的镜像版——**底部最强、向上连续衰减到 0**，无硬边。
///
/// 用于详情页底部常驻播放区：列表内容从按钮下方穿过时被逐渐糊开，
/// 按钮自身只做液态玻璃高光，不再各自叠 BackdropFilter（避免双层模糊发灰）。
class BottomBarBlur extends StatefulWidget {
  const BottomBarBlur({
    super.key,
    required this.height,
    required this.active,
    this.sigma = 30,
    this.degraded = false,
  });

  /// 模糊带总高度（按按钮区高度再往上留一段过渡）。
  final double height;

  /// 是否需要模糊（false 时完全透明、不渲染，省 GPU）。
  final bool active;

  /// 底部最大模糊强度。
  final double sigma;

  /// 滚动降级（见 [StatusBarBlur.degraded]）。
  final bool degraded;

  @override
  State<BottomBarBlur> createState() => _BottomBarBlurState();
}

class _BottomBarBlurState extends State<BottomBarBlur>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: widget.active ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant BottomBarBlur oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      widget.active ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 滚动降级：纯渐变顶替，不碰 BackdropFilter（见 widget.degraded 注释）
    if (widget.degraded) {
      return SizedBox(
        height: widget.height,
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  AppColors.bg.withValues(alpha: 0.82),
                  AppColors.bg.withValues(alpha: 0.45),
                  AppColors.bg.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_c.value);
        if (t <= 0.001) return SizedBox(height: widget.height);
        return SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              // 模糊强度从下到上连续衰减到 0，没有硬边
              Positioned.fill(
                child: RepaintBoundary(
                  child: Inspire.backdropBlur(
                    config: InspireBlurConfig.bottomToTop(
                      sigma: widget.sigma * t,
                      extent: 1.0,
                      fadeCurve: Curves.easeInSine,
                    ),
                  ),
                ),
              ),
              // 极轻压暗，保证按钮与文字可读
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        AppColors.bg.withOpacity(0.42 * t),
                        AppColors.bg.withOpacity(0.14 * t),
                        AppColors.bg.withOpacity(0.0),
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 顶部状态栏渐进模糊：默认完全透明，页面上滑后才淡入。
///
/// 使用 inspire_blur 的 GPU 着色器让模糊强度随位置**连续衰减**到 0，
/// 不会像多层 BackdropFilter 那样在边界留下硬线。
class StatusBarBlur extends StatefulWidget {
  const StatusBarBlur({
    super.key,
    required this.height,
    required this.active,
    this.sigma = 30,
    this.degraded = false,
  });

  /// 模糊带总高度（一般取状态栏高度 + 一段过渡）。
  final double height;

  /// 是否已经上滑（false 时完全透明、不渲染模糊）。
  final bool active;

  /// **滚动降级开关**（性能关键）。
  ///
  /// 为 true 时不渲染 `BackdropFilter`，改用同色半透明渐变。
  ///
  /// 原因：`BackdropFilter` 每帧都要把**整块滚动内容**重新采样 + 跑模糊
  /// 着色器。详情页滚动时上下两条模糊带各跑一遍，中端机直接从 60fps 掉到
  /// 30fps 左右（媒体库页没有常驻模糊，所以丝滑）。
  ///
  /// 策略：滚动开始 → true（立刻换成纯渐变，零 GPU 开销）；
  /// 滚动停止 180ms → false（淡回真模糊）。静止时液态玻璃一点不少。
  final bool degraded;

  /// 顶部最大模糊强度。
  final double sigma;

  @override
  State<StatusBarBlur> createState() => _StatusBarBlurState();
}

class _StatusBarBlurState extends State<StatusBarBlur>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: widget.active ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant StatusBarBlur oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      widget.active ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 滚动降级：纯渐变顶替，不碰 BackdropFilter（见 widget.degraded 注释）
    if (widget.degraded) {
      return SizedBox(
        height: widget.height,
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.bg.withValues(alpha: 0.78),
                  AppColors.bg.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_c.value);
        if (t <= 0.001) return SizedBox(height: widget.height);
        return SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              // 模糊强度从上到下连续衰减到 0，没有硬边
              Positioned.fill(
                child: RepaintBoundary(
                  child: Inspire.backdropBlur(
                    config: InspireBlurConfig.topToBottom(
                      sigma: widget.sigma * t,
                      extent: 1.0,
                      fadeCurve: Curves.easeInSine,
                    ),
                  ),
                ),
              ),
              // 极轻压暗，保证状态栏图标可读
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.bg.withOpacity(0.18 * t),
                        AppColors.bg.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
