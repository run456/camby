import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../widgets/glass_toast.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/media_poster.dart';

/// 演职员详情页（对齐影片详情的观感）：
/// 全屏模糊背景 + 顶部清晰头像渐隐 → 姓名 → 简介（可展开）
/// → 全部/电影/剧集 选项 → 排序与筛选抽屉（与媒体库同款）→ 作品网格
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
  String? _error;
  int _tab = 0; // 0 全部 1 电影 2 剧集
  bool _expanded = false;
  bool _fav = false;
  bool _favBusy = false;

  /// 排序（与媒体库同一套交互）：0 发行日期 / 1 评分 / 2 标题
  int _sortKey = 0;
  bool _desc = true;
  /// 年代筛选：0 不限 / 1 近 3 年 / 2 近 10 年 / 3 更早
  int _decade = 0;

  @override
  void initState() {
    super.initState();
    // 先用本地缓存的收藏状态，避免离线时 ♥ 状态丢失
    _fav = widget.state.isPersonFavorite(widget.person.id);
    _load();
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
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString();
          _loading = false;
        });
    }
  }

  String? get _birth {
    final iso = _info?['PremiereDate'] as String?;
    final d = iso == null ? null : DateTime.tryParse(iso);
    return d == null
        ? null
        : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  static const _decadeNames = ['不限', '近 3 年', '近 10 年', '更早'];
  static const _sortNames = ['发行日期', '评分', '标题'];

  /// 抽屉里「共 N 部」：按草稿年代档位实时算，不依赖已应用的筛选
  int _countFor(List<MediaItem> all, int decade) {
    final now = DateTime.now().year;
    final byTab = switch (_tab) {
      1 => all.where((e) => e.isMovie),
      2 => all.where((e) => e.isSeries),
      _ => all.where((_) => true),
    };
    return byTab.where((e) {
      final y = e.year;
      if (y <= 0) return true;
      return switch (decade) {
        1 => now - y <= 3,
        2 => now - y <= 10,
        3 => now - y > 10,
        _ => true,
      };
    }).length;
  }

  /// 当前筛选的简短摘要（显示在筛选按钮上）
  String _filterSummary() {
    final parts = <String>[
      if (_decade != 0) _decadeNames[_decade],
      '${_sortNames[_sortKey]}${_desc ? '↓' : '↑'}',
    ];
    return parts.isEmpty ? '筛选' : parts.join('·');
  }

  String get _overview => (_info?['Overview'] as String?) ?? '';

  List<MediaItem> get _filtered {
    final all = _films ?? [];
    final now = DateTime.now().year;
    final byTab = switch (_tab) {
      1 => all.where((e) => e.isMovie).toList(),
      2 => all.where((e) => e.isSeries).toList(),
      _ => List<MediaItem>.of(all),
    };
    final byDecade = byTab.where((e) {
      final y = e.year;
      if (y <= 0) return true; // 没有年份信息不过滤
      return switch (_decade) {
        1 => now - y <= 3,
        2 => now - y <= 10,
        3 => now - y > 10,
        _ => true,
      };
    }).toList();
    int cmp(MediaItem a, MediaItem b) => switch (_sortKey) {
          1 => a.rating.compareTo(b.rating),
          2 => a.name.compareTo(b.name),
          _ => a.year.compareTo(b.year),
        };
    byDecade.sort(_desc ? (a, b) => cmp(b, a) : cmp);
    return byDecade;
  }

  /// 排序与筛选抽屉：与媒体库同一套版式（排序字段行 × 升/降 + 条件chips
  /// + 底部 重置 / 应用筛选）。
  Future<void> _showFilterSheet() async {
    final result = await showModalBottomSheet<(int, bool, int)>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _PersonFilterSheet(
        sortKey: _sortKey,
        desc: _desc,
        decade: _decade,
        total: _countFor(_films ?? const [], _decade),
      ),
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
    final p = widget.person;
    final server = widget.state.server;
    final imgUrl = (server != null && p.id != null)
        ? server.personImageUrl(p.id!, p.imageTag)
        : null;
    final films = _filtered;
    final topPad = MediaQuery.of(context).padding.top;
    final wide = MediaQuery.of(context).size.width >= 840;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // 整页底色：同一张头像模糊 + 深色遮罩（与影片详情一致）
          // RepaintBoundary 让这层只栅格化一次，滚动期间走缓存纹理
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
          // 独立图层：滚动只重绘列表，背后全屏模糊不再每帧重算
          RepaintBoundary(
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                // 顶部清晰头像，底部渐隐透出模糊主色调
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 340,
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.white, Colors.white, Colors.transparent],
                        stops: [0.0, 0.72, 1.0],
                      ).createShader(rect),
                      child: imgUrl != null
                          ? CachedImage(
                              url: imgUrl,
                              alignment: Alignment.topCenter,
                              memWidth: 900,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      // 姓名 + 出生日期
                      Center(
                        child: Column(
                          children: [
                            Text(
                              p.name,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            if (_birth != null) ...[
                              const SizedBox(height: 5),
                              Text(
                                _birth!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.muted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (_overview.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: _OverviewText(
                            text: _overview,
                            expanded: _expanded,
                            onToggle: () =>
                                setState(() => _expanded = !_expanded),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      // 筛选选项（分段控件）：全部 / 电影 / 剧集 + 筛选入口
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Row(
                          children: [
                            Expanded(
                              child: _Seg(
                                options: const ['全部', '电影', '剧集'],
                                index: _tab,
                                onChanged: (i) => setState(() => _tab = i),
                              ),
                            ),
                            const SizedBox(width: 10),
                            LiquidPress(
                              onTap: _showFilterSheet,
                              radius: 999,
                              scale: 0.94,
                              semanticLabel: '作品排序与筛选',
                              child: Container(
                                height: 34,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 11),
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
                                      _filterSummary(),
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
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 作品网格：Sliver 懒加载，滚动手感与详情页一致
                // （之前 shrinkWrap GridView 一次性构建全部条目，卡片一多
                //   滚动就发坠）
                const SliverToBoxAdapter(child: SizedBox(height: 14)),
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      child: Text(
                        _error != null ? '加载失败：$_error' : '该分类下暂无作品',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(wide ? 28 : 18, 0, wide ? 28 : 18, 40),
                    sliver: SliverGrid(
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: wide ? 6 : 3,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 16,
                        childAspectRatio: 0.52,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (c, i) => PosterCard(
                          item: films[i],
                          width: double.infinity,
                          heroTag: 'person-${widget.person.id}-${films[i].id}',
                          onTap: () => widget.onOpenDetail(
                            films[i],
                            heroTag:
                                'person-${widget.person.id}-${films[i].id}',
                          ),
                        ),
                        childCount: films.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 顶栏（最上层，保证可点）
          _buildTopBar(context, topPad),
        ],
      ),
    );
  }

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
    );
  }
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
      shadows: const [
        BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
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
        child: Icon(icon, size: 17, color: iconColor ?? Colors.white),
      ),
    );
    if (semanticLabel == null) return btn;
    return Semantics(button: true, label: semanticLabel, child: btn);
  }
}

/// 演员作品「排序与筛选」抽屉：版式与媒体库筛选一致。
/// 草稿态在内部编辑，点「应用筛选」才提交，返回 (sortKey, desc, decade)。
class _PersonFilterSheet extends StatefulWidget {
  const _PersonFilterSheet({
    required this.sortKey,
    required this.desc,
    required this.decade,
    required this.total,
  });

  final int sortKey;
  final bool desc;
  final int decade;
  final int total;

  @override
  State<_PersonFilterSheet> createState() => _PersonFilterSheetState();
}

class _PersonFilterSheetState extends State<_PersonFilterSheet> {
  static const _sortNames = ['发行日期', '评分', '标题'];
  static const _decadeNames = ['不限', '近 3 年', '近 10 年', '更早'];

  late int _sortKey;
  late bool _desc;
  late int _decade;

  @override
  void initState() {
    super.initState();
    _sortKey = widget.sortKey;
    _desc = widget.desc;
    _decade = widget.decade;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF171C27), Color(0xFF10141D)],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 9),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: Colors.white.withOpacity(0.22),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: Row(
                children: [
                  const Text(
                    '排序与筛选',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${widget.total} 项 · 已选 ${_decade == 0 ? 0 : 1} 个条件',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                shrinkWrap: true,
                children: [
                  _sectionTitle('排序方式', '点字段切换，右侧选升 / 降'),
                  ...List.generate(_sortNames.length, (i) {
                    final on = _sortKey == i;
                    return _SortRow(
                      name: _sortNames[i],
                      active: on,
                      desc: _desc,
                      onSelect: () => setState(() => _sortKey = i),
                      onDir: (v) => setState(() {
                        _desc = v;
                        _sortKey = i;
                      }),
                    );
                  }),
                  _sectionTitle('年代', '单选'),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (var i = 0; i < _decadeNames.length; i++)
                        _chip(
                          _decadeNames[i],
                          on: _decade == i,
                          onTap: () => setState(() => _decade = i),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
            // 底部操作栏：重置 + 应用筛选
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Row(
                children: [
                  LiquidPress(
                    onTap: () => setState(() {
                      _decade = 0;
                      _sortKey = 0;
                      _desc = true;
                    }),
                    radius: 14,
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.22),
                        ),
                      ),
                      child: const Center(
                        child: Text(
                          '重置',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LiquidPress(
                      onTap: () =>
                          Navigator.pop(context, (_sortKey, _desc, _decade)),
                      radius: 14,
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF2F7FE8), Color(0xFF4F9CFF)],
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x592F7FE8),
                              blurRadius: 18,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Text(
                            '应用筛选',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
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
      ),
    );
  }

  Widget _sectionTitle(String title, String? hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              color: AppColors.muted,
            ),
          ),
          const Spacer(),
          if (hint != null)
            Text(
              hint,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: AppColors.muted.withOpacity(0.7),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, {required bool on, required VoidCallback onTap}) {
    return LiquidPress(
      onTap: onTap,
      radius: 15,
      scale: 0.95,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: on
              ? const Color(0x334F8CFF)
              : Colors.white.withOpacity(0.06),
          border: Border.all(
            color: on
                ? const Color(0x874F8CFF)
                : Colors.white.withOpacity(0.10),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: on ? const Color(0xFFCFE0FF) : AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// 排序字段行：字段名 + 升/降分段（与媒体库同款）
class _SortRow extends StatelessWidget {
  const _SortRow({
    required this.name,
    required this.active,
    required this.desc,
    required this.onSelect,
    required this.onDir,
  });

  final String name;
  final bool active;
  final bool desc;
  final VoidCallback onSelect;
  final ValueChanged<bool> onDir;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: LiquidPress(
        onTap: onSelect,
        radius: 13,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: active
                ? const Color(0x334F8CFF)
                : Colors.white.withOpacity(0.04),
            border: Border.all(
              color: active
                  ? const Color(0x874F8CFF)
                  : Colors.white.withOpacity(0.10),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w700,
                    color: active ? Colors.white : const Color(0xFFD5DEEF),
                  ),
                ),
              ),
              _dirSeg(!desc, '↑ 升', () => onDir(false)),
              const SizedBox(width: 3),
              _dirSeg(desc, '↓ 降', () => onDir(true)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dirSeg(bool on, String label, VoidCallback onTap) {
    return LiquidPress(
      onTap: onTap,
      radius: 7,
      scale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: on
              ? const Color(0x594F8CFF)
              : Colors.black.withOpacity(0.30),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: on ? const Color(0xFFCFE0FF) : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

/// 简介文本：默认截断，点「更多」展开 / 收起
/// 分段控件（1.7.38）：把原来三个独立胶囊合成一体，
/// 选中态是一整块背景在槽内滑动，不再出现「两颗胶囊之间有一条缝」的观感。
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
                  border: Border.all(color: AppColors.primary.withOpacity(0.55)),
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
                            fontWeight: k == i ? FontWeight.w800 : FontWeight.w600,
                            color: k == i ? Colors.white : AppColors.muted,
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
