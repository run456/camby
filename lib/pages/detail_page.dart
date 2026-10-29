import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/folder_sheet.dart';
import '../widgets/media_poster.dart';
import 'tag_page.dart';
import '../widgets/glass_toast.dart';
import '../widgets/liquid_press.dart';
import '../widgets/status_bar_blur.dart';
import 'person_page.dart';
import 'subtitle_filter_page.dart';

/// 影片详情：封面全幅压标题 → 元信息 → 收藏 → 剧情简介 → 主演 → 相似推荐
/// 底部常驻液态玻璃「继续播放」按钮
class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.item,
    required this.onPlay,
    required this.state,
    required this.onOpenDetail,
    this.heroTag,
  });

  final MediaItem item;

  /// resume=true：从上次位置续播；false：从头播放（重新播放）
  final void Function(
    MediaItem item,
    SubtitleTrackInfo? subtitle, {
    bool resume,
  })
  onPlay;
  final AppState state;
  final OpenDetail onOpenDetail;

  /// 与来源卡片一致的 Hero tag，用于「封面就地放大」转场
  final String? heroTag;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  final ScrollController _scroll = ScrollController();

  /// 滚动位置只驱动顶栏渐变与状态栏模糊，不再 setState 重建整页
  final ValueNotifier<double> _offsetVN = ValueNotifier<double>(0);

  /// 只在跨越阈值时翻转，避免每一像素都重建状态栏模糊组件
  final ValueNotifier<bool> _blurOn = ValueNotifier<bool>(false);
  late MediaItem _item;
  List<MediaItem>? _similar;
  List<MediaItem>? _episodes;
  bool _descExpanded = false;
  bool _mediaExpanded = false;
  SubtitleTrackInfo? _selectedSubtitle;
  bool _refreshing = false;
  static const String _offSubtitle = '__off__';

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    _selectedSubtitle = _defaultSubtitle(_item);
    _scroll.addListener(() {
      final o = _scroll.offset.clamp(0.0, 400.0);
      _offsetVN.value = o;
      final on = o > 24;
      if (_blurOn.value != on) _blurOn.value = on;
    });
    _loadExtras();
  }

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _item = widget.item;
      _selectedSubtitle = _defaultSubtitle(_item);
      _similar = null;
      _episodes = null;
      _descExpanded = false;
      _mediaExpanded = false;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _loadExtras();
    }
  }

  SubtitleTrackInfo? _defaultSubtitle(MediaItem it) {
    if (it.subtitles.isEmpty) return null;
    for (final s in it.subtitles) {
      if (s.isDefault) return s;
    }
    return it.subtitles.first;
  }

  Future<void> _pickSubtitle() async {
    final tracks = _item.subtitles;
    if (tracks.isEmpty) return;
    final result = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xF21A2233),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
                child: Text(
                  '选择字幕',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              for (final t in tracks)
                ListTile(
                  dense: true,
                  title: Text(t.label, style: const TextStyle(fontSize: 13.5)),
                  trailing: _selectedSubtitle?.index == t.index
                      ? const Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(t),
                ),
              ListTile(
                dense: true,
                title: const Text('关闭字幕', style: TextStyle(fontSize: 13.5)),
                trailing: _selectedSubtitle == null
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.of(ctx).pop(_offSubtitle),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _selectedSubtitle = result == _offSubtitle
          ? null
          : (result is SubtitleTrackInfo ? result : _selectedSubtitle);
    });
  }

  List<String> _tagList(MediaItem it) {
    final list = <String>[];
    final seen = <String>{};
    // 分辨率默认作为一个标签（strm 等读不到真实高度时不显示）
    if (it.resolutionKnown) {
      final res = it.isTrue4K ? '2160P' : '${it.videoHeight}P';
      list.add(res);
      seen.add(res.toUpperCase());
    }
    // 来自 NFO <tag>（Emby 的 Tags / TagItems）
    for (final t in it.tags) {
      final s = t.trim();
      if (s.isEmpty) continue;
      if (!seen.add(s.toUpperCase())) continue;
      list.add(s);
    }
    return list;
  }

  void _openSubtitleFilter() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SubtitleFilterPage(
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  void _openTag(String tag) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagPage(
          tag: tag,
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  void _showBackdrop(String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.92),
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: CachedImage(url: url, fit: BoxFit.contain, memWidth: 1600),
          ),
        ),
      ),
    );
  }

  Future<void> _loadExtras() async {
    final server = widget.state.server;
    if (server == null || _item.id.startsWith('demo-')) return;
    server
        .similar(_item.id)
        .then((list) {
          if (mounted) setState(() => _similar = list);
        })
        .catchError((_) {});
    if (_item.isSeries) {
      server
          .episodes(_item.id)
          .then((list) {
            if (mounted) setState(() => _episodes = list);
          })
          .catchError((_) {});
    }
  }

  /// 顶部刷新：重新拉取该条目详情并刷新页面数据
  Future<void> _refreshItem() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final server = widget.state.server;
    MediaItem? fresh;
    if (server != null && !_item.id.startsWith('demo-')) {
      fresh = await server.itemDetail(_item.id);
    }
    if (!mounted) return;
    setState(() {
      if (fresh != null) _item = fresh;
      _refreshing = false;
      _selectedSubtitle = _defaultSubtitle(_item);
      _episodes = null;
      _similar = null;
    });
    if (fresh != null) {
      widget.state.replaceItem(fresh);
      _loadExtras();
      _toast('已刷新影片信息');
    } else {
      _toast('刷新失败，请检查网络');
    }
  }

  Future<void> _openFolders() async {
    await showFolderSheet(context, widget.state, _item);
    if (!mounted) return;
    final updated = widget.state.items.where((e) => e.id == _item.id).toList();
    if (updated.isNotEmpty) {
      setState(() => _item = updated.first);
    }
  }

  void _toast(String text) => showToast(context, text);

  @override
  void dispose() {
    _offsetVN.dispose();
    _blurOn.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final wide = MediaQuery.of(context).size.width >= 840;
    // 海报按原始比例展示，标题上移叠到海报下半区（盖住海报大字的低半部分）
    final posterAspect = (item.posterAspect > 0 ? item.posterAspect : 0.6667)
        .clamp(0.4, 2.4);
    final posterH = MediaQuery.of(context).size.width / posterAspect;
    final titleLift = (posterH * 0.18).clamp(56.0, 150.0);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // 整页底色：同一张竖版海报模糊 + 深色遮罩
          // RepaintBoundary 让这层只栅格化一次，滚动期间走缓存纹理
          if ((item.posterUrl ?? item.backdropUrl) != null)
            Positioned.fill(
              child: RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: CachedImage(
                    url: item.posterUrl ?? item.backdropUrl,
                    memWidth: 220,
                  ),
                ),
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
          Positioned.fill(
            // 独立图层：滚动只重绘列表，背后全屏模糊不再每帧重算
            child: RepaintBoundary(
              child: ListView(
                controller: _scroll,
                physics: const BouncingScrollPhysics(),
                cacheExtent: 800,
                padding: EdgeInsets.zero,
                children: [
                  // 海报按原始比例完整显示（不裁切）
                  RepaintBoundary(
                    child: AspectRatio(
                      aspectRatio: posterAspect,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if ((item.posterUrl ?? item.backdropUrl) != null)
                            ShaderMask(
                              // 海报底部渐隐，透出底下的模糊主色调
                              blendMode: BlendMode.dstIn,
                              shaderCallback: (rect) => const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white,
                                  Colors.white,
                                  Colors.transparent,
                                ],
                                stops: [0.0, 0.72, 1.0],
                              ).createShader(rect),
                              child: CachedImage(
                                url: item.posterUrlFor(900) ?? item.backdropUrl,
                                memWidth: 900,
                              ),
                            )
                          else
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    item.colors.first.withOpacity(0.9),
                                    AppColors.bgTop,
                                    AppColors.bg,
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, -titleLift),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 标题压在封面上
                          Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: wide ? 32 : 26,
                              fontWeight: FontWeight.w900,
                              height: 1.16,
                              letterSpacing: -0.6,
                              color: Colors.white,
                              shadows: const [
                                Shadow(
                                  color: Color(0xCC000000),
                                  blurRadius: 16,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            [
                              if (item.year > 0) '${item.year}',
                              if (item.runtimeMin > 0) '${item.runtimeMin} 分钟',
                              if (item.director.isNotEmpty)
                                '导演 ${item.director}',
                              if (item.studio.isNotEmpty) item.studio,
                            ].join('  ·  '),
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFFD3DEF0),
                            ),
                          ),
                          const SizedBox(height: 9),
                          // 规格徽章
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
                              _Badge(
                                icon: Icons.graphic_eq_rounded,
                                label:
                                    '${item.audioCodec} ${item.audioChannels}ch',
                              ),
                            ],
                          ),
                          if (item.subtitles.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                const Text(
                                  '字幕',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.muted,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                _SubtitlePill(
                                  label: _selectedSubtitle?.label ?? '关闭字幕',
                                  onTap: _pickSubtitle,
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 20),
                          // 剧情简介：液态玻璃卡片
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0x1FFFFFFF), Color(0x0AFFFFFF)],
                              ),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.14),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 18,
                                  offset: Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _SectionLabel('剧情简介'),
                                const SizedBox(height: 8),
                                GestureDetector(
                                  onTap: () => setState(
                                    () => _descExpanded = !_descExpanded,
                                  ),
                                  child: Text(
                                    item.overview,
                                    maxLines: _descExpanded ? null : 5,
                                    overflow: _descExpanded
                                        ? null
                                        : TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      height: 1.7,
                                      color: Color(0xFFC6D3E6),
                                    ),
                                  ),
                                ),
                                if (item.overview.length > 80)
                                  GestureDetector(
                                    onTap: () => setState(
                                      () => _descExpanded = !_descExpanded,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        _descExpanded ? '收起' : '更多',
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          color: AppColors.accent,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (item.isSeries) ...[
                            const SizedBox(height: 22),
                            _SectionLabel(
                              '分集',
                              trailing: _episodes == null
                                  ? null
                                  : '共 ${_episodes!.length} 集',
                            ),
                            const SizedBox(height: 10),
                            _episodeList(),
                          ],
                          if (item.people.isNotEmpty) ...[
                            const SizedBox(height: 22),
                            _SectionLabel('主演'),
                            const SizedBox(height: 12),
                            _castRow(),
                          ],
                          if (_tagList(item).isNotEmpty ||
                              itemHasChineseSubtitle(item)) ...[
                            const SizedBox(height: 22),
                            const _SectionLabel('标签'),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (itemHasChineseSubtitle(item))
                                  _InfoTag(
                                    label: '中文字幕',
                                    icon: Icons.subtitles_rounded,
                                    onTap: _openSubtitleFilter,
                                  ),
                                ..._tagList(item).map(
                                  (t) => _TagButton(
                                    label: t,
                                    onTap: () => _openTag(t),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (item.backdrops.isNotEmpty) ...[
                            const SizedBox(height: 22),
                            _SectionLabel(
                              '剧照',
                              trailing: '${item.backdrops.length} 张',
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 136,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: item.backdrops.length,
                                itemBuilder: (c, i) => Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: LiquidPress(
                                    onTap: () =>
                                        _showBackdrop(item.backdrops[i]),
                                    radius: 12,
                                    scale: 0.97,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 214,
                                        child: CachedImage(
                                          url: item.backdrops[i],
                                          memWidth: 480,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          _SectionLabel('相似推荐'),
                          const SizedBox(height: 12),
                          _similarRow(),
                          // 媒体信息：文件路径 / 封装 / 大小 / 入库时间
                          if (item.filePath.isNotEmpty ||
                              item.fileSizeBytes > 0) ...[
                            const SizedBox(height: 22),
                            _mediaInfoCard(item),
                          ],
                          const SizedBox(height: 120),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 状态栏渐进模糊：上滑后才出现（放在顶栏之前，保证按钮不被糊）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: ValueListenableBuilder<bool>(
                valueListenable: _blurOn,
                builder: (_, on, __) => StatusBarBlur(
                  height: MediaQuery.of(context).padding.top + 24,
                  active: on,
                  sigma: 20,
                ),
              ),
            ),
          ),
          // 顶栏（最上层，保证可点）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: _offsetVN,
              builder: (_, o, __) => Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(
                        (0.55 * (1 - o / 300)).clamp(0.0, 0.55),
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                    child: Row(
                      children: [
                        _RoundBtn(
                          icon: Icons.arrow_back_ios_new_rounded,
                          onTap: () => Navigator.pop(context),
                        ),
                        const Spacer(),
                        _RoundBtn(
                          icon: _refreshing
                              ? Icons.sync_rounded
                              : Icons.refresh_rounded,
                          onTap: _refreshing ? null : _refreshItem,
                        ),
                        const SizedBox(width: 8),
                        _RoundBtn(
                          icon: Icons.create_new_folder_outlined,
                          onTap: _openFolders,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 底部常驻播放区：渐变模糊带（状态栏镜像） + 整体进度按钮
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Stack(
              children: [
                // ① 渐变模糊带：底部最强、向上连续淡出（与状态栏同款着色器）
                IgnorePointer(
                  child: BottomBarBlur(
                    height:
                        math.max(
                          4.0,
                          MediaQuery.of(context).padding.bottom - 10,
                        ) +
                        110,
                    active: true,
                    // BackdropFilter 每帧都在重采样，sigma 越大越吃 GPU，
                    // 30→20 视觉几乎无差，中低端机滚动明显更顺
                    sigma: 20,
                  ),
                ),
                // ② 按钮行
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    14,
                    20,
                    // 全面屏手势条本身已占 24~40dp，这里再收 10dp 让按钮更贴底
                    math.max(4.0, MediaQuery.of(context).padding.bottom - 10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ProgressPlayButton(
                          item: item,
                          onTap: () => widget.onPlay(item, _selectedSubtitle),
                        ),
                      ),
                      const SizedBox(width: 10),
                      LiquidPress(
                        onTap: () => widget.onPlay(
                          item,
                          _selectedSubtitle,
                          resume: false,
                        ),
                        radius: 28,
                        semanticLabel: '重新播放',
                        child: Container(
                          width: 56,
                          height: 58,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0x3DFFFFFF), Color(0x14FFFFFF)],
                            ),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.20),
                            ),
                          ),
                          child: const Icon(
                            Icons.replay_rounded,
                            size: 23,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeList() {
    final eps = _episodes;
    if (eps == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
      );
    }
    if (eps.isEmpty)
      return const Text(
        '暂无分集信息',
        style: TextStyle(fontSize: 11.5, color: AppColors.muted),
      );
    return SizedBox(
      height: 62,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: eps.length,
        itemBuilder: (c, i) {
          final e = eps[i];
          final cur = (e.resumeProgress ?? 0) > 0.01;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: LiquidPress(
              onTap: () => widget.onPlay(e, _defaultSubtitle(e), resume: true),
              radius: 12,
              scale: 0.97,
              child: Container(
                width: 128,
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: cur
                      ? const LinearGradient(
                          colors: [Color(0x334F8CFF), Color(0x1A7B5CFF)],
                        )
                      : LinearGradient(
                          colors: [
                            Colors.white.withOpacity(0.07),
                            Colors.white.withOpacity(0.03),
                          ],
                        ),
                  border: Border.all(
                    color: cur
                        ? const Color(0x664F8CFF)
                        : Colors.white.withOpacity(0.10),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'S${e.seasonNumber ?? 1}E${e.episodeNumber ?? i + 1}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.runtimeMin > 0 ? '${e.runtimeMin} 分钟' : '未观看',
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _castRow() {
    final server = widget.state.server;
    return SizedBox(
      height: 104,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _item.people.length,
        itemBuilder: (c, i) {
          final p = _item.people[i];
          final img = (server != null && p.id != null)
              ? server.personImageUrl(p.id!, p.imageTag)
              : null;
          return LiquidPress(
            radius: 14,
            scale: 0.96,
            onTap: () {
              if (p.id == null) return;
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
            },
            child: Container(
              width: 68,
              margin: const EdgeInsets.only(right: 12),
              child: Column(
                children: [
                  // 圆角方头像（参考图样式）
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: demoLibrary[i % demoLibrary.length].colors,
                      ),
                      border: Border.all(color: Colors.white.withOpacity(0.18)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: img != null
                          ? CachedImage(
                              url: img,
                              memWidth: 200,
                              errorWidget: const Icon(
                                Icons.person_rounded,
                                color: Colors.white54,
                                size: 26,
                              ),
                            )
                          : const Icon(
                              Icons.person_rounded,
                              color: Colors.white54,
                              size: 26,
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (p.role.isNotEmpty)
                    Text(
                      p.role,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9,
                        color: AppColors.muted,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 媒体信息卡：文件路径（默认两行，超长折叠）+ 封装/大小/入库时间。
  /// 与剧情简介同款液态玻璃卡片；点按展开/收起，长按复制路径。
  Widget _mediaInfoCard(MediaItem item) {
    // URL 编码的路径（如挂载网盘）解码成中文显示
    String path = item.filePath;
    try {
      if (path.contains('%')) path = Uri.decodeFull(path);
    } catch (_) {}
    final hasMeta = item.fileSizeBytes > 0 || item.dateCreatedMs != null;
    final meta = [
      if (item.container.isNotEmpty) item.container.toUpperCase(),
      if (item.fileSizeBytes > 0)
        '${(item.fileSizeBytes / 1073741824).toStringAsFixed(2)} GB',
      if (item.dateCreatedMs != null) _dateLabel(item.dateCreatedMs!),
    ].join('   ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x1FFFFFFF), Color(0x0AFFFFFF)],
        ),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('媒体信息'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() => _mediaExpanded = !_mediaExpanded),
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: item.filePath));
              _toast('已复制文件路径');
            },
            child: Text(
              path,
              maxLines: _mediaExpanded ? null : 2,
              overflow: _mediaExpanded ? null : TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.55,
                color: Color(0xFFC6D3E6),
              ),
            ),
          ),
          if (!_mediaExpanded && path.length > 88)
            GestureDetector(
              onTap: () => setState(() => _mediaExpanded = true),
              child: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '展开',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else if (_mediaExpanded && path.length > 88)
            GestureDetector(
              onTap: () => setState(() => _mediaExpanded = false),
              child: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '收起',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          if (hasMeta) ...[
            const SizedBox(height: 10),
            Text(
              meta,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFFD3DEF0),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _dateLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final two = (int v) => v.toString().padLeft(2, '0');
    return '添加于: ${d.year}/${two(d.month)}/${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  Widget _similarRow() {
    final list = _similar;
    if (list == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
      );
    }
    if (list.isEmpty)
      return const Text(
        '暂无相关推荐',
        style: TextStyle(fontSize: 11.5, color: AppColors.muted),
      );
    return SizedBox(
      height: 202,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: list.length,
        itemBuilder: (c, i) => Padding(
          padding: const EdgeInsets.only(right: 11),
          child: PosterCard(
            item: list[i],
            onTap: () => widget.onOpenDetail(list[i]),
          ),
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.42),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: gold
              ? const Color(0x66FFC55A)
              : Colors.white.withOpacity(0.16),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 11,
            color: gold ? const Color(0xFFFFC55A) : const Color(0xFFCDD9EA),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: gold ? const Color(0xFFFFD79A) : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.trailing});
  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
          ),
      ],
    );
  }
}

class _TagButton extends StatelessWidget {
  const _TagButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 999,
      scale: 0.96,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Colors.white.withOpacity(0.07),
          border: Border.all(color: Colors.white.withOpacity(0.14)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFFC6D3E6)),
        ),
      ),
    );
  }
}

/// 信息型标签（不可点击，用于「中文字幕」等派生属性）
class _InfoTag extends StatelessWidget {
  const _InfoTag({required this.label, required this.icon, this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 999,
      scale: 0.96,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x334F8CFF), Color(0x142E6FE0)],
          ),
          border: Border.all(color: const Color(0x664F8CFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: const Color(0xFF9CC2FF)),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFCFE0FF),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 3),
              const Icon(
                Icons.chevron_right_rounded,
                size: 14,
                color: Color(0xFF9CC2FF),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SubtitlePill extends StatelessWidget {
  const _SubtitlePill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 999,
      scale: 0.96,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Colors.white.withOpacity(0.12),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: AppColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// 整体进度播放按钮：
/// 蓝色填充从左铺到播放百分比 = 已播放部分，右侧保持液态玻璃；
/// 图标与文字叠在填充层之上（无需细进度条）。
class _ProgressPlayButton extends StatelessWidget {
  const _ProgressPlayButton({required this.item, required this.onTap});

  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final progress = (item.resumeProgress ?? 0).clamp(0.0, 1.0);
    final label = progress >= 0.99
        ? '重新播放'
        : progress > 0
        ? '继续播放'
        : '立即播放';
    return LiquidPress(
      onTap: onTap,
      radius: 29,
      scale: 0.97,
      tint: 0.16,
      glow: 0.26,
      shadows: const [
        BoxShadow(
          color: Color(0x28000000),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
      child: Container(
        height: 58,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(29),
          child: Stack(
            children: [
              // 液态玻璃底（未播放部分）
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(29),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0x33FFFFFF), Color(0x12FFFFFF)],
                    ),
                    border: Border.all(color: Colors.white.withOpacity(0.26)),
                  ),
                ),
              ),
              // 已播放进度：蓝色填充整块按钮左侧
              if (progress > 0.001)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Color(0xFF2F7FE8), Color(0xFF4F9CFF)],
                        ),
                      ),
                    ),
                  ),
                ),
              // 进度右缘高光线：区分玻璃与蓝色
              if (progress > 0.001 && progress < 0.999)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withOpacity(0.85),
                              Colors.white.withOpacity(0.35),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // 顶部镜面高光
              Positioned(
                left: 26,
                right: 26,
                top: 0,
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withOpacity(0.0),
                        Colors.white.withOpacity(0.55),
                        Colors.white.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
              // 内容层（图标 + 文案 + 百分比）
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      size: 22,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        shadows: [
                          Shadow(color: Color(0x59000000), blurRadius: 8),
                        ],
                      ),
                    ),
                    if (progress > 0.001 && progress < 0.999) ...[
                      const SizedBox(width: 7),
                      Text(
                        '· ${(progress * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          shadows: [
                            Shadow(color: Color(0x59000000), blurRadius: 8),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 顶部按钮不做实时模糊：滚动时每个 BackdropFilter 都要逐帧重采样，
    // 3 个按钮就是 3 层，改用半透明渐变 + 高光描边（视觉几乎无差）
    return LiquidPress(
      onTap: onTap,
      radius: 20,
      shadows: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ],
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.20),
              Colors.white.withOpacity(0.06),
            ],
          ),
          border: Border.all(color: Colors.white.withOpacity(0.24)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: 17,
          color: onTap == null ? Colors.white38 : Colors.white,
        ),
      ),
    );
  }
}
