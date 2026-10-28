import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import 'cached_image.dart';

/// 新建 / 重命名收藏夹的输入弹窗
Future<String?> promptFolderName(
  BuildContext context, {
  String title = '新建收藏夹',
  String initial = '',
  String confirmText = '创建',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 34),
      child: Glass(
        radius: 24,
        blur: 24,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.white.withOpacity(0.07),
                border: Border.all(color: Colors.white.withOpacity(0.16)),
              ),
              child: TextField(
                controller: ctrl,
                autofocus: true,
                maxLength: 20,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                  hintText: '输入收藏夹名称',
                  hintStyle: TextStyle(fontSize: 13.5, color: AppColors.muted),
                ),
                onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: LiquidPress(
                    onTap: () => Navigator.pop(ctx),
                    radius: 22,
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        color: Colors.white.withOpacity(0.07),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.14),
                        ),
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LiquidPress(
                    onTap: () => Navigator.pop(ctx, ctrl.text.trim()),
                    radius: 22,
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        gradient: AppColors.ctaGradient,
                      ),
                      child: Text(
                        confirmText,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 打开「移动到收藏夹」弹层
/// - 影片未收藏时先自动收藏（保证出现在「全部」里）
/// - 支持多选、当场新建收藏夹
Future<void> showFolderSheet(
  BuildContext context,
  AppState state,
  MediaItem item,
) async {
  if (!item.userFavorite) {
    await state.toggleFavorite(item);
  }
  if (!context.mounted) return;

  final selected = <String>{...state.folderIdsOfItem(item.id)};

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 8,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheet) {
            final folders = state.folders;
            return Glass(
              radius: 26,
              blur: 26,
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 抓手
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: Colors.white.withOpacity(0.26),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 38,
                          height: 52,
                          child: CachedImage(
                            url: item.posterUrlFor(200),
                            memWidth: 200,
                            errorWidget: Container(
                              color: Colors.white.withOpacity(0.08),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            const Text(
                              '已收藏 · 选择要归入的收藏夹',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '移动到收藏夹（可多选）',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.muted,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 9),
                  if (folders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        '还没有自定义收藏夹，先新建一个吧',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.muted.withOpacity(0.9),
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 232),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final f in folders)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _FolderRow(
                                  name: f.name,
                                  count: f.itemIds.length,
                                  selected: selected.contains(f.id),
                                  onTap: () {
                                    setSheet(() {
                                      if (!selected.remove(f.id)) {
                                        selected.add(f.id);
                                      }
                                    });
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 2),
                  // 当场新建
                  LiquidPress(
                    onTap: () async {
                      final name = await promptFolderName(ctx);
                      if (name == null || name.isEmpty) return;
                      final f = await state.createFolder(name);
                      selected.add(f.id);
                      setSheet(() {});
                    },
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        color: Colors.white.withOpacity(0.04),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.14),
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.add_rounded,
                            size: 17,
                            color: AppColors.muted,
                          ),
                          SizedBox(width: 8),
                          Text(
                            '新建收藏夹…',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  LiquidPress(
                    radius: 13,
                    onTap: () async {
                      await state.setItemFolders(item.id, selected);
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: Container(
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(23),
                        gradient: AppColors.ctaGradient,
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x554F8CFF),
                            blurRadius: 16,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Text(
                        '完成',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.name,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 13,
      scale: 0.98,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x4D4F8CFF), Color(0x1F5F8CFF)],
                )
              : LinearGradient(
                  colors: [
                    Colors.white.withOpacity(0.07),
                    Colors.white.withOpacity(0.04),
                  ],
                ),
          border: Border.all(
            color: selected
                ? const Color(0x994F8CFF)
                : Colors.white.withOpacity(0.12),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.folder_rounded : Icons.folder_open_rounded,
              size: 16,
              color: selected ? const Color(0xFF9CC2FF) : AppColors.muted,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? Colors.white : const Color(0xFFD5E1F2),
                ),
              ),
            ),
            Text(
              '$count',
              style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
            ),
            const SizedBox(width: 9),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 19,
              height: 19,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.primary : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? AppColors.primary
                      : Colors.white.withOpacity(0.34),
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(
                      Icons.check_rounded,
                      size: 12,
                      color: Colors.white,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
