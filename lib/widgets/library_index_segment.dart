import 'package:flutter/material.dart';

import 'haptics.dart';
import 'liquid_press.dart';

/// 媒体库二级浏览维度（v2.0.60 设计稿方案 A，v2.0.68 扩为 4 类）。
///
/// 用户确认：收藏与媒体库合并，不再占一级导航；原收藏页位置换成搜索 Tab。
/// 于是「影片 / 演员 / 系列 / 收藏」四个维度共用顶部这一条分段控件，
/// 四个页面（含演员 / 系列 / 收藏索引页）顶部都常驻它。
enum LibraryIndexTab { movies, actors, series, favorites }

/// 四档雾面分段控件（v2.0.68）。
///
/// 这套白 6% 底 / 白 10% 描边 / 白雾面选中项的样式，被 v2.0.68 的
/// 底部导航 `GlassNavBar` 直接复用，是全应用「低干扰选中态」的基准。
class LibraryIndexSegment extends StatelessWidget {
  const LibraryIndexSegment({
    super.key,
    required this.tab,
    required this.onChanged,
  });

  final LibraryIndexTab tab;
  final ValueChanged<LibraryIndexTab> onChanged;

  /// v2.0.68：全部使用空心线性图标，与一级 Tab 的 outlined 图标族一致。
  static const _labels = ['影片', '演员', '系列', '收藏'];
  static const _icons = [
    Icons.local_movies_outlined,
    Icons.person_outline_rounded,
    Icons.collections_bookmark_outlined,
    Icons.favorite_border_rounded,
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
