// 平板/手机统一断点（M1 地基）
//
// 对齐设计稿 camby_tablet_redesign.html §响应式与断点：
//   ≥ 1200dp  扩展（expanded）：左侧导航栏 + 6 列栅格 + 主从分栏
//   840–1199  中等（medium）  ：图标条导航 + 4 列栅格 + 详情侧栏折叠
//   < 840dp   手机（phone）    ：底部 Tab + 3 列，保持手机手势一致
//
// 注意：之前方案 MD §3 写成 Material 3 的 600/840 二值，与设计稿三档不符，
// 此处以设计稿为准。MagicPad3 横屏≈1660 / 竖屏≈1110 均命中 ≥840（平板形态）。
//
// 约定：
// - 业务层（emby_client / app_state / 播控）**一律不**判断设备类型；
// - 只有「导航外壳」(main.dart) 会读取 breakpoint 决定 Rail vs 底部 Tab；
// - 页面内部如需分栏/列数，读 context.breakpoint 自行响应（后续 M2/M3）。

import 'package:flutter/material.dart';

/// 三档布局形态。
enum Breakpoint {
  /// < 840dp：手机，底部悬浮 Tab。
  phone,

  /// 840–1199dp：中等（多为竖屏平板 / 折叠屏展开），图标条 Rail。
  medium,

  /// ≥ 1200dp：扩展（横屏平板），带标签 Rail + 主从分栏。
  expanded,
}

/// 设计稿三档断点阈值。
const double kTabletBreakpoint = 840; // 平板形态起点（替代旧散落的 `>= 840`）
const double kExpandedBreakpoint = 1200; // 进入「扩展」主从分栏
const double kRailWidth = 96; // 设计稿 .rail{width:96px}

extension CambyLayout on BuildContext {
  double get screenWidth => MediaQuery.of(this).size.width;
  double get screenHeight => MediaQuery.of(this).size.height;

  /// 当前形态（读约束宽度，符合设计稿三档）。
  Breakpoint get breakpoint {
    final w = screenWidth;
    if (w >= kExpandedBreakpoint) return Breakpoint.expanded;
    if (w >= kTabletBreakpoint) return Breakpoint.medium;
    return Breakpoint.phone;
  }

  bool get isPhone => breakpoint == Breakpoint.phone;
  bool get isMedium => breakpoint == Breakpoint.medium;
  bool get isExpanded => breakpoint == Breakpoint.expanded;

  /// ≥840：平板形态（中等或扩展），统一启用左侧 Rail 替代底部 Tab。
  bool get isTablet => !isPhone;

  /// 是否启用左侧导航栏（替代底部 Tab）。
  bool get useRail => isTablet;

  /// 媒体栅格列数：扩展 7 列 / 中等 5 列 / 手机 3 列。
  /// v2.0.9 实测反馈：平板 6/4 列封面偏大，加密到 7/5（对齐「全部收藏」观感）。
  int get mediaGridColumns => isExpanded ? 7 : (isTablet ? 5 : 3);

  /// 收藏栅格列数：扩展 6 列 / 中等 5 列 / 手机 3 列。
  /// v2.0.9 实测反馈：一排 4 个浪费空间 → 中等 5、扩展 6。
  int get favoriteGridColumns => isExpanded ? 6 : (isTablet ? 5 : 3);
}

/// 播放页控件度量（手机 / 平板两套）
///
/// 播放器两端**功能完全一致**（都强制横屏），但控件尺寸与间距必须随分辨率
/// 放大，否则 1600×1000 的平板上会出现「三个小按钮挤在大屏中间」。
///
/// 判断依据用**屏幕短边（横屏下即高度）**，不能用宽：手机横屏宽 852
/// 已 ≥840，按宽判断会把手机误判成平板。
///
/// 平板数值对齐设计稿 camby_tablet_redesign.html §播放器：
/// `.pcenter .cbtn 56 / .big 84 / gap 44`、`.ptop padding 16 26`、
/// `.pbottom padding 0 30 18`、`.psub font-size 27`（= 基准 17 × 1.6）。
///
/// 手机端每一项都**等于改造前的写死值**，由 `test/player_ui_metrics_test.dart`
/// 逐项加锁，保证手机零视觉漂移。
class PlayerUi {
  const PlayerUi._({
    required this.tablet,
    required this.sideBtn,
    required this.sideIcon,
    required this.playBtn,
    required this.playIcon,
    required this.clusterGap,
    required this.topPadH,
    required this.topPadV,
    required this.topIcon,
    required this.topTitle,
    required this.topMeta,
    required this.topChipH,
    required this.topChipFont,
    required this.topChipPadH,
    required this.topIconGap,
    required this.topTitleGap,
    required this.barInset,
    required this.barBottom,
    required this.barGap,
    required this.barInnerGap,
    required this.barHitH,
    required this.barTrackH,
    required this.barActiveH,
    required this.timeFont,
    required this.chipH,
    required this.chipFont,
    required this.chipIcon,
    required this.chipGap,
    required this.tipW,
    required this.tipFont,
    required this.tipPadH,
    required this.tipPadV,
    required this.scrubFont,
    required this.scrubSubFont,
    required this.adjustW,
    required this.adjustEdge,
    required this.adjustIcon,
    required this.adjustBarH,
    required this.panelMaxW,
    required this.subtitleScale,
  });

  /// 手机横屏（短边 < 620）：沿用现有尺寸，一行不动。
  factory PlayerUi.phone() => const PlayerUi._(
    tablet: false,
    sideBtn: 50,
    sideIcon: 23,
    playBtn: 66,
    playIcon: 30,
    clusterGap: 26,
    topPadH: 14,
    topPadV: 8,
    topIcon: 15,
    topTitle: 13.5,
    topMeta: 10,
    topChipH: 34,
    topChipFont: 11,
    topChipPadH: 12,
    topIconGap: 8,
    topTitleGap: 10,
    barInset: 16,
    barBottom: 10,
    barGap: 8,
    barInnerGap: 10,
    barHitH: 34,
    barTrackH: 4,
    barActiveH: 8,
    timeFont: 11,
    chipH: 30,
    chipFont: 11,
    chipIcon: 13,
    chipGap: 8,
    tipW: 92,
    tipFont: 17,
    tipPadH: 14,
    tipPadV: 12,
    scrubFont: 32,
    scrubSubFont: 12,
    adjustW: 68,
    adjustEdge: 48,
    adjustIcon: 17,
    adjustBarH: 150,
    panelMaxW: 470,
    subtitleScale: 1.0,
  );

  /// 平板横屏（短边 ≥ 620）：设计稿尺寸，间距放大幅度大于按钮。
  factory PlayerUi.tablet() => const PlayerUi._(
    tablet: true,
    sideBtn: 56,
    sideIcon: 26,
    playBtn: 84,
    playIcon: 36,
    clusterGap: 44,
    topPadH: 26,
    topPadV: 16,
    topIcon: 19,
    topTitle: 16,
    topMeta: 12,
    topChipH: 38,
    topChipFont: 12.5,
    topChipPadH: 16,
    topIconGap: 12,
    topTitleGap: 14,
    barInset: 30,
    barBottom: 18,
    barGap: 12,
    barInnerGap: 14,
    barHitH: 46,
    barTrackH: 6,
    barActiveH: 11,
    timeFont: 13.5,
    chipH: 38,
    chipFont: 13.5,
    chipIcon: 16,
    chipGap: 12,
    tipW: 112,
    tipFont: 21,
    tipPadH: 18,
    tipPadV: 14,
    scrubFont: 44,
    scrubSubFont: 15,
    adjustW: 84,
    adjustEdge: 72,
    adjustIcon: 21,
    adjustBarH: 190,
    panelMaxW: 620,
    subtitleScale: 1.6,
  );

  final bool tablet;
  final double sideBtn;
  final double sideIcon;
  final double playBtn;
  final double playIcon;
  final double clusterGap;
  final double topPadH;
  final double topPadV;
  final double topIcon;
  final double topTitle;
  final double topMeta;
  final double topChipH;
  final double topChipFont;
  final double topChipPadH;
  final double topIconGap;
  final double topTitleGap;
  final double barInset;
  final double barBottom;
  final double barGap;
  final double barInnerGap;
  final double barHitH;
  final double barTrackH;
  final double barActiveH;
  final double timeFont;
  final double chipH;
  final double chipFont;
  final double chipIcon;
  final double chipGap;
  final double tipW;
  final double tipFont;
  final double tipPadH;
  final double tipPadV;
  final double scrubFont;
  final double scrubSubFont;
  final double adjustW;
  final double adjustEdge;
  final double adjustIcon;
  final double adjustBarH;
  final double panelMaxW;
  final double subtitleScale;

  /// 双击 ±10 秒提示相对屏心的水平位移（右侧为正）：
  ///   播放钮半宽 + 按钮间隔 + 快进退钮**整宽** + 按钮间隔 + 气泡半宽
  /// 手机：33 + 26 + 50 + 26 + 46 = 181（与 v2.0.3 定稿一致）
  /// 平板：42 + 44 + 56 + 44 + 56 = 242
  /// 注意气泡与按钮之间留的是**一整个 clusterGap**，所以公式里出现两次。
  double get tipOffset =>
      playBtn / 2 + clusterGap + sideBtn + clusterGap + tipW / 2;

  /// 按屏幕短边取度量：≥620 走平板，否则手机。
  static PlayerUi of(BuildContext context) {
    final short = MediaQuery.sizeOf(context).shortestSide;
    return short >= 620 ? PlayerUi.tablet() : PlayerUi.phone();
  }

  /// 同 of()，直接传尺寸（测试用）。
  static PlayerUi forSize(Size size) =>
      size.shortestSide >= 620 ? PlayerUi.tablet() : PlayerUi.phone();
}
