import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/folder_sheet.dart';
import 'folder_page.dart';
import 'person_page.dart';

/// 收藏页（方案 B）：影片收藏 / 演员收藏
/// 影片收藏以「海报堆叠墙」呈现收藏夹，点击进入夹内网格
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({
    super.key,
    required this.state,
    required this.onOpenDetail,
  });

  final AppState state;
  final OpenDetail onOpenDetail;

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
    final tabs = ['影片收藏', '演员收藏'];
    final subtitle = _tab == 0
        ? '${state.favorites.length} 部 · ${state.folders.length} 个收藏夹'
        : '${state.favoritePersons.length} 位演员';
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
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        '收藏',
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
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                // 液态玻璃分段控件
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Colors.white.withOpacity(0.06),
                    border: Border.all(color: Colors.white.withOpacity(0.10)),
                  ),
                  child: Row(
                    children: [
                      _segItem(tabs[0], Icons.local_movies_rounded, 0),
                      _segItem(tabs[1], Icons.person_rounded, 1),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
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

  Widget _segItem(String label, IconData icon, int idx) {
    final on = _tab == idx;
    return Expanded(
      child: LiquidPress(
        radius: 999,
        scale: 0.96,
        onTap: () {
          if (_tab == idx) return;
          setState(() => _tab = idx);
          if (idx == 1 && widget.state.server != null) {
            widget.state.loadFavoritePersons();
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: 38,
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
            boxShadow: on
                ? const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: on ? Colors.white : AppColors.muted),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                  color: on ? Colors.white : AppColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 影片收藏：海报堆叠墙 ----------------

  Widget _movieWall() {
    final state = widget.state;
    final folders = state.folders;
    final all = state.favorites;
    final allCovers = all.take(4).toList();
    final tiles = folders.length + 2; // 全部 + 自定义夹 + 新建

    return GridView.builder(
      key: const ValueKey('movies'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 112),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 22,
        childAspectRatio: 0.60,
      ),
      itemCount: tiles,
      itemBuilder: (c, i) {
        if (i == 0) {
          return _StackTile(
            name: '全部',
            count: all.length,
            covers: allCovers,
            onTap: () => _openFolder(null, '全部收藏'),
          );
        }
        if (i <= folders.length) {
          final f = folders[i - 1];
          return _StackTile(
            key: ValueKey(f.id),
            name: f.name,
            count: f.itemIds.length,
            covers: state.coverCandidates(f, 4),
            onTap: () => _openFolder(f.id, f.name),
            onLongPress: () => _manageFolder(f),
          );
        }
        return _NewFolderTile(onTap: _createFolder);
      },
    );
  }

  void _openFolder(String? id, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
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
      return Center(
        key: const ValueKey('actors-empty'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.favPersonsLoading)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.person_outline_rounded,
                size: 44,
                color: AppColors.muted.withOpacity(0.5),
              ),
            const SizedBox(height: 14),
            Text(
              state.favPersonsLoading ? '正在读取演员收藏…' : '还没有收藏演员',
              style: const TextStyle(fontSize: 13, color: AppColors.muted),
            ),
            if (!state.favPersonsLoading) ...[
              const SizedBox(height: 6),
              const Text(
                '进入演员页点击右上角 ♥ 即可收藏',
                style: TextStyle(fontSize: 11.5, color: AppColors.muted),
              ),
            ],
          ],
        ),
      );
    }
    return GridView.builder(
      key: const ValueKey('actors'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 112),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 18,
        childAspectRatio: 0.72,
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
      MaterialPageRoute(
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
                    : math.min(3, covers.length - 1);
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    for (var depth = maxDepth; depth >= 0; depth--)
                      _layer(depth, w, h),
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
          const SizedBox(height: 9),
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

  /// depth: 0 = 最上层（夹内最新海报）；1~3 = 后方渐变卡，按设计稿向两侧扇形散开。
  /// 之前每层都画海报，四张海报色调相近、叠起来糊成一张，看不出"扑克牌"层次。
  Widget _layer(int depth, double w, double h) {
    // 角度 / 位移取自设计稿（卡片 132×198 时的 8°/4°/-4° 与 7/4/-4px）
    final (angle, dxr, dyr) = switch (depth) {
      3 => (0.155, 0.078, -0.036),
      2 => (0.085, 0.044, -0.019),
      1 => (-0.105, -0.074, -0.019),
      _ => (0.0, 0.0, 0.0),
    };
    final tints = switch (depth) {
      3 => const [Color(0xFF2C415C), Color(0xFF111A28)],
      2 => const [Color(0xFF3B5270), Color(0xFF172231)],
      1 => const [Color(0xFF5B3C4A), Color(0xFF1D1726)],
      _ => const [Color(0xFF3F3560), Color(0xFF181D33)],
    };
    // 只有最上层用真实海报；后层用纯渐变卡托出扇面
    final item = depth == 0 && covers.isNotEmpty ? covers.first : null;

    Widget inner;
    if (item != null) {
      inner = CachedImage(
        url: item.posterUrlFor(600),
        memWidth: 600,
        errorWidget: _placeholder,
      );
    } else {
      inner = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: tints,
          ),
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: h * 0.10),
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: inner,
      ),
    );

    card = Transform.rotate(
      angle: angle,
      child: Transform.translate(
        offset: Offset(w * dxr, h * dyr),
        child: card,
      ),
    );
    return SizedBox(width: w, height: h, child: card);
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
            child: CustomPaint(
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
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
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
                  child: url != null
                      ? CachedImage(
                          url: url,
                          memWidth: 300,
                          errorWidget: _avatarFallback(),
                        )
                      : _avatarFallback(),
                ),
              ),
            ),
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
