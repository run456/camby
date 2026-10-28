import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 全局轻量提示：白字 + 深色玻璃底 + 细白描边。
///
/// 不用 SnackBar 是因为它继承主题正文色，在深色玻璃上会出现「字看不见」的问题；
/// 这里直接挂在 root Overlay 上，任何页面调用都是同一套观感。
void showToast(
  BuildContext context,
  String text, {
  IconData? icon,
  Duration duration = const Duration(milliseconds: 1600),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  // 连续提示时先移除上一条：避免两条气泡同位置堆叠出“横线”
  _current?.remove();
  final entry = OverlayEntry(
    builder: (_) => _ToastBubble(text: text, icon: icon, duration: duration),
  );
  _current = entry;
  overlay.insert(entry);
  unawaited(
    Future<void>.delayed(
      duration + const Duration(milliseconds: 220),
      () {
        if (_current == entry) _current = null;
        entry.remove();
      },
    ),
  );
}

OverlayEntry? _current;

class _ToastBubble extends StatefulWidget {
  const _ToastBubble({required this.text, required this.duration, this.icon});

  final String text;
  final IconData? icon;
  final Duration duration;

  @override
  State<_ToastBubble> createState() => _ToastBubbleState();
}

class _ToastBubbleState extends State<_ToastBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
    Future<void>.delayed(widget.duration, () {
      if (mounted) _c.reverse();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 24,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _c,
          child: Center(
            // 宽度上限：长文案也不会把气泡撑到贴边/溢出
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.86,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  // 纯深色玻璃：不用渐变描边（渐变叠在视频上会出现亮线）
                  color: const Color(0xE6161C29),
                  border: Border.all(color: Colors.white.withOpacity(0.16)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x4D000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(widget.icon, size: 14, color: AppColors.accent),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        widget.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
