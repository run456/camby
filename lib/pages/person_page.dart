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

  /// 作品附加筛选（1.7.38 新增）：年代 0 全部 / 1 近 3 年 / 2 近 10 年 / 3 更早
  int _decade = 0;
  /// 排序 0 上映时间 / 1 评分 / 2 名称
  int _sort = 0;

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

  /// 当前附加筛选的简短摘要（显示在筛选按钮上）
  String _filterSummary() {
    final d = switch (_decade) {
      1 => '近3年',
      2 => '近10年',
      3 => '更早',
      _ => null,
    };
    final s = switch (_sort) {
      1 => '评分',
      2 => '名称',
      _ => null,
    };
    final parts = <String>[
      if (d != null) d,
      if (s != null) s,
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
    // 排序：默认按上映时间倒序（参考 Emby 原生作品表）
    byDecade.sort((a, b) => switch (_sort) {
          1 => b.rating.compareTo(a.rating),
          2 => a.name.compareTo(b.name),
          _ => b.year.compareTo(a.year),
        });
    return byDecade;
  }

  /// 作品筛选抽屉：年代 + 排序。结果直接落到 _filtered。
  Future<void> _showFilterSheet() async {
    const decades = ['不限', '近 3 年', '近 10 年', '更早'];
    const sorts = ['上映时间', '评分', '名称'];
    var d = _decade;
    var s = _sort;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: const BoxDecoration(
            color: Color(0xF2141A28),
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: Colors.white.withOpacity(0.25),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 12, 18, 6),
                  child: Text(
                    '筛选作品',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 4, 18, 6),
                  child: Text(
                    '年代',
                    style: TextStyle(fontSize: 11, color: Color(0xFF9FB0CC)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: _Seg(
                    options: decades,
                    index: d,
                    onChanged: (i) => setSheet(() => d = i),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
                  child: Text(
                    '排序',
                    style: TextStyle(fontSize: 11, color: Color(0xFF9FB0CC)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: _Seg(
                    options: sorts,
                    index: s,
                    onChanged: (i) => setSheet(() => s = i),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: _SheetBtn(
                          label: '重置',
                          onTap: () => setSheet(() {
                            d = 0;
                            s = 0;
                          }),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SheetBtn(
                          label: '应用',
                          accent: true,
                          onTap: () {
                            setState(() {
                              _decade = d;
                              _sort = s;
                            });
                            Navigator.pop(ctx);
                          },
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
    );
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
              // 筛选 tab（分段控件）：全部 / 电影 / 剧集 + 附加筛选入口
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
                      semanticLabel: '作品筛选',
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: Colors.white.withOpacity(0.05),
                          border: Border.all(color: Colors.white.withOpacity(0.10)),
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
            // -1 为最左、1 为最右；滑块宽 1/n，要按剩余行程缩放到 ±(1-unit)
            alignment: Alignment(n <= 1 ? 0 : -1 + (2.0 * i / (n - 1)) * (1 - unit), 0),
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

/// 筛选抽屉里的按钮（重置 / 应用）
class _SheetBtn extends StatelessWidget {
  const _SheetBtn({required this.label, required this.onTap, this.accent = false});
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 14,
      scale: 0.97,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: accent
              ? const LinearGradient(
                  colors: [Color(0x664F8CFF), Color(0x667B5CFF)],
                )
              : null,
          color: accent ? null : Colors.white.withOpacity(0.06),
          border: Border.all(
            color: accent
                ? AppColors.primary.withOpacity(0.6)
                : Colors.white.withOpacity(0.12),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ),
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
