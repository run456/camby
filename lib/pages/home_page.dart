import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/media_poster.dart';
import '../widgets/poster_hero.dart';
import 'search_page.dart';

/// 首页（沉浸式）：
/// 1. 竖版海报满屏铺满（封面），文字叠在底部渐隐区上
/// 2. 整页底色 = 同一张海报的高斯模糊 + 深色遮罩（滚动时保持）
/// 3. 板块：每日推荐（PageView 缓动）/ 继续观看 / 最近添加 / 按媒体库分组
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.onOpenDetail,
    required this.state,
    required this.onOpenLibrary,
    required this.onOpenAll,
  });

  final OpenDetail onOpenDetail;
  final void Function(LibraryView view) onOpenLibrary;
  final VoidCallback onOpenAll;
  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Hero 解码宽度：393dp 屏物理宽约 1179，900 已足够且解码更快
  static const int _heroDecodeWidth = 900;

  late MediaItem _hero;
  final List<MediaItem> _heroPool = [];
  int _heroIndex = 0;
  final Map<String, List<MediaItem>> _rows = {};
  bool _rowsLoading = false;
  String _loadedKey = '';
  late PageController _heroController;
  bool _heroJump = false;

  /// 文字层 / 背景层各自独立通知：
  /// 翻页时不再 setState 重建整个滚动列表，只重建这两块。
  late final ValueNotifier<MediaItem> _heroVN;
  late final ValueNotifier<MediaItem> _bgHeroVN;
  Timer? _bgTimer;

  @override
  void initState() {
    super.initState();
    _heroController = PageController(viewportFraction: 1.0);
    _build();
    _heroVN = ValueNotifier(_hero);
    _bgHeroVN = ValueNotifier(_hero);
    _loadRows();
    widget.state.addListener(_onStateChanged);
    _precacheAdjacent();
  }

  @override
  void dispose() {
    _bgTimer?.cancel();
    _heroVN.dispose();
    _bgHeroVN.dispose();
    _heroController.dispose();
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    final key = '${widget.state.items.length}|${widget.state.views.length}';
    if (key != _loadedKey) {
      _heroPool.clear();
      _rows.clear();
      _rowsLoading = false;
      _build();
      _loadRows();
      _heroVN.value = _hero;
      _bgHeroVN.value = _hero;
    }
    if (mounted) setState(() {});
  }

  void _build() {
    final source = widget.state.items.isEmpty
        ? demoLibrary
        : widget.state.items;
    if (_heroPool.isEmpty) {
      final pool = List<MediaItem>.from(source);
      pool.sort((a, b) {
        double s(MediaItem i) =>
            i.rating + (i.addedDaysAgo < 30 ? 0.5 : 0) + (i.isTrue4K ? 0.3 : 0);
        return s(b).compareTo(s(a));
      });
      _heroPool.addAll(pool.take(6));
    }
    _hero = _heroPool.isEmpty
        ? demoLibrary.first
        : _heroPool[_heroIndex % _heroPool.length];
  }

  Future<void> _loadRows() async {
    final views = widget.state.views;
    _loadedKey = '${widget.state.items.length}|${views.length}';
    if (views.isEmpty) return;
    setState(() => _rowsLoading = true);
    var empty = 0;
    for (final v in views) {
      final list = await widget.state.previewForView(v);
      if (!mounted) return;
      setState(() => _rows[v.id] = list);
      if (list.isEmpty) empty++;
    }
    if (mounted) setState(() => _rowsLoading = false);
    // 空行自动重试一次：服务端刚启动/正在扫描时首次请求常拿到空列表
    if (empty > 0 && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;
      for (final v in views) {
        if ((_rows[v.id] ?? const <MediaItem>[]).isNotEmpty) continue;
        final list = await widget.state.previewForView(v, force: true);
        if (!mounted) return;
        if (list.isNotEmpty) setState(() => _rows[v.id] = list);
      }
    }
  }

  /// 单个媒体库行的手动重试（点「暂无内容」区域触发）
  Future<void> _retryRow(LibraryView v) async {
    setState(() => _rowsLoading = true);
    final list = await widget.state.previewForView(v, force: true);
    if (!mounted) return;
    setState(() {
      _rows[v.id] = list;
      _rowsLoading = false;
    });
  }

  /// 顶栏副标题：服务器 · 片数（离线/演示各有说法，避免只显示一个数字看不懂）
  String _sourceInfo(AppState state) {
    if (state.demoMode) return '演示媒体库 · ${state.items.length} 项';
    if (state.offline) return '离线 · 缓存 ${state.items.length} 项';
    final host = state.server?.host ?? '';
    return host.isEmpty
        ? '已连接 · ${state.items.length} 项'
        : '$host · ${state.items.length} 项';
  }

  /// 搜索页转场：与详情页同款（半透明路由 + 淡入上浮），不再用 Material 缩放转场
  Route<void> _searchRoute(AppState state) {
    return PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) =>
          SearchPage(state: state, onOpenDetail: widget.onOpenDetail),
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.05),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  void _precacheAdjacent() {
    if (_heroPool.isEmpty) return;
    final n = _heroPool.length;
    // 前后各预取一张，滑动时不用等解码
    for (final d in const [-1, 1]) {
      final item = _heroPool[(_heroIndex + d) % n];
      final url = item.posterUrlFor(_heroDecodeWidth) ?? item.backdropUrl;
      if (url == null) continue;
      // 关键：按目标解码尺寸预取（ResizeImage 的 cache key 才与 CachedImage 一致），
      // 否则预取的是原图、滑到该页仍要二次解码
      precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(url, cacheKey: imageCacheKey(url)),
          width: _heroDecodeWidth,
        ),
        context,
      ).catchError((_) {});
    }
  }

  void _onHeroChanged(int i) {
    if (_heroPool.isEmpty) return;
    if (_heroJump && i == _heroIndex) {
      _heroJump = false;
      return;
    }
    _heroIndex = i;
    final item = _heroPool[i % _heroPool.length];
    _hero = item;
    // 只刷文字层（不 setState，滚动列表不重建）
    _heroVN.value = item;
    // 背景延后 120ms 再换：避开翻页动画，避免模糊层与滑动抢帧
    _bgTimer?.cancel();
    _bgTimer = Timer(const Duration(milliseconds: 120), () {
      if (mounted) _bgHeroVN.value = item;
    });
    _precacheAdjacent();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final hero = _hero;
    // 每日推荐：按海报原始比例完整展示（与详情页一致），不再裁切
    final heroAspect =
        (_heroPool.isNotEmpty ? _heroPool.first.posterAspect : 0.6667).clamp(
          0.55,
          0.85,
        );

    return Container(
      color: AppColors.bg,
      child: Stack(
        children: [
          // ---- 固定底色：海报模糊 + 深色遮罩（滚动时保持）----
          // P0：去掉 ScaleTransition（每帧重新栅格化模糊层）、时长 700→380、
          // sigma 60→40；背景由独立 notifier 驱动，翻页不重建整页
          Positioned.fill(
            child: ValueListenableBuilder<MediaItem>(
              valueListenable: _bgHeroVN,
              builder: (context, bgHero, _) {
                final bgUrl = bgHero.posterUrl ?? bgHero.backdropUrl;
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 380),
                  // 关键：默认 layoutBuilder 是 loose 约束，Image 只会按自身尺寸居中，
                  // 导致背景铺不满、露出黑色底。这里强制 expand 与详情页一致。
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  ),
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: KeyedSubtree(
                    key: ValueKey('bg-${bgHero.id}'),
                    child: bgUrl != null
                        ? ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: 40,
                              sigmaY: 40,
                            ),
                            child: SizedBox.expand(
                              child: CachedImage(url: bgUrl, memWidth: 220),
                            ),
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [bgHero.colors.first, AppColors.bg],
                              ),
                            ),
                          ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.30),
                    Colors.black.withOpacity(0.42),
                    Colors.black.withOpacity(0.55),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),

          // ---- 滚动内容 ----
          Positioned.fill(
            child: RefreshIndicator(
              color: AppColors.primary,
              backgroundColor: const Color(0xF2121828),
              onRefresh: () => state.refresh(),
              // 独立图层：滚动只重绘列表，背后全屏模糊/大图不再每帧重算
              child: RepaintBoundary(
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    // 每日推荐：整版竖图（原始比例）+ PageView 横滑，滑动时缩放淡入
                    SliverToBoxAdapter(
                      child: AspectRatio(
                        aspectRatio: heroAspect,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // 整块 PageView 共用一层 ShaderMask（每帧 1 层，
                            // 而不是原来「每页 1 层 × 左右两页」），保留底部渐隐观感
                            ShaderMask(
                              blendMode: BlendMode.dstIn,
                              shaderCallback: (rect) => const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white,
                                  Colors.white,
                                  Colors.transparent,
                                ],
                                stops: [0.0, 0.62, 1.0],
                              ).createShader(rect),
                              child: PageView.builder(
                                controller: _heroController,
                                physics: const PageScrollPhysics(),
                                itemCount: _heroPool.isEmpty
                                    ? 1
                                    : _heroPool.length,
                                onPageChanged: _onHeroChanged,
                                itemBuilder: (c, i) {
                                  final item = _heroPool.isEmpty
                                      ? hero
                                      : _heroPool[i % _heroPool.length];
                                  final url =
                                      item.posterUrlFor(_heroDecodeWidth) ??
                                      item.backdropUrl;
                                  return RepaintBoundary(
                                    child: LiquidPress(
                                      onTap: () => widget.onOpenDetail(
                                        item,
                                        heroTag: 'home-hero-${item.id}',
                                      ),
                                      radius: 16,
                                      scale: 0.98,
                                      glow: 0.20,
                                      child: url != null
                                          ? PosterHero(
                                              tag: 'home-hero-${item.id}',
                                              url: url,
                                              fromRadius: 0,
                                              memWidth: _heroDecodeWidth,
                                              child: CachedImage(
                                                url: url,
                                                memWidth: _heroDecodeWidth,
                                              ),
                                            )
                                          : DecoratedBox(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    item.colors.first
                                                        .withOpacity(0.95),
                                                    AppColors.bg,
                                                  ],
                                                ),
                                              ),
                                            ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            // 文字叠在海报下半区（独立 notifier：翻页只刷这一块）
                            Positioned(
                              left: 18,
                              right: 18,
                              bottom: 16,
                              child: ValueListenableBuilder<MediaItem>(
                                valueListenable: _heroVN,
                                builder: (context, h, _) => _heroContent(h),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 继续观看
                    if (state.continueWatching.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 20),
                            _RowHeader(
                              title: '继续观看',
                              action: '${state.continueWatching.length} 部',
                              onAction: widget.onOpenAll,
                            ),
                            SizedBox(
                              // 全宽大卡：封面完整展示（16:9）
                              height:
                                  (MediaQuery.of(context).size.width - 32) *
                                      9 /
                                      16 +
                                  2,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                itemCount: state.continueWatching.length,
                                itemBuilder: (c, i) => Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: ContinueCard(
                                    item: state.continueWatching[i],
                                    width:
                                        MediaQuery.of(context).size.width - 32,
                                    onTap: () => widget.onOpenDetail(
                                      state.continueWatching[i],
                                      heroTag:
                                          'home-continue-${state.continueWatching[i].id}',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),

                    // 最近添加（3×3 网格，最近 9 部）
                    if (state.items.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _RowHeader(
                          title: '最近添加',
                          action: '${state.recentlyAdded.length} 部',
                          onAction: widget.onOpenAll,
                        ),
                      ),
                    if (state.items.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 11,
                                mainAxisSpacing: 16,
                                childAspectRatio: 0.53,
                              ),
                          itemCount: state.recentlyAdded.take(9).length,
                          itemBuilder: (c, i) {
                            final e = state.recentlyAdded[i];
                            return PosterCard(
                              item: e,
                              width: double.infinity,
                              heroTag: 'home-grid-${e.id}',
                              onTap: () => widget.onOpenDetail(
                                e,
                                heroTag: 'home-grid-${e.id}',
                              ),
                            );
                          },
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 20)),

                    // 按媒体库分组
                    if (state.views.isNotEmpty)
                      ...state.views.map((v) {
                        final row = _rows[v.id] ?? const <MediaItem>[];
                        return SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _RowHeader(
                                title: v.name,
                                action: '查看全部',
                                onAction: () => widget.onOpenLibrary(v),
                              ),
                              SizedBox(
                                height: 216,
                                child: row.isEmpty
                                    ? LiquidPress(
                                        // 空行可点重试：只重拉这一个库，不再靠整页刷新
                                        onTap: _rowsLoading
                                            ? null
                                            : () => _retryRow(v),
                                        radius: 12,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          child: Row(
                                            children: [
                                              SizedBox(
                                                width: 16,
                                                height: 16,
                                                child: _rowsLoading
                                                    ? const CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color:
                                                            AppColors.primary,
                                                      )
                                                    : const Icon(
                                                        Icons
                                                            .refresh_rounded,
                                                        size: 15,
                                                        color:
                                                            AppColors.primary,
                                                      ),
                                              ),
                                              const SizedBox(width: 10),
                                              Text(
                                                _rowsLoading
                                                    ? '正在载入 ${v.name}…'
                                                    : '暂无内容 · 点此重试',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.muted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        scrollDirection: Axis.horizontal,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        itemCount: row.length,
                                        itemBuilder: (c, i) => Padding(
                                          padding: const EdgeInsets.only(
                                            right: 11,
                                          ),
                                          child: PosterCard(
                                            item: row[i],
                                            width: 118,
                                            heroTag:
                                                'home-row-${v.id}-${row[i].id}',
                                            onTap: () => widget.onOpenDetail(
                                              row[i],
                                              heroTag:
                                                  'home-row-${v.id}-${row[i].id}',
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 22),
                            ],
                          ),
                        );
                      }),

                    const SliverToBoxAdapter(child: SizedBox(height: 110)),
                  ],
                ),
              ),
            ),
          ),

          // 顶部栏（来源信息 + 搜索 + 连接）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 14, 0),
                child: Row(
                  children: [
                    // 左侧来源信息：CAMBY / 服务器 · 片数（海报上直接叠字，带投影保证可读）
                    Expanded(
                      child: IgnorePointer(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'CAMBY',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 3,
                                color: Colors.white,
                                shadows: [
                                  Shadow(
                                    color: Color(0xCC000000),
                                    blurRadius: 12,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _sourceInfo(state),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFD7E2F5),
                                shadows: [
                                  Shadow(
                                    color: Color(0xCC000000),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _GlassCircleBtn(
                      icon: Icons.search_rounded,
                      semanticLabel: '搜索',
                      onTap: () => Navigator.of(
                        context,
                      ).push(_searchRoute(state)),
                    ),
                    const SizedBox(width: 10),
                    _Pill(
                      onTap: () => state.refresh(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            state.demoMode || state.offline
                                ? Icons.wifi_off_rounded
                                : Icons.wifi_rounded,
                            size: 13,
                            color: state.demoMode || state.offline
                                ? AppColors.muted
                                : AppColors.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            state.demoMode
                                ? '演示'
                                : (state.offline
                                      ? '离线'
                                      : '${state.items.length}'),
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 海报底部叠放的文字与操作（非交互信息设为手势穿透，保证 PageView 可横向滑动）
  Widget _heroContent(MediaItem item) {
    final genre = _displayGenre(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        IgnorePointer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  if (item.rating > 0)
                    _Badge(
                      icon: Icons.star_rounded,
                      label: item.rating.toStringAsFixed(1),
                      gold: true,
                    ),
                  if (item.isTrue4K)
                    _Badge(icon: Icons.hd_rounded, label: '2160p'),
                  _Badge(
                    icon: Icons.movie_creation_outlined,
                    label: item.videoCodec,
                  ),
                  if (item.audioChannels >= 6)
                    _Badge(
                      icon: Icons.graphic_eq_rounded,
                      label: '${item.audioChannels}ch',
                    ),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  height: 1.18,
                  letterSpacing: -0.4,
                  color: Colors.white,
                  shadows: [Shadow(color: Color(0xE6000000), blurRadius: 18)],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (item.year > 0) '${item.year}',
                  if (item.isTrue4K) '2160P' else '1080P',
                  if (genre != null) genre,
                ].join('  ·  '),
                style: const TextStyle(fontSize: 11, color: Color(0xFFD3DEF0)),
              ),
              if (item.overview.isNotEmpty) ...[
                const SizedBox(height: 7),
                Text(
                  item.overview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: Color(0xFFDCE6F5),
                    shadows: [Shadow(color: Color(0xCC000000), blurRadius: 10)],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        IgnorePointer(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_heroPool.length.clamp(1, 6), (i) {
              final sel = i == _heroIndex % (_heroPool.length.clamp(1, 6));
              return AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: sel ? 16 : 5,
                height: 5,
                decoration: BoxDecoration(
                  color: sel ? Colors.white : Colors.white.withOpacity(0.32),
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

/// 顶栏液态玻璃圆钮（搜索等）：渐变玻璃 + 上缘高光 + 投影
/// 刻意不做实时 BackdropFilter：海报横移时每帧重算模糊是横滑掉帧主因
class _GlassCircleBtn extends StatelessWidget {
  const _GlassCircleBtn({
    required this.icon,
    required this.onTap,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 20,
      scale: 0.92,
      semanticLabel: semanticLabel,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.26),
              Colors.white.withOpacity(0.08),
            ],
          ),
          border: Border.all(color: Colors.white.withOpacity(0.28)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Stack(
          children: [
            // 上缘镜面高光
            Positioned(
              left: 9,
              right: 9,
              top: 1,
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0),
                      Colors.white.withOpacity(0.55),
                      Colors.white.withOpacity(0),
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: Icon(
                icon,
                size: 20,
                color: Colors.white,
                shadows: const [
                  Shadow(color: Color(0x66000000), blurRadius: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;
  static const double _height = 38;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: _height / 2,
      scale: 0.95,
      child: Container(
        height: _height,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_height / 2),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.24),
              Colors.white.withOpacity(0.08),
            ],
          ),
          border: Border.all(color: Colors.white.withOpacity(0.26)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Center(child: child),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, this.gold = false});
  final IconData icon;
  final String label;
  final bool gold;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 11,
            color: gold ? const Color(0xFFFFC55A) : const Color(0xFFD5E0F0),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _RowHeader extends StatelessWidget {
  const _RowHeader({required this.title, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 11),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          if (action != null)
            LiquidPress(
              onTap: onAction,
              radius: 10,
              scale: 0.94,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    action!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: AppColors.muted,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 继续观看：全宽大卡（封面完整展示 + 播放钮 + 标题 + 播放百分比）
class ContinueCard extends StatelessWidget {
  const ContinueCard({
    super.key,
    required this.item,
    this.onTap,
    this.width = 244,
  });
  final MediaItem item;
  final VoidCallback? onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final progress = item.resumeProgress ?? 0;
    final imgH = width * 9 / 16;
    return LiquidPress(
      onTap: onTap,
      radius: 14,
      scale: 0.98,
      glow: 0.20,
      child: SizedBox(
        width: width,
        child: Stack(
          children: [
            PosterHero(
              tag: 'home-continue-${item.id}',
              url: item.backdropUrl ?? item.posterUrl,
              memWidth: 600,
              fromRadius: 14,
              child: MediaPoster(
                item: item,
                height: imgH,
                width: width,
                showTitle: false,
                backdrop: true,
                radius: 14,
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x66000000)],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.38),
                    border: Border.all(color: Colors.white.withOpacity(0.7)),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 26,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            // 标题（左）+ 播放百分比（右，封面内底部）
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(13, 0, 13, 9),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              shadows: [
                                Shadow(color: Color(0x66000000), blurRadius: 6),
                              ],
                            ),
                          ),
                        ),
                        if (progress > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              '${(progress * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                shadows: [
                                  Shadow(
                                    color: Color(0x66000000),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 内嵌进度条（封面底边）
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: Colors.white.withOpacity(0.18),
                      valueColor: const AlwaysStoppedAnimation(
                        AppColors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 取第一个非「分辨率/编码」类标签，避免「1080P · 1080P」这种重复展示
String? _displayGenre(MediaItem item) {
  final res = RegExp(
    r'^(2160|1080|720|480|360)[pPiI]$|^[48]K$|^UHD$|^H\.?26[45]$|^HEVC$|^AVC$|^X26[45]$|^BluRay$|^WEB-?DL$',
    caseSensitive: false,
  );
  for (final g in item.genres) {
    final t = g.trim();
    if (t.isNotEmpty && !res.hasMatch(t)) return t;
  }
  return null;
}
