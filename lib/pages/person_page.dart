import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../widgets/glass_toast.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/media_poster.dart';

/// 演职员详情页（参考 Emby 原生）：
/// 全屏头像背景 → 姓名 → 出生日期 → 简介（可展开）→ 全部/电影/剧集 筛选 → 作品网格
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

  String get _overview => (_info?['Overview'] as String?) ?? '';

  List<MediaItem> get _filtered {
    final all = _films ?? [];
    switch (_tab) {
      case 1:
        return all.where((e) => e.isMovie).toList();
      case 2:
        return all.where((e) => e.isSeries).toList();
      default:
        return all;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final server = widget.state.server;
    final imgUrl = (server != null && p.id != null)
        ? server.personImageUrl(p.id!, p.imageTag)
        : null;
    final films = _filtered;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // 全屏头像背景
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 400,
            child: imgUrl != null
                ? CachedImage(
                    url: imgUrl,
                    alignment: Alignment.topCenter,
                    memWidth: 600,
                  )
                : const SizedBox.shrink(),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 400,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.30),
                    Colors.transparent,
                    AppColors.bg.withOpacity(0.92),
                    AppColors.bg,
                  ],
                  stops: const [0.0, 0.30, 0.78, 1.0],
                ),
              ),
            ),
          ),
          // 顶栏放在 ListView 之后（Stack 最上层）：
          // 否则 ListView 会优先命中测试，把顶栏区域的点击全部吃掉
          ListView(
            padding: EdgeInsets.zero,
            children: [
              const SizedBox(height: 318),
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
                    onToggle: () => setState(() => _expanded = !_expanded),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // 筛选 tab：全部 / 电影 / 剧集
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    _FilmTab(
                      label: '全部',
                      selected: _tab == 0,
                      onTap: () => setState(() => _tab = 0),
                    ),
                    const SizedBox(width: 10),
                    _FilmTab(
                      label: '电影',
                      selected: _tab == 1,
                      onTap: () => setState(() => _tab = 1),
                    ),
                    const SizedBox(width: 10),
                    _FilmTab(
                      label: '剧集',
                      selected: _tab == 2,
                      onTap: () => setState(() => _tab = 2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _buildWorks(context, films),
              const SizedBox(height: 40),
            ],
          ),
          // 顶栏（最上层，保证可点）
          _buildTopBar(context),
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

  Widget _buildTopBar(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: Row(
            children: [
              // 深色遮罩上用深底圆钮保证可点可见
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.35),
                ),
                child: LiquidPress(
                  radius: 20,
                  semanticLabel: '返回',
                  onTap: () => Navigator.pop(context),
                  child: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 17,
                    color: Colors.white,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.35),
                ),
                child: LiquidPress(
                  radius: 20,
                  semanticLabel: _fav ? '取消收藏' : '收藏演员',
                  onTap: _toggleFav,
                  child: Icon(
                    _fav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 18,
                    color: _fav ? const Color(0xFFFF5C7A) : Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWorks(BuildContext context, List<MediaItem> films) {
    if (_loading) {
      return const Padding(
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
      );
    }
    if (films.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Text(
          _error != null ? '加载失败：$_error' : '该分类下暂无作品',
          style: const TextStyle(fontSize: 12, color: AppColors.muted),
        ),
      );
    }
    final wide = MediaQuery.of(context).size.width >= 840;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: wide ? 28 : 18),
      child: GridView.builder(
        shrinkWrap: true,
        // 关键：嵌套 GridView 默认会吃掉 MediaQuery.padding.top，造成巨大空白
        padding: EdgeInsets.zero,
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: wide ? 6 : 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 16,
          childAspectRatio: 0.52,
        ),
        itemCount: films.length,
        itemBuilder: (c, i) => PosterCard(
          item: films[i],
          width: double.infinity,
          heroTag: 'person-${widget.person.id}-${films[i].id}',
          onTap: () => widget.onOpenDetail(
            films[i],
            heroTag: 'person-${widget.person.id}-${films[i].id}',
          ),
        ),
      ),
    );
  }
}

/// 简介文本：默认截断，点「更多」展开 / 收起
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

class _FilmTab extends StatelessWidget {
  const _FilmTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 999,
      scale: 0.95,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected
              ? AppColors.primary.withOpacity(0.16)
              : Colors.white.withOpacity(0.05),
          border: Border.all(
            color: selected
                ? AppColors.primary.withOpacity(0.55)
                : Colors.white.withOpacity(0.10),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? AppColors.ink : AppColors.muted,
          ),
        ),
      ),
    );
  }
}
