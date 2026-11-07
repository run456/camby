import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../widgets/glass_toast.dart';
import '../theme.dart';
import '../layout.dart';
import '../widgets/cached_image.dart';
import '../widgets/gender_badge.dart';
import '../widgets/media_filter_sheet.dart';
import '../widgets/media_poster.dart';

/// 演员详情页（v2.0.61 设计稿方案 A）。
///
/// 旧版把 200px 的小头像放大铺成 340dp 满幅 banner，既发糊又构图被切，
/// 而且整页没有任何「参演总数」。这一版按用户确认的方案改造：
///  - 头像「框起来」：82×102 圆角卡片（头像单独请求 maxWidth=400）
///  - 单页滚动 + **吸顶筛选条**：资料卡 → 字段网格 → 简介 → 吸顶
///    「全部/电影/剧集 + 漏斗 + 计数」→ 作品网格
///  - 资料卡一个大数字「N 部影片」，筛选条右侧「共 N 部 / M / N 部」
///  - 字段走 S1（只用 Emby 现有字段），**有值才渲染**，不摆一排「—」
///  - 性别走 G4：服务端给 gender 才显示 ♀/♂，没给用中性图标，绝不猜
///  - 平板（≥840dp）：左资料卡 + 右独立作品区，列数仍走 mediaGridColumns
///
/// 总数优先用 personItems 的服务端列表，离线 / 失败 / 加载中回退到
/// [AppState.items] 按 people 本地聚合，所以断网也有数（S1 的设计取舍）。
/// 作品网格仍只用服务端列表（与改造前一致，零回归），本地聚合只兜底数字。
class PersonPage extends StatefulWidget {
  const PersonPage({
    super.key,
    required this.person,
    required this.state,
    required this.onOpenDetail,
  });

  final CastMember person;
  final AppState state;
  final OpenDetail onOpenDetail;

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  List<MediaItem>? _films;
  Map<String, dynamic>? _info;
  bool _loading = true;
  int _tab = 0; // 0 全部 1 电影 2 剧集
  bool _expanded = false;
  bool _fav = false;
  bool _favBusy = false;

  /// 顶栏随滚动淡出，让吸顶筛选条能干净地贴在状态栏下方。
  /// 用 ValueNotifier 只重建顶栏，不整页 setState（性能红线）。
  final ValueNotifier<double> _topBarFade = ValueNotifier<double>(1.0);

  /// 排序与筛选状态（与媒体库同一份实现：5 字段 × 升降 + 分辨率 + 字幕 + 标签）
  final MediaFilter _filter = MediaFilter(sort: 1);

  @override
  void initState() {
    super.initState();
    // 先用本地缓存的收藏状态，避免离线时 ♥ 状态丢失
    _fav = widget.state.isPersonFavorite(widget.person.id);
    _load();
  }

  @override
  void dispose() {
    _topBarFade.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final server = widget.state.server;
    final pid = widget.person.id;
    if (server == null || pid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    server.personDetails(pid).then((info) {
      if (mounted)
        setState(() {
          _info = info;
          final ud = info?['UserData'] as Map<String, dynamic>?;
          _fav = ud?['IsFavorite'] == true;
        });
    });
    try {
      final list = await server.personItems(pid);
      if (mounted)
        setState(() {
          _films = list;
          _loading = false;
        });
    } catch (_) {
      // 断网 / 服务端失败：_films 保持 null，作品与总数自动回退到本地聚合
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------- 数据 ----------------

  /// 本地聚合：媒体库里 people 命中该演员的影片。只算一次（late final）。
  late final List<MediaItem> _localFilms =
      widget.state.items.where(_isFilmOfPerson).toList();

  bool _isFilmOfPerson(MediaItem m) {
    final p = widget.person;
    final pid = p.id;
    final pname = p.name.trim().toUpperCase();
    for (final c in m.people) {
      if (pid != null && pid.isNotEmpty && c.id == pid) return true;
      if (c.name.trim().toUpperCase() == pname) return true;
    }
    return false;
  }

  /// 作品网格数据源：与改造前完全一致，只用 personItems 的服务端列表。
  /// 离线 / 加载中为空 —— 本地聚合只给「总数 / 最近」兜底，不拼进网格，
  /// 避免把缺 metadata 的本地条目塞进 PosterCard（也避免测试视口既有溢出）。
  List<MediaItem> get _gridFilms => _films ?? const <MediaItem>[];

  /// 参演总数：服务端列表优先，离线 / 加载中 / 空结果回退本地聚合。
  int get _total {
    final remote = _films?.length ?? 0;
    return remote > 0 ? remote : _localFilms.length;
  }

  /// 离线（还没拿到作品列表）时的空态提示，讲清「有数但列表需联网」。
  String? get _offlineHint => (_films == null && _localFilms.isNotEmpty)
      ? '作品列表需联网加载 · 本地媒体库共 ${_localFilms.length} 部'
      : null;

  int? get _latestYear {
    final source = _gridFilms.isNotEmpty ? _gridFilms : _localFilms;
    int? best;
    for (final m in source) {
      if (m.year > 0 && (best == null || m.year > best)) best = m.year;
    }
    return best;
  }

  String? get _birth {
    final iso = _info?['PremiereDate'] as String?;
    final d = iso == null ? null : DateTime.tryParse(iso);
    return d == null
        ? null
        : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// 性别：演员卡带的值优先，其次从 personDetails 里读（G4：归一不了即 null）。
  String? get _gender =>
      widget.person.gender ??
      normalizeGender(_info?['Gender'] ?? _info?['Sex']);

  /// 别名：仅当服务端给了且与姓名不同才显示（S1：有值才渲染）。
  String? get _alias {
    final a = (_info?['OriginalTitle'] as String?)?.trim();
    if (a == null || a.isEmpty || a == widget.person.name) return null;
    return a;
  }

  /// 出生地：ProductionLocations（Person item 常为空，空则隐藏）。
  String? get _birthPlace {
    final locs = _info?['ProductionLocations'];
    if (locs is List && locs.isNotEmpty) {
      final v = locs.first.toString().trim();
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  /// 先按「全部 / 电影 / 剧集」tab 过滤（筛选与排序在公共 [MediaFilter] 里做）
  Iterable<MediaItem> _byTab(List<MediaItem> all) => switch (_tab) {
    1 => all.where((e) => e.isMovie),
    2 => all.where((e) => e.isSeries),
    _ => all.where((_) => true),
  };

  String get _overview => (_info?['Overview'] as String?) ?? '';

  List<MediaItem> get _filtered => _filter.apply(_byTab(_gridFilms));

  /// 排序与筛选抽屉：与媒体库完全同一套版式与能力
  Future<void> _showFilterSheet() async {
    final result = await showMediaFilterSheet(
      context,
      filter: _filter,
      source: _byTab(_gridFilms),
    );
    if (result == null || !mounted) return;
    setState(() => _filter.applyResult(result));
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical) {
      final o = (1.0 - n.metrics.pixels / 110.0).clamp(0.0, 1.0);
      if ((_topBarFade.value - o).abs() > 0.02) _topBarFade.value = o;
    }
    return false; // 继续冒泡，不吞掉通知
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final server = widget.state.server;
    final imgUrl = (server != null && p.id != null)
        // v2.0.61：资料卡头像单独请求更大尺寸，避免 200px 缩略图发糊
        ? server.personImageUrl(p.id!, p.imageTag, maxWidth: 400)
        : null;
    final films = _filtered;
    final total = _total;
    final topPad = MediaQuery.of(context).padding.top;
    final wide = context.isTablet;
    final hPad = wide ? 24.0 : 16.0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // 弱模糊氛围底色：只做背景，不再当主视觉。
          // RepaintBoundary 让这层只栅格化一次，滚动期间走缓存纹理。
          if (imgUrl != null)
            Positioned.fill(
              child: RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: CachedImage(url: imgUrl, memWidth: 220),
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
          // SafeArea 让 viewport 从状态栏下方开始 —— pinned 筛选条正好贴在
          // 状态栏下、顶栏原位置；配合顶栏淡出，吸顶后不互相遮挡。
          Positioned.fill(
            child: SafeArea(
              top: true,
              bottom: false,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: RepaintBoundary(
                  child: wide
                      ? _wideBody(
                          imgUrl: imgUrl,
                          films: films,
                          total: total,
                        )
                      : _phoneBody(
                          imgUrl: imgUrl,
                          films: films,
                          total: total,
                          hPad: hPad,
                        ),
                ),
              ),
            ),
          ),
          // 顶栏（最上层，滚动时淡出）
          _buildTopBar(context, topPad),
        ],
      ),
    );
  }

  // ---------------- 两种主体布局 ----------------

  /// 手机：单页滚动，资料卡 → 字段网格 → 简介 → 吸顶筛选 → 作品网格。
  Widget _phoneBody({
    required String? imgUrl,
    required List<MediaItem> films,
    required int total,
    required double hPad,
  }) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            // 56 = 顶栏圆钮(40) + 上下留白，让首屏资料卡不与顶栏重叠
            padding: EdgeInsets.fromLTRB(hPad, 56, hPad, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _profileCard(imgUrl: imgUrl, vertical: false, total: total),
                const SizedBox(height: 10),
                _fieldsGrid(total),
                if (_overview.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _overviewBlock(),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _FilterHeaderDelegate(
            height: 46,
            child: _filterBar(films: films, total: total, hPad: hPad),
          ),
        ),
        ..._worksSlivers(films, hPad),
      ],
    );
  }

  /// 平板：左侧固定资料卡，右侧独立作品区（各自滚动，筛选条在右侧吸顶）。
  Widget _wideBody({
    required String? imgUrl,
    required List<MediaItem> films,
    required int total,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 250,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 56, 8, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _profileCard(imgUrl: imgUrl, vertical: true, total: total),
                const SizedBox(height: 10),
                _fieldsGrid(total, cols: 2),
                if (_overview.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _overviewBlock(),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 56)),
              SliverPersistentHeader(
                pinned: true,
                delegate: _FilterHeaderDelegate(
                  height: 46,
                  child:
                      _filterBar(films: films, total: total, hPad: 12),
                ),
              ),
              ..._worksSlivers(films, 12),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- 资料卡 ----------------

  Widget _avatarFrame(double w, double h, String? imgUrl) {
    return Container(
      width: w,
      height: h,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.20),
            Colors.white.withOpacity(0.04),
          ],
        ),
        border: Border.all(color: Colors.white.withOpacity(0.28)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: imgUrl != null
            ? CachedImage(
                url: imgUrl,
                memWidth: 400,
                alignment: Alignment.topCenter,
                errorWidget: _avatarPlaceholder(),
              )
            : _avatarPlaceholder(),
      ),
    );
  }

  Widget _avatarPlaceholder() => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3A2D4A), Color(0xFF141B29)],
          ),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.person_rounded,
            size: 34, color: Colors.white.withOpacity(0.35)),
      );

  Widget _profileCard({
    required String? imgUrl,
    required bool vertical,
    required int total,
  }) {
    final p = widget.person;
    final gender = _gender;
    final gLabel = genderLabel(gender);
    final badges = <Widget>[
      _badge('演员', const Color(0xFFB79CFF)),
      if (_birth != null) _badge(_birth!, const Color(0xFFC2CDE0)),
      // G4：只有服务端给了明确性别才渲染 ♀/♂ 徽标，否则完全不显示
      if (gLabel != null)
        _badge(
          '${gender == kGenderFemale ? '♀' : '♂'} $gLabel',
          gender == kGenderFemale
              ? const Color(0xFFB98CFF)
              : const Color(0xFF6FA8FF),
        ),
    ];
    final frame = _avatarFrame(vertical ? 74 : 82, vertical ? 92 : 102, imgUrl);
    final info = Column(
      crossAxisAlignment:
          vertical ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          p.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: vertical ? TextAlign.center : TextAlign.start,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.4,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          alignment: vertical ? WrapAlignment.center : WrapAlignment.start,
          children: badges,
        ),
        const SizedBox(height: 9),
        // 参演总数大数字（用户确认「资料卡大数字 + 筛选条计数」）
        Row(
          mainAxisSize: vertical ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment:
              vertical ? MainAxisAlignment.center : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$total',
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Color(0xFFFFA347),
                letterSpacing: -1,
              ),
            ),
            const SizedBox(width: 4),
            const Text(
              '部影片',
              style: TextStyle(fontSize: 10.5, color: AppColors.muted),
            ),
          ],
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.055),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withOpacity(0.13)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: vertical
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [frame, const SizedBox(height: 10), info],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                frame,
                const SizedBox(width: 12),
                Expanded(child: info),
              ],
            ),
    );
  }

  Widget _badge(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.withOpacity(0.16),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.withOpacity(0.4)),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            color: c.withOpacity(0.95),
          ),
        ),
      );

  /// 字段网格（S1：只用 Emby 现有字段，有值才渲染，不摆一排「—」）。
  Widget _fieldsGrid(int total, {int cols = 3}) {
    final fields = <_FieldData>[
      if (_birth != null) _FieldData('生日', _birth!),
      _FieldData('参演', '$total 部'),
      if (_latestYear != null) _FieldData('最近', '${_latestYear}年'),
      _FieldData('收藏', _fav ? '已收藏' : '未收藏'),
      if (_alias != null) _FieldData('别名', _alias!),
      if (genderLabel(_gender) != null)
        _FieldData('性别', genderLabel(_gender)!),
      if (_birthPlace != null) _FieldData('出生地', _birthPlace!),
    ];
    return LayoutBuilder(
      builder: (context, cons) {
        const gap = 6.0;
        final w = (cons.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final f in fields)
              SizedBox(width: w, child: _fieldChip(f.label, f.value)),
          ],
        );
      },
    );
  }

  Widget _fieldChip(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 9, color: AppColors.muted)),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      );

  Widget _overviewBlock() => _OverviewText(
        text: _overview,
        expanded: _expanded,
        onToggle: () => setState(() => _expanded = !_expanded),
      );

  // ---------------- 吸顶筛选条 ----------------

  /// 「全部/电影/剧集 + 漏斗」原样保留，右侧加计数：
  /// 未筛选显示「共 N 部」，切 tab / 改漏斗后显示「筛选结果 / 总数」。
  Widget _filterBar({
    required List<MediaItem> films,
    required int total,
    required double hPad,
  }) {
    // 有实际网格结果时才显示「筛选结果 / 总数」；离线（网格空）始终显示
    // 「共 N 部」，避免出现「0 / 4 部」这种让人困惑的计数。
    final filtered =
        films.isNotEmpty && (_tab != 0 || _filter.activeCount > 0);
    final label = filtered ? '${films.length} / $total 部' : '共 $total 部';
    return Container(
      height: 46,
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xF20B1020),
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Seg(
              options: const ['全部', '电影', '剧集'],
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
          const SizedBox(width: 8),
          MediaFilterButton(filter: _filter, onTap: _showFilterSheet),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: Color(0xFFFFA347),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _worksSlivers(List<MediaItem> films, double hPad) {
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      if (_loading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
        )
      else if (films.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Text(
              _offlineHint ?? '该分类下暂无作品',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 40),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              // 平板 / 手机列数继续走断点，不硬编码
              crossAxisCount: context.mediaGridColumns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 14,
              childAspectRatio: 0.55,
            ),
            delegate: SliverChildBuilderDelegate(
              (c, i) => PosterCard(
                item: films[i],
                width: double.infinity,
                heroTag: 'person-${widget.person.id}-${films[i].id}',
                onTap: () => widget.onOpenDetail(
                  films[i],
                  heroTag: 'person-${widget.person.id}-${films[i].id}',
                ),
              ),
              childCount: films.length,
            ),
          ),
        ),
    ];
  }

  // ---------------- 顶栏 / 收藏 ----------------

  Future<void> _toggleFav() async {
    if (widget.person.id == null || _favBusy) return;
    setState(() => _favBusy = true);
    final target = !_fav;
    setState(() => _fav = target);
    // 走 AppState：服务端 + 本地缓存一起更新，收藏页立即可见
    await widget.state.togglePersonFavorite(widget.person);
    if (!mounted) return;
    setState(() => _fav = widget.state.isPersonFavorite(widget.person.id));
    setState(() => _favBusy = false);
    showToast(context, _fav ? '已收藏演员' : '已取消收藏');
  }

  Widget _buildTopBar(BuildContext context, double topPad) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<double>(
        valueListenable: _topBarFade,
        builder: (context, o, _) => Opacity(
          opacity: o,
          child: IgnorePointer(
            ignoring: o < 0.1,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, topPad + 8, 14, 0),
              child: Row(
                children: [
                  _RoundBtn(
                    icon: Icons.arrow_back_ios_new_rounded,
                    semanticLabel: '返回',
                    onTap: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  _RoundBtn(
                    icon: _fav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    semanticLabel: _fav ? '取消收藏' : '收藏演员',
                    iconColor: _fav ? const Color(0xFFFF5C7A) : Colors.white,
                    onTap: _toggleFav,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 吸顶筛选条委托：固定高度，内容由页面构造（含 _Seg / 漏斗 / 计数）。
class _FilterHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _FilterHeaderDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox(height: height, child: child);

  @override
  bool shouldRebuild(covariant _FilterHeaderDelegate old) =>
      old.height != height || !identical(old.child, child);
}

class _FieldData {
  const _FieldData(this.label, this.value);
  final String label;
  final String value;
}

/// 顶部圆形按钮：半透明渐变 + 高光描边（与影片详情页 _RoundBtn 同款液态玻璃）
class _RoundBtn extends StatelessWidget {
  const _RoundBtn({
    required this.icon,
    this.onTap,
    this.semanticLabel,
    this.iconColor,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final btn = LiquidPress(
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
        // 真磨砂玻璃：与详情页/首页顶栏圆钮统一
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
                colors: [
                  Colors.white.withOpacity(0.20),
                  Colors.white.withOpacity(0.06),
                ],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.24)),
            ),
            child: Icon(icon, size: 17, color: iconColor ?? Colors.white),
          ),
        ),
      ),
    );
    if (semanticLabel == null) return btn;
    return Semantics(button: true, label: semanticLabel, child: btn);
  }
}

/// 演员作品「排序与筛选」分段控件（与媒体库版式一致）。
class _Seg extends StatelessWidget {
  const _Seg({
    required this.options,
    required this.index,
    required this.onChanged,
  });

  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final n = options.length;
    final i = index.clamp(0, n - 1);
    final unit = 1.0 / n;
    // 槽内有 3dp 内边距：滑块宽度要按去掉边距后的宽度算
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            // 滑块宽 1/n、alignment ∈ [-1,1]：第 k 段的中点对齐用
            // -1 + 2k/(n-1)。之前误乘 (1-unit)，三档时「电影」的高亮块
            // 偏在左半边、与文字错位。
            alignment: Alignment(n <= 1 ? 0 : -1 + 2.0 * i / (n - 1), 0),
            child: FractionallySizedBox(
              widthFactor: unit,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: const LinearGradient(
                    colors: [Color(0x384F8CFF), Color(0x247B5CFF)],
                  ),
                  border: Border.all(
                    color: AppColors.primary.withOpacity(0.55),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (var k = 0; k < n; k++)
                Expanded(
                  child: Semantics(
                    selected: k == i,
                    button: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => onChanged(k),
                      child: Center(
                        child: Text(
                          options[k],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: k == i
                                ? FontWeight.w800
                                : FontWeight.w600,
                            // 未选中也要看得清：白色 90%（原来是 muted，偏暗）
                            color: k == i
                                ? Colors.white
                                : Colors.white.withOpacity(0.90),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverviewText extends StatelessWidget {
  const _OverviewText({
    required this.text,
    required this.expanded,
    required this.onToggle,
  });
  final String text;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: Text.rich(
        TextSpan(
          text: expanded
              ? text
              : (text.length > 90 ? '${text.substring(0, 90)}…' : text),
          style: const TextStyle(
            fontSize: 12.5,
            height: 1.6,
            color: Color(0xFFC3D3EE),
          ),
          children: [
            if (text.length > 90)
              TextSpan(
                text: expanded ? ' 收起' : ' 更多',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
