// 平板「数据」tab 统一布局行组件（v2.0.104）
//
// 背景：数据洞察页（stats_page）与观影日历页（watch_calendar_page）此前各用
// 一套互不相同、彼此错位的分栏逻辑——洞察页把卡片左右交替塞进两条独立流式
// Column，日历页手写 Row + 两列 Column，列高都由数据决定，结果同行卡片底边
// 与下一张起点必然错位。用户明确选择「等宽双列 · 按行对齐 · 等高拉伸填满」。
//
// 本文件提供两个子页共用的唯一排布原语 [equalHeightRow] 与两个共享常量，
// 保证两页在平板（≥840dp）上视觉一致；手机端两页仍走各自单列，不受影响。

import 'package:flutter/material.dart';

/// 平板双栏列间距（两个子页共用）。
const double kTabletColumnGap = 14.0;

/// 底部悬浮导航留白：页面 ListView 的 padding.bottom 统一引用此值。
///
/// 导航条位于 `MediaQuery.padding.bottom + 20`、高 `AppNav.barHeight=56`，
/// 合计约 76dp；150 留出充足呼吸空间，深/浅色、全面屏/非全面屏都不遮挡。
const double kFloatingNavInset = 150.0;

/// 一行两卡：等宽、顶部对齐、等高拉伸填满。
///
/// [IntrinsicHeight] 先把整行高度定为两张卡中较高者，[Row] 的
/// `CrossAxisAlignment.stretch` 再把较矮的一张拉到同高。两张卡各占一个
/// [Expanded]，宽度始终相等。行数有界、且作为列表项懒构造时才 build，
/// 额外一次 intrinsic 测量的开销可接受；不使用 GridView/shrinkWrap/
/// crossAxisCount，不触 `tools/perf_audit.py` 任何红线。
///
/// [left]/[right] 若为 `null`，该侧仍占位（空 [SizedBox.expand]），保证另一半
/// 不会被拉满整行——奇数尾卡需要这种"半幅留白"行为。
Widget equalHeightRow(
  BuildContext context,
  Widget? left,
  Widget? right, {
  double gap = kTabletColumnGap,
}) {
  return IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: left ?? const SizedBox.expand()),
        SizedBox(width: gap),
        Expanded(child: right ?? const SizedBox.expand()),
      ],
    ),
  );
}
