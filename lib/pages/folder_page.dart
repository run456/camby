import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/folder_sheet.dart';
import '../widgets/media_filter_sheet.dart';
import '../widgets/media_poster.dart';

/// 收藏夹内容页：3 列海报网格 + 与演员页同款的排序筛选
/// folderId == null 表示「全部收藏」
class FolderPage extends StatefulWidget {
  const FolderPage({
    super.key,
    required this.state,
    required this.onOpenDetail,
    this.folderId,
  });

  final AppState state;
  final OpenDetail onOpenDetail;
  final String? folderId;

  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  /// 排序（与媒体库 / 演员页同一套）：0 发行日期 / 1 评分 / 2 标题
  int _sortKey = 0;
  bool _desc = true;

  /// 年代筛选：0 不限 / 1 近 3 年 / 2 近 10 年 / 3 更早
  int _decade = 0;

  Future<void> _showFilterSheet(int total) async {
    final result = await showMediaFilterSheet(
      context,
      sortKey: _sortKey,
      desc: _desc,
      decade: _decade,
      total: total,
    );
    if (result == null || !mounted) return;
    setState(() {
      _sortKey = result.$1;
      _desc = result.$2;
      _decade = result.$3;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final folder = state.folderById(widget.folderId);
        final items = folder == null
            ? state.favorites
            : state.itemsOfFolder(folder);
        final shown = applyMediaFilter(
          items,
          sortKey: _sortKey,
          desc: _desc,
          decade: _decade,
        );
        final title = folder?.name ?? '全部收藏';
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                  child: Row(
                    children: [
                      GlassIconButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        size: 38,
                        iconSize: 15,
                        onTap: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              '${items.length} 部影片',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 排序与筛选：与演员页同款（排序字段 × 升/降 + 年代）
                      LiquidPress(
                        onTap: () => _showFilterSheet(items.length),
                        radius: 999,
                        scale: 0.94,
                        semanticLabel: '排序与筛选',
                        child: Container(
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: Colors.white.withOpacity(0.05),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.10),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.tune_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                mediaFilterSummary(_sortKey, _desc, _decade),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (folder != null) ...[
                        const SizedBox(width: 8),
                        GlassIconButton(
                          icon: Icons.edit_outlined,
                          size: 38,
                          iconSize: 16,
                          onTap: () => _manageFolder(context, folder),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: shown.isEmpty
                      ? _empty()
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 112),
                          physics: const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 11,
                                mainAxisSpacing: 16,
                                childAspectRatio: 0.55,
                              ),
                          itemCount: shown.length,
                          itemBuilder: (c, i) {
                            final it = shown[i];
                            return GestureDetector(
                              onLongPress: () =>
                                  showFolderSheet(context, state, it),
                              child: PosterCard(
                                item: it,
                                width: double.infinity,
                                heroTag:
                                    'fav-${widget.folderId ?? 'all'}-${it.id}',
                                onTap: () => widget.onOpenDetail(
                                  it,
                                  heroTag:
                                      'fav-${widget.folderId ?? 'all'}-${it.id}',
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_open_rounded,
            size: 44,
            color: AppColors.muted.withOpacity(0.5),
          ),
          const SizedBox(height: 12),
          const Text(
            '这个收藏夹还是空的',
            style: TextStyle(fontSize: 13.5, color: AppColors.muted),
          ),
          const SizedBox(height: 6),
          const Text(
            '在「全部收藏」里长按影片即可归入',
            style: TextStyle(fontSize: 11.5, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  void _manageFolder(BuildContext context, FavoriteFolder folder) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Glass(
        radius: 24,
        blur: 24,
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: Colors.white.withOpacity(0.26),
              ),
            ),
            const SizedBox(height: 16),
            _action(
              icon: Icons.drive_file_rename_outline_rounded,
              label: '重命名收藏夹',
              onTap: () async {
                Navigator.pop(ctx);
                final name = await promptFolderName(
                  context,
                  title: '重命名收藏夹',
                  initial: folder.name,
                  confirmText: '保存',
                );
                if (name == null || name.isEmpty) return;
                await widget.state.renameFolder(folder.id, name);
              },
            ),
            const SizedBox(height: 8),
            _action(
              icon: Icons.delete_outline_rounded,
              label: '删除收藏夹（影片仍保留在收藏）',
              danger: true,
              onTap: () async {
                Navigator.pop(ctx);
                await widget.state.deleteFolder(folder.id);
                if (context.mounted) Navigator.pop(context);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return LiquidPress(
      onTap: onTap,
      radius: 14,
      scale: 0.98,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: danger
              ? const Color(0x1FFF6B8A)
              : Colors.white.withOpacity(0.06),
          border: Border.all(
            color: danger
                ? const Color(0x55FF6B8A)
                : Colors.white.withOpacity(0.12),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: danger ? AppColors.danger : Colors.white,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: danger ? AppColors.danger : Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
