library;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'haptics.dart';
import 'liquid_press.dart';

/// 空态：说清「为什么空」+ 给一个能立刻点的动作（v2.0.64 质感包）。
///
/// 组件只负责统一视觉，**不套通用文案**：标题、原因、按钮名与真实动作
/// 全部由各页逐处传入（见对比稿 03 的 13 处 CTA 映射）。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.reason,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
  });

  final IconData icon;
  final String title;
  final String? reason;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: LayoutBuilder(
        builder: (context, cons) {
          final body = Padding(
            padding: padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              // 玻璃质感图标：纯渐变 + 高光边框，不用实时模糊，
              // 避免在空态这一层引入逐帧重采样。
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  borderRadius: AppRadii.lgBr,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0x2235E0C4), Color(0x0C7B6BF0)],
                  ),
                  border: Border.all(color: Colors.white.withOpacity(0.18)),
                ),
                child: Icon(icon, size: 30, color: AppColors.ink.withOpacity(0.86)),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink,
                ),
              ),
              if (reason != null) ...[
                const SizedBox(height: 7),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    reason!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.muted,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
              if (primaryLabel != null && onPrimary != null) ...[
                const SizedBox(height: 18),
                _PrimaryCta(label: primaryLabel!, onTap: onPrimary!),
              ],
              if (secondaryLabel != null && onSecondary != null) ...[
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () {
                    AppHaptics.light();
                    onSecondary!();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.muted,
                    textStyle: const TextStyle(fontSize: 11),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(secondaryLabel!),
                ),
              ],
              ],
            ),
          );
          // 空态常被放进无界高度的 Center / Column 里：此时不能塞
          // SingleChildScrollView（viewport 需要有限高度），直接返回内容。
          if (!cons.maxHeight.isFinite) return body;
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: body,
          );
        },
      ),
    );
  }
}

class _PrimaryCta extends StatelessWidget {
  const _PrimaryCta({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      radius: AppRadii.pill,
      scale: 0.97,
      onTap: () {
        AppHaptics.light();
        onTap();
      },
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          borderRadius: AppRadii.pillBr,
          gradient: AppColors.ctaGradient,
          border: Border.all(color: Colors.white.withOpacity(0.20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片内的小型空态（统计页各图表、分集 / 推荐区等）。
///
/// 这些位置空间有限，放不下大图标 + 双按钮：改成「一行原因 + 一个能点的动作」。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.align = TextAlign.left,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final showAction = actionLabel != null && onAction != null;
    return Column(
      crossAxisAlignment: align == TextAlign.center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          textAlign: align,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.muted,
            height: 1.5,
          ),
        ),
        if (showAction) ...[
          const SizedBox(height: 7),
          LiquidPress(
            radius: AppRadii.pill,
            scale: 0.97,
            onTap: () {
              AppHaptics.light();
              onAction!();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: AppRadii.pillBr,
                color: AppColors.primary.withOpacity(0.16),
                border: Border.all(color: AppColors.primary.withOpacity(0.45)),
              ),
              child: Text(
                actionLabel!,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFBFD4FF),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
