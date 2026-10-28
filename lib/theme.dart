import 'package:flutter/material.dart';

import 'dart:ui';

import 'widgets/liquid_press.dart';

/// Camby 设计系统
/// Material 3 Expressive + 液态玻璃 Liquid Glass
class AppColors {
  static const bg = Color(0xFF06080E);
  static const bgTop = Color(0xFF0A0F1A);
  static const surface = Color(0xFF101726);
  static const ink = Color(0xFFF2F7FF);
  static const muted = Color(0xFF8B9BB4);
  static const primary = Color(0xFF4F8CFF); // 蓝紫主色
  static const secondary = Color(0xFF7B5CFF);
  static const accent = Color(0xFF5B8CFF); // 亮蓝强调
  static const cyan = Color(0xFF38E8C8);
  static const warn = Color(0xFFFFC55A);
  static const danger = Color(0xFFFF6B8A);

  /// 主行动按钮渐变：蓝 → 紫
  static const ctaGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF4F8CFF), Color(0xFF7B5CFF)],
  );
}

class AppTheme {
  static ThemeData dark() {
    const cs = ColorScheme.dark(
      primary: AppColors.primary,
      secondary: AppColors.secondary,
      tertiary: AppColors.accent,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: AppColors.bg,
      brightness: Brightness.dark,
      splashFactory: InkSparkle.splashFactory,
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 29,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
          height: 1.15,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          height: 1.6,
          color: Color(0xFFC3D3EE),
        ),
        bodySmall: TextStyle(fontSize: 11.5, color: AppColors.muted),
        labelSmall: TextStyle(fontSize: 10.5, color: AppColors.muted),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
    );
  }
}

/// 液态玻璃容器：背景模糊 + 饱和提升 + 边缘折射高光
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.blur = 26,
    this.radius = 24,
    this.padding = const EdgeInsets.all(16),
    this.tint = 0.10,
    this.border = true,
    this.soft = false,
    this.margin,
    this.width,
    this.height,
    this.gradient,
    this.onTap,
  });

  final Widget child;
  final double blur;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double tint;
  final bool border;
  final bool soft;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final Gradient? gradient;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    Widget content = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        gradient:
            gradient ??
            LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(soft ? tint * 0.9 : tint * 1.6),
                Colors.white.withOpacity(soft ? tint * 0.3 : tint * 0.5),
                Colors.white.withOpacity(soft ? tint * 0.5 : tint * 0.9),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
        border: border
            ? Border.all(color: Colors.white.withOpacity(0.18), width: 1)
            : null,
      ),
      child: child,
    );

    content = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: content,
    );

    content = ClipRRect(borderRadius: r, child: content);

    // 折射高光层：对角镜面光 + 顶部弧形柔光（液态玻璃）
    content = Stack(
      children: [
        content,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: r,
                gradient: LinearGradient(
                  stops: const [0.0, 0.34, 0.66, 1.0],
                  colors: [
                    Colors.white.withOpacity(0.26),
                    Colors.white.withOpacity(0.0),
                    Colors.white.withOpacity(0.0),
                    Colors.white.withOpacity(0.12),
                  ],
                  begin: const Alignment(-1.2, -1.0),
                  end: const Alignment(1.2, 1.0),
                ),
              ),
            ),
          ),
        ),
        // 顶部弧形柔光：像光线打在玻璃上表面
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: r,
                gradient: RadialGradient(
                  center: const Alignment(-0.65, -1.25),
                  radius: 1.4,
                  colors: [
                    Colors.white.withOpacity(0.14),
                    Colors.white.withOpacity(0.0),
                  ],
                  stops: const [0.0, 0.55],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (onTap != null) {
      // 液态按下态：下沉 + 内部散射提亮 + 手指处镜面光晕
      content = LiquidPress(onTap: onTap, radius: radius, child: content);
    }
    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }
    return content;
  }
}

/// 玻璃圆形图标按钮
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 42,
    this.active = false,
    this.iconSize = 18,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Glass(
      width: size,
      height: size,
      padding: EdgeInsets.zero,
      radius: size / 2,
      blur: 18,
      tint: active ? 0.20 : 0.12,
      onTap: onTap,
      child: Icon(
        icon,
        size: iconSize,
        color: onTap == null ? AppColors.muted : AppColors.ink,
      ),
    );
  }
}

/// 强调色主按钮（形态过渡 pill）
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.expand = true,
    this.height = 46,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool expand;
  final double height;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton>
    with SingleTickerProviderStateMixin {
  double _t = 0;

  void _set(double v) => setState(() => _t = v);

  @override
  Widget build(BuildContext context) {
    final radius = 26.0 - 10 * _t; // pill → 圆角矩形
    return GestureDetector(
      onTapDown: (_) => _set(1),
      onTapUp: (_) => _set(0),
      onTapCancel: () => _set(0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: 1 - 0.03 * _t,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Container(
              height: widget.height,
              width: widget.expand ? double.infinity : null,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                gradient: AppColors.ctaGradient,
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x594F8CFF),
                    blurRadius: 24,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: widget.expand
                    ? MainAxisSize.max
                    : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                ],
              ),
            ),
            // 按下高光：主按钮是实心渐变，按压时整片提亮即可
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _t,
                  duration: const Duration(milliseconds: 160),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0x47FFFFFF), Color(0x0FFFFFFF)],
                      ),
                      border: Border.all(color: Color(0x4DFFFFFF)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 玻璃标签胶囊（评分 / 年份 / 媒体徽章）
class ChipLabel extends StatelessWidget {
  const ChipLabel(
    this.text, {
    super.key,
    this.color,
    this.gold = false,
    this.cyan = false,
    this.small = false,
  });
  final String text;
  final Color? color;
  final bool gold;
  final bool cyan;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final bg = gold
        ? const Color(0x33FFB64D)
        : cyan
        ? const Color(0x2E38E8C8)
        : Colors.white.withOpacity(0.13);
    final bd = gold
        ? const Color(0x66FFB64D)
        : cyan
        ? const Color(0x6638E8C8)
        : Colors.white.withOpacity(0.16);
    final fg = gold
        ? const Color(0xFFFFD9A1)
        : cyan
        ? const Color(0xFFA7F3E4)
        : (color ?? const Color(0xFFDBE7FB));
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 7 : 9,
        vertical: small ? 2 : 3.5,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: bd, width: 1),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: small ? 9 : 10.5,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

/// 渐变海报（演示数据无真实图片时的替代方案）
class PosterBox extends StatelessWidget {
  const PosterBox({
    super.key,
    required this.item,
    this.height = 150,
    this.radius = 14,
    this.progress,
  });

  final MediaItemPlaceholder item;
  final double height;
  final double radius;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
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
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: height * 0.55,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withOpacity(0.55)],
                ),
              ),
            ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Text(
              item.title,
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
          if (progress != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(0),
                ),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: Colors.white.withOpacity(0.18),
                  valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 占位用的极简媒体模型（页面层使用完整 MediaItem）
class MediaItemPlaceholder {
  const MediaItemPlaceholder({required this.title, required this.colors});
  final String title;
  final List<Color> colors;
}
