import 'package:flutter/material.dart';

import 'dart:ui';

import 'widgets/liquid_press.dart';

/// 一套调色板（v2.0.98 · 浅色玻璃主题）。
///
/// 深色沿用 v2.0.75 起的原配色，浅色是新增的。真正被 global 引用的是
/// [AppColors] 这层门面 —— 页面里 390 处 `AppColors.xxx` 一个字都不用改。
///
/// **为什么不做成 ThemeExtension**：那需要把 390 处引用全改成
/// `context.colors.xxx`，改动面比收益大得多，且 `const` 上下文更麻烦。
/// 这里走「全局可切换调色板 + 切换时整棵树重建」，代价是切换瞬间要重建
/// 一次 UI（低频操作），换来零侵入的迁移。
abstract class AppPalette {
  const AppPalette();

  bool get isDark;

  Color get bg;
  Color get bgTop;
  Color get surface;

  /// 主文字。
  Color get ink;

  /// 次级文字（正文字号用，比 [ink] 淡一档）。
  Color get inkSoft;

  /// 卡片标题（海报下方那行片名）。比 [inkSoft] 再亮/暗一点，
  /// 让「标题」与「元信息」拉开一档。
  Color get cardTitle;

  /// 胶囊标签的前景色（评分 / 年份徽章）。
  Color get chipFg;

  Color get muted;
  Color get primary;
  Color get secondary;
  Color get accent;
  Color get cyan;
  Color get warn;
  Color get danger;

  LinearGradient get ctaGradient;

  /// 叠加层基色：深色主题是**白**，浅色主题是**黑**。
  ///
  /// 全站 451 处 `Colors.white.withValues(alpha: 0.06)` 这种「往上提亮一档」
  /// 的半透层，在浅色底上完全失效（白叠白 = 看不见）。统一改成
  /// `AppColors.w.withValues(...)` 后，浅色下自动变成「往下压暗一档」，
  /// 层级关系原样保留。
  Color get w;

  /// 毛玻璃底板与其描边 / 投影。
  Color get glassBase;
  Color get glassBorder;
  Color get glassShadow;

  /// 骨架屏。
  Color get skeletonBase;
  Color get skeletonHi;
}

/// 深色（原配色，v2.0.75 起未变）。
class _DarkPalette extends AppPalette {
  const _DarkPalette();

  @override
  bool get isDark => true;

  @override
  Color get bg => const Color(0xFF06080E);
  @override
  Color get bgTop => const Color(0xFF0A0F1A);
  @override
  Color get surface => const Color(0xFF101726);
  @override
  Color get ink => const Color(0xFFF2F7FF);
  @override
  Color get inkSoft => const Color(0xFFC3D3EE);
  @override
  Color get cardTitle => const Color(0xFFE2EAF8);
  @override
  Color get chipFg => const Color(0xFFDBE7FB);
  @override
  Color get muted => const Color(0xFF8B9BB4);
  @override
  Color get primary => const Color(0xFF4F8CFF);
  @override
  Color get secondary => const Color(0xFF7B5CFF);
  @override
  Color get accent => const Color(0xFF5B8CFF);
  @override
  Color get cyan => const Color(0xFF38E8C8);
  @override
  Color get warn => const Color(0xFFFFC55A);
  @override
  Color get danger => const Color(0xFFFF6B8A);

  @override
  LinearGradient get ctaGradient => const LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF4F8CFF), Color(0xFF7B5CFF)],
  );

  @override
  Color get w => Colors.white;
  @override
  Color get glassBase => const Color(0xFF0B1220);
  @override
  Color get glassBorder => const Color(0x17FFFFFF);
  @override
  Color get glassShadow => const Color(0x24000000);
  @override
  Color get skeletonBase => const Color(0xFF121B2C);
  @override
  Color get skeletonHi => const Color(0xFF1C2A42);
}

/// 浅色（v2.0.98 新增）。
///
/// 不是把深色「反相」—— 那样会得到一片刺眼的纯白。这里按设计稿给的
/// 方向走**冷调灰白**：底 0xFFF3F5FA、卡片纯白、文字墨黑，
/// 强调色整体压深一档以保证白底上的对比度（蓝 4F8CFF → 3B6FE0）。
class _LightPalette extends AppPalette {
  const _LightPalette();

  @override
  bool get isDark => false;

  @override
  Color get bg => const Color(0xFFF3F5FA);
  @override
  Color get bgTop => const Color(0xFFFFFFFF);
  @override
  Color get surface => const Color(0xFFFFFFFF);
  @override
  Color get ink => const Color(0xFF151A24);
  @override
  Color get inkSoft => const Color(0xFF3C4759);
  @override
  Color get cardTitle => const Color(0xFF2A3346);
  @override
  Color get chipFg => const Color(0xFF33405A);
  @override
  Color get muted => const Color(0xFF6B7A90);
  @override
  Color get primary => const Color(0xFF3B6FE0);
  @override
  Color get secondary => const Color(0xFF6A4BF0);
  @override
  Color get accent => const Color(0xFF3F72E8);
  @override
  Color get cyan => const Color(0xFF0E9E90);
  @override
  Color get warn => const Color(0xFFCE8613);
  @override
  Color get danger => const Color(0xFFD93E62);

  @override
  LinearGradient get ctaGradient => const LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF3B6FE0), Color(0xFF6A4BF0)],
  );

  @override
  Color get w => Colors.black;
  @override
  Color get glassBase => const Color(0xFFFFFFFF);
  @override
  Color get glassBorder => const Color(0x14000000);
  @override
  Color get glassShadow => const Color(0x1A1B2A4A);
  @override
  Color get skeletonBase => const Color(0xFFE6EAF2);
  @override
  Color get skeletonHi => const Color(0xFFF1F4F9);
}

/// Camby 设计系统
/// Material 3 Expressive + 毛玻璃 Frosted Glass（v2.0.81 起，液态玻璃已移除）
///
/// v2.0.98：从「一组 const 颜色」改成「转发到当前 [palette] 的门面」。
/// 引用点写法完全不变（`AppColors.ink`），只是不再能在 `const` 上下文里用 ——
/// 全项目 50 处 `const` 已随本次改造清掉。
class AppColors {
  const AppColors._();

  static const AppPalette darkPalette = _DarkPalette();
  static const AppPalette lightPalette = _LightPalette();

  static AppPalette _palette = darkPalette;

  /// 当前调色板。切换主题时由 [ThemeController] 调 [apply]。
  static AppPalette get palette => _palette;

  /// 切到指定亮度。幂等；返回是否真的发生了变化。
  static bool apply({required bool dark}) {
    final next = dark ? darkPalette : lightPalette;
    if (identical(_palette, next)) return false;
    _palette = next;
    return true;
  }

  static bool get isDark => _palette.isDark;

  static Color get bg => _palette.bg;
  static Color get bgTop => _palette.bgTop;
  static Color get surface => _palette.surface;
  static Color get ink => _palette.ink;
  static Color get inkSoft => _palette.inkSoft;
  static Color get cardTitle => _palette.cardTitle;
  static Color get chipFg => _palette.chipFg;
  static Color get muted => _palette.muted;
  static Color get primary => _palette.primary;
  static Color get secondary => _palette.secondary;
  static Color get accent => _palette.accent;
  static Color get cyan => _palette.cyan;
  static Color get warn => _palette.warn;
  static Color get danger => _palette.danger;

  /// 主行动按钮渐变：蓝 → 紫（与 v2.0.22 起的原配方一致）。
  /// v2.0.73/74 试过青绿系，真机确认原蓝色才是目标，v2.0.75 全量回退。
  static LinearGradient get ctaGradient => _palette.ctaGradient;

  /// 叠加层基色：深色主题白、浅色主题黑。见 [AppPalette.w]。
  static Color get w => _palette.w;
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
        color: AppColors.w.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: AppColors.w.withValues(alpha: 0.16),
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

  /// 卡片标题（海报下方）。
  static TextStyle get cardTitle => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: AppColors.cardTitle,
  );

  /// 海报内叠加的片名（恒白 —— 压在图片上，不随主题走）。
  static const TextStyle posterTitle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    color: Colors.white,
    height: 1.2,
  );

  /// 卡片元信息（年份 / 剩余时长）。
  static TextStyle get cardMeta => TextStyle(
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

/// 骨架渐变：低饱和的玻璃底，与 [PosterBox] 同一套视觉语言，
/// 但去掉高饱和色块，避免加载态比真实海报还抢眼。
///
/// v2.0.98：改成按主题取值。浅色下用冷灰白，深色下沿用原深蓝。
class SkeletonColors {
  const SkeletonColors._();

  static Color get base => AppColors.palette.skeletonBase;
  static Color get hi => AppColors.palette.skeletonHi;

  static LinearGradient get gradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [base, hi, base],
    stops: const [0.0, 0.52, 1.0],
  );

  /// 文字条：比海报块更暗一档，形成层次。
  static LinearGradient get bar => LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: _barColors,
    stops: const [0.0, 0.5, 1.0],
  );

  static List<Color> get _barColors {
    if (!AppColors.isDark) {
      return const [
        Color(0xFFE9EDF4),
        Color(0xFFF3F6FB),
        Color(0xFFE9EDF4),
      ];
    }
    return const [
      Color(0xFF182337),
      Color(0xFF22314A),
      Color(0xFF182337),
    ];
  }
}

class AppTheme {
  /// v2.0.98：单一入口按亮度构建。调用前 [AppColors.apply] 必须已经切过 ——
  /// 两者是同一份状态的两种投影，必须同步，否则会出现「页面是浅色、
  /// 对话框是深色」的错位。
  static ThemeData build({required bool dark}) {
    final scheme = ColorScheme(
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.secondary,
      onSecondary: Colors.white,
      tertiary: AppColors.accent,
      onTertiary: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      error: AppColors.danger,
      onError: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      brightness: dark ? Brightness.dark : Brightness.light,
      splashFactory: InkSparkle.splashFactory,
      // 浅色下 Material 组件的默认水波纹是黑色，压在彩色按钮上会显脏；
      // 统一用主色的低透明版本，深浅两套都能看。
      highlightColor: AppColors.w.withValues(alpha: 0.05),
      textTheme: TextTheme(
        displayLarge: const TextStyle(
          fontSize: 29,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
          height: 1.15,
        ),
        titleLarge: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: const TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          height: 1.6,
          color: AppColors.inkSoft,
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
      // 弹窗 / 底部面板：深浅两套各给一个与页面同族的底，避免 Material
      // 默认的纯白（深色下）或纯黑（浅色下）像贴了块补丁。
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: dark ? const Color(0xFF1B2436) : const Color(0xFF2A3345),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12.5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 兼容旧调用点（测试里还有几处直接调 `dark()`）。
  static ThemeData dark() {
    AppColors.apply(dark: true);
    return build(dark: true);
  }
}

/// 毛玻璃容器：单层背景模糊 + 深色半透底 + 极细冷白边。
///
/// v2.0.81：移除「液态玻璃」整套链路（自定义 shader 折射 / 青品红分色描边 /
/// 对角镜面高光 / 内发光 / 色彩矩阵 / 材质档位开关）。真机上 shader 从未
/// 生效，叠在深色卡上的那几层白色高光正是「四周泛白」的根源，而开关因
/// 真机上 shader 滤镜恒不可用也完全没有作用 —— 整套开关遂一并删除。
/// 现在全站统一为干净的 iOS 式保守毛玻璃：只保留一次 BackdropFilter，
/// 其余靠底色与一道细边表达厚度。
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
  /// 开启模糊时每一帧都要重采样，中低端 GPU 会被拖垮。播放控件层传 false，
  /// 仅保留半透明玻璃质感。
  final bool blurEnabled;

  /// 同 sigma 的模糊滤镜复用同一实例：避免每块玻璃每次 build 都新建引擎侧
  /// ImageFilter（P0）。ImageFilter 不可变，跨实例共享安全。
  static ImageFilter _blurFilter(double sigma) => _blurCache.putIfAbsent(
    sigma,
    () => ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  );
  static final Map<double, ImageFilter> _blurCache = <double, ImageFilter>{};

  /// 半透底板：深色是冷蓝黑，浅色是纯白。见 [AppPalette.glassBase]。
  static Color get _base => AppColors.palette.glassBase;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final dark = AppColors.isDark;

    // tint 保留给旧调用点：只极轻微调亮底板，不铺渐变、不产生白边。
    final tintNow = tint * 0.7 * 0.25;
    // 浅色下玻璃要更实一点：白底叠白玻璃如果太透，会看不清边界，
    // 于是整体从「磨砂玻璃」滑向「脏抹布」。深色维持原配方。
    final baseAlpha = blurEnabled
        ? (soft
              ? (dark ? 0.55 : 0.72)
              : (dark ? 0.66 : 0.82))
        : (dark ? 0.42 : 0.66);
    final fillColor = Color.alphaBlend(
      AppColors.w.withValues(alpha: tintNow),
      _base,
    ).withValues(alpha: baseAlpha);

    final body = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        color: gradient == null ? fillColor : null,
        gradient: gradient,
        border: border
            ? Border.all(
                // 深色：一道极细的冷白边表达厚度；
                // 浅色：同一条边换成淡墨，否则白边在白底上等于没有。
                color: dark
                    ? Colors.white.withValues(alpha: 0.09)
                    : const Color(0x14000000),
                width: 0.8,
              )
            : null,
      ),
      child: child,
    );

    // RepaintBoundary 必须放在 BackdropFilter 的 child 层：包在 filter 外层会
    // 新建 layer，导致 BackdropFilter 采样不到背后的内容（模糊失效）。
    final clipped = ClipRRect(
      borderRadius: r,
      child: blurEnabled
          ? BackdropFilter(
              filter: _blurFilter(blur),
              child: RepaintBoundary(child: body),
            )
          : RepaintBoundary(child: body),
    );

    Widget content = clipped;
    if (onTap != null) {
      content = LiquidPress(onTap: onTap, radius: radius, child: content);
    }
    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        // 浅色下阴影要更淡更散：深色投影落在白底上会变成一圈脏边。
        boxShadow: [
          BoxShadow(
            color: AppColors.palette.glassShadow,
            blurRadius: dark ? 12 : 18,
            offset: Offset(0, dark ? 4 : 6),
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
        : AppColors.w.withValues(alpha: 0.13);
    final bd = gold
        ? const Color(0x66FFB64D)
        : cyan
        ? const Color(0x6638E8C8)
        : AppColors.w.withValues(alpha: 0.16);
    final fg = gold
        ? const Color(0xFFFFD9A1)
        : cyan
        ? const Color(0xFFA7F3E4)
        : (color ?? AppColors.chipFg);
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
                  valueColor: AlwaysStoppedAnimation(AppColors.accent),
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
