import 'package:flutter/material.dart';

import 'dart:ui';

import 'liquid_glass.dart';
import 'widgets/liquid_press.dart';

/// Camby 设计系统
/// Material 3 Expressive + 液态玻璃 Liquid Glass
class AppColors {
  static const bg = Color(0xFF06080E);
  static const bgTop = Color(0xFF0A0F1A);
  static const surface = Color(0xFF101726);
  static const ink = Color(0xFFF2F7FF);
  static const muted = Color(0xFF8B9BB4);
  static const primary = Color(0xFF3BE0C4); // 青绿主色（v2.0.73 由蓝紫切换）
  static const secondary = Color(0xFF19B3A6); // 深青（次色 / 渐变暗端）
  static const accent = Color(0xFF5AF0D6); // 亮青绿强调
  static const cyan = Color(0xFF38E8C8);
  static const warn = Color(0xFFFFC55A);
  static const danger = Color(0xFFFF6B8A);

  /// 主行动按钮渐变：深青 → 亮青绿
  static const ctaGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF19C7B0), Color(0xFF3BE0C4)],
  );
}

/// 底部导航视觉 token（v2.0.68 · 低干扰雾面分段条）。
///
/// 用户真机反馈 v2.0.67 的青蓝渐变胶囊「抢镜、有些宽」，确认改用
/// 媒体库顶部 `LibraryIndexSegment` 的背景与选中样式：白 6% 底 + 白 10%
/// 描边 + 白 22%→8% 选中渐变 + 白 26% 内描边 + 全圆角。
/// 整条 bar 从「撑满屏幕」收成 280dp 居中悬浮、高 50dp，手机 / 平板
/// 共用一份常量，不再按 isTablet 分叉。
/// **切换动画（AnimatedContainer + AnimatedSize，260ms）原样保留**。
class AppNav {
  const AppNav._();

  /// 选中项渐变：与 `LibraryIndexSegment` 完全同款的白雾面。
  /// 去掉 v2.0.67 的青 → 湖蓝 → 主蓝高饱和三色渐变与青色外发光。
  static const capsuleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x38FFFFFF), Color(0x14FFFFFF)],
  );

  /// 待更新红点配色（设计稿默认关，本版未接更新源，只保留色值）。
  static const badgeColor = Color(0xFFFF5A5F);

  /// 轨道：56dp 全圆角雾面分段条（v2.0.69 由 50 上调，真机反馈偏小）。
  /// 56 = 1px 描边 + 3dp 内距 + 48dp 单项 + 3dp 内距 + 1px 描边。
  static const double barHeight = 56;
  static const double barRadius = 999;

  /// 单项：未选中 48×48 纯线性图标，选中 112×48 药丸（图标 + 文字）。
  static const double itemHeight = 48;
  static const double itemRadius = 999;
  static const double idleWidth = 48;
  static const double selectedWidth = 112;

  /// 手机 / 平板统一 312dp 居中悬浮（v2.0.69 由 280 上调，视觉比例更稳）。
  /// 312 − 1px×2 描边 − 3dp×2 内距 = 304 = 112 + 4×48，定宽 Row 零余量，
  /// 沿用 v2.0.67 修 `RenderFlex overflowed by 2.0 pixels` 的经验。
  static const double tabletBarWidth = 312;
  static const double barInset = 3;

  /// 切换动效：胶囊宽度与文字展开共用一条曲线，避免两段动画错拍。
  static const Duration duration = Duration(milliseconds: 260);
  static const Curve curve = Curves.easeOutCubic;
}

/// 圆角档位（v2.0.64 质感包）。
///
/// 此前 `circular(2/3/4/8/9/11/12/13/14/15/999)` 混用，多为历史像素微调。
/// 按对比稿只收敛「卡片 / 胶囊 / 面板」三类高频，其余保留不动以避免大 diff。
class AppRadii {
  const AppRadii._();

  static const double sm = 6;
  static const double md = 12;
  static const double lg = 20;
  static const double pill = 999;

  static const BorderRadius smBr = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdBr = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgBr = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius pillBr = BorderRadius.all(Radius.circular(pill));
}

/// 大面积半透面（v2.0.65 统一）。
///
/// 详情简介 / 媒体信息这类**整块宽度**的容器，一旦带亮描边或外阴影，
/// 叠在全屏模糊背景上就会浮起来，和页面里那些小胶囊「平贴」的观感对不上
/// （用户反馈「是不是加了阴影」）。这里统一成**无描边、低对比纯填充**：
/// 只靠留白与内容排版分区，不再造第二层「玻璃框」。
///
/// 小胶囊 / 可点标签仍走各自的彩色配方（`_Cap` 等），不要改用本装饰。
class AppSurface {
  const AppSurface._();

  /// 大面积内容块：与胶囊 [ChipLabel] 同款 1px 描边，无 shadow、无渐变。
  ///
  /// v2.0.66：真机确认去掉描边后，两块大卡片反而与页面里的小胶囊「不像一套」。
  /// 描边色直接对齐 ChipLabel 的 `bd`（白 16%）；填充比胶囊的 13% 略低，
  /// 避免整块面积过大而发白。投影自 v2.0.54 起不再使用。
  static BoxDecoration soft({double radius = 14, double opacity = 0.06}) =>
      BoxDecoration(
        color: Colors.white.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.16),
          width: 1,
        ),
      );
}

/// 字号 token（v2.0.64 质感包）。
///
/// 全项目 337 处手写 fontSize 不一次性替换，只把「同一类信息」统一：
/// 重点是卡片标题（统一 11）与年份 / 计数 / 胶囊（统一 10）。
class AppType {
  const AppType._();

  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );
  static const TextStyle section = TextStyle(
    fontSize: 15.5,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
  );
  static const TextStyle body = TextStyle(fontSize: 13, height: 1.6);

  /// 卡片标题：首页 / 媒体库 / 收藏 / 演员 / 系列五页统一使用。
  static const TextStyle caption = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );

  /// 年份、计数、胶囊等元信息。
  static const TextStyle micro = TextStyle(fontSize: 10);

  /// 卡片标题（浅色，海报下方）。
  static const TextStyle cardTitle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: Color(0xFFE2EAF8),
  );

  /// 海报内叠加的片名（白字）。
  static const TextStyle posterTitle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    color: Colors.white,
    height: 1.2,
  );

  /// 卡片元信息（年份 / 剩余时长）。
  static const TextStyle cardMeta = TextStyle(
    fontSize: 10,
    color: AppColors.muted,
  );
}

/// 动效时长补充（v2.0.64）。基础三档在 [Anim] 里，这里只加质感包专用项。
class AppMotion {
  const AppMotion._();

  /// 图片淡入：比 Anim.fast(160) 略柔，比 Anim.base(220) 利落。
  static const Duration imageFade = Duration(milliseconds: 180);

  /// 骨架 → 内容交叉淡出，避免两层叠加瞬间变亮。
  static const Duration crossFade = Duration(milliseconds: 120);

  /// shimmer 扫光周期：慢到不抢注意力。
  static const Duration shimmer = Duration(milliseconds: 1500);

  /// 按压缩放时长（沿用 LiquidPress 手感）。
  static const Duration press = Duration(milliseconds: 90);
}

/// 骨架渐变：低饱和的深色玻璃底，与 [PosterBox] 同一套视觉语言，
/// 但去掉高饱和色块，避免加载态比真实海报还抢眼。
class SkeletonColors {
  const SkeletonColors._();

  static const Color base = Color(0xFF121B2C);
  static const Color hi = Color(0xFF1C2A42);

  static const LinearGradient gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [base, hi, base],
    stops: [0.0, 0.52, 1.0],
  );

  /// 文字条：比海报块更暗一档，形成层次。
  static const LinearGradient bar = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF182337), Color(0xFF22314A), Color(0xFF182337)],
    stops: [0.0, 0.5, 1.0],
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
        // v2.0.64：卡片标题 11 / 元信息 10，与 AppType.caption、micro 对齐。
        bodySmall: TextStyle(fontSize: 11, color: AppColors.muted),
        labelSmall: TextStyle(fontSize: 10, color: AppColors.muted),
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
    this.blurEnabled = true,
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

  /// 是否启用实时 BackdropFilter 模糊。播放页控件压在逐帧更新的视频之上，
  /// 开启模糊时每一帧都要重采样，中低端 GPU 会被拖垮（表现为唤出控件时
  /// 视频卡顿/像暂停了 1 秒）。播放控件层传 false，仅保留半透明玻璃质感。
  final bool blurEnabled;

  /// 背景色彩矩阵：saturate 1.45 + contrast 1.06（标准亮度权重公式）。
  ///
  /// v2.0.73 修复：v2.0.70 那版系数是错的（R 行 -0.286/1.259/0.127），
  /// 把主色 #4F8CFF 算成 #BA9246 —— 全站按钮/开关/进度条被染成金黄。
  /// 现在用规范矩阵：sr=(1-s)*0.213、sg=(1-s)*0.715、sb=(1-s)*0.072。
  ///
  /// **只作用于 BackdropFilter 采样到的背景**，不碰玻璃内部内容
  /// （内容若被调色，文字和品牌色会整体偏色）。
  static const List<double> _vibrancy = [
    1.4353, -0.3411, -0.0343, 0, -7.65,
    -0.1017, 1.1959, -0.0343, 0, -7.65,
    -0.1017, -0.3411, 1.5027, 0, -7.65,
    0, 0, 0, 1, 0,
  ];

  /// 玻璃底板色（v2.0.73）：真机反馈弹窗过于通透，背后文字直接透上来很乱。
  /// 底板压住一层深色，模糊只负责边缘的「玻璃感」。
  static const Color _base = Color(0xFF0B111C);

  /// 内发光：Flutter BoxShadow 无 inset，用边缘内渐变近似玻璃厚度。
  Widget _innerGlow(BorderRadius r, double a) => Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.92,
                colors: [
                  Colors.white.withOpacity(0.0),
                  Colors.white.withOpacity(a),
                ],
                stops: const [0.72, 1.0],
              ),
            ),
          ),
        ),
      );

  /// 折射高光层：对角镜面光 + 顶部弧形柔光。L1 仅提亮高光，真折射留待 L2。
  /// 用 Positioned.fill 包住内部 Stack，使其跟随父级尺寸（内部仅两个定位子，
  /// 自身无法在无约束父级下确定尺寸）。
  Widget _specular(BorderRadius r, {double diag = 0.32, double top = 0.18}) =>
      Positioned.fill(
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: r,
                    gradient: LinearGradient(
                      stops: const [0.0, 0.34, 0.66, 1.0],
                      colors: [
                        Colors.white.withOpacity(diag),
                        Colors.white.withOpacity(0.0),
                        Colors.white.withOpacity(0.0),
                        Colors.white.withOpacity(diag * 0.5),
                      ],
                      begin: const Alignment(-1.2, -1.0),
                      end: const Alignment(1.2, 1.0),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: r,
                    gradient: RadialGradient(
                      center: const Alignment(-0.65, -1.25),
                      radius: 1.4,
                      colors: [
                        Colors.white.withOpacity(top),
                        Colors.white.withOpacity(0.0),
                      ],
                      stops: const [0.0, 0.55],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    // tint 让出一档给色彩矩阵，避免叠加后过曝
    final tintNow = tint * 0.7;

    // L2 液态：开启 + 后端支持 shader + 非播放页（blurEnabled=false 已排除）
    final useLiquid =
        blurEnabled && GlassConfig.liquidEnabled && LiquidGlass.supported;
    final dpr = MediaQuery.of(context).devicePixelRatio;

    // 边缘色散描边：L2 用青/品红分色细边模拟 RGB 色散（不依赖 shader 也可见，
    // 是「真的生效」的可见保底层）；L1 保持白色亮边。
    final Border? glassBorder = border
        ? (useLiquid
            ? const Border(
                top: BorderSide(color: Color(0x5538E8C8), width: 1.0),
                left: BorderSide(color: Color(0x3A38E8C8), width: 1.0),
                right: BorderSide(color: Color(0x3AFF6BD6), width: 1.0),
                bottom: BorderSide(color: Color(0x55FF6BD6), width: 1.0),
              )
            : Border.all(color: Colors.white.withOpacity(0.22), width: 0.9))
        : null;

    // v2.0.73：玻璃不再「全透」。底板压一层深色，模糊只做边缘玻璃感；
    // 播放页（blurEnabled=false）没有真实模糊，底板让得更透以免糊住画面。
    final baseAlpha = blurEnabled ? (soft ? 0.52 : 0.70) : 0.42;
    Color fill(double whiteA) => Color.alphaBlend(
          Colors.white.withOpacity(whiteA),
          _base,
        ).withOpacity(baseAlpha);

    final body = Container(
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
                fill(soft ? tintNow * 0.9 : tintNow * 1.6),
                fill(soft ? tintNow * 0.3 : tintNow * 0.5),
                fill(soft ? tintNow * 0.5 : tintNow * 0.9),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
        border: glassBorder,
      ),
      child: child,
    );

    // 滤镜层：两条路径都只处理「背后透出的背景」，内容原色不动。
    //   L2 = 模糊 → shader 沿法线偏移采样（真折射 + 色散）
    //   L1 = 模糊 → 色彩矩阵（saturate/contrast，纯 CPU 参数）
    // v2.0.73 修复：矩阵以前套在 body 外层（ColorFiltered），连按钮、文字一起
    // 调色，品牌蓝被算成金黄。现在塞进 BackdropFilter 的 filter 链。
    final ImageFilter? filter = !blurEnabled
        ? null
        : (useLiquid
            ? ImageFilter.compose(
                inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                outer: ImageFilter.shader(
                  LiquidGlass.shader(
                    radius: radius * dpr,
                    refraction: 10 * dpr,
                    dispersion: 0.22,
                    specular: 0.5,
                  ),
                ),
              )
            : ImageFilter.compose(
                inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                outer: ColorFilter.matrix(_vibrancy),
              ));

    final clipped = ClipRRect(
      borderRadius: r,
      child: filter == null
          ? body
          : BackdropFilter(filter: filter, child: body),
    );

    // 厚度层：内发光 + 折射高光。L2 加强高光、补边缘菲涅尔体积感。
    Widget content = Stack(
      children: [
        clipped,
        _innerGlow(r, useLiquid ? 0.15 : 0.10),
        _specular(
          r,
          diag: useLiquid ? 0.42 : 0.32,
          top: useLiquid ? 0.24 : 0.18,
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
    // 外阴影：托起体积，置于最外层避免被 ClipRRect 裁掉
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: content,
    );
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
    this.blurEnabled = true,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool active;
  final bool blurEnabled;

  @override
  Widget build(BuildContext context) {
    return Glass(
      width: size,
      height: size,
      padding: EdgeInsets.zero,
      radius: size / 2,
      blur: 18,
      tint: active ? 0.20 : 0.12,
      blurEnabled: blurEnabled,
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
        borderRadius: AppRadii.pillBr,
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
              style: AppType.posterTitle,
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

/// 动效规范常量（v1.7.38）。
///
/// 原先把 `easeOutCubic` / `easeOut` / `easeInSine` 和 150/160/200/220/260/280/300ms
/// 散落在各个页面里，同一个 App 的手感被切成好几段。这里收成一套：
/// 三档时长 + 两条曲线，所有转场/面板/按压都从这里取。
class Anim {
  const Anim._();

  /// 标准出场/进场曲线
  static const Curve curve = Curves.easeOutCubic;

  /// 收回/离场曲线
  static const Curve curveIn = Curves.easeInCubic;

  /// 微交互（高亮、按压回弹）
  static const Duration fast = Duration(milliseconds: 160);

  /// 控件层淡入淡出
  static const Duration base = Duration(milliseconds: 220);

  /// 页面转场
  static const Duration slow = Duration(milliseconds: 320);

  /// 页面转场退场时长（比入场略快，符合"退出比进入干脆"的直觉）
  static const Duration exit = Duration(milliseconds: 280);
}
