import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models.dart';
import '../routes.dart';
import '../theme.dart';
import '../layout.dart';
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
    required this.onPlayPart,
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

  /// 播放「额外部分」（同一影片的 -Cd1 / -Cd2 等其它 MediaSource）
  final void Function(MediaItem item, MediaExtraPart part) onPlayPart;
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
  List<MediaItem>? _trailers;

  /// 「额外部分」的独立子条目（分段 / 花絮）。与 `item.extraParts`
  /// （同条目下的多个 MediaSource）合并展示。
  List<MediaItem>? _extras;
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
    // 播放页退出后会回写进度 / 收藏到全局状态，这里跟着刷新按钮文案
    widget.state.addListener(_onStateChanged);
    _loadExtras();
  }

  /// 全局条目变了（播放进度、收藏、字幕轨）→ 同步到本页
  void _onStateChanged() {
    if (!mounted) return;
    MediaItem? fresh;
    for (final e in widget.state.items) {
      if (e.id == _item.id) {
        fresh = e;
        break;
      }
    }
    if (fresh == null) return;
    final changed =
        fresh.resumeProgress != _item.resumeProgress ||
        fresh.resumeSeconds != _item.resumeSeconds ||
        fresh.userFavorite != _item.userFavorite ||
        fresh.userPlayed != _item.userPlayed ||
        fresh.subtitles.length != _item.subtitles.length;
    if (!changed) return;
    setState(() => _item = fresh!);
  }

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _item = widget.item;
      _selectedSubtitle = _defaultSubtitle(_item);
      _similar = null;
      _episodes = null;
      _trailers = null;
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
      CambyRoutes.fade(
        builder: (_) => SubtitleFilterPage(
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  void _openTag(String tag) {
    Navigator.of(context).push(
      CambyRoutes.fade(
        builder: (_) => TagPage(
          tag: tag,
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  /// 剧照查看器：多张剧照可左右滑动切换，点按空白关闭，顶部显示页码
  void _showBackdrops(List<String> urls, int initial) {
    if (urls.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.92),
      builder: (ctx) {
        final page = PageController(initialPage: initial.clamp(0, urls.length - 1));
        final idx = ValueNotifier<int>(initial.clamp(0, urls.length - 1));
        return StatefulBuilder(
          builder: (ctx2, setSt) => GestureDetector(
            onTap: () => Navigator.of(ctx).pop(),
            child: Stack(
              children: [
                PageView.builder(
                  controller: page,
                  itemCount: urls.length,
                  onPageChanged: (i) => idx.value = i,
                  // 关键：不包裹 InteractiveViewer。它的缩放手势会与 PageView 的
                  // 横向翻页在手势竞技场里互相抢，导致左右滑动卡顿/粘连。去掉后
                  // 翻页顺滑；点按空白关闭由外层 GestureDetector 处理。
                  itemBuilder: (c, i) => RepaintBoundary(
                    child: Center(
                      child: CachedImage(
                        url: urls[i],
                        fit: BoxFit.contain,
                        // 全屏查看 1100 足清，比 1280 再省一截解码/显存，滑动更跟手
                        memWidth: 1100,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: MediaQuery.of(ctx).padding.top + 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: ValueListenableBuilder<int>(
                        valueListenable: idx,
                        builder: (_, v, __) => Text(
                          '${v + 1} / ${urls.length}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 「额外部分」栏目：两类来源合并展示
  ///
  /// 1. `item.extraParts` —— 同一影片的多个 MediaSource（`-Cd1` / `-Cd2` 被
  ///    识别成同一部的分段），起播时带 `MediaSourceId`；
  /// 2. `_extras` —— 被扫成**独立子条目**的分段/花絮，本身就是一个完整条目，
  ///    直接起播。
  ///
  /// 两者都空时整块不出现（与网页版一致）。
  Widget _extraPartsSection(MediaItem item) {
    final sources = item.extraParts;
    final children = _extras ?? const <MediaItem>[];
    if (sources.isEmpty && children.isEmpty) return const SizedBox.shrink();
    final total = sources.length + children.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel('额外部分', trailing: '$total 个'),
        const SizedBox(height: 12),
        SizedBox(
          height: 98,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: total,
            itemBuilder: (c, i) {
              // 子条目排前面（信息更全：有自己海报/时长），其后是 MediaSource
              if (i < children.length) {
                final e = children[i];
                return _extraCard(
                  title: e.name,
                  spec: e.runtimeMin > 0 ? '${e.runtimeMin} 分钟' : '',
                  thumb: e.posterUrl ?? e.backdropUrl ?? item.backdropUrl,
                  onTap: () => widget.onPlay(e, null, resume: false),
                );
              }
              final p = sources[i - children.length];
              return _extraCard(
                title: p.name,
                spec: p.specLine,
                thumb: item.backdropUrl ?? item.posterUrl,
                onTap: () => widget.onPlayPart(item, p),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 单张「额外部分」卡片（缩略图 + 名称 + 规格 + 播放按钮）
  Widget _extraCard({
    required String title,
    required String spec,
    required String? thumb,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: LiquidPress(
        radius: 12,
        scale: 0.97,
        semanticLabel: '播放额外部分 $title',
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 168,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumb != null && thumb.isNotEmpty)
                  CachedImage(url: thumb, memWidth: 360, fit: BoxFit.cover)
                else
                  Container(color: const Color(0x33204A80)),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.85),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        if (spec.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              spec,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 8.5,
                                color: Colors.white60,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Center(
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withOpacity(0.5),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.7),
                      ),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 20,
                      color: Colors.white,
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

  /// 预告片栏目：本地预告片可在 App 内直接播放；远程外链（YouTube 等）跳转系统浏览器
  Widget _trailerSection(MediaItem item) {
    final local = _trailers ?? const <MediaItem>[];
    final remote = item.trailerUrls;
    if (local.isEmpty && remote.isEmpty) return const SizedBox.shrink();
    final total = local.length + remote.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel('预告片', trailing: '$total 个'),
        const SizedBox(height: 12),
        SizedBox(
          height: 98,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: total,
            itemBuilder: (c, i) {
              final isLocal = i < local.length;
              final MediaItem? tr = isLocal ? local[i] : null;
              final String? remoteUrl =
                  isLocal ? null : remote[i - local.length];
              // 本地预告片多为视频 Extra，自身没有海报/剧照，退回电影的 backdrop 当缩略图
              final thumb =
                  tr?.posterUrl ?? tr?.backdropUrl ?? item.backdropUrl;
              final title = tr?.name ?? '远程预告片';
              final isRemote = remoteUrl != null;
              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: LiquidPress(
                  radius: 12,
                  scale: 0.97,
                  onTap: () {
                    if (tr != null) {
                      widget.onPlay(tr, null, resume: false);
                    } else if (remoteUrl != null) {
                      unawaited(
                        launchUrl(
                          Uri.parse(remoteUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                      );
                    }
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 168,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (thumb != null)
                            CachedImage(
                              url: thumb,
                              memWidth: 360,
                              fit: BoxFit.cover,
                            )
                          else
                            Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0x334F8CFF),
                                    Color(0x14305FB0),
                                  ],
                                ),
                              ),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Colors.black.withOpacity(0.82),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                          Center(
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.black.withOpacity(0.5),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.7),
                                ),
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (isRemote)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: Colors.black.withOpacity(0.55),
                                ),
                                child: const Text(
                                  '外链',
                                  style: TextStyle(
                                    fontSize: 8.5,
                                    color: Colors.white70,
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
            },
          ),
        ),
      ],
    );
  }

  /// 预告片诊断：逐端点列出真实返回，便于定位「网页能播、App 不显示」
  Future<void> _showTrailerDiag() async {
    final server = widget.state.server;
    if (server == null) return;
    _toast('正在检测预告片接口…');
    final log = await server.trailerDiag(_item.id);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xF21A2233),
        title: const Text('预告片诊断', style: TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: SelectableText(
            '影片 ID: ${_item.id}\n\n${log.join('\n\n')}',
            style: const TextStyle(fontSize: 11, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final list = await server.trailers(
                _item.id,
                includeLocalChildren: !_item.isSeries,
              );
              if (mounted) {
                setState(() => _trailers = list);
                _toast(list.isEmpty ? '仍未找到预告片' : '已重新加载 ${list.length} 个');
              }
            },
            child: const Text('重新加载'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
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
    // 预告片：本地预告片（Emby 独立视频项）+ 远程外链（RemoteTrailers）
    server
        .trailers(_item.id, includeLocalChildren: !_item.isSeries)
        .then((list) {
          if (mounted) setState(() => _trailers = list);
        })
        .catchError((_) {});
    // 额外部分：独立子条目（分段/花絮）。仅电影查，剧集没有这个语义
    if (!_item.isSeries) {
      server
          .extraParts(_item.id)
          .then((list) {
            if (mounted) setState(() => _extras = list);
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

  /// 剧情简介：液态玻璃卡片（手机/平板共用）
  /// 剧情简介玻璃卡片。
  /// [withTitle]：是否内嵌「剧情简介」标题。平板端改为列左缘外部标题（与
  /// 主演/标签等板块统一左缘，根治「信息卡片标题比板块标题右缩」的对齐 bug），
  /// 故传 false；手机端保持原样（默认 true）。
  Widget _overviewCard(MediaItem item, {bool withTitle = true}) {
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
          if (withTitle) ...[
            const _SectionLabel('剧情简介'),
            const SizedBox(height: 8),
          ],
          GestureDetector(
            onTap: () => setState(() => _descExpanded = !_descExpanded),
            child: Text(
              item.overview,
              maxLines: _descExpanded ? null : 5,
              overflow: _descExpanded ? null : TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.7,
                color: Color(0xFFC6D3E6),
              ),
            ),
          ),
          if (item.overview.length > 80)
            GestureDetector(
              onTap: () => setState(() => _descExpanded = !_descExpanded),
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
    );
  }

  /// 平板详情（v2.0.12 按设计稿 docs/detail_tablet_proposal.html 实施）：
  /// ① 头部横幅 330：横版 backdrop 全宽铺底 + 底部/左侧双向渐变压暗，
  ///    竖版海报（180×262）悬浮在左，标题/徽章/元信息/操作按钮压左下，
  ///    右下角观看进度条 —— 一进页面就能按播放；
  /// ② 下部板块（v2.0.16 按 docs/detail_sections_proposal.html 重排）：
  ///    **单列**结构，顺序 = 分集(剧集)→剧情简介→媒体信息→主演→标签→剧照→
  ///    相似推荐；所有板块标题与内容严格同一左缘；
  /// ③ 断点：扩展档（≥1200）占满内容区；中等档（840–1199）限宽 760 居中；
  /// ④ 手机端（<840）完全不动。
  List<Widget> _tabletChildren(MediaItem item) {
    final tags = _tagList(item);
    final master = context.isExpanded;

    final body = _tabletSections(item, tags);
    return [
      _tabletBanner(item),
      const SizedBox(height: 22),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        // 中等档：限宽居中（设计稿 §断点③）；扩展档占满内容区
        child: master
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: body,
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: body,
                  ),
                ),
              ),
      ),
      // v2.0.13：平板已无底部播放条，底部预留从 120 收到 32
      const SizedBox(height: 32),
    ];
  }

  /// 下部板块（设计稿 docs/detail_sections_proposal.html 单列顺序）：
  /// 分集 / 剧情简介 / 媒体信息 / 主演 / 标签 / 剧照 / 相似推荐。
  /// 剧情简介与媒体信息用「列左缘外部标题」+ 玻璃卡片（withTitle: false），
  /// 与 主演/标签/剧照/相似 的板块标题严格同左缘。
  List<Widget> _tabletSections(MediaItem item, List<String> tags) {
    return [
      if (item.isSeries) ...[
        _SectionLabel(
          '分集',
          trailing: _episodes == null ? null : '共 ${_episodes!.length} 集',
        ),
        const SizedBox(height: 10),
        _episodeList(),
        const SizedBox(height: 22),
      ],
      // 剧情简介（设计稿板块 1）
      const _SectionLabel('剧情简介'),
      const SizedBox(height: 10),
      _overviewCard(item, withTitle: false),
      // 媒体信息（设计稿板块 2）
      if (item.filePath.isNotEmpty || item.fileSizeBytes > 0) ...[
        const SizedBox(height: 22),
        const _SectionLabel('媒体信息'),
        const SizedBox(height: 10),
        _mediaInfoCard(item, withTitle: false),
      ],
      // 主演（设计稿板块 3）
      if (item.people.isNotEmpty) ...[
        const SizedBox(height: 22),
        const _SectionLabel('主演'),
        const SizedBox(height: 12),
        _castRow(),
      ],
      // 标签（设计稿板块 4）：胶囊 chip 流，与标题同左缘
      if (tags.isNotEmpty || itemHasChineseSubtitle(item)) ...[
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
            ...tags.map((t) => _TagButton(label: t, onTap: () => _openTag(t))),
          ],
        ),
      ],
      // 预告片（本地可播 / 远程外链）：置于剧照之上，仅检测到 trailer 文件才显示
      if ((_trailers?.isNotEmpty == true) || item.trailerUrls.isNotEmpty) ...[
        const SizedBox(height: 22),
        _trailerSection(item),
      ],
      // 额外部分（分段 / 花絮），有才显示
      if (item.extraParts.isNotEmpty || (_extras?.isNotEmpty == true)) ...[
        const SizedBox(height: 22),
        _extraPartsSection(item),
      ],
      // 剧照（设计稿板块 5）：横向滚动 16:9，标题右侧数量
      if (item.backdrops.isNotEmpty) ...[
        const SizedBox(height: 22),
        _SectionLabel('剧照', trailing: '${item.backdrops.length} 张'),
        const SizedBox(height: 12),
        SizedBox(
          height: 136,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: item.backdrops.length,
            itemBuilder: (c, i) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: LiquidPress(
                onTap: () => _showBackdrops(item.backdrops, i),
                radius: 12,
                scale: 0.97,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 214,
                    child: CachedImage(url: item.backdrops[i], memWidth: 480),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      // 预告片/额外部分缺失时的诊断入口（都有就不打扰）
      if (((_trailers?.isEmpty ?? true) && item.trailerUrls.isEmpty ||
              (item.extraParts.isEmpty && (_extras?.isEmpty ?? true))) &&
          !item.id.startsWith('demo-')) ...[
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _showTrailerDiag,
            icon: const Icon(Icons.bug_report_outlined, size: 15),
            label: const Text('没看到预告片/额外部分？点此诊断'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.muted,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 11.5),
            ),
          ),
        ),
      ],
      // 相似推荐（设计稿板块 6）
      const SizedBox(height: 22),
      const _SectionLabel('相似推荐'),
      const SizedBox(height: 12),
      _similarRow(),
    ];
  }

  /// 头部横幅（设计稿 .banner）：backdrop 全宽铺底 + 双向渐变 + 悬浮海报 +
  /// 左下信息/操作 + 右下观看进度。高 330，顶部避让状态栏。
  Widget _tabletBanner(MediaItem item) {
    final topPad = MediaQuery.of(context).padding.top;
    final bgUrl = item.backdropUrl;
    final posterUrl = item.posterUrlFor(800);
    final progress = (item.resumeProgress ?? 0).clamp(0.0, 1.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, topPad + 12, 24, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: 330,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ① backdrop 全宽铺底 + 高斯模糊（v2.0.17：与首页 Hero 同做法，
              //    sigma 40 + 低清采样 220，模糊层更省内存；scale 1.12 防止
              //    模糊采样在圆角边缘露出透明羽化）
              if (bgUrl != null)
                RepaintBoundary(
                  child: Transform.scale(
                    scale: 1.12,
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                      child: CachedImage(
                        url: bgUrl,
                        fit: BoxFit.cover,
                        memWidth: 220,
                      ),
                    ),
                  ),
                )
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [item.colors.first, AppColors.bg],
                    ),
                  ),
                ),
              // ② 底部渐暗（衔接下方内容）
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [const Color(0xB304080E), Colors.transparent],
                      stops: const [0.0, 0.45],
                    ),
                  ),
                ),
              ),
              // ③ 左侧压暗（信息区可读）
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        const Color(0xCC04080E),
                        const Color(0x8C04080E),
                        Colors.black.withOpacity(0.05),
                      ],
                      stops: const [0.0, 0.4, 0.8],
                    ),
                  ),
                ),
              ),
              // ④ 悬浮海报 + 信息/操作列（v2.0.19 按实测反馈重排）：
              //    海报与背景框上下、左右等距（330-262)/2 = 34；
              //    信息列垂直居中不再贴底，顺序 = 媒体徽章 → 标题 →
              //    元信息 → 播放按钮（左）+ 观看进度（右）同一水平行
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 34),
                child: Row(
                  children: [
                    if (posterUrl != null)
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.18),
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x99000000),
                              blurRadius: 44,
                              offset: Offset(0, 18),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: SizedBox(
                            width: 180,
                            height: 262,
                            child: CachedImage(
                              url: posterUrl,
                              fit: BoxFit.cover,
                              memWidth: 500,
                            ),
                          ),
                        ),
                      ),
                    if (posterUrl != null) const SizedBox(width: 26),
                    Expanded(child: _bannerInfo(item, progress)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 横幅信息列（垂直居中）：徽章 → 标题 → 元信息 →
  /// [播放按钮行（左） + 观看进度（右）] 同一水平行
  Widget _bannerInfo(MediaItem item, double progress) {
    final actors = item.people
        .take(3)
        .map((e) => e.name)
        .where((e) => e.isNotEmpty)
        .join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IgnorePointer(
          child: Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              if (item.rating > 0)
                _Badge(
                  icon: Icons.star_rounded,
                  label: item.rating.toStringAsFixed(1),
                  gold: true,
                ),
              if (item.isTrue4K) _Badge(icon: Icons.hd_rounded, label: '2160p'),
              _Badge(
                icon: Icons.movie_creation_outlined,
                label: item.videoCodec,
              ),
              if (item.audioChannels > 0)
                _Badge(
                  icon: Icons.graphic_eq_rounded,
                  label: '${item.audioCodec} ${item.audioChannels}ch',
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        IgnorePointer(
          child: Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              height: 1.18,
              letterSpacing: -0.5,
              color: Colors.white,
              shadows: [Shadow(color: Color(0xCC000000), blurRadius: 16)],
            ),
          ),
        ),
        const SizedBox(height: 8),
        IgnorePointer(
          child: Text(
            [
              if (item.year > 0) '${item.year}',
              if (item.runtimeMin > 0) '${item.runtimeMin} 分钟',
              if (progress > 0.001) '已看 ${(progress * 100).round()}%',
              if (actors.isNotEmpty) '主演：$actors',
            ].join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFFD3DEF0)),
          ),
        ),
        const SizedBox(height: 14),
        // 观看进度信息：靠右（实测反馈 v2.0.19，位于元信息与播放按钮之间）
        if (progress > 0.001) ...[
          SizedBox(width: 220, child: _bannerProgress(item, progress)),
          const SizedBox(height: 12),
        ],
        _bannerActions(item, progress),
      ],
    );
  }

  /// 横幅操作行：立即/继续播放（渐变主按钮）+ 从头播放 + 收藏 + 已看
  Widget _bannerActions(MediaItem item, double progress) {
    final resume = progress > 0.001;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        LiquidPress(
          onTap: () => widget.onPlay(item, _selectedSubtitle, resume: resume),
          radius: 26,
          semanticLabel: resume ? '继续播放' : '立即播放',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: const LinearGradient(
                colors: [Color(0xFF3F7EF0), Color(0xFF6B5DF3)],
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x664F8CFF),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_arrow_rounded,
                  size: 20,
                  color: Colors.white,
                ),
                const SizedBox(width: 7),
                Text(
                  resume ? '继续播放' : '立即播放',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
        _BannerGhostBtn(
          icon: Icons.replay_rounded,
          label: '从头播放',
          onTap: () => widget.onPlay(item, _selectedSubtitle, resume: false),
        ),
        _BannerGhostBtn(
          icon: item.userFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: item.userFavorite ? '已收藏' : '收藏',
          active: item.userFavorite,
          onTap: _openFolders,
        ),
        _BannerGhostBtn(
          icon: item.userPlayed
              ? Icons.check_circle_rounded
              : Icons.check_circle_outline_rounded,
          label: item.userPlayed ? '已看' : '标记已看',
          active: item.userPlayed,
          onTap: () {
            final target = !item.userPlayed;
            widget.state.togglePlayed(item);
            _toast(target ? '已标记已看' : '已标记未看');
          },
        ),
      ],
    );
  }

  /// 观看进度（设计稿 .prog）：百分比 + 剩余分钟 + 细进度条（元信息与播放按钮之间）
  /// v2.0.21：文字与进度条改为靠左对齐；进度条满宽、填充从左往右
  /// （旧实现 Column crossAxis.end + 轨道随内容收缩被右对齐，观感是
  /// 「从右往左走」，现轨道 width:double.infinity 定满宽、Align 靠左锚定）
  Widget _bannerProgress(MediaItem item, double progress) {
    final remainMin = item.runtimeMin > 0
        ? (item.runtimeMin * (1 - progress)).round()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '观看进度 ${(progress * 100).round()}%'
          '${remainMin != null ? ' · 剩余 $remainMin 分钟' : ''}',
          style: const TextStyle(fontSize: 11, color: Color(0xFFB9C4DA)),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 5,
            width: double.infinity,
            color: Colors.white.withOpacity(0.15),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progress.clamp(0.02, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2F7FE8), Color(0xFF4F9CFF)],
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _offsetVN.dispose();
    _blurOn.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    // v2.0.12：平板（≥840，含中等档）统一走设计稿横幅 + 双栏/居中单列布局；
    // 手机（<840）保持原版零改动
    final wide = context.isTablet;
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
              child: wide
                  // 平板（≥840）：设计稿横幅 + 双栏 / 居中单列
                  ? ListView(
                      controller: _scroll,
                      physics: const BouncingScrollPhysics(),
                      cacheExtent: 800,
                      padding: EdgeInsets.zero,
                      children: _tabletChildren(item),
                    )
                  : ListView(
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
                                if ((item.posterUrl ?? item.backdropUrl) !=
                                    null)
                                  ShaderMask(
                                    // 海报底部渐隐，透出底下的模糊主色调
                                    blendMode: BlendMode.dstIn,
                                    shaderCallback: (rect) =>
                                        const LinearGradient(
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
                                      url:
                                          item.posterUrlFor(900) ??
                                          item.backdropUrl,
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
                            padding: EdgeInsets.symmetric(
                              horizontal: wide ? 32 : 20,
                            ),
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
                                    if (item.runtimeMin > 0)
                                      '${item.runtimeMin} 分钟',
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
                                      _Badge(
                                        icon: Icons.hd_rounded,
                                        label: '2160p',
                                      ),
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
                                        label:
                                            _selectedSubtitle?.label ?? '关闭字幕',
                                        onTap: _pickSubtitle,
                                      ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 20),
                                // 剧情简介：液态玻璃卡片（手机/平板共用）
                                _overviewCard(item),
                                // 媒体信息：文件路径 / 封装 / 大小 / 入库时间
                                // （v1.7.50：按设计稿移到剧情简介之后）
                                if (item.filePath.isNotEmpty ||
                                    item.fileSizeBytes > 0) ...[
                                  const SizedBox(height: 22),
                                  _mediaInfoCard(item),
                                ],
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
                                if ((_trailers?.isNotEmpty == true) ||
                                    item.trailerUrls.isNotEmpty) ...[
                                  const SizedBox(height: 22),
                                  _trailerSection(item),
                                ],
                                if (item.extraParts.isNotEmpty ||
                                    (_extras?.isNotEmpty == true)) ...[
                                  const SizedBox(height: 22),
                                  _extraPartsSection(item),
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
                                        padding: const EdgeInsets.only(
                                          right: 10,
                                        ),
                                        child: LiquidPress(
                                          onTap: () =>
                                              _showBackdrops(item.backdrops, i),
                                          radius: 12,
                                          scale: 0.97,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
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
                                if ((_trailers?.isEmpty ?? true) &&
                                    item.trailerUrls.isEmpty &&
                                    !item.id.startsWith('demo-')) ...[
                                  const SizedBox(height: 10),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: _showTrailerDiag,
                                      icon: const Icon(
                                        Icons.bug_report_outlined,
                                        size: 15,
                                      ),
                                      label: const Text('没看到预告片/额外部分？点此诊断'),
                                      style: TextButton.styleFrom(
                                        foregroundColor: AppColors.muted,
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(0, 32),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        textStyle: const TextStyle(
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 22),
                                _SectionLabel('相似推荐'),
                                const SizedBox(height: 12),
                                _similarRow(),
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
                // 模糊强度下调：模糊带随滚动每帧重采样，sigma 越大越吃 GPU，
                // 14 与 20 视觉差别很小，但中低端机滑动明显更顺
                sigma: 14,
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
                          // 收藏状态钮：已收藏点亮成粉红实心，点开收藏夹弹窗管理
                          icon: _item.userFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          active: _item.userFavorite,
                          semanticLabel: _item.userFavorite ? '已收藏' : '收藏',
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
          // v2.0.13：仅手机保留 —— 平板横幅操作行已有
          // 「继续播放 / 从头播放 / 收藏 / 标记已看」，底部再放一条就是重复按钮
          if (!wide)
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
                      // 30→16 视觉几乎无差，中低端机滚动明显更顺
                      sigma: 16,
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
              // v2.0.14：演员页只压栈、不弹自己。
              // 旧实现给 PersonPage 的 onOpenDetail 里先 Navigator.pop(context)，
              // context 是详情1的，pop 掉的正好是演员页自身 → 栈变成
              // [首页→详情1→详情2]，返回就跳过了演员页。改成直接复用
              // widget.onOpenDetail，与「相似推荐」卡片同一套（逐级压栈可逐级返回）。
              Navigator.push(
                context,
                CambyRoutes.fade(
                  builder: (_) => PersonPage(
                    person: p,
                    state: widget.state,
                    onOpenDetail: widget.onOpenDetail,
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
  /// 媒体信息玻璃卡片。同 [_overviewCard]：平板端传 [withTitle]=false，
  /// 由外部「媒体信息」标题统一左缘。
  Widget _mediaInfoCard(MediaItem item, {bool withTitle = true}) {
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
          if (withTitle) ...[
            const _SectionLabel('媒体信息'),
            const SizedBox(height: 8),
          ],
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
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFD3DEF0)),
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

/// 横幅幽灵按钮：玻璃胶囊（从头播放 / 收藏 / 已看）
class _BannerGhostBtn extends StatelessWidget {
  const _BannerGhostBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 26,
      semanticLabel: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            colors: [
              Colors.white.withOpacity(active ? 0.22 : 0.12),
              Colors.white.withOpacity(active ? 0.10 : 0.04),
            ],
          ),
          border: Border.all(
            color: active
                ? const Color(0x884F8CFF)
                : Colors.white.withOpacity(0.16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? const Color(0xFF9CC2FF) : const Color(0xFFDFE7F5),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active
                    ? const Color(0xFFCFE0FF)
                    : const Color(0xFFDFE7F5),
              ),
            ),
          ],
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
  const _RoundBtn({
    required this.icon,
    this.onTap,
    this.active = false,
    this.semanticLabel,
  });
  final IconData icon;
  final VoidCallback? onTap;

  /// 激活态（收藏心形点亮）：粉红渐变 + 描边，与收藏夹弹窗「已收藏」一致
  final bool active;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 20,
      semanticLabel: semanticLabel,
      shadows: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ],
      child: ClipOval(
        // 真磨砂玻璃：与其他页顶栏圆钮（首页 _GlassCircleBtn 等）统一
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: active
                    ? const [Color(0x8CFF6B8B), Color(0x59E0355E)]
                    : [
                        Colors.white.withOpacity(0.20),
                        Colors.white.withOpacity(0.06),
                      ],
              ),
              border: Border.all(
                color: active
                    ? const Color(0xA6FF8FA6)
                    : Colors.white.withOpacity(0.24),
              ),
            ),
            child: Icon(
              icon,
              size: 17,
              color: onTap == null
                  ? Colors.white38
                  : active
                  ? const Color(0xFFFFE1E8)
                  : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
