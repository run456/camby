import 'package:flutter/material.dart';

import '../theme.dart';

/// 液态玻璃按下态
///
/// 玻璃材质被按压时的物理表现：轻微下沉（被压薄）+ 内部散射增强（变亮）
/// + 手指位置出现镜面光晕（折射焦点）+ 边缘高光加亮（玻璃厚度被挤压）。
///
/// 用法：把原本的 `GestureDetector(onTap: ..., child: 按钮)` 换成
/// `LiquidPress(onTap: ..., radius: 圆角, child: 按钮)`。
class LiquidPress extends StatefulWidget {
  const LiquidPress({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.radius = 999,
    this.borderRadius,
    this.scale = 0.955,
    this.enabled = true,
    this.glow = 0.30,
    this.tint = 0.20,
    this.duration = const Duration(milliseconds: 90),
    this.behavior = HitTestBehavior.opaque,
    this.semanticLabel,
    this.shadows,
    this.clip = true,
  });

  /// 按钮本体（不再自己包 GestureDetector）
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 高光裁剪圆角（与按钮外形一致，才不会有直角溢出）
  final double radius;
  final BorderRadius? borderRadius;

  /// 按下缩放：0.955 适合常规按钮，0.97 适合大卡
  final double scale;
  final bool enabled;

  /// 手指处的光晕强度 / 整片玻璃的提亮强度
  final double glow;
  final double tint;
  final Duration duration;
  final HitTestBehavior behavior;
  final String? semanticLabel;

  /// 外阴影（放在裁剪层之外，否则会被 ClipRRect 切掉）
  final List<BoxShadow>? shadows;

  /// 是否把子内容裁进圆角。默认 true（按钮类）；
  /// 子内容需要探出边界（如收藏页海报堆叠墙的后层卡）时传 false —— 
  /// 按下高光层自带圆角装饰，不裁也不会溢出。
  final bool clip;

  @override
  State<LiquidPress> createState() => _LiquidPressState();
}

class _LiquidPressState extends State<LiquidPress> {
  bool _down = false;
  Alignment _focus = Alignment.center;

  bool get _on => _down && widget.enabled;

  void _downAt(TapDownDetails d) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0) {
      final local = box.globalToLocal(d.globalPosition);
      _focus = Alignment(
        ((local.dx / (box.size.width / 2)) - 1).clamp(-1.0, 1.0),
        ((local.dy / (box.size.height / 2)) - 1).clamp(-1.0, 1.0),
      );
    }
    setState(() => _down = true);
  }

  void _release() {
    if (!_down) return;
    setState(() => _down = false);
  }

  @override
  Widget build(BuildContext context) {
    final br = widget.borderRadius ?? BorderRadius.circular(widget.radius);
    return Semantics(
      button: widget.onTap != null,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: widget.behavior,
        onTapDown: widget.enabled ? _downAt : null,
        onTapUp: widget.enabled ? (_) => _release() : null,
        onTapCancel: widget.enabled ? _release : null,
        onTap: widget.enabled ? widget.onTap : null,
        onLongPress: widget.onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: br,
            boxShadow: widget.shadows,
          ),
          child: AnimatedScale(
            scale: _on ? widget.scale : 1.0,
            duration: widget.duration,
            curve: Curves.easeOutCubic,
            child: _body(br),
          ),
        ),
      ),
    );
  }

  /// 高光层自带圆角装饰（不会溢出），只有子内容本身需要按需裁进圆角
  Widget _body(BorderRadius br) {
    final stack = Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        // 按下高光层：整片提亮 + 手指位置镜面光晕 + 边缘加亮
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _on ? 1 : 0,
              duration: widget.duration,
              curve: Curves.easeOutCubic,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: br,
                  // 整片玻璃被压薄 → 整体提亮
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(widget.tint),
                      Colors.white.withOpacity(widget.tint * 0.25),
                      Colors.white.withOpacity(widget.tint * 0.6),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: br,
                    // 手指处的折射焦点
                    gradient: RadialGradient(
                      center: _focus,
                      radius: 1.15,
                      colors: [
                        Colors.white.withOpacity(widget.glow),
                        Colors.white.withOpacity(widget.glow * 0.35),
                        Colors.white.withOpacity(0),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                    // 玻璃被挤压 → 边缘高光更亮
                    border: Border.all(
                      color: Colors.white.withOpacity(0.30),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    if (!widget.clip) return stack;
    return ClipRRect(borderRadius: br, child: stack);
  }
}

/// 圆形玻璃图标按钮（自带液态按下态）
///
/// 用于详情页顶栏、播放页等不需要实时模糊的位置：半透明渐变 + 高光描边。
class LiquidIconButton extends StatelessWidget {
  const LiquidIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 17,
    this.active = false,
    this.color,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool active;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: size / 2,
      semanticLabel: semanticLabel,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: active
                ? const [Color(0x594F8CFF), Color(0x332E6FE0)]
                : [
                    Colors.white.withOpacity(0.20),
                    Colors.white.withOpacity(0.06),
                  ],
          ),
          border: Border.all(
            color: active
                ? const Color(0x8C4F8CFF)
                : Colors.white.withOpacity(0.24),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: color ?? (onTap == null ? Colors.white38 : Colors.white),
        ),
      ),
    );
  }
}

/// 玻璃胶囊按钮（文字 / 文字+图标），自带液态按下态
class LiquidPill extends StatelessWidget {
  const LiquidPill({
    super.key,
    required this.label,
    this.icon,
    this.trailing,
    this.onTap,
    this.height = 34,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
    this.active = false,
    this.accent = false,
    this.fontSize = 12,
  });

  final String label;
  final IconData? icon;
  final IconData? trailing;
  final VoidCallback? onTap;
  final double height;
  final EdgeInsetsGeometry padding;
  final bool active;

  /// 蓝色调（用于「中文字幕」这类强调标签）
  final bool accent;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final base = accent
        ? const [Color(0x334F8CFF), Color(0x142E6FE0)]
        : active
        ? const [Color(0x3DFFFFFF), Color(0x1AFFFFFF)]
        : [Colors.white.withOpacity(0.12), Colors.white.withOpacity(0.06)];
    final bd = accent
        ? const Color(0x664F8CFF)
        : Colors.white.withOpacity(active ? 0.32 : 0.18);
    final fg = accent
        ? const Color(0xFFCFE0FF)
        : (onTap == null ? AppColors.muted : AppColors.ink);
    return LiquidPress(
      onTap: onTap,
      radius: height / 2,
      child: Container(
        height: height,
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height / 2),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: base,
          ),
          border: Border.all(color: bd),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: fontSize + 1,
                color: accent ? const Color(0xFF9CC2FF) : fg,
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 3),
              Icon(
                trailing,
                size: fontSize + 2,
                color: accent ? const Color(0xFF9CC2FF) : AppColors.muted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
