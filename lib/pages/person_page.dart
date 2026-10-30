import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../widgets/glass_toast.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/media_filter_sheet.dart';
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

  /// 排序与筛选状态（与媒体库同一份实现：5 字段 × 升降 + 分辨率 + 字幕 + 标签）
  final MediaFilter _filter = MediaFilter(sort: 1);

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

  /// 先按「全部 / 电影 / 剧集」tab 过滤（筛选与排序在公共 [MediaFilter] 里做）
  Iterable<MediaItem> _byTab(List<MediaItem> all) => switch (_tab) {
    1 => all.where((e) => e.isMovie),
    2 => all.where((e) => e.isSeries),
    _ => all.where((_) => true),
  };

  String get _overview => (_info?['Overview'] as String?) ?? '';

  List<MediaItem> get _filtered => _filter.apply(_byTab(_films ?? const []));

  /// 排序与筛选抽屉：与媒体库完全同一套版式与能力
  Future<void> _showFilterSheet() async {
    final result = await showMediaFilterSheet(
      context,
      filter: _filter,
      source: _byTab(_films ?? const []),
    );
    if (result == null || !mounted) return;
    setState(() => _filter.applyResult(result));
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
                        colors: [
                          Colors.white,
                          Colors.white,
                          Colors.transparent,
                        ],
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
                            MediaFilterButton(
                              filter: _filter,
                              onTap: _showFilterSheet,
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
                    padding: EdgeInsets.fromLTRB(
                      wide ? 28 : 18,
                      0,
                      wide ? 28 : 18,
                      40,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
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

/// 演员作品「排序与筛选」抽屉：版式与媒体库筛选一致。
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
