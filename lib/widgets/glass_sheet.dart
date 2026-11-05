import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';

/// 通用玻璃面板容器：播放页四类弹层（变速 / 字幕 / 信息 / 样式）与在线字幕
/// 搜索面板共用同一套外观。
///
/// 设计上刻意是**居中卡片**而不是底部抽屉：横屏播放时底部抽屉会压住进度条，
/// 也不方便单手够。最大宽度走 [PlayerUi.panelMaxW]（手机 470 / 平板 620），
/// 因此手机和平板都不会拉成一条横贯屏幕的色块。
///
/// 播放页一律不做实时背景重采样，避免每次唤出面板都把视频压停；这里用
/// 高不透明底色 + 细边框 + 投影还原同样的玻璃观感。面板本身是静态的，
/// 外层包 RepaintBoundary，父层重绘时不会跟着重绘整块卡片。
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final avail = media.size.height - media.padding.vertical;
    return RepaintBoundary(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: PlayerUi.of(context).panelMaxW,
            // 上下各留 12px，尽量吃满可用高度（横屏 ~500px 也能显示完整）
            maxHeight: avail - 24,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xF2141A28),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.10),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 40,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 居中面板的路由：自带可点暗层、淡入缩放入场，退场走反向动画。
///
/// 不用 `showGeneralDialog`：它底层的 RawDialogRoute 不接受返回手势，系统侧滑
/// 返回时面板会「啪」地消失。PageRouteBuilder 是标准 PageRoute，参与返回手势
/// 并驱动退场动画的反向播放。
class GlassPanelRoute<T> extends PageRouteBuilder<T> {
  GlassPanelRoute({required WidgetBuilder builder, super.settings})
    : super(
        opaque: false,
        barrierDismissible: true,
        barrierColor: const Color(0x99000000),
        barrierLabel: '关闭面板',
        transitionDuration: Anim.base,
        reverseTransitionDuration: Anim.fast,
        // PageRouteBuilder 的页面挂在 Navigator 的 Overlay 上，不会继承主页的
        // Scaffold/Material。缺 Material 祖先时，WidgetsApp 的兜底
        // DefaultTextStyle（debugLabel: "fallback style; consider putting your
        // text in a Material"，黄色双下划线）会 merge 进弹层里每一个 Text，
        // 即使 Text 自带 style 也只覆盖颜色/字号、盖不掉 decoration ——
        // 这就是弹层文字一片黄线的原因。这里统一补一层透明 Material，
        // 所有走 GlassPanelRoute 的面板一次性修好，且完全不改变外观。
        pageBuilder: (ctx, _, _) => Material(
          type: MaterialType.transparency,
          child: builder(ctx),
        ),
        transitionsBuilder: (ctx, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Anim.curve,
            reverseCurve: Anim.curveIn,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      );
}

/// 弹层里的一行：选中态用主题色高亮 + 勾选图标。
/// 播放页的字幕轨道、在线字幕搜索结果共用。
class SheetRow extends StatelessWidget {
  const SheetRow({
    super.key,
    required this.label,
    this.hint,
    this.leading,
    this.selected = false,
    required this.onTap,
  });

  final String label;
  final String? hint;

  /// 行首徽标（在线字幕用来标「迅雷 / SubtitleCat」），播放页轨道行不传。
  final Widget? leading;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected
                ? AppColors.accent.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              if (hint != null)
                Text(
                  hint!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9FB0CC),
                  ),
                ),
              if (selected) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: AppColors.accent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
