import 'dart:ui';

import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';
import 'liquid_press.dart';

/// 通用玻璃面板容器：播放页四类弹层（变速 / 字幕 / 信息 / 样式）与在线字幕
/// 搜索面板共用同一套外观。
///
/// 设计上刻意是**居中卡片**而不是底部抽屉：横屏播放时底部抽屉会压住进度条，
/// 也不方便单手够。最大宽度走 [PlayerUi.panelMaxW]（手机 470 / 平板 620），
/// 因此手机和平板都不会拉成一条横贯屏幕的色块。
///
/// [blur] 控制是否做真正的液态玻璃磨砂：
/// - `false`（默认，播放器弹层）：高不透明底色 + 细边框 + 投影，**不做**
///   实时背景重采样，避免每次唤出面板都把视频压停；用厚重底色 + 边框 + 投影
///   还原玻璃观感。面板本身是静态的，外层包 RepaintBoundary。
/// - `true`（详情页的翻译弹层等）：对面板背后的内容做 [BackdropFilter] 高斯模糊，
///   叠半透明深色玻璃质感 + 顶部高光，是真正的 frosted / liquid glass。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.blur = false,
    this.maxWidth,
    this.maxHeightFactor,
  });

  final Widget child;

  /// 是否开启真正的背景磨砂（液态玻璃）。详见类注释。
  final bool blur;

  /// v2.0.66：覆盖默认面板宽度（PlayerUi.panelMaxW：手机 470 / 平板 620）。
  /// 「播放信息」字段短，收窄到 400 更像一张信息卡，不再是一大块黑板。
  final double? maxWidth;

  /// 相对可用高度的比例硬上限。不传时沿用 avail - 24（尽量吃满）。
  /// 只对需要兜底的短面板传，字幕列表 / 在线字幕等长列表保持原行为。
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final avail = media.size.height - media.padding.vertical;
    final fullH = avail - 24;
    final wanted = avail * (maxHeightFactor ?? 1);
    final floor = fullH < 200 ? fullH : 200.0;
    final maxH = maxHeightFactor == null
        ? fullH
        : wanted.clamp(floor, fullH).toDouble();
    return RepaintBoundary(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth ?? PlayerUi.of(context).panelMaxW,
            // 上下各留 12px，尽量吃满可用高度（横屏 ~500px 也能显示完整）
            maxHeight: maxH,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: blur
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.10),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 40,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: blur
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.12),
                              Colors.white.withValues(alpha: 0.04),
                            ],
                          ),
                        ),
                        child: child,
                      ),
                    ),
                  )
                : Container(
                    decoration: BoxDecoration(
                      color: const Color(0xF2141A28),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: child,
                  ),
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
        pageBuilder: (ctx, _, _) =>
            Material(type: MaterialType.transparency, child: builder(ctx)),
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
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
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

// ───────────────────────────────────────────────────────────────────────────
// v2.0.82 · 全站统一弹窗
// ───────────────────────────────────────────────────────────────────────────

/// 居中弹窗的公共骨架（原播放页私有 `_Sheet`，一字未改地上提）。
/// 「选择字幕」面板就是它的实例：[GlassPanel] 磨砂卡 + 白粗标题 +
/// 右上角圆形关闭按钮 + 可滚动内容。全站居中弹窗一律复用它，
/// 不再各页面自己拼 `Dialog + Glass`，避免同一 App 里三套弹窗外观。
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.title,
    required this.children,
    this.blur = true,
    this.maxWidth,
    this.maxHeightFactor,
    this.compact = false,
  });

  final String title;
  final List<Widget> children;
  final bool blur;
  final double? maxWidth;
  final double? maxHeightFactor;

  /// 短面板按内容收拢，不拉伸成近满屏（播放信息卡用）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      blur: blur,
      maxWidth: maxWidth,
      maxHeightFactor: maxHeightFactor,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏固定，不随内容滚动
            Padding(
              padding: compact
                  ? const EdgeInsets.fromLTRB(16, 10, 12, 6)
                  : const EdgeInsets.fromLTRB(20, 14, 14, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: compact ? 14 : 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).maybePop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.10),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (compact)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 2, bottom: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 弹窗底部的一条动作：**纯文字 + 统一蓝色**（v2.0.82）。
/// 不再有青绿「知道了」、灰色「取消」、红色「删除」或主题默认色。
class AppDialogAction<T> {
  const AppDialogAction({required this.label, this.value, this.onTap});

  final String label;

  /// 点击后 pop 出去的值；给了 [onTap] 时忽略。
  final T? value;

  /// 需要复制文本 / 重新拉数据等自定义行为时自己接管（记得自行 pop）。
  final void Function(BuildContext context)? onTap;
}

/// 统一的居中说明 / 确认弹窗。
///
/// - 容器：与「选择字幕」完全同款 [GlassPanel] + [AppSheet]（`blur: true`，
///   圆角 24、白 18% 细边、右上圆形关闭、淡入缩放入场、支持返回手势）。
/// - 文字：标题白粗；正文蓝灰 `#9FB0CC`（与字幕面板提示文字同色）；
///   **所有动作文字统一 [AppColors.accent] 蓝**。
/// - [message] 与 [body] 二选一：纯说明用前者，需要 `SelectableText` /
///   输入框 / 多段排版时传后者。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget? body,
  WidgetBuilder? bodyBuilder,
  List<AppDialogAction<T>> actions = const [],
  double? maxWidth,
}) {
  assert(
    message != null || body != null || bodyBuilder != null,
    'showAppDialog 需要 message / body / bodyBuilder',
  );
  return Navigator.of(context).push<T>(
    GlassPanelRoute<T>(
      builder: (ctx) => AppSheet(
        title: title,
        maxWidth: maxWidth,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
            child: bodyBuilder != null
                ? bodyBuilder(ctx)
                : (body ??
                      Text(
                        message ?? '',
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: Color(0xFF9FB0CC),
                        ),
                      )),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final a in actions)
                    LiquidPress(
                      radius: 10,
                      onTap: () {
                        if (a.onTap != null) {
                          a.onTap!(ctx);
                        } else {
                          Navigator.of(ctx).pop(a.value);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(
                          a.label,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
