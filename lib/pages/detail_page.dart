import 'dart:async';
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
import '../widgets/gender_badge.dart';
import '../widgets/media_poster.dart';
import 'tag_page.dart';
import '../widgets/glass_toast.dart';
import '../widgets/liquid_press.dart';
import '../lara/translate_cache.dart';
import '../lara/translate_sheet.dart';
import '../metadata/nfo_reader.dart';
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

  /// 本机缓存的 Lara 译文（title / overview），进入详情页时预读，
  /// 用于翻译按钮的「已译」高亮与「下次点开直接查看」。
  Map<String, CachedTranslation>? _cachedTrans;

  /// v2.0.54：从同目录 NFO 兜底读到的系列名。Emby 对 Movie 不给
  /// `SeriesName`，但刮削器写的 `<series>` / `<set><name>` 是有效系列信息。
  String _nfoSeries = '';

  /// v2.0.62：NFO 读取每一步的诊断。系列显示「无」时点胶囊可查看，
  /// 把「还是没加载」变成能看到具体失败原因（哪个 URL、什么状态）。
  List<NfoProbe> _nfoProbes = const <NfoProbe>[];
  bool _nfoTried = false;

  /// 滚动降级：滚动期间关掉实时模糊（换成纯渐变），停下 180ms 后恢复。
  ///
  /// 详情页上下两条渐进模糊带都是 `BackdropFilter`，每帧要把整块滚动内容
  /// 重新采样 + 跑模糊着色器，是滑动卡顿的主因（媒体库页没有常驻模糊，所以丝滑）。
  /// 这里只切一个 bool，模糊组件内部直接换静态渐变，不碰 GPU 重采样。
  /// 降级状态用 ValueNotifier 而不是 setState：
  /// 它只被「顶栏 3 个圆钮 / 顶部模糊带 / 底部模糊带」三处消费，
  /// 用 setState 会让整页 build 重跑一遍（10 个板块的 widget 全部新建），
  /// 而那正好发生在滚动起始帧——最不该掉帧的时刻。
  final ValueNotifier<bool> _degradedVN = ValueNotifier<bool>(false);
  Timer? _degradeTimer;

  /// 滚动事件序号：每来一次滚动事件 +1。
  ///
  /// 用「序号是否变化」判断期间是否还在滚，而不是比 `DateTime.now()`——
  /// 墙钟和 Timer 的时钟不是同一个，系统时间被 NTP 校正时会误判，
  /// 表现就是「滚动停下后模糊再也回不来」。
  int _scrollSeq = 0;

  /// 接住**所有**后代滚动通知（含剧照 / 胶囊行这类内层横向 ListView）。
  /// 主 `_scroll` 的 listener 只知道自己那一条列表，内层滚动不会触发降级，
  /// 顶栏 BackdropFilter 便会一直实时重采样。返回 false 让通知继续冒泡。
  bool _anyScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
      _onScrollActivity();
    }
    return false;
  }

  /// 滚动开始 → 立即降级；停止 180ms 后 → 复原（静止态保留完整液态玻璃）
  void _onScrollActivity() {
    _scrollSeq++;
    if (_degradedVN.value) return;
    _degradedVN.value = true;
    _scheduleRestore(_scrollSeq);
  }

  /// 一段静默期后恢复模糊；若期间又发生滚动（序号变了），则顺延一轮。
  void _scheduleRestore(int seq) {
    _degradeTimer?.cancel();
    _degradeTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      if (_scrollSeq != seq) {
        _scheduleRestore(_scrollSeq);
        return;
      }
      if (_degradedVN.value) _degradedVN.value = false;
    });
  }

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
      // 滚动降级统一交给外层 NotificationListener（_anyScrollNotification），
      // 它同时覆盖内层横向列表；这里不再重复调 _onScrollActivity。
    });
    // 播放页退出后会回写进度 / 收藏到全局状态，这里跟着刷新按钮文案
    widget.state.addListener(_onStateChanged);
    _loadExtras();
    _loadTranslationCache();
    _loadNfoSeries();
  }

  /// Emby 对电影不给 SeriesName，尝试从 NFO 兜底读系列名。
  ///
  /// v2.0.62：Emby 官方明确不解析 `<set><name>`（只把它留给 Kodi），所以
  /// 直读 .nfo 是唯一路径。旧版候选只有「同名 .nfo + Emby 代理 / 直链」，
  /// 且 `_kItemFields` 没要 Path，路径常常为空 → 永远读不到。这一版：
  ///  1. 先取全库里已回填的最新 seriesName（全库扫描的结果）避免重复请求；
  ///  2. filePath 缺失时补全单条详情（现在会带 Path）；
  ///  3. 用 [buildNfoCandidates] 铺开「同名 / movie.nfo × 直链 / 去签名 / 代理」；
  ///  4. 记录每一步诊断，供「系列：无」胶囊点击查看。
  /// 全程异步、失败静默、不阻塞首帧。
  Future<void> _loadNfoSeries() async {
    final state = widget.state;
    for (final e in state.items) {
      if (e.id == _item.id && e.seriesName.trim().isNotEmpty) {
        if (mounted) setState(() => _nfoSeries = e.seriesName.trim());
        return;
      }
    }
    if (_item.seriesName.trim().isNotEmpty) return;
    var path = _item.filePath;
    if (path.trim().isEmpty) {
      final server = state.server;
      if (server != null && !_item.id.startsWith('demo-')) {
        final fresh = await server.itemDetail(_item.id);
        if (!mounted) return;
        if (fresh != null) {
          setState(() => _item = fresh);
          path = fresh.filePath;
          if (fresh.seriesName.trim().isNotEmpty) return;
        }
      }
    }
    final server = state.server;
    final candidates = buildNfoCandidates(
      path,
      embyBase: server?.baseUrl,
      embyToken: server?.token,
      itemId: _item.id,
    );
    if (!mounted) return;
    _nfoTried = true;
    if (candidates.isEmpty) {
      setState(() => _nfoProbes = const <NfoProbe>[]);
      return;
    }
    final result = await loadNfoSeriesDetailed(candidates);
    if (!mounted) return;
    setState(() => _nfoProbes = result.probes);
    if (!result.ok) return;
    final v = result.series!.trim();
    setState(() => _nfoSeries = v);
    // v2.0.58 起：把 NFO 读到的系列名回填到全库，否则点「系列」胶囊
    // 打开的聚合页几乎全空，媒体库「系列」筛选也拿不到数据。
    _backfillSeries(v);
  }

  /// 系列显示「无」时，点胶囊把 NFO 读取诊断摊开给用户看（URL 已脱敏）。
  void _showNfoDiagnosis() {
    final probes = _nfoProbes;
    final body = probes.isEmpty
        ? (_nfoTried
            ? '未能派生出任何 NFO 地址：这部影片没有可用的 Path / '
                'MediaSources 路径。\n\n可到「媒体库 → 系列 → 从服务器补全系列」'
                '查看全库诊断，确认服务端到底能不能访问 .nfo。'
            : '尚未尝试读取 NFO，可下拉刷新重试。')
        : probes.map((p) => '· ${p.describe}').join('\n');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF171C29),
        title: const Text('系列 NFO 读取诊断',
            style: TextStyle(fontSize: 15, color: Colors.white)),
        content: SingleChildScrollView(
          child: Text(
            body,
            style: const TextStyle(
                fontSize: 11, color: Colors.white70, height: 1.55),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 回填系列名到全库条目：仅在目标条目 seriesName 为空时写一次，
  /// 避免覆盖服务端已有值或重复触发 notifyListeners。
  void _backfillSeries(String v) {
    final state = widget.state;
    MediaItem? target;
    for (final e in state.items) {
      if (e.id == _item.id) {
        target = e;
        break;
      }
    }
    if (target == null || target.seriesName.trim().isNotEmpty) return;
    state.replaceItem(target.copyWith(seriesName: v));
  }

  /// 预读本机缓存的 Lara 译文（title / overview），供翻译按钮「已译」标记与
  /// 「下次点开直接查看」使用。读不到也不影响主流程。
  Future<void> _loadTranslationCache() async {
    try {
      final m = await LaraTranslateCache.loadAll(_item.id);
      if (!mounted) return;
      setState(() => _cachedTrans = m);
    } catch (_) {
      // 缓存读取出错静默忽略，不阻断详情页
    }
  }

  /// 打开翻译弹层：先按字段读缓存（有则弹层直接展示译文），关闭后刷新「已译」标记。
  Future<void> _openTranslate(String field, String original) async {
    if (original.trim().isEmpty) {
      if (context.mounted) showToast(context, '没有可翻译的内容');
      return;
    }
    final existing = await LaraTranslateCache.load(_item.id, field);
    if (!mounted) return;
    if (!context.mounted) return;
    await showTranslateSheet(
      context,
      itemId: _item.id,
      field: field,
      original: original,
      existing: existing,
    );
    if (mounted) await _loadTranslationCache();
  }

  /// 标题 / 简介旁的翻译按钮：已缓存译文时高亮成主题色并提示「查看/重新翻译」。
  ///
  /// [onBanner] 用于压在封面图上的标题：那里背景明暗不定，纯图标容易糊进海报，
  /// 改为半透明深色圆底 + 白图标（与顶部返回/收藏圆钮同一套）。
  Widget _translateButton(
    String field,
    String original, {
    bool onBanner = false,
  }) {
    final cached = _cachedTrans?[field];
    final tip = cached != null ? '查看 / 重新翻译' : '翻译';
    final icon = Icon(
      Icons.translate_rounded,
      size: 18,
      color: cached != null
          ? AppColors.accent
          : (onBanner ? Colors.white : const Color(0xFF9FB0CC)),
    );
    if (!onBanner) {
      return IconButton(
        onPressed: () => _openTranslate(field, original),
        icon: icon,
        tooltip: tip,
        splashRadius: 16,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
      );
    }
    // 压在封面上的变体：用 LiquidPress 圆钮（顶部返回/刷新/收藏同款，已验证可点）。
    // 此前用 Tooltip > GestureDetector 包裹，而 Tooltip 内部会给子节点套一层
    // behavior: opaque 的 GestureDetector，它只认 onLongPress，会吞掉短按，导致按钮
    // 「按不了」——故不再经过 Tooltip。这里不复用 _RoundBtn（它自带 BackdropFilter
    // 且未接滚动降级），以免在详情页凭空多一层实时模糊；海报本身已是模糊底，半透明
    // 玻璃圆钮观感足够。
    return LiquidPress(
      onTap: () => _openTranslate(field, original),
      radius: 20,
      semanticLabel: tip,
      child: ClipOval(
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: cached != null
                  ? [
                      AppColors.accent.withOpacity(0.26),
                      AppColors.accent.withOpacity(0.10),
                    ]
                  : [
                      Colors.white.withOpacity(0.20),
                      Colors.white.withOpacity(0.06),
                    ],
            ),
            border: Border.all(
              color: cached != null
                  ? AppColors.accent.withOpacity(0.55)
                  : Colors.white.withOpacity(0.24),
            ),
          ),
          child: Center(
            child: Icon(
              Icons.translate_rounded,
              size: 17,
              color: cached != null ? AppColors.accent : Colors.white,
            ),
          ),
        ),
      ),
    );
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
    // 全局状态回写时保留已加载的分段（来自 mediaSources 单条详情），
    // 避免被批量列表条目（通常只带主版本 MediaSource）覆盖成空
    setState(() => _item = fresh!.copyWith(extraParts: _item.extraParts));
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
      _loadTranslationCache();
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

  /// v2.0.55：点导演 / 制造商胶囊 → 按该值筛出全库影片。
  ///
  /// 与点标签胶囊走同一个 [TagPage]，只是把匹配字段从 tags/genres 换成
  /// `MediaItem.director` / `MediaItem.studio`。全库列表本身已请求
  /// People / Studios 字段，因此这里不需要额外拉接口。
  void _openCredit(String value, TagPageMode mode) {
    final v = value.trim();
    if (v.isEmpty) return;
    Navigator.of(context).push(
      CambyRoutes.fade(
        builder: (_) => TagPage(
          tag: v,
          mode: mode,
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  /// v2.0.58：点「系列」胶囊 → 列出全库同系列影片。
  ///
  /// 注意数据边界：Emby 对 Movie 通常不返回 SeriesName，详情页显示的系列名
  /// 多半来自 NFO 兜底（`_nfoSeries`），而全库列表里其它影片的 `seriesName`
  /// 往往为空。因此 [TagPage] 的 series 模式用「系列名 / 标签 / 类型 / 标题」
  /// 去空白后的包含匹配，尽量把同系列影片捞出来，而不是只做精确相等。
  void _openSeries(String name) {
    final v = name.trim();
    if (v.isEmpty) return;
    Navigator.of(context).push(
      CambyRoutes.fade(
        builder: (_) => TagPage(
          tag: v,
          mode: TagPageMode.series,
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  /// 打开演员页。
  ///
  /// 从 `_castRow()` 内联逻辑抽出（信息区胶囊复用同一入口）。
  /// 只压栈、不弹自己：给 PersonPage 传 `widget.onOpenDetail`，
  /// 与「相似推荐」卡片同一套，逐级压栈可逐级返回。
  void _openPerson(CastMember p) {
    if (p.id == null) return;
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
  }

  /// 剧照查看器：多张剧照可左右滑动切换，点按空白关闭，页码紧贴图片。
  ///
  /// v2.0.49 两处修正：
  /// - showDialog 的 builder 直接返回 GestureDetector（不是 AlertDialog / Dialog），
  ///   没有 Material 祖先，WidgetsApp 的兜底 DefaultTextStyle 会给页码套上黄色
  ///   双下划线。补一层透明 Material 修掉（与 GlassPanelRoute 同源问题）。
  /// - 页码原固定在屏幕最顶部，图片居中，中间隔一大片黑。改为「页码 + 图片区」
  ///   组成一个居中的 Column，页码紧贴图片区上缘 10px，不再孤零零飘在顶部。
  void _showBackdrops(List<String> urls, int initial) {
    if (urls.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (ctx) {
        final page = PageController(
          initialPage: initial.clamp(0, urls.length - 1),
        );
        final idx = ValueNotifier<int>(initial.clamp(0, urls.length - 1));
        final size = MediaQuery.of(ctx).size;
        // 图片区占屏高 68%：宽图 contain 后仍按屏宽铺满，竖图也有足够高度；
        // 上下留白对称，页码贴在区顶，二者成为一个整体。
        final imageH = size.height * 0.68;
        return StatefulBuilder(
          builder: (ctx2, setSt) => Material(
            type: MaterialType.transparency,
            child: SizedBox.expand(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(ctx).pop(),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: ValueListenableBuilder<int>(
                          valueListenable: idx,
                          builder: (_, v, __) => Text(
                            '${v + 1} / ${urls.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: size.width,
                        height: imageH,
                        child: PageView.builder(
                          controller: page,
                          itemCount: urls.length,
                          onPageChanged: (i) => idx.value = i,
                          // 关键：不包裹 InteractiveViewer。它的缩放手势会与 PageView
                          // 的横向翻页在手势竞技场里互抢，导致滑动卡顿/粘连。
                          itemBuilder: (c, i) => RepaintBoundary(
                            child: Center(
                              child: CachedImage(
                                url: urls[i],
                                fit: BoxFit.contain,
                                // 全屏查看 1100 足清，滑动更跟手
                                memWidth: 1100,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 「视频」板块：**预告片 + 额外部分合并成一行**（v2.0.41 紧凑化）。
  ///
  /// 之前是两个独立板块，各带一个大标题和一整行卡片，仅这两块就吃掉约
  /// 230px。合并后共用一行横滑，卡片左上角挂角标区分来源：
  /// - `预告`：预告片（本地视频条目 / 远程外链）
  /// - `分段`：`-Cd1`/`-Cd2` 等其它 MediaSource
  /// - `花絮`：被扫成独立子条目的额外内容
  ///
  /// 顺序：预告片 → 分段 → 花絮。全部为空时整块不出现。
  Widget _videoSection(MediaItem item) {
    final trailers = _trailers ?? const <MediaItem>[];
    final remote = item.trailerUrls;
    final sources = item.extraParts;
    final children = _extras ?? const <MediaItem>[];
    final total =
        trailers.length + remote.length + sources.length + children.length;
    if (total == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel('视频', trailing: '$total 个'),
        const SizedBox(height: 10),
        SizedBox(
          height: 74,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: total,
            itemBuilder: (c, i) {
              // 按「预告片 → 分段 → 花絮」切段取
              if (i < trailers.length) {
                final tr = trailers[i];
                return _videoCard(
                  title: tr.name,
                  tag: '预告',
                  tagColor: const Color(0xFF5B8CFF),
                  thumb: tr.posterUrl ?? tr.backdropUrl ?? item.backdropUrl,
                  onTap: () => widget.onPlay(tr, null, resume: false),
                );
              }
              var k = i - trailers.length;
              if (k < remote.length) {
                final url = remote[k];
                return _videoCard(
                  title: '远程预告片',
                  tag: '外链',
                  tagColor: const Color(0xFF5B8CFF),
                  thumb: item.backdropUrl,
                  onTap: () => unawaited(
                    launchUrl(
                      Uri.parse(url),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                );
              }
              k -= remote.length;
              if (k < sources.length) {
                final p = sources[k];
                return _videoCard(
                  title: p.name,
                  tag: '分段',
                  tagColor: const Color(0xFFF5A052),
                  thumb: item.backdropUrl ?? item.posterUrl,
                  onTap: () => widget.onPlayPart(item, p),
                );
              }
              final e = children[k - sources.length];
              return _videoCard(
                title: e.name,
                tag: '花絮',
                tagColor: const Color(0xFF4ECF9A),
                thumb: e.posterUrl ?? e.backdropUrl ?? item.backdropUrl,
                onTap: () => widget.onPlay(e, null, resume: false),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 「视频」板块的单张卡片：缩略图 + 左上角来源角标 + 播放按钮 + 底部标题。
  ///
  /// 高度 74（原预告片/额外部分各 98），宽度 132（原 168）——合并后一行能
  /// 多露 1 张，且总高只有原来的一半。
  Widget _videoCard({
    required String title,
    required String tag,
    required Color tagColor,
    required String? thumb,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: LiquidPress(
        radius: 11,
        scale: 0.97,
        semanticLabel: '$tag $title',
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: SizedBox(
            width: 132,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumb != null && thumb.isNotEmpty)
                  CachedImage(url: thumb, memWidth: 320, fit: BoxFit.cover)
                else
                  const ColoredBox(color: Color(0x33204A80)),
                // 底部压暗，保证标题可读
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xD9000000), Color(0x00000000)],
                        ),
                      ),
                      child: SizedBox(height: 42),
                    ),
                  ),
                ),
                // 来源角标
                Positioned(
                  left: 5,
                  top: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: tagColor.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tag,
                      style: const TextStyle(
                        fontSize: 7.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
                // 播放按钮
                Center(
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.42),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.62),
                      ),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
                // 标题
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 4,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      height: 1.2,
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

  /// 预告片诊断：逐端点列出真实返回，便于定位「网页能播、App 不显示」
  /// 是否显示「诊断」入口。
  ///
  /// 规则只有一条：**内容没齐全就显示**（预告片或额外部分任一缺失）。
  /// 之前两端各写一份条件，平板那份还是旧逻辑（有预告片就整行隐藏），
  /// 结果「额外部分」取不到时连诊断入口也看不见，彻底没法排查。
  bool get _showDiagEntry {
    if (_item.id.startsWith('demo-')) return false;
    final hasTrailer =
        (_trailers?.isNotEmpty == true) || _item.trailerUrls.isNotEmpty;
    final hasExtra =
        _item.extraParts.isNotEmpty || (_extras?.isNotEmpty == true);
    return !hasTrailer || !hasExtra;
  }

  Future<void> _showTrailerDiag() async {
    final server = widget.state.server;
    if (server == null) return;
    _toast('正在检测预告片 / 额外部分接口…');
    final log = await server.trailerDiag(_item.id);
    if (!mounted) return;
    final fullText = '影片 ID: ${_item.id}\n\n${log.join('\n\n')}';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xF21A2233),
        title: const Text('预告片 / 额外部分诊断', style: TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: SelectableText(
            fullText,
            style: const TextStyle(fontSize: 11, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            // 截图常有滚动截断 / 看不清，直接复制纯文本一次性拿全
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: fullText));
              if (ctx.mounted) Navigator.of(ctx).pop();
              _toast('诊断结果已复制，可直接粘贴反馈');
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final list = await server.trailers(
                _item.id,
                includeLocalChildren: !_item.isSeries,
              );
              final extras = _item.isSeries
                  ? <MediaItem>[]
                  : await server.extraParts(_item.id);
              final parts = _item.isSeries
                  ? const <MediaExtraPart>[]
                  : await server.mediaSources(_item.id);
              if (mounted) {
                setState(() {
                  _trailers = list;
                  _extras = extras;
                  if (parts.isNotEmpty) {
                    _item = _item.copyWith(extraParts: parts);
                  }
                });
                _toast(
                  '预告片 ${list.length} 个 · 额外部分 ${extras.length} 个'
                  ' · 分段 ${parts.length} 个',
                );
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
    // 分段（同一影片的 -Cd1/-Cd2 等其它 MediaSource）：批量列表只回主版本，
    // 必须走单条详情补拉一次，否则详情页「额外部分」永远只剩独立子条目。
    // Emby 网页版能切换 cd2 正是靠这些分段。
    server
        .mediaSources(_item.id)
        .then((parts) {
          if (mounted && parts.isNotEmpty) {
            setState(() => _item = _item.copyWith(extraParts: parts));
          }
        })
        .catchError((_) {});
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
      _loadNfoSeries();
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

  /// 手机端播放行：`[▶ 继续播放（带进度填充）] [字幕 ▾]`
  ///
  /// 高度 46（原底部悬浮版 58）。字幕胶囊只在有字幕轨时出现，紧贴右侧；
  /// 没有字幕时播放按钮独占整行。
  Widget _playRow(MediaItem item) {
    final hasSub = item.subtitles.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: _ProgressPlayButton(
            item: item,
            height: 46,
            onTap: () => widget.onPlay(item, _selectedSubtitle),
            onLongPress: () =>
                widget.onPlay(item, _selectedSubtitle, resume: false),
          ),
        ),
        if (hasSub) ...[
          const SizedBox(width: 10),
          SizedBox(
            height: 46,
            child: _SubtitlePill(
              label: _selectedSubtitle?.label ?? '字幕',
              maxWidth: 118,
              onTap: _pickSubtitle,
            ),
          ),
        ],
      ],
    );
  }

  /// 剧情简介：液态玻璃卡片（手机/平板共用）
  /// 剧情简介玻璃卡片。
  /// [withTitle]：是否内嵌「剧情简介」标题。平板端改为列左缘外部标题（与
  /// 主演/标签等板块统一左缘，根治「信息卡片标题比板块标题右缩」的对齐 bug），
  /// 故传 false；手机端保持原样（默认 true）。
  Widget _overviewCard(MediaItem item, {bool withTitle = true}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      // v2.0.54：改为与标签胶囊同款的「半透明纯色框」。原来是渐变 +
      // 18px 外阴影模拟玻璃，每次滚动重绘都要重新光栅化渐变与模糊阴影；
      // 纯色 + 1px 边框可直接走图层缓存，减少剧照横滑时的合成开销。
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (withTitle) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: const _SectionLabel('剧情简介')),
                _translateButton('overview', item.overview),
              ],
            ),
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
  /// 手机端详情板块（`< 840`）：返回 `ListView` 的 children 中「头部横幅之后」
  /// 的那一段。抽成独立方法是为了让 [widget._showDiagEntry] 之类需要
  /// `setState` 状态的条件随状态刷新（之前内联在 build 里，条件读的是构建期
  /// 快照，异步加载完成后入口不会出现）。
  List<Widget> _phoneSections(MediaItem item) {
    final tags = _tagList(item);
    return [
      // 播放行（v2.0.43）：原来悬浮在底部，会压住简介和剧照，且那条
      // 常驻模糊带是第三处 BackdropFilter。改成内联到简介上方后，
      // 底部干净了，也少一层每帧重采样。字幕选择紧贴其右。
      _playRow(item),
      const SizedBox(height: 16),
      _overviewCard(item),
      if (item.filePath.isNotEmpty || item.fileSizeBytes > 0) ...[
        const SizedBox(height: 16),
        _mediaInfoCard(item),
      ],
      // 信息区（规格三列 + 演员 + 标签）：合并成一块，比原来「主演/标签」
      // 两个独立板块省空间，同时补出 系列 / 发行日期 / 时长 三项信息
      const SizedBox(height: 16),
      _InfoBlock(
        item: item,
        tags: tags,
        hasChineseSub: itemHasChineseSubtitle(item),
        onOpenSubtitleFilter: _openSubtitleFilter,
        onOpenTag: _openTag,
        onOpenPerson: _openPerson,
        onOpenDirector: (v) => _openCredit(v, TagPageMode.director),
        onOpenStudio: (v) => _openCredit(v, TagPageMode.studio),
        onOpenSeries: _openSeries,
        onNoSeriesTap: _showNfoDiagnosis,
        seriesNameOverride: _nfoSeries,
      ),
      // 视频（预告片 + 额外部分合并为一行，卡片带来源角标）
      if ((_trailers?.isNotEmpty == true) ||
          item.trailerUrls.isNotEmpty ||
          item.extraParts.isNotEmpty ||
          (_extras?.isNotEmpty == true)) ...[
        const SizedBox(height: 16),
        _videoSection(item),
      ],
      // 剧照（设计稿板块 5）：横向滚动 16:9，标题右侧数量
      if (item.backdrops.isNotEmpty) ...[
        const SizedBox(height: 16),
        _SectionLabel('剧照', trailing: '${item.backdrops.length} 张'),
        const SizedBox(height: 10),
        SizedBox(
          height: 104,
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
                    // v2.0.54：卡片显示宽 214，480 采样过大会拖慢解码 / 占内存
                    child: CachedImage(url: item.backdrops[i], memWidth: 320),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      // 诊断入口：内容没齐全就显示（见 _showDiagEntry）
      if (_showDiagEntry) ...[
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
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: const _SectionLabel('剧情简介')),
          _translateButton('overview', item.overview),
        ],
      ),
      const SizedBox(height: 10),
      _overviewCard(item, withTitle: false),
      // 媒体信息（设计稿板块 2）
      if (item.filePath.isNotEmpty || item.fileSizeBytes > 0) ...[
        const SizedBox(height: 22),
        const _SectionLabel('媒体信息'),
        const SizedBox(height: 10),
        _mediaInfoCard(item, withTitle: false),
      ],
      // 信息区（规格三列 + 演员 + 标签）：与手机端共用同一套组件
      const SizedBox(height: 22),
      _InfoBlock(
        item: item,
        tags: tags,
        hasChineseSub: itemHasChineseSubtitle(item),
        onOpenSubtitleFilter: _openSubtitleFilter,
        onOpenTag: _openTag,
        onOpenPerson: _openPerson,
        onOpenDirector: (v) => _openCredit(v, TagPageMode.director),
        onOpenStudio: (v) => _openCredit(v, TagPageMode.studio),
        onOpenSeries: _openSeries,
        onNoSeriesTap: _showNfoDiagnosis,
        seriesNameOverride: _nfoSeries,
      ),
      // 视频（预告片 + 额外部分合并为一行，卡片带来源角标）
      if ((_trailers?.isNotEmpty == true) ||
          item.trailerUrls.isNotEmpty ||
          item.extraParts.isNotEmpty ||
          (_extras?.isNotEmpty == true)) ...[
        const SizedBox(height: 22),
        _videoSection(item),
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
                    // v2.0.54：卡片显示宽 214，480 采样过大会拖慢解码 / 占内存
                    child: CachedImage(url: item.backdrops[i], memWidth: 320),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      // 预告片/额外部分缺失时的诊断入口（都有就不打扰）
      if (_showDiagEntry) ...[
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: IgnorePointer(
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
            ),
            _translateButton('title', item.name, onBanner: true),
          ],
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
    _degradeTimer?.cancel();
    _degradedVN.dispose();
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
            child: NotificationListener<ScrollNotification>(
              // v2.0.54：内层横向列表（剧照 / 标签胶囊行）的滚动通知不会经过
              // 主 _scroll，导致顶栏 BackdropFilter 在横滑时仍逐帧重采样 ——
              // 这正是「剧照滑动还是有点掉帧」的主因之一。统一在这里接住
              // 所有后代滚动通知，复用既有 _degradedVN 降级机制。
              onNotification: _anyScrollNotification,
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
                        // 手机横幅：海报 + 标题块用 Stack 重叠（标题压在封面上）。
                        // 不能再用「ListView 垂直排列 + Transform.translate 上移」：
                        // Transform 只改「视觉位置」、不改「布局槽位」，命中测试按布局
                        // 位置把标题按钮所在区域判给下层海报，按钮永远收不到点击——
                        // 这就是 v2.0.51 修掉的「标题旁翻译按钮点不动」的根因。
                        //
                        // v2.0.52：Stack 作为 ListView 的第一个 child，其「布局占位高度」
                        // 必须比海报实际高度少 titleLift。否则标题块虽被压到海报上，
                        // 后续板块（继续播放 / 剧情简介）却仍从完整海报底部开始排，
                        // 中间凭空空出 titleLift（56~150px）——用户反馈「继续播放和
                        // 信息页离标题太远」即是此因。这里用 SizedBox 缩短占位，
                        // 再用 OverflowBox 让内部 Stack 仍以完整 posterH 布局并溢出
                        // 显示（clipBehavior: Clip.none）：视觉完全不变，但布局槽位
                        // 上抬 titleLift，后续板块自然紧跟标题块。因为全程没用
                        // Transform，布局位置与视觉位置一致，命中测试不会退化。
                        SizedBox(
                          height: posterH - titleLift,
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minHeight: posterH,
                            maxHeight: posterH,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // 海报按原始比例完整显示（不裁切）
                                RepaintBoundary(
                                  child: AspectRatio(
                                    aspectRatio: posterAspect,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if ((item.posterUrl ??
                                                item.backdropUrl) !=
                                            null) ...[
                                          // 海报底部渐隐用 ShaderMask（真实 alpha 渐隐）。
                                          //
                                          // v2.0.41 曾改为「叠一层纯色渐变」，结果底部出现
                                          // 明显断层——因为叠的是固定色 #06080E，而页面背景
                                          // 是随主色变化的，两色对不上就露出硬边。这里恢复
                                          // ShaderMask：透明处直接透出页面背景，不依赖色值。
                                          //
                                          // 性能：外层已有 RepaintBoundary，saveLayer 结果会
                                          // 被缓存成图层，滚动时只是平移复用，不逐帧重算。
                                          ShaderMask(
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
                                          ),
                                        ] else
                                          DecoratedBox(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: [
                                                  item.colors.first.withOpacity(
                                                    0.9,
                                                  ),
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
                                // 标题块压在封面底部（bottom: titleLift 使其上抬，露出下方
                                // 海报）；右上角挂翻译按钮。此块在 Stack 上层，命中测试可
                                // 正常点到按钮（修复前在 Transform 平移层里点不动）。
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: titleLift,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // 标题压在封面上：右上角挂翻译按钮（v2.0.49 补齐手机布局，
                                        // 之前只有平板 banner 有，手机看不到）
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                item.name,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 26,
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
                                            ),
                                            const SizedBox(width: 8),
                                            _translateButton(
                                              'title',
                                              item.name,
                                              onBanner: true,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          [
                                            if (item.year > 0) '${item.year}',
                                            if (item.runtimeMin > 0)
                                              '${item.runtimeMin} 分钟',
                                            if (item.director.isNotEmpty)
                                              '导演 ${item.director}',
                                            if (item.studio.isNotEmpty)
                                              item.studio,
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
                                                label: item.rating
                                                    .toStringAsFixed(1),
                                                gold: true,
                                              ),
                                            if (item.isTrue4K)
                                              _Badge(
                                                icon: Icons.hd_rounded,
                                                label: '2160p',
                                              ),
                                            _Badge(
                                              icon:
                                                  Icons.movie_creation_outlined,
                                              label: item.videoCodec,
                                            ),
                                            _Badge(
                                              icon: Icons.graphic_eq_rounded,
                                              label:
                                                  '${item.audioCodec} ${item.audioChannels}ch',
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // 其余内容（播放行 → 简介 → 板块），紧跟标题块底部排布
                        // （徽章 → 播放行间距 20，与 v2.0.51 之前一致）
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 20),
                              // 板块：播放行 → 简介 → 媒体信息 → 信息区（系列/
                              // 演员/标签）→ 视频 → 剧照 → 诊断入口 → 相似推荐
                              ..._phoneSections(item),
                              // 底部不再有悬浮播放条（v2.0.43 移到简介上方），
                              // 留白 120 → 24，只够避开手势条
                              SizedBox(
                                height:
                                    24 + MediaQuery.of(context).padding.bottom,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
          // 状态栏渐进模糊：上滑后才出现（放在顶栏之前，保证按钮不被糊）
          //
          // v2.0.44：与首页（main.dart 的 shell）保持完全一致 —— 不传 degraded，
          // sigma 用默认 30。之前为了省 GPU 降级成渐变、sigma 压到 14，滚动时
          // 状态栏会「变样」，跟首页对不上。首页一直实时模糊也很顺，说明这一条
          // 不是瓶颈（底部模糊带已在 v2.0.43 移除，圆钮也已降级）。
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
                ),
              ),
            ),
          ),
          // 顶栏（最上层，保证可点）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Stack(
              children: [
                // 只有这层随滚动重建（每帧一次渐变），按钮区不再被牵连。
                // 之前整个顶栏都包在 ValueListenableBuilder 里，滚动时
                // 3 个按钮每帧重建一遍，纯属白烧。
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _offsetVN,
                      builder: (_, o, __) => DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(
                                alpha: (0.55 * (1 - o / 300)).clamp(0.0, 0.55),
                              ),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 非定位子项：由它决定 Stack 的高度（否则无界高度会断言失败）
                ValueListenableBuilder<bool>(
                  valueListenable: _degradedVN,
                  builder: (_, deg, __) => SizedBox(
                    width: double.infinity,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                        child: Row(
                          children: [
                            _RoundBtn(
                              icon: Icons.arrow_back_ios_new_rounded,
                              degraded: deg,
                              onTap: () => Navigator.pop(context),
                            ),
                            const Spacer(),
                            _RoundBtn(
                              icon: _refreshing
                                  ? Icons.sync_rounded
                                  : Icons.refresh_rounded,
                              degraded: deg,
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
                              degraded: deg,
                              onTap: _openFolders,
                            ),
                          ],
                        ),
                      ),
                    ),
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
      // v2.0.54：改为与标签胶囊同款的「半透明纯色框」。原来是渐变 +
      // 18px 外阴影模拟玻璃，每次滚动重绘都要重新光栅化渐变与模糊阴影；
      // 纯色 + 1px 边框可直接走图层缓存，减少剧照横滑时的合成开销。
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
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

class _SubtitlePill extends StatelessWidget {
  const _SubtitlePill({
    required this.label,
    required this.onTap,
    this.maxWidth = 200,
  });

  final String label;
  final VoidCallback onTap;

  /// 播放行里空间紧，窄屏要截断（字幕名可能很长，如「简体中文 (ASS)」）
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 999,
      scale: 0.96,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Colors.white.withOpacity(0.12),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.ink,
                  fontWeight: FontWeight.w600,
                ),
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
  const _ProgressPlayButton({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.height = 58,
  });

  final MediaItem item;
  final VoidCallback onTap;

  /// 长按 = 从头播放。原来底部那条还有独立的「重播」圆钮，移到详情页
  /// 内联后位置不够，改成长按——功能没丢，只占一个按钮的地方。
  final VoidCallback? onLongPress;

  /// v2.0.43：按钮从底部悬浮栏移到「剧情简介」上方，高度 58 → 46
  /// （内联在卡片流里，太厚会顶掉一屏内容）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final r = height / 2;
    final progress = (item.resumeProgress ?? 0).clamp(0.0, 1.0);
    final label = progress >= 0.99
        ? '重新播放'
        : progress > 0
        ? '继续播放'
        : '立即播放';
    return LiquidPress(
      onTap: onTap,
      onLongPress: onLongPress,
      radius: r,
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
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(r),
          child: Stack(
            children: [
              // 液态玻璃底（未播放部分）
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(r),
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
    this.degraded = false,
  });
  final IconData icon;
  final VoidCallback? onTap;

  /// 滚动降级：为 true 时不做实时 BackdropFilter，只留半透明渐变。
  ///
  /// 三个圆钮各带一个 sigma=16 的 BackdropFilter，常驻压在滚动内容上，
  /// 滚动时每帧都要重新采样——这是两条模糊带之外最容易漏掉的一处。
  /// 按钮只有 40×40，去掉模糊后视觉几乎无差（底色本来就是玻璃渐变）。
  final bool degraded;

  /// 激活态（收藏心形点亮）：粉红渐变 + 描边，与收藏夹弹窗「已收藏」一致
  final bool active;
  final String? semanticLabel;

  /// 包一层磨砂；降级时直接返回原 widget（不创建 BackdropFilter）
  Widget _glassBody(Widget child) {
    if (degraded) return child;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: child,
    );
  }

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
        // 真磨砂玻璃：与其他页顶栏圆钮（首页 _GlassCircleBtn 等）统一。
        // 滚动期间降级为纯渐变（见 [degraded]），避免 3 个按钮每帧重采样。
      child: _glassBody(
          Container(
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

/// 详情页「信息区」：规格三列（系列 / 发行 / 时长）+ 导演/制造商行 +
/// 演员行 + 标签行。
///
/// 设计来源：参考截图（浅色三列 + 三色胶囊），转为深色液态玻璃配色；
/// 采用紧凑版——每行单行横滑、全部可滑到，锁图标按需求去掉。
///
/// v2.0.55：导演 / 制造商从演员行里拆出来**单独成行**，并支持点击按该值
/// 筛选全库影片。原来三条信息混在「演员」标题下，语义不对且不好点。
///
/// v2.0.61 / G4：演员胶囊前缀不再写死 ♀（此前无论男女一律显示 ♀，导致
/// 男优被全标成女性）。改为按服务端明确给出的 gender 渲染 ♀/♂，读不到就
/// 用中性人物图标，绝不按名字 / 头像猜。
class _InfoBlock extends StatelessWidget {
  const _InfoBlock({
    required this.item,
    required this.tags,
    required this.hasChineseSub,
    required this.onOpenSubtitleFilter,
    required this.onOpenTag,
    required this.onOpenPerson,
    required this.onOpenDirector,
    required this.onOpenStudio,
    required this.onOpenSeries,
    this.onNoSeriesTap,
    this.seriesNameOverride = '',
  });

  final MediaItem item;
  final List<String> tags;
  final bool hasChineseSub;
  final VoidCallback onOpenSubtitleFilter;
  final void Function(String tag) onOpenTag;
  final void Function(CastMember p) onOpenPerson;
  final void Function(String name) onOpenDirector;
  final void Function(String name) onOpenStudio;
  final void Function(String name) onOpenSeries;

  /// v2.0.62：系列为「无」时点胶囊看 NFO 诊断，不再是一个死占位。
  final VoidCallback? onNoSeriesTap;

  /// NFO 直读兜底拿到的系列名。Emby 对电影的 `SeriesName` 通常为空，
  /// 即使 NFO 里写了 `<series>` / `<set><name>` 也不会带出来。
  final String seriesNameOverride;

  static const _orange = Color(0xFFF5A052);
  static const _purple = Color(0xFFB98CFF);
  static const _green = Color(0xFF4ECF9A);
  // v2.0.54：演员行的导演 / 制造商信息标签独立配色
  static const _blue = Color(0xFF6FA8FF);
  static const _teal = Color(0xFF5FCFC0);

  /// 「无」用的中性灰（与胶囊行末尾 `+N` 同色，语义都是「占位/弱信息」）
  static const _dim = Color(0xFF7E8DA6);

  /// 发行日期：优先 PremiereDate，缺失回退到年份
  String get _releaseText {
    if (item.premiereDate.isNotEmpty) return item.premiereDate;
    if (item.year > 0) return '${item.year}';
    return '—';
  }

  /// 时长：与参考图同款 `45m` 写法；>=60 分钟显示 `2h32m`
  String get _runtimeText {
    final m = item.runtimeMin;
    if (m <= 0) return '—';
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '${h}h' : '${h}h${r}m';
  }

  @override
  Widget build(BuildContext context) {
    final seriesName = (seriesNameOverride.trim().isNotEmpty
            ? seriesNameOverride
            : item.seriesName)
        .trim();
    final director = item.director.trim();
    final studio = item.studio.trim();
    final hasCredits = director.isNotEmpty || studio.isNotEmpty;
    final creditCount =
        (director.isNotEmpty ? 1 : 0) + (studio.isNotEmpty ? 1 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 规格三列 ──
        // v2.0.59：系列名**完整显示**。上一版用 SizedBox(height:40) 固定盒 +
        // maxLines:2 + ellipsis，真机上第二行被垂直裁掉、行尾还带省略号
        // （用户反馈「系列文字还是被切了」）。现在系列胶囊不限行数、占满列宽
        // 自然换行；三列靠「标签行 + 值起始线」顶部对齐，发行日期 / 时长放在
        // 26px 盒里垂直居中，单行文字基线与胶囊第一行基本一致。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 系列：**始终显示**，没有就标「无」——空着会让三列看着少一格，
            // 反而让人以为信息没加载出来（v2.0.43 按反馈调整）。有值时可点。
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _MiniLabel('系列'),
                  const SizedBox(height: 6),
                  _Cap(
                    text: seriesName.isEmpty ? '无' : seriesName,
                    color: seriesName.isEmpty ? _dim : _orange,
                    maxWidth: double.infinity,
                    maxLines: seriesName.isEmpty ? 1 : null,
                    fillWidth: true,
                    onTap: seriesName.isEmpty
                        ? onNoSeriesTap
                        : () => onOpenSeries(seriesName),
                    trailing: seriesName.isEmpty
                        ? null
                        : const Icon(
                            Icons.chevron_right,
                            size: 12,
                            color: _orange,
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _MiniLabel('发行日期'),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 26,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _Plain(text: _releaseText),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _MiniLabel('时长'),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 26,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _Plain(text: _runtimeText),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        // ── 导演 / 制造商（v2.0.55：从演员行拆出，单独一行且可点筛选） ──
        // 即使没有演员，只要 Emby/NFO 给了导演或工作室，这一行也要出现。
        if (hasCredits) ...[
          const _HSep(),
          const _MiniLabel('导演 / 制造商'),
          const SizedBox(height: 7),
          _CapRow(
            count: creditCount,
            itemBuilder: (i) {
              if (director.isNotEmpty && i == 0) {
                return _Cap(
                  text: '导演 $director',
                  color: _blue,
                  maxWidth: 220,
                  leading: const Icon(
                    Icons.movie_creation_outlined,
                    size: 11,
                    color: _blue,
                  ),
                  onTap: () => onOpenDirector(director),
                );
              }
              return _Cap(
                text: '制造商 $studio',
                color: _teal,
                maxWidth: 220,
                leading: const Icon(Icons.business, size: 11, color: _teal),
                onTap: () => onOpenStudio(studio),
              );
            },
          ),
        ],
        // ── 演员 ──
        if (item.people.isNotEmpty) ...[
          const _HSep(),
          const _MiniLabel('演员'),
          const SizedBox(height: 7),
          _CapRow(
            count: item.people.length,
            itemBuilder: (i) {
              final p = item.people[i];
              // v2.0.61 / G4：不再写死 ♀。服务端明确给 gender 才渲染 ♀/♂，
              // 读不到就用中性人物图标，绝不按名字 / 头像猜性别。
              return _Cap(
                text: p.name,
                color: _purple,
                leading: genderLeading(p.gender),
                onTap: () => onOpenPerson(p),
              );
            },
          ),
        ],
        // ── 标签 ──
        if (tags.isNotEmpty || hasChineseSub) ...[
          const _HSep(),
          const _MiniLabel('标签'),
          const SizedBox(height: 7),
          _CapRow(
            count: tags.length + (hasChineseSub ? 1 : 0),
            itemBuilder: (i) {
              if (hasChineseSub && i == 0) {
                return _Cap(
                  text: '中文字幕',
                  color: _green,
                  onTap: onOpenSubtitleFilter,
                );
              }
              final t = tags[i - (hasChineseSub ? 1 : 0)];
              return _Cap(text: t, color: _green, onTap: () => onOpenTag(t));
            },
          ),
        ],
      ],
    );
  }
}

/// 信息区的小标题（10px，弱化，与参考图一致）
class _MiniLabel extends StatelessWidget {
  const _MiniLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      color: AppColors.muted,
      letterSpacing: 0.2,
    ),
  );
}

/// 信息区分隔细线（左实右渐隐，弱化但仍分区）
class _HSep extends StatelessWidget {
  const _HSep();

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: const EdgeInsets.only(top: 13, bottom: 11),
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0x17FFFFFF), Color(0x00FFFFFF)]),
    ),
  );
}

/// 纯文字值（发行日期 / 时长）
class _Plain extends StatelessWidget {
  const _Plain({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: Color(0xFFE9EFFA),
      letterSpacing: -0.2,
      height: 1.35,
    ),
  );
}

/// 单个彩色胶囊。
///
/// [maxLines] 为 null 时不限行数、不省略，用于「系列」这类必须完整显示的长
/// 文本；[fillWidth] 让胶囊占满父级列宽并用 Expanded 分配文字宽度，避免
/// `mainAxisSize: min` + Flexible 把长文本挤成很窄的竖条。
class _Cap extends StatelessWidget {
  const _Cap({
    required this.text,
    required this.color,
    this.leading,
    this.trailing,
    this.onTap,
    this.maxWidth = 190,
    this.maxLines = 1,
    this.fillWidth = false,
  });

  final String text;
  final Color color;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double maxWidth;
  final int? maxLines;
  final bool fillWidth;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.visible : TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        color: Color.lerp(color, Colors.white, 0.25),
        letterSpacing: 0.1,
      ),
    );
    final body = Container(
      width: fillWidth ? double.infinity : null,
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: fillWidth ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 4)],
          if (fillWidth) Expanded(child: label) else Flexible(child: label),
          if (trailing != null) ...[const SizedBox(width: 3), trailing!],
        ],
      ),
    );
    if (onTap == null) return body;
    return LiquidPress(
      onTap: onTap,
      radius: 7,
      scale: 0.96,
      semanticLabel: text,
      child: body,
    );
  }
}

/// 单行横滑的胶囊行：**全部渲染**，横向滑动查看。
///
/// 用横向 ListView 而不是 Wrap：紧凑版的核心就是「永远只占一行」，
/// 标签再多也不撑高板块。
///
/// v2.0.54 之前按屏宽估算只渲染前 `visible` 个、末尾补一个不可点的 `+N`，
/// 结果标签一多根本滑不到后面那些（用户反馈「标签过多时，可滑动查看」）。
/// 改为 `itemCount = count` 全部渲染；ListView.builder 本身懒构建，屏外
/// 卡片不会一次性铺开，标签再多也不会拖慢首帧。
class _CapRow extends StatelessWidget {
  const _CapRow({required this.count, required this.itemBuilder});

  final int count;
  final Widget Function(int i) itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return SizedBox(
      height: 28,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: count,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: itemBuilder(i),
        ),
      ),
    );
  }
}
