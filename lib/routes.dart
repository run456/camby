import 'package:flutter/material.dart';

import 'theme.dart';

/// 全站统一的转场（v1.7.39）。
///
/// 背景：详情页走 300ms Hero、搜索页 220ms 淡入、设置/媒体库还是
/// `MaterialPageRoute` 的默认右滑缩放，同一个 App 里有三种转场语言。
/// 这里统一收成一条：**淡入 + 轻微上浮**，时长与曲线都取 [Anim]。
///
/// 为什么不用 `MaterialPageRoute`：它的默认动画是平台相关的（Android 上
/// 从底部升起并淡入、iOS 上从右侧推入），同一份代码在两个平台手感不同，
/// 而且时长不可控。`PageRouteBuilder` 能把这两件事都钉死。
class CambyRoutes {
  const CambyRoutes._();

  /// 统一淡入转场。
  ///
  /// 入场 320ms（[Anim.slow]）淡入 + 8dp 上浮，退场 280ms（[Anim.exit]）
  /// 反向播放 —— 退场比入场略快，符合"退出要干脆"的直觉。
  static PageRoute<T> fade<T>({
    required WidgetBuilder builder,
    String? name,
    bool fullscreenDialog = false,
  }) {
    return PageRouteBuilder<T>(
      settings: RouteSettings(name: name),
      fullscreenDialog: fullscreenDialog,
      transitionDuration: Anim.slow,
      reverseTransitionDuration: Anim.exit,
      pageBuilder: (context, animation, secondaryAnimation) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Anim.curve,
          reverseCurve: Anim.curveIn,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.012),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}
