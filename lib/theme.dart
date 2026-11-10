import 'package:flutter/material.dart';

import 'dart:math';
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
  static const primary = Color(0xFF4F8CFF); // 蓝紫主色（v2.0.75 回归原配色）
  static const secondary = Color(0xFF7B5CFF);
  static const accent = Color(0xFF5B8CFF); // 亮蓝强调
  static const cyan = Color(0xFF38E8C8);
  static const warn = Color(0xFFFFC55A);
  static const danger = Color(0xFFFF6B8A);

  /// 主行动按钮渐变：蓝 → 紫（与 v2.0.22 起的原配方一致）。
  /// v2.0.73/74 试过青绿系，真机确认原蓝色才是目标，v2.0.75 全量回退。
  static const ctaGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF4F8CFF), Color(0xFF7B5CFF)],
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
    this.blur = 20,
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
    this.fullRefraction = false,
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

  /// 整面折射模式（仅用于最大、最像工具栏的玻璃：底部导航条 / 播放控制条）。
  /// 开启时 shader 把折射扩展到整块卡面（真实透镜弯曲）、模糊收窄到 ~10、
  /// 镜面高光由 [LiquidLightSource] 动态驱动。小卡片保持默认 false（毛玻璃）。
  final bool fullRefraction;

  /// 是否启用实时 BackdropFilter 模糊。播放页控件压在逐帧更新的视频之上，
  /// 开启模糊时每一帧都要重采样，中低端 GPU 会被拖垮（表现为唤出控件时
  /// 视频卡顿/像暂停了 1 秒）。播放控件层传 false，仅保留半透明玻璃质感。
  final bool blurEnabled;

  /// 背景色彩矩阵：saturate 1.18 + contrast 1.03（标准亮度权重公式）。
  ///
  /// v2.0.73 修复：v2.0.70 那版系数是错的（R 行 -0.286/1.259/0.127），
  /// 把主色 #4F8CFF 算成 #BA9246 —— 全站按钮/开关/进度条被染成金黄。
  /// 现在用规范矩阵：sr=(1-s)*0.213、sg=(1-s)*0.715、sb=(1-s)*0.072。
  ///
  /// v2.0.76：1.45 的饱和度对深色界面太猛——数据页那几团彩色光晕被放大后，
  /// 透过玻璃混成一锅灰紫雾，观感「脏」。降到 1.18 / 1.03，背景该沉的沉下去，
  /// 玻璃里只剩下淡淡的色相过渡。仍是规范矩阵，主色不会被算偏。
  ///
  /// **只作用于 BackdropFilter 采样到的背景**，不碰玻璃内部内容
  /// （内容若被调色，文字和品牌色会整体偏色）。
  static const List<double> _vibrancy = [
    1.17591, -0.13256, -0.01335, 0, -3.84,
    -0.03949, 1.08284, -0.01335, 0, -3.84,
    -0.03949, -0.13256, 1.20205, 0, -3.84,
    0, 0, 0, 1, 0,
  ];

  /// 玻璃底板色（v2.0.76）：比 v2.0.73 再深一档，压住背后的彩色光斑。
  /// 玻璃的「净」来自底板足够深，模糊只负责边缘那一点流动感。
  static const Color _base = Color(0xFF070C15);

  /// 内发光：Flutter BoxShadow 无 inset，用边缘内渐变近似玻璃厚度。
  /// v2.0.76：起亮位置从 0.72 推到 0.88，只在最外一圈留厚度，
  /// 不再把整块卡面洗白。
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
                stops: const [0.88, 1.0],
              ),
            ),
          ),
        ),
      );

  /// 折射高光层：对角镜面光 + 顶部弧形柔光。L1 仅提亮高光，真折射留待 L2。
  /// 用 Positioned.fill 包住内部 Stack，使其跟随父级尺寸（内部仅两个定位子，
  /// 自身无法在无约束父级下确定尺寸）。
  ///
  /// v2.0.76：v2.0.72 的 diag 0.42 是沿整块对角铺开的白，等于给每张卡蒙了层
  /// 白纱——这是「玻璃变脏」的主因。现在把白光压成贴着边缘的一道窄光，
  /// 中间完全透明，卡面恢复深色，只有转折处反光。
  Widget _specular(BorderRadius r, {double diag = 0.16, double top = 0.10}) =>
      Positioned.fill(
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: r,
                    gradient: LinearGradient(
                      stops: const [0.0, 0.07, 0.30, 0.70, 0.93, 1.0],
                      colors: [
                        Colors.white.withOpacity(diag),
                        Colors.white.withOpacity(0.0),
                        Colors.white.withOpacity(0.0),
                        Colors.white.withOpacity(0.0),
                        Colors.white.withOpacity(diag * 0.45),
                        Colors.white.withOpacity(diag * 0.8),
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
                      radius: 0.95,
                      colors: [
                        Colors.white.withOpacity(top),
                        Colors.white.withOpacity(0.0),
                      ],
                      stops: const [0.0, 0.22],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        // v2.0.76：监听材质档位。开关一拨，每块玻璃自己重绘，
        // 不依赖父页面 setState（页面被 IndexedStack 缓存时也能立即生效）。
        valueListenable: GlassConfig.liquid,
        builder: (context, _, __) {
          final useLiquid =
              GlassConfig.liquidEnabled && LiquidGlass.supported;
          if (fullRefraction && useLiquid) {
            // 整面折射 + 动态镜面：光源匀速公转，仅大玻璃订阅此帧驱动。
            return ValueListenableBuilder<double>(
              valueListenable: LiquidLightSource.angle,
              builder: (ctx, a, ___) =>
                  _assemble(ctx, Offset(cos(a), sin(a)), useLiquid),
            );
          }
          return _assemble(context, const Offset(0.45, -1.0), useLiquid);
        },
      );

  Widget _assemble(BuildContext context, Offset light, bool useLiquid) {
    final r = BorderRadius.circular(radius);
    // tint 让出一档给色彩矩阵，避免叠加后过曝
    final tintNow = tint * 0.7;

    // useLiquid 由 build 顶层计算后作为参数传入（见 _assemble 签名）。
    final dpr = MediaQuery.of(context).devicePixelRatio;

    // 边缘色散描边：L2 用青/品红分色细边模拟 RGB 色散。
    // v2.0.76：原来 0x55/0x3A 的强度在深色卡面上会显出一圈绿粉脏边，
    // 收到几乎只剩一道冷光，只在近看时才看得出分色。
    final Border? glassBorder = border
        ? (useLiquid
            ? const Border(
                top: BorderSide(color: Color(0x2E38E8C8), width: 0.9),
                left: BorderSide(color: Color(0x1F38E8C8), width: 0.9),
                right: BorderSide(color: Color(0x1FFF6BD6), width: 0.9),
                bottom: BorderSide(color: Color(0x2EFF6BD6), width: 0.9),
              )
            : Border.all(color: Colors.white.withOpacity(0.20), width: 0.9))
        : null;

    // v2.0.76：底板更实。玻璃的干净来自「深底 + 边缘微光」，
    // 底太透时背后的彩色光斑会糊成灰雾（真机反馈的「脏」）。
    final baseAlpha = blurEnabled ? (soft ? 0.62 : 0.78) : 0.42;
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
                fill(soft ? tintNow * 0.55 : tintNow * 1.0),
                fill(soft ? tintNow * 0.20 : tintNow * 0.30),
                fill(soft ? tintNow * 0.32 : tintNow * 0.55),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
        border: glassBorder,
      ),
      child: child,
    );

    // 滤镜层：所有路径都只处理「背后透出的背景」，内容原色不动。
    //   L2 整面（fullRefraction）：先 shader 对清晰背景整面折射，再轻模糊柔化
    //       → 真实透镜弯曲（背景在玻璃内被放大/扭曲），模糊收窄到 ~10
    //   L2 边缘（小卡片）：先模糊，再 shader 仅在边缘带做色散/菲涅尔高光
    //   L1：模糊 → 色彩矩阵（saturate/contrast，纯 CPU 参数）
    //   播放页（blurEnabled=false 且 L2）：纯 shader 折射，背后是逐帧视频
    // v2.0.73 修复：矩阵以前套在 body 外层（ColorFiltered），连按钮、文字一起
    // 调色，品牌蓝被算成金黄。现在塞进 BackdropFilter 的 filter 链。
    final ImageFilter? filter = !useLiquid
        ? (blurEnabled ? ImageFilter.blur(sigmaX: blur, sigmaY: blur) : null)
        : (blurEnabled
            ? (fullRefraction
                ? ImageFilter.compose(
                    // 先折射（作用于清晰背景），后轻模糊
                    inner: ImageFilter.shader(
                      LiquidGlass.shader(
                        radius: radius * dpr,
                        refraction: 14 * dpr,
                        dispersion: 0.30,
                        specular: 0.6,
                        full: true,
                        light: light,
                      ),
                    ),
                    outer: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  )
                : ImageFilter.compose(
                    inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    outer: ImageFilter.shader(
                      LiquidGlass.shader(
                        radius: radius * dpr,
                        refraction: 10 * dpr,
                        dispersion: 0.22,
                        specular: 0.35,
                        full: false,
                        light: light,
                      ),
                    ),
                  ))
            : ImageFilter.shader(
                LiquidGlass.shader(
                  radius: radius * dpr,
                  refraction: 10 * dpr,
                  dispersion: 0.22,
                  specular: 0.35,
                  full: false,
                  light: light,
                ),
              ));

    final clipped = ClipRRect(
      borderRadius: r,
      child: filter == null
          ? body
          : BackdropFilter(filter: filter, child: body),
    );

    // 厚度层：内发光 + 折射高光。L2 的高光只在边缘收口，不做整面提亮。
    Widget content = Stack(
      children: [
        clipped,
        _innerGlow(r, useLiquid ? 0.07 : 0.05),
        _specular(
          r,
          diag: useLiquid ? 0.18 : 0.13,
          top: useLiquid ? 0.11 : 0.08,
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
    // 外阴影：托起体积，置于最外层避免被 ClipRRect 裁掉。
    // v2.0.76：多卡连续排布时 0x59 的黑影会互相叠成灰带，收到 0x42。
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const [
          BoxShadow(
            color: Color(0x42000000),
            blurRadius: 26,
            offset: Offset(0, 10),
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
