import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import 'cached_image.dart';
import 'glass_toast.dart';

/// 新建 / 重命名收藏夹的输入弹窗
///
/// v1.7.43：外层加 [SingleChildScrollView]，修掉「输入框被切掉一截」——
/// 之前 Glass 直接顶在 Dialog 里，内容达到可用高度上限时 Flutter 会裁掉
/// 溢出部分，看起来像输入框少了一半。可滚动后最多变成「要滑一下」。
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
      child: SingleChildScrollView(
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
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withOpacity(0.07),
                  border: Border.all(color: Colors.white.withOpacity(0.16)),
                ),
                child: Center(
                  child: TextField(
                    controller: ctrl,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    style: const TextStyle(fontSize: 14),
                    cursorColor: AppColors.primary,
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: '输入收藏夹名称',
                      hintStyle: TextStyle(
                        fontSize: 13.5,
                        color: AppColors.muted,
                      ),
                    ),
                    onSubmitted: (v) => Navigator.pop(ctx, _clip(v)),
                  ),
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
                      onTap: () => Navigator.pop(ctx, _clip(ctrl.text)),
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
    ),
  );
}

/// 收藏夹名统一在这里截断：不用 `TextField.maxLength` 是因为它会挤出一行
/// 计数器，把原本就紧张的高度又吃掉一截（1.7.40 裁切问题的一部分）。
String _clip(String raw) {
  final t = raw.trim();
  return t.length > 20 ? t.substring(0, 20) : t;
}

/// 打开「收藏夹」弹层（v2）
///
/// 三处与 v1 的区别：
/// 1. 头部加**可点红心胶囊** —— 之前只能收藏不能取消，要取消得先退出弹窗回详情页；
/// 2. 「新建收藏夹」改**内联输入行** —— 不再弹二级对话框（输入框被切的现场就在那）；
/// 3. 整体**可滚动 + 避让键盘与手势条** —— 收藏夹多了也不会顶出屏幕。
Future<void> showFolderSheet(
  BuildContext context,
  AppState state,
  MediaItem item,
) async {
  // 未收藏时先自动收藏（保证这条片子在「全部」里能查到）
  if (!item.userFavorite) {
    await state.toggleFavorite(item);
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black54,
    builder: (_) => _FolderSheet(state: state, item: item),
  );
}

class _FolderSheet extends StatefulWidget {
  const _FolderSheet({required this.state, required this.item});

  final AppState state;
  final MediaItem item;

  @override
  State<_FolderSheet> createState() => _FolderSheetState();
}

class _FolderSheetState extends State<_FolderSheet> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  late bool _fav;
  late Set<String> _selected;
  bool _busy = false;

  AppState get _state => widget.state;

  /// 每次操作都取最新快照：`toggleFavorite` 是按 `item.userFavorite` 取反的，
  /// 如果一直用打开弹窗时那份快照，连点两次就会「一直取消」而不回收藏态。
  MediaItem get _item => _state.items.firstWhere(
    (e) => e.id == widget.item.id,
    orElse: () => widget.item,
  );

  @override
  void initState() {
    super.initState();
    _fav = _item.userFavorite;
    _selected = {..._state.folderIdsOfItem(widget.item.id)};
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _toggleFav() async {
    final next = !_item.userFavorite;
    await _state.toggleFavorite(_item);
    if (!mounted) return;
    setState(() {
      _fav = next;
      // 取消收藏时 AppState 会把这条从所有收藏夹里摘掉，这里同步清空，
      // 否则重新收藏时会「凭空」回到原来的夹子里。
      if (!next) _selected.clear();
    });
    if (!mounted) return;
    showToast(
      context,
      next ? '已加入收藏' : '已取消收藏',
      icon: next ? Icons.favorite_rounded : Icons.favorite_border_rounded,
    );
  }

  Future<void> _createInline() async {
    if (!_fav) return;
    final name = _clip(_ctrl.text);
    if (name.isEmpty) return;
    // 同名就直接复用，避免出现两个「想看」
    final exist = _state.folders.where((f) => f.name == name);
    if (exist.isNotEmpty) {
      setState(() {
        _selected.add(exist.first.id);
        _ctrl.clear();
      });
      _focus.unfocus();
      return;
    }
    final f = await _state.createFolder(name);
    if (!mounted) return;
    setState(() {
      _selected.add(f.id);
      _ctrl.clear();
    });
    _focus.unfocus();
    showToast(context, '已新建「$name」', icon: Icons.folder_rounded);
  }

  Future<void> _done() async {
    if (_busy) return;
    setState(() => _busy = true);
    if (_fav) {
      await _state.setItemFolders(widget.item.id, _selected);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // 键盘弹起时 viewInsets 已包含底部系统区，不能再叠加一次 safe area，
    // 否则输入行会被顶高一截（看起来「按钮飘了」）
    final bottomPad = media.viewInsets.bottom > 0
        ? 14.0
        : 14.0 + media.padding.bottom;
    final folders = _state.folders;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom + 8),
      child: Glass(
        radius: 26,
        blur: 26,
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 0),
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPad),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.82),
          child: SingleChildScrollView(
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
                _header(),
                const SizedBox(height: 16),
                Text(
                  '收藏夹（可多选）',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.muted.withOpacity(_fav ? 1 : 0.5),
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 9),
                if (folders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      '还没有自定义收藏夹，先在下面建一个吧',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.muted.withOpacity(0.9),
                      ),
                    ),
                  )
                else
                  Opacity(
                    opacity: _fav ? 1 : 0.42,
                    child: IgnorePointer(
                      ignoring: !_fav,
                      child: ConstrainedBox(
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
                                    selected: _selected.contains(f.id),
                                    onTap: () {
                                      setState(() {
                                        if (!_selected.remove(f.id)) {
                                          _selected.add(f.id);
                                        }
                                      });
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                _inlineInput(),
                const SizedBox(height: 14),
                LiquidPress(
                  radius: 23,
                  enabled: !_busy,
                  onTap: _done,
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(23),
                      gradient: _fav ? AppColors.ctaGradient : null,
                      color: _fav ? null : Colors.white.withOpacity(0.07),
                      border: _fav
                          ? null
                          : Border.all(
                              color: Colors.white.withOpacity(0.14),
                            ),
                      boxShadow: _fav
                          ? const [
                              BoxShadow(
                                color: Color(0x554F8CFF),
                                blurRadius: 16,
                                offset: Offset(0, 6),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      _fav ? '完成' : '关闭',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: _fav ? Colors.white : AppColors.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 38,
            height: 52,
            child: CachedImage(
              url: _item.posterUrlFor(200),
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
                _item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _fav ? '已收藏 · 选择要归入的收藏夹' : '未收藏 · 点红心即可加入收藏',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _HeartPill(on: _fav, onTap: _toggleFav),
      ],
    );
  }

  Widget _inlineInput() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 46,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        color: Colors.white.withOpacity(_fav ? 0.05 : 0.03),
        border: Border.all(
          color: Colors.white.withOpacity(0.14),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.add_rounded,
            size: 17,
            color: AppColors.muted.withOpacity(_fav ? 1 : 0.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              enabled: _fav,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 13),
              cursorColor: AppColors.primary,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '新建收藏夹，回车创建',
                hintStyle: TextStyle(fontSize: 12.5, color: AppColors.muted),
              ),
              onSubmitted: (_) => unawaited(_createInline()),
            ),
          ),
          const SizedBox(width: 6),
          // 只让「创建」按钮跟着输入内容重建，不惊动整个弹层
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _ctrl,
            builder: (_, v, __) => _CreateBtn(
              enabled: _fav && v.text.trim().isNotEmpty,
              onTap: _createInline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 头部红心胶囊：♥已收藏（粉红渐变）/ ♡收藏（灰玻璃）
class _HeartPill extends StatelessWidget {
  const _HeartPill({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 17,
      scale: 0.94,
      child: AnimatedContainer(
        duration: Anim.fast,
        curve: Anim.curve,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          gradient: on
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFF5E7A), Color(0xFFFF8A6B)],
                )
              : null,
          color: on ? null : Colors.white.withOpacity(0.06),
          border: on ? null : Border.all(color: Colors.white.withOpacity(0.18)),
          boxShadow: on
              ? const [
                  BoxShadow(
                    color: Color(0x55FF5E7A),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              on ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 15,
              color: on ? Colors.white : AppColors.muted,
            ),
            const SizedBox(width: 5),
            Text(
              on ? '已收藏' : '收藏',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: on ? Colors.white : AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateBtn extends StatelessWidget {
  const _CreateBtn({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: enabled ? onTap : null,
      radius: 10,
      scale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: enabled
              ? AppColors.primary.withOpacity(0.92)
              : Colors.white.withOpacity(0.06),
        ),
        child: Text(
          '创建',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: enabled ? Colors.white : AppColors.muted,
          ),
        ),
      ),
    );
  }
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
