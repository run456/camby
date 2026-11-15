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
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // v1.7.66：与服务器同步收藏夹（拉回播放列表 + 推送未上云的本地夹）
                      _SyncButton(state: state),
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
            const Text(
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
                      const Text(
                        '管理',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted,
                        ),
                      ),
                      const Icon(
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
        SizedBox(
          height: context.isTablet ? 230 : 196,
          child: ListView(
            key: const ValueKey('folder-rail'),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            children: [
              _folderCard(
                key: const ValueKey('folder-all'),
                name: '全部',
                count: all.length,
                covers: all.take(4).toList(),
                onTap: () => _openFolder(null, '全部收藏'),
              ),
              for (final f in folders)
                _folderCard(
                  key: ValueKey('folder-${f.id}'),
                  name: f.name,
                  count: f.itemIds.length,
                  covers: state.coverCandidates(f, 4),
                  onTap: () => _openFolder(f.id, f.name),
                  onLongPress: () => _manageFolder(f),
                ),
              _newFolderCard(),
            ],
          ),
        ),
        if (all.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              const Text(
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

  /// 收藏夹横滑大卡：宽度固定，扇形堆叠沿用 [_StackTile]。
  Widget _folderCard({
    Key? key,
    required String name,
    required int count,
    required List<MediaItem> covers,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SizedBox(
        width: 148,
        child: _StackTile(
          key: key,
          name: name,
          count: count,
          covers: covers,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      ),
    );
  }

  /// 新建收藏夹虚线卡（横滑条尾部）。
  Widget _newFolderCard() {
    return SizedBox(
      width: 120,
      child: _NewFolderTile(onTap: _createFolder),
    );
  }

  /// 「管理」：列出现有收藏夹，点右侧「…」进重命名 / 删除。
  void _folderMenu(List<FavoriteFolder> folders) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
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
                color: Colors.white.withValues(alpha: 0.26),
              ),
            ),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '管理收藏夹',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 6),
            for (final f in folders)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  f.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${f.itemIds.length} 部',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.muted,
                  ),
                ),
                trailing: const Icon(
                  Icons.more_horiz_rounded,
                  size: 18,
                  color: AppColors.muted,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _manageFolder(f);
                },
              ),
          ],
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
                color: Colors.white.withOpacity(0.26),
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

  // ---------------- 演员收藏 ----------------

  Widget _actorGrid() {
    final state = widget.state;
    final list = state.favoritePersons;
    if (list.isEmpty) {
      final connected = state.server != null;
      return Center(
        key: const ValueKey('actors-empty'),
        child: state.favPersonsLoading
            ? const Column(
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
                color: Colors.white.withOpacity(0.26),
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
    return LiquidPress(
      onTap: onTap,
      onLongPress: onLongPress,
      radius: 14,
      scale: 0.97,
      glow: 0.18,
      // 堆叠墙的后层卡靠 Transform 探出瓦片矩形，这里不能裁剪 ——
      // 之前后层就是被这层 ClipRRect 裁掉的，只剩一条「被裁的边」
      clip: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (c, cons) {
                final w = cons.maxWidth;
                final h = cons.maxHeight;
                // 层数跟随夹内影片数：空夹只画 1 张占位，1 部不堆叠
                final maxDepth = covers.isEmpty
                    ? 0
                    : math.min(2, covers.length - 1);
                // v2.0.10：角标贴到**封面**右上角 —— 此前固定在瓦片 top:8，
                // 平板上封面按原生比例贴底后上边留白很大，角标悬在半空
                const scale = 0.85;
                final cw2 = w * scale;
                final ch2 =
                    MediaQuery.of(context).size.width >= kTabletBreakpoint
                    ? math.min(h * scale, cw2 * 1.45)
                    : h * scale;
                return Stack(
                  clipBehavior: Clip.none,
                  // v1.7.66：卡片贴底对齐 —— 之前 Center 让 0.85 缩放的
                  // 海报上下各空 7.5%，标题和封面之间显得很宽
                  alignment: Alignment.bottomCenter,
                  children: [
                    for (var depth = maxDepth; depth >= 0; depth--)
                      _layer(
                        depth,
                        w,
                        h,
                        tablet:
                            MediaQuery.of(context).size.width >=
                            kTabletBreakpoint,
                      ),
                    if (count > 0)
                      Positioned(
                        top: math.max(8.0, h - ch2 + 8),
                        right: (w - cw2) / 2 + 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(9),
                            color: Colors.black.withOpacity(0.42),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.16),
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
                );
              },
            ),
          ),
          // v1.7.67：海报贴底后 3dp 即可（此前居中导致约 20dp 空隙）
          const SizedBox(height: 3),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 1),
          Text(
            '$count 部影片',
            style: const TextStyle(fontSize: 10, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  /// depth: 0 = 最上层（夹内最新海报）；1 = 左后卡；2 = 右后卡。
  /// 按设计稿：三张**真实海报**像扑克牌一样向两侧扇开，后面两张从主海报
  /// 左右探出、顶部略高。卡片统一缩到 0.85 居中 —— 主海报不再撑满整格，
  /// 给后层留出探出的空间（探出量控制在格内，不压相邻卡片）。
  ///
  /// v1.7.63：幅度改用「方案 B · 更克制」—— 后卡只约 ±2.5°、探出 2%，
  /// 扇形整体收在格内（约 6dp 余量），相邻收藏夹不再互相压盖。
  Widget _layer(int depth, double w, double h, {bool tablet = false}) {
    // 角度 / 位移（相对卡片尺寸）：前卡微倾，后卡 ±2.5° 向两侧、向上探出
    final (angle, dxr, dyr) = switch (depth) {
      2 => (0.040, 0.020, -0.024),
      1 => (-0.046, -0.020, -0.024),
      _ => (-0.020, -0.008, 0.008),
    };
    const scale = 0.85;
    final cw = w * scale;
    // 平板（≥840）：5 列瓦片高远大于海报自然高，改按海报原生比例
    // （与 PosterCard 一致取 宽×1.45）约束卡高，避免 cover 上下裁切封面
    final ch = tablet ? math.min(h * scale, cw * 1.45) : h * scale;

    // 后层也用真实海报（依次取夹内第 2、3 张）；空夹才退到占位渐变
    MediaItem? item;
    if (covers.isNotEmpty) {
      item = depth == 0 ? covers.first : covers[depth % covers.length];
    }

    Widget inner;
    if (item != null) {
      inner = CachedImage(
        url: item.posterUrlFor(600),
        memWidth: 600,
        errorWidget: _placeholder,
      );
      // 后层压暗，把视觉重心让给前卡
      if (depth > 0) {
        inner = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.30),
                Colors.black.withOpacity(0.55),
              ],
            ),
          ),
          child: inner,
        );
      }
    } else {
      inner = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: depth == 0
                ? const [Color(0xFF3F3560), Color(0xFF181D33)]
                : const [Color(0xFF2C415C), Color(0xFF111A28)],
          ),
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: ch * 0.10),
            child: Icon(
              Icons.movie_creation_outlined,
              size: depth == 0 ? 24 : 19,
              color: Colors.white.withOpacity(depth == 0 ? 0.30 : 0.15),
            ),
          ),
        ),
      );
    }

    Widget card = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          width: depth == 0 ? 1.4 : 1.0,
          color: Colors.white.withOpacity(depth == 0 ? 0.26 : 0.20),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(13), child: inner),
    );

    card = Transform.rotate(
      angle: angle,
      alignment: Alignment.bottomCenter,
      child: Transform.translate(
        offset: Offset(cw * dxr, ch * dyr),
        child: card,
      ),
    );
    // v1.7.67：Align 贴底 + 卡片尺寸收在自身 —— 之前外层 Stack 改了
    // bottomCenter 但这里的 Center 又把海报居中了一次，标题间距没变小
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(width: cw, height: ch, child: card),
    );
  }

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
        color: Colors.white.withOpacity(0.22),
      ),
    ),
  );
}

/// 标题行右侧的「与服务器同步」按钮（v1.7.66）。
///
/// 点击：把未上云的本地收藏夹推到服务端播放列表 + 拉回其他设备的改动，
/// 完成后 toast 汇报数量；未连接服务器时提示不可用。
class _SyncButton extends StatefulWidget {
  const _SyncButton({required this.state});

  final AppState state;

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: _busy ? null : _sync,
      radius: 999,
      scale: 0.92,
      glow: 0.14,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.06),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: _busy
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              )
            : const Icon(Icons.sync_rounded, size: 18, color: Colors.white70),
      ),
    );
  }

  Future<void> _sync() async {
    if (widget.state.server == null) {
      showToast(context, '未连接服务器，无法同步', icon: Icons.info_outline_rounded);
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await widget.state.syncFoldersFromServer();
      if (!mounted) return;
      final pending = widget.state.pendingSyncCount;
      if (pending > 0) {
        // 失败诊断：把服务端返回的具体错误带给用户，不再只说"待重试"
        final d = widget.state.folderSyncDiag;
        final detail = d.isEmpty
            ? ''
            : '：${d.length > 42 ? '${d.substring(0, 42)}…' : d}';
        showToast(
          context,
          '已同步 · $n 个收藏夹（$pending 个待重试）$detail',
          icon: Icons.warning_amber_rounded,
        );
      } else {
        showToast(
          context,
          '已同步 · $n 个收藏夹与服务器一致',
          icon: Icons.check_circle_outline_rounded,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showToast(context, '同步失败，请检查网络后重试', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
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
                      color: Colors.white.withOpacity(0.26),
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
                              color: Colors.white.withOpacity(0.06),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.14),
                              ),
                            ),
                            child: const Icon(
                              Icons.add_rounded,
                              size: 21,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 9),
                          const Text(
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
          const Text(
            '新建收藏夹',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 1),
          const Text(
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
                      border: Border.all(color: Colors.white.withOpacity(0.18)),
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
          const Text(
            '♥ 已收藏',
            style: TextStyle(fontSize: 9, color: AppColors.danger),
          ),
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
      color: Colors.white.withOpacity(0.35),
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
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
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.3,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          label,
          style: const TextStyle(
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
      color: Colors.white.withValues(alpha: 0.08),
    );
  }

  /// 紧凑维度切换：22dp 文本胶囊，替掉旧的一整行 34dp 分段控件。
  Widget _miniTabs() {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withValues(alpha: 0.05),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _mini('影片', 0, Icons.local_movies_outlined,
              const ValueKey('subtab-movies')),
          _mini('演员', 1, Icons.person_outline_rounded,
              const ValueKey('subtab-actors')),
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
          color: on ? Colors.white.withValues(alpha: 0.16) : null,
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
                    color: Colors.white.withValues(alpha: 0.05),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: const Icon(
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
        const Text(
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
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.6,
            color: AppColors.muted,
          ),
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
                    color: Colors.white.withValues(alpha: 0.06),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: const Text(
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
        const Text(
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
