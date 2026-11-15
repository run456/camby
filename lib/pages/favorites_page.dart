import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../layout.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/folder_sheet.dart';
import '../widgets/glass_toast.dart';
import '../widgets/empty_state.dart';
import '../widgets/library_index_segment.dart';
import '../widgets/media_poster.dart';
import 'folder_page.dart';
import 'person_page.dart';

/// 媒体库「收藏」维度（方案 B）：影片收藏 / 演员收藏
///
/// v2.0.68：收藏并入媒体库成为第 4 类，不再是一级 Tab 页；顶部与
/// 影片 / 演员 / 系列页共用 `LibraryIndexSegment` 4 类主分段，
/// 内部再分「影片收藏 / 演员收藏」两档次级维度。
/// 影片收藏以「海报堆叠墙」呈现收藏夹，点击进入夹内网格。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({
    super.key,
    required this.state,
    required this.onOpenDetail,
    this.onSwitchTab,
    this.onIndexTabChanged,
  });

  final AppState state;
  final OpenDetail onOpenDetail;

  /// v2.0.64 空态 CTA：切到「我的」Tab 连接服务器的真实跳转。
  final ValueChanged<int>? onSwitchTab;

  /// v2.0.68：4 类主分段切换（由 LibraryPage._setIndexTab 承接）。
  final ValueChanged<LibraryIndexTab>? onIndexTabChanged;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  int _tab = 0; // 0 影片 1 演员

  @override
  void initState() {
    super.initState();
    // 演员收藏来自服务端，进页面静默拉一次（失败保留本地缓存）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.state.server != null) widget.state.loadFavoritePersons();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final subtitle = _tab == 0
        ? '收藏 · ${state.favorites.length} 部 · ${state.activeFolders.length} 个收藏夹'
        : '收藏 · ${state.favoritePersons.length} 位演员';
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // 背景光晕：给玻璃提供采样内容
          Positioned(
            top: -110,
            right: -70,
            child: Container(
              width: 300,
              height: 300,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x334F8CFF), Color(0x004F8CFF)],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 60,
            left: -90,
            child: Container(
              width: 260,
              height: 260,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x2E7B5CFF), Color(0x007B5CFF)],
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // 标题
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                  child: Row(
                    // v1.7.67：标题 / 副标题 / 同步按钮水平居中对齐
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        '媒体库',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.6,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // v2.0.105：上传/下载分离，各自选「覆盖 / 合并」
                      _SyncButtons(state: state),
                    ],
                  ),
                ),
                // v1.7.64：标题区与封面的间距收紧（14→10），与下方
                // 「夹名 ↔ 新建卡」的节奏一致
                const SizedBox(height: 10),
                // v2.0.68：媒体库 4 类主分段（影片 / 演员 / 系列 / 收藏），
                // 与影片 / 演员 / 系列页顶部完全同一个组件。
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: LibraryIndexSegment(
                    tab: LibraryIndexTab.favorites,
                    onChanged: widget.onIndexTabChanged ?? (_) {},
                  ),
                ),
                const SizedBox(height: 10),
                // v2.0.97（设计稿 P0）：三格统计条。哪怕全是 0 也把结构撑起来 ——
                // 以前内容一空，整页就只剩两张卡和一大片黑。
                _StatsBar(
                  movies: state.favorites.length,
                  folders: state.activeFolders.length,
                  recent: widget.state.recentFavoriteCount(7),
                  tab: _tab,
                  onTab: _setSubTab,
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _tab == 0 ? _movieWall() : _actorGrid(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 影片 / 演员维度切换（v2.0.97：由统计条内联触发）。
  ///
  /// 切到演员时顺手拉一次收藏演员 —— 旧的分段控件在这里做了同样的事，
  /// 换皮不能把这个副作用弄丢。
  void _setSubTab(int i) {
    if (_tab == i) return;
    setState(() => _tab = i);
    if (i == 1 && widget.state.server != null) {
      widget.state.loadFavoritePersons();
    }
  }

  // ---------------- 影片收藏（v2.0.97 重做） ----------------

  /// 设计稿 §2：把「2 张小卡 + 大片留白」换成三段式 ——
  ///  · 空态：插画 + 双 CTA + 一句说明，告诉新用户下一步做什么；
  ///  · 有数据：收藏夹横滑大卡（沿用 [_StackTile] 的扇形堆叠）+ 最近收藏横排。
  /// 底部导航、毛玻璃、动效一律不动。
  Widget _movieWall() {
    final state = widget.state;
    final folders = state.activeFolders;
    final all = state.favorites;

    if (all.isEmpty && folders.isEmpty) {
      return _FavoritesEmpty(
        key: const ValueKey('movies-empty'),
        connected: state.server != null,
        onBrowse: () => widget.onIndexTabChanged?.call(LibraryIndexTab.movies),
        onConnect: () => widget.onSwitchTab?.call(4),
        onCreate: _createFolder,
      );
    }

    return ListView(
      key: const ValueKey('movies'),
      padding: EdgeInsets.fromLTRB(18, context.isTablet ? 2 : 6, 18, 112),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      children: [
        // 我的收藏夹
        Row(
          children: [
            Text(
              '我的收藏夹',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppColors.ink,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            if (folders.isNotEmpty)
              LiquidPress(
                radius: 999,
                scale: 0.95,
                onTap: () => _folderMenu(folders),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '管理',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 14,
                        color: AppColors.muted,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _folderGrid(folders, all),
        if (all.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Text(
                '最近收藏',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              LiquidPress(
                radius: 999,
                scale: 0.95,
                onTap: () => _openFolder(null, '全部收藏'),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '查看全部 ›',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accent.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            // PosterCard 自带片名行，高度 = 108/0.6667 + 标题 ≈ 200
            height: 204,
            child: ListView.builder(
              key: const ValueKey('recent-rail'),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: all.take(12).length,
              itemBuilder: (c, i) {
                final e = all[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: SizedBox(
                    width: 108,
                    child: PosterCard(
                      item: e,
                      width: 108,
                      showProgress: true,
                      onTap: () => widget.onOpenDetail(e),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  /// 一屏最多铺几个收藏夹 tile（含「全部」与末尾入口）。
  ///
  /// v2.0.103：以前是一条无止境的横滑条，夹子一多要来回甩才能找到目标，
  /// 而且扇形堆叠把封面互相遮住。改成 2 列（平板 3 列）网格，超出的收进
  /// 「管理」弹窗 —— 弹窗里可以直接点进对应收藏夹。
  static const int _kMaxFolderTiles = 6;

  Widget _folderGrid(List<FavoriteFolder> folders, List<MediaItem> all) {
    return LayoutBuilder(
      builder: (context, cons) {
        final cols = context.isTablet ? 3 : 2;
        const gap = 12.0;
        final cardW = (cons.maxWidth - gap * (cols - 1)) / cols;
        // 与 [_StackTile] 的 2:3 完整海报 + 两行标题保持一致
        final cardH = math.min(cardW * 1.5, 320.0) + 36;
        final shown = folders.take(_kMaxFolderTiles - 2).toList();
        final overflow = folders.length > shown.length;
        return Wrap(
          key: const ValueKey('folder-grid'),
          spacing: gap,
          runSpacing: 14,
          children: [
            _folderCard(
              key: const ValueKey('folder-all'),
              width: cardW,
              name: '全部',
              count: all.length,
              covers: all.take(4).toList(),
              onTap: () => _openFolder(null, '全部收藏'),
            ),
            for (final f in shown)
              _folderCard(
                key: ValueKey('folder-${f.id}'),
                width: cardW,
                name: f.name,
                count: f.itemIds.length,
                covers: widget.state.coverCandidates(f, 4),
                onTap: () => _openFolder(f.id, f.name),
                onLongPress: () => _manageFolder(f),
              ),
            if (overflow)
              _allFoldersCard(cardW, cardH, folders)
            else
              _newFolderCard(cardW, cardH),
          ],
        );
      },
    );
  }

  Widget _folderCard({
    Key? key,
    required double width,
    required String name,
    required int count,
    required List<MediaItem> covers,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return SizedBox(
      width: width,
      child: _StackTile(
        key: key,
        name: name,
        count: count,
        covers: covers,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }

  /// 新建收藏夹虚线卡（网格末格）。
  Widget _newFolderCard(double width, double height) {
    return SizedBox(
      width: width,
      height: height,
      child: _NewFolderTile(onTap: _createFolder),
    );
  }

  /// 收藏夹超出网格上限时的「查看全部」入口，点开就是可点进的管理弹窗。
  Widget _allFoldersCard(
    double width,
    double height,
    List<FavoriteFolder> folders,
  ) {
    return SizedBox(
      width: width,
      height: height,
      child: LiquidPress(
        radius: 14,
        scale: 0.97,
        onTap: () => _folderMenu(folders),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: math.min(width * 1.5, 320.0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.primary.withValues(alpha: 0.16),
                    AppColors.w.withValues(alpha: 0.04),
                  ],
                ),
                border: Border.all(color: AppColors.w.withValues(alpha: 0.14)),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.grid_view_rounded,
                      size: 30,
                      color: AppColors.accent.withValues(alpha: 0.9),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '查看全部收藏夹',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '共 ${folders.length} 个',
                      style: TextStyle(fontSize: 10, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '全部收藏夹',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「管理」弹窗：既是导航也是管理。
  ///
  /// v2.0.103 以前点整行只弹「重命名 / 删除」，想看夹子里有什么还得回到
  /// 横滑条去找 —— 夹子一多基本找不到。现在整行 = 进入该收藏夹，右侧「…」
  /// 才进重命名 / 删除；列表可滚动，顶上还有「全部收藏」和「新建」。
  void _folderMenu(List<FavoriteFolder> folders) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Glass(
        radius: 24,
        blur: 24,
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: AppColors.w.withValues(alpha: 0.26),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text(
                  '我的收藏夹',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '共 ${folders.length} 个 · 点开即进入',
                  style: TextStyle(fontSize: 10.5, color: AppColors.muted),
                ),
                const Spacer(),
                LiquidPress(
                  radius: 999,
                  scale: 0.95,
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _createFolder();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_rounded,
                          size: 14,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '新建',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.68,
              ),
              child: ListView(
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                children: [
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: _folderLeading(null),
                    title: Text(
                      '全部收藏',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    subtitle: Text(
                      '${widget.state.favorites.length} 部',
                      style: TextStyle(fontSize: 11, color: AppColors.muted),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _openFolder(null, '全部收藏');
                    },
                  ),
                  for (final f in folders)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: _folderLeading(f),
                      title: Text(
                        f.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink,
                        ),
                      ),
                      subtitle: Text(
                        '${f.itemIds.length} 部',
                        style: TextStyle(fontSize: 11, color: AppColors.muted),
                      ),
                      trailing: IconButton(
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          size: 18,
                          color: AppColors.muted,
                        ),
                        tooltip: '重命名 / 删除',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _manageFolder(f);
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openFolder(f.id, f.name);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹窗行左侧的小封面：有片就用该夹最近一部的海报，空夹给文件夹图标。
  Widget _folderLeading(FavoriteFolder? f) {
    final candidates = f == null
        ? widget.state.favorites.take(1).toList()
        : widget.state.coverCandidates(f, 1);
    final MediaItem? cover = candidates.isEmpty ? null : candidates.first;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 30,
        height: 44,
        child: cover == null
            ? Icon(Icons.folder_outlined, size: 20, color: AppColors.muted)
            : CachedImage(
                url: cover.posterUrlFor(300),
                memWidth: 200,
                errorWidget: Icon(
                  Icons.folder_outlined,
                  size: 20,
                  color: AppColors.muted,
                ),
              ),
      ),
    );
  }

  void _openFolder(String? id, String title) {
    Navigator.push(
      context,
      CambyRoutes.fade(
        builder: (_) => FolderPage(
          state: widget.state,
          folderId: id,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  Future<void> _createFolder() async {
    final name = await promptFolderName(context);
    if (name == null || name.isEmpty) return;
    await widget.state.createFolder(name);
  }

  void _manageFolder(FavoriteFolder f) {
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
                color: AppColors.w.withValues(alpha: 0.26),
              ),
            ),
            const SizedBox(height: 16),
            _sheetAction(
              icon: Icons.drive_file_rename_outline_rounded,
              label: '重命名收藏夹',
              onTap: () async {
                Navigator.pop(ctx);
                final name = await promptFolderName(
                  context,
                  title: '重命名收藏夹',
                  initial: f.name,
                  confirmText: '保存',
                );
                if (name == null || name.isEmpty) return;
                await widget.state.renameFolder(f.id, name);
              },
            ),
            const SizedBox(height: 8),
            _sheetAction(
              icon: Icons.delete_outline_rounded,
              label: '删除收藏夹（影片仍保留在收藏）',
              danger: true,
              onTap: () async {
                Navigator.pop(ctx);
                await widget.state.deleteFolder(f.id);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _sheetAction({
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
              : AppColors.w.withValues(alpha: 0.06),
          border: Border.all(
            color: danger
                ? const Color(0x55FF6B8A)
                : AppColors.w.withValues(alpha: 0.12),
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

  // ---------------- 演员收藏 ----------------

  Widget _actorGrid() {
    final state = widget.state;
    final list = state.favoritePersons;
    if (list.isEmpty) {
      final connected = state.server != null;
      return Center(
        key: const ValueKey('actors-empty'),
        child: state.favPersonsLoading
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(height: 12),
                  Text(
                    '正在读取演员收藏…',
                    style: TextStyle(fontSize: 13, color: AppColors.muted),
                  ),
                ],
              )
            : SizedBox(
                // v2.0.64：空态给一个能立刻点的真实动作，不再只是「一句死话」。
                height: 320,
                child: EmptyState(
                  icon: Icons.person_outline_rounded,
                  title: '还没有收藏演员',
                  reason: connected
                      ? '进入影片详情，在演员头像右上角点 ♥ 即可收藏。'
                      : '还没有连接服务器。先在「我的 → 我的服务器」连接，再回来收藏演员。',
                  primaryLabel: connected ? '去影片找演员' : '去连接服务器',
                  onPrimary: () {
                    // v2.0.68：收藏已在媒体库内，「去影片」是切 4 类主分段，
                    // 不再是切一级 Tab；「去连接服务器」仍跳「我的」。
                    if (connected) {
                      widget.onIndexTabChanged?.call(LibraryIndexTab.movies);
                    } else {
                      widget.onSwitchTab?.call(4);
                    }
                  },
                ),
              ),
      );
    }
    return GridView.builder(
      key: const ValueKey('actors'),
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 112),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // v2.0.59：头像不再撑满格宽，改为有上限的固定尺寸 + 加密列数。
        // 手机旧值 3 列时单个头像约 118dp，真机反馈「太大了」。
        crossAxisCount: context.actorGridColumns,
        crossAxisSpacing: 10,
        mainAxisSpacing: 14,
        childAspectRatio: 0.80,
      ),
      itemCount: list.length,
      itemBuilder: (c, i) {
        final p = list[i];
        return _ActorTile(
          person: p,
          state: state,
          onTap: () => _openPerson(p),
          onLongPress: () => _confirmUnfavActor(p),
        );
      },
    );
  }

  void _openPerson(CastMember p) {
    Navigator.push(
      context,
      CambyRoutes.fade(
        builder: (_) => PersonPage(
          person: p,
          state: widget.state,
          onOpenDetail: (m, {String? heroTag}) {
            Navigator.pop(context);
            widget.onOpenDetail(m, heroTag: heroTag);
          },
        ),
      ),
    );
  }

  void _confirmUnfavActor(CastMember p) {
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
                color: AppColors.w.withValues(alpha: 0.26),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '取消收藏「${p.name}」？',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            _sheetAction(
              icon: Icons.heart_broken_rounded,
              label: '取消收藏演员',
              danger: true,
              onTap: () async {
                Navigator.pop(ctx);
                await widget.state.togglePersonFavorite(p);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

// ---------------- 组件 ----------------

/// 海报堆叠卡：底层扇形错开，最上层为封面
class _StackTile extends StatelessWidget {
  const _StackTile({
    super.key,
    required this.name,
    required this.count,
    required this.covers,
    this.onTap,
    this.onLongPress,
  });

  final String name;
  final int count;
  final List<MediaItem> covers; // 0 = 最新（封面）
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    // v2.0.103：取消扇形叠放。三张海报互相压盖 + 0.85 缩放 + cover，
    // 让「封面显示不完整」—— 用户只能看到最上层海报被裁过的一条。
    // 现在一张海报按 2:3 原生比例铺满卡片宽度，不旋转、不缩放、不裁切；
    // 万一服务器给的是非标准比例，contain 也保证整张都在。
    final MediaItem? cover = covers.isEmpty ? null : covers.first;
    return LiquidPress(
      onTap: onTap,
      onLongPress: onLongPress,
      radius: 14,
      scale: 0.97,
      glow: 0.18,
      clip: false,
      child: LayoutBuilder(
        builder: (c, cons) {
          final w = cons.maxWidth;
          final posterH = math.min(w * 1.5, 320.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: SizedBox(
                      width: w,
                      height: posterH,
                      child: cover == null
                          ? _placeholder
                          : CachedImage(
                              url: cover.posterUrlFor(600),
                              memWidth: 600,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              errorWidget: _placeholder,
                            ),
                    ),
                  ),
                  if (count > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          color: Colors.black.withValues(alpha: 0.42),
                          border: Border.all(
                            color: AppColors.w.withValues(alpha: 0.16),
                          ),
                        ),
                        child: Text(
                          '$count',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                '$count 部影片',
                style: TextStyle(fontSize: 10, color: AppColors.muted),
              ),
            ],
          );
        },
      ),
    );
  }

  // v2.0.103：扇形叠放（原 _layer）已移除 —— 它把封面互相压盖并二次裁切，
  // 现在 [_StackTile.build] 直接铺一张完整海报。

  Widget get _placeholder => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF243049), Color(0xFF121826)],
      ),
    ),
    child: Center(
      child: Icon(
        Icons.movie_creation_outlined,
        size: 26,
        color: AppColors.w.withValues(alpha: 0.22),
      ),
    ),
  );
}

/// 标题行右侧的「与服务器同步」按钮（v1.7.66）。
///
/// 点击：把未上云的本地收藏夹推到服务端播放列表 + 拉回其他设备的改动，
/// 完成后 toast 汇报数量；未连接服务器时提示不可用。
/// 收藏夹上传/下载按钮组（v2.0.105）。
///
/// 旧的单按钮把「本机有夹」一律当成上行覆盖，导致平板旧数据反复冲掉手机
/// 新数据。现在方向由用户显式选择：上传 / 下载，各自再选「覆盖 / 合并」。
class _SyncButtons extends StatefulWidget {
  const _SyncButtons({required this.state});

  final AppState state;

  @override
  State<_SyncButtons> createState() => _SyncButtonsState();
}

class _SyncButtonsState extends State<_SyncButtons> {
  bool _uploading = false;
  bool _downloading = false;

  bool get _busy => _uploading || _downloading;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _roundButton(
          key: const ValueKey('fav-upload'),
          icon: Icons.cloud_upload_rounded,
          tooltip: '上传收藏到服务器',
          busy: _uploading,
          onTap: _busy ? null : () => _pickMode(upload: true),
        ),
        const SizedBox(width: 6),
        _roundButton(
          key: const ValueKey('fav-download'),
          icon: Icons.cloud_download_rounded,
          tooltip: '从服务器下载收藏',
          busy: _downloading,
          onTap: _busy ? null : () => _pickMode(upload: false),
        ),
      ],
    );
  }

  Widget _roundButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool busy,
    required VoidCallback? onTap,
  }) {
    return LiquidPress(
      onTap: onTap,
      radius: 999,
      scale: 0.92,
      glow: 0.14,
      child: Container(
        key: key,
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.w.withValues(alpha: 0.06),
          border: Border.all(color: AppColors.w.withValues(alpha: 0.12)),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              )
            : Tooltip(
                message: tooltip,
                child: Icon(icon, size: 18, color: Colors.white70),
              ),
      ),
    );
  }

  /// 弹出「覆盖 / 合并」选择。返回 null = 取消，true = 覆盖，false = 合并。
  Future<void> _pickMode({required bool upload}) async {
    final title = upload ? '上传到服务器' : '下载到本机';
    final desc = upload
        ? '把本机收藏夹同步到服务器播放列表。'
        : '把服务器播放列表刷新到本机收藏夹。';
    final overwrite = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.palette.glassBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.w.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(desc, style: TextStyle(fontSize: 12, color: AppColors.muted)),
              const SizedBox(height: 14),
              _modeTile(
                title: '覆盖',
                subtitle: upload
                    ? '服务器以本机为准，删除服务器多余的收藏夹和影片'
                    : '本机以服务器为准，删除本机多余的收藏夹和影片',
                color: AppColors.warn,
                icon: Icons.warning_amber_rounded,
                onTap: () => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 10),
              _modeTile(
                title: '合并',
                subtitle: '保留两端内容，取并集，不删除任何一方',
                color: AppColors.accent,
                icon: Icons.check_circle_outline_rounded,
                onTap: () => Navigator.pop(ctx, false),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('取消', style: TextStyle(color: AppColors.muted)),
              ),
            ],
          ),
        ),
      ),
    );
    if (overwrite == null || !mounted) return;
    await _run(upload: upload, overwrite: overwrite);
  }

  Widget _modeTile({
    required String title,
    required String subtitle,
    required Color color,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return LiquidPress(
      onTap: onTap,
      radius: 14,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.w.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.w.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _run({
    required bool upload,
    required bool overwrite,
  }) async {
    if (widget.state.server == null) {
      showToast(context, '未连接服务器，无法同步', icon: Icons.info_outline_rounded);
      return;
    }
    setState(() {
      if (upload) {
        _uploading = true;
      } else {
        _downloading = true;
      }
    });
    final action = upload ? '上传' : '下载';
    final mode = overwrite ? '覆盖' : '合并';
    try {
      final n = upload
          ? await widget.state.uploadFoldersToServer(overwrite: overwrite)
          : await widget.state.downloadFoldersFromServer(overwrite: overwrite);
      if (!mounted) return;
      final pending = widget.state.pendingSyncCount;
      if (pending > 0) {
        final d = widget.state.folderSyncDiag;
        final detail = d.isEmpty
            ? ''
            : '：${d.length > 42 ? '${d.substring(0, 42)}…' : d}';
        showToast(
          context,
          '$action完成（$mode）· $n 个收藏夹（$pending 个待重试）$detail',
          icon: Icons.warning_amber_rounded,
        );
      } else {
        showToast(
          context,
          '$action完成（$mode）· $n 个收藏夹',
          icon: Icons.check_circle_outline_rounded,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showToast(context, '$action失败，请检查网络后重试', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) {
        setState(() {
          if (upload) {
            _uploading = false;
          } else {
            _downloading = false;
          }
        });
      }
    }
  }
}

/// 新建收藏夹虚线卡
class _NewFolderTile extends StatelessWidget {
  const _NewFolderTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 14,
      scale: 0.97,
      glow: 0.18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            // v1.7.67：虚线外框缩到与海报堆叠卡一致（0.85 缩放 + 贴底），
            // 看起来和其他收藏夹一样大；内部按钮/文字还原 v1.7.63 尺寸
            // v2.0.10：平板下封面高按原生比例（宽×1.45）收窄，虚线框同款
            // 收窄 —— 此前固定 0.85 高，比旁边的收藏夹封面高出一大截
            child: Align(
              alignment: Alignment.bottomCenter,
              child: LayoutBuilder(
                builder: (c, cons) {
                  final tablet =
                      MediaQuery.of(context).size.width >= kTabletBreakpoint;
                  final w = cons.maxWidth;
                  final h = cons.maxHeight;
                  final cw = w * 0.85;
                  final ch = tablet ? math.min(h * 0.85, cw * 1.45) : h * 0.85;
                  final box = CustomPaint(
                    painter: _DashedRRectPainter(
                      radius: 14,
                      color: AppColors.w.withValues(alpha: 0.26),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.w.withValues(alpha: 0.06),
                              border: Border.all(
                                color: AppColors.w.withValues(alpha: 0.14),
                              ),
                            ),
                            child: const Icon(
                              Icons.add_rounded,
                              size: 21,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            '新建收藏夹',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ); // CustomPaint
                  if (tablet) {
                    return SizedBox(width: cw, height: ch, child: box);
                  }
                  return FractionallySizedBox(
                    widthFactor: 0.85,
                    heightFactor: 0.85,
                    child: box,
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            '新建收藏夹',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            '输入名称创建',
            style: TextStyle(fontSize: 10, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.radius, required this.color});

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    const dash = 7.0;
    const gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = math.min(d + dash, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}

/// 演员收藏卡
class _ActorTile extends StatelessWidget {
  const _ActorTile({
    required this.person,
    required this.state,
    required this.onTap,
    required this.onLongPress,
  });

  final CastMember person;
  final AppState state;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final server = state.server;
    final url = (server != null && person.id != null)
        ? server.personImageUrl(person.id!, person.imageTag)
        : null;
    return LiquidPress(
      onTap: onTap,
      onLongPress: onLongPress,
      radius: 12,
      scale: 0.97,
      glow: 0.18,
      child: Column(
        children: [
          LayoutBuilder(
            builder: (c, cons) {
              // v2.0.59：头像不再撑满整格。手机上限 78dp、平板上限 104dp，
              // 且不超过格宽的 90%，避免收藏人数少时出现巨型圆头像。
              final cap = context.isPhone ? 78.0 : 104.0;
              final size = math.min(cons.maxWidth * 0.9, cap);
              return Center(
                child: SizedBox(
                  width: size,
                  height: size,
                  // v2.0.61 ① 体检：这里外层 SizedBox 本来就是 tight 正方形
                  // 约束（不变形），但照演员总览页的做法把 Container 尺寸与
                  // 图片的 tight 约束显式写死，避免以后有人把它塞进 loose 的
                  // Stack 又踩回「竖椭圆」的坑。视觉与之前完全等价。
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.w.withValues(alpha: 0.18),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x55000000),
                          blurRadius: 14,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: SizedBox.expand(
                        child: url != null
                            ? CachedImage(
                                url: url,
                                memWidth: 200,
                                errorWidget: _avatarFallback(),
                              )
                            : _avatarFallback(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text('♥ 已收藏', style: TextStyle(fontSize: 9, color: AppColors.danger)),
        ],
      ),
    );
  }

  Widget _avatarFallback() => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2A3550), Color(0xFF141B29)],
      ),
    ),
    alignment: Alignment.center,
    child: Icon(
      Icons.person_rounded,
      size: 28,
      color: AppColors.w.withValues(alpha: 0.35),
    ),
  );
}

/// 三格统计条（v2.0.97 · 设计稿 P0）。
///
/// 以前「0 部 · 0 个收藏夹」挤在标题右侧的小字里，内容一空整页就塌。
/// 这里把结构显式撑起来：收藏影片 / 收藏夹 / 近 7 天新增，右侧再挂一个
/// 紧凑的「影片 / 演员」切换 —— 取代旧的那一整行 34dp 分段控件。
class _StatsBar extends StatelessWidget {
  const _StatsBar({
    required this.movies,
    required this.folders,
    required this.recent,
    required this.tab,
    required this.onTab,
  });

  final int movies;
  final int folders;
  final int recent;
  final int tab;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x1FFFFFFF), Color(0x0AFFFFFF)],
        ),
        border: Border.all(color: AppColors.w.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          _cell('$movies', '收藏影片'),
          _divider(),
          _cell('$folders', '收藏夹'),
          _divider(),
          _cell(recent > 0 ? '+$recent' : '0', '近 7 天新增'),
          const Spacer(),
          _miniTabs(),
        ],
      ),
    );
  }

  Widget _cell(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.3,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          label,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.w.withValues(alpha: 0.08),
    );
  }

  /// 紧凑维度切换：22dp 文本胶囊，替掉旧的一整行 34dp 分段控件。
  Widget _miniTabs() {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: AppColors.w.withValues(alpha: 0.05),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _mini(
            '影片',
            0,
            Icons.local_movies_outlined,
            const ValueKey('subtab-movies'),
          ),
          _mini(
            '演员',
            1,
            Icons.person_outline_rounded,
            const ValueKey('subtab-actors'),
          ),
        ],
      ),
    );
  }

  Widget _mini(String label, int idx, IconData icon, Key key) {
    final on = tab == idx;
    return LiquidPress(
      key: key,
      radius: 999,
      scale: 0.94,
      onTap: () => onTab(idx),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: on ? AppColors.w.withValues(alpha: 0.16) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: on ? AppColors.ink : AppColors.muted),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                color: on ? AppColors.ink : AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 收藏空态（v2.0.97 · 设计稿 P0）。
///
/// 旧空态只有两张卡 + 大片留白，新用户看不出下一步。这里补上：
/// 品牌蓝紫径向光晕里的线性图标、双 CTA、以及「收藏夹会同步到服务器」
/// 这句关键说明 —— 一句话把「能跨设备」的能力讲清楚。
class _FavoritesEmpty extends StatelessWidget {
  const _FavoritesEmpty({
    super.key,
    required this.connected,
    required this.onBrowse,
    required this.onConnect,
    required this.onCreate,
  });

  final bool connected;
  final VoidCallback onBrowse;
  final VoidCallback onConnect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 112),
      children: [
        Center(
          child: SizedBox(
            width: 150,
            height: 150,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0x4D4F8CFF), Color(0x007B5CFF)],
                      stops: [0.0, 1.0],
                    ),
                  ),
                ),
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.w.withValues(alpha: 0.05),
                    border: Border.all(
                      color: AppColors.w.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Icon(
                    Icons.favorite_border_rounded,
                    size: 34,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          '还没有收藏的影片',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          connected
              ? '在影片详情页点心形即可加入收藏，\n也可以先建个收藏夹把想看的片归归类。'
              : '还没有连接服务器。先在「我的 → 我的服务器」连接，\n再回来收藏影片。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, height: 1.6, color: AppColors.muted),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: LiquidPress(
                radius: 13,
                onTap: connected ? onBrowse : onConnect,
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    gradient: AppColors.ctaGradient,
                  ),
                  child: Text(
                    connected ? '去挑几部片' : '去连接服务器',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LiquidPress(
                radius: 13,
                onTap: onCreate,
                child: Container(
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    color: AppColors.w.withValues(alpha: 0.06),
                    border: Border.all(
                      color: AppColors.w.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Text(
                    '新建收藏夹',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          '收藏夹会同步到服务器，换设备也在。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.5,
            color: AppColors.muted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
