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

  /// 媒体栅格列数（设计稿 §断点）：扩展 6 列 / 中等 4 列 / 手机 3 列。
  int get mediaGridColumns => isExpanded ? 6 : (isTablet ? 4 : 3);

  /// 收藏栅格列数（设计稿 .collection）：扩展 5 列 / 中等 4 列 / 手机 3 列。
  int get favoriteGridColumns => isExpanded ? 5 : (isTablet ? 4 : 3);
}
