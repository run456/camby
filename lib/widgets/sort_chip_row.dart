import 'package:flutter/material.dart';

import '../theme.dart';
import 'liquid_press.dart';

/// 统一的排序选择行：年份 / 标题 / 评分 三个胶囊。
///
/// v1.7.72：所有标签类页面（#分辨率 / 标签 / 中文字幕）共用同一控件、同一版式。
/// 交互：点选一个字段 → 按该字段**倒序**（降序）；再点同一字段 → 切换**正序**（升序），
/// 来回切换。选中字段带 ↑/↓ 箭头指示当前方向。
enum SortField { year, title, rating }

class SortChipRow extends StatelessWidget {
  const SortChipRow({
    super.key,
    required this.field,
    required this.ascending,
    required this.onChanged,
  });

  final SortField field;

  /// true = 正序（升序：年份从小到大 / 标题 A→Z / 评分低→高）
  final bool ascending;
  final void Function(SortField field, bool ascending) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          _chip('年份', SortField.year),
          const SizedBox(width: 8),
          _chip('标题', SortField.title),
          const SizedBox(width: 8),
          _chip('评分', SortField.rating),
        ],
      ),
    );
  }

  Widget _chip(String label, SortField f) {
    final on = field == f;
    final text = on
        ? '$label ${ascending ? '↑' : '↓'}'
        : label;
    return LiquidPress(
      radius: 999,
      scale: 0.95,
      onTap: () {
        // 已选中 → 翻转方向；未选中 → 默认倒序（更符合「先看新的/高分」）
        if (on) {
          onChanged(f, !ascending);
        } else {
          onChanged(f, false);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: on
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x3D4F8CFF), Color(0x1A5F8CFF)],
                )
              : null,
          color: on ? null : Colors.white.withOpacity(0.05),
          border: Border.all(
            color: on
                ? const Color(0x884F8CFF)
                : Colors.white.withOpacity(0.12),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            color: on ? const Color(0xFFCFE0FF) : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

/// 按统一字段排序（原地排序）。
void sortItemsBy(List items, SortField field, bool ascending) {
  int cmp(dynamic a, dynamic b) {
    switch (field) {
      case SortField.year:
        // 年份相同时按标题稳定排序，避免同批次影片乱跳
        final c = (a.year as int).compareTo(b.year as int);
        return c != 0 ? c : (a.name as String).compareTo(b.name as String);
      case SortField.title:
        return (a.name as String).toLowerCase().compareTo(
              (b.name as String).toLowerCase(),
            );
      case SortField.rating:
        final c = (a.rating as double).compareTo(b.rating as double);
        return c != 0 ? c : (a.name as String).compareTo(b.name as String);
    }
  }

  items.sort((a, b) => ascending ? cmp(a, b) : cmp(b, a));
}
