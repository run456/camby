import 'package:flutter/material.dart';

import 'haptics.dart';
import 'liquid_press.dart';

/// 媒体库二级浏览维度（v2.0.60 设计稿方案 A）。
///
/// 底部 5 个 Tab 已满且共用 `GlassNavBar._items`（手机 Tab 与平板 Rail 同源），
/// 所以「演员」「系列」不再占一级导航，而是收进媒体库页顶部的分段控件。
enum LibraryIndexTab { movies, actors, series }

/// 三档液态玻璃分段控件，与收藏页「影片收藏 / 演员收藏」同一套观感。
class LibraryIndexSegment extends StatelessWidget {
  const LibraryIndexSegment({
    super.key,
    required this.tab,
    required this.onChanged,
  });

  final LibraryIndexTab tab;
  final ValueChanged<LibraryIndexTab> onChanged;

  static const _labels = ['影片', '演员', '系列'];
  static const _icons = [
    Icons.local_movies_outlined,
    Icons.person_outline_rounded,
    Icons.collections_bookmark_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < LibraryIndexTab.values.length; i++)
            Expanded(child: _item(i)),
        ],
      ),
    );
  }

  Widget _item(int i) {
    final on = LibraryIndexTab.values[i] == tab;
    return LiquidPress(
      radius: 999,
      scale: 0.96,
      onTap: () {
        AppHaptics.light();
        onChanged(LibraryIndexTab.values[i]);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: on
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x38FFFFFF), Color(0x14FFFFFF)],
                )
              : null,
          border: Border.all(
            color: on ? Colors.white.withOpacity(0.26) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_icons[i], size: 13,
                color: on ? Colors.white : Colors.white.withOpacity(0.55)),
            const SizedBox(width: 5),
            Text(
              _labels[i],
              style: TextStyle(
                fontSize: 12,
                fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                color: on ? Colors.white : Colors.white.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
