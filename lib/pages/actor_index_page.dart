import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../layout.dart';
import '../models.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/library_index_segment.dart';
import '../widgets/liquid_press.dart';
import 'person_page.dart';

/// 演员总览（v2.0.60 设计稿方案 A 的「演员」二级分段）。
///
/// 数据源是 [AppState.items] 里每部影片的 `people`（解析时已过滤为
/// Actor / GuestStar，导演单独抽走），按人物 id（无 id 按大写名字）去重并
/// 统计参演部数，纯客户端内存聚合，不打额外服务端请求。
///
/// 「女演员」规则：Emby 的 People **不返回性别**，[CastMember] 只有
/// name / role / id / imageTag。这里按用户确认的 A1 + A2 同时提供：
///   · 全部（A1，不过滤）
///   · 女演员（A2，`imageTag != null` 近似，女优基本有头像、男优常无）
///   · 已收藏
/// 三档可随时切换，不写死过滤。
class ActorIndexPage extends StatefulWidget {
  const ActorIndexPage({
    super.key,
    required this.state,
    required this.onOpenDetail,
    required this.tab,
    required this.onTabChanged,
  });

  final AppState state;
  final OpenDetail onOpenDetail;
  final LibraryIndexTab tab;
  final ValueChanged<LibraryIndexTab> onTabChanged;

  @override
  State<ActorIndexPage> createState() => _ActorIndexPageState();
}

class _ActorIndexPageState extends State<ActorIndexPage> {
  /// 0 全部（A1） / 1 女演员（A2） / 2 已收藏
  int _scope = 0;

  /// 0 参演最多（默认，用户确认「按推荐」） / 1 名字 A–Z / 2 最近参演
  int _sort = 0;
  String _query = '';
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final all = _aggregate(state);
    final entries = _apply(all, state);
    final favCount = all
        .where((e) => state.isPersonFavorite(e.id))
        .length;
    final wide = context.isTablet;
    final hPad = wide ? 24.0 : 16.0;
    final top = MediaQuery.of(context).padding.top;

    return Container(
      color: AppColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, top + 12, hPad, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.people_outline_rounded,
                        size: 20, color: AppColors.ink),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '演员',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          Text(
                            '共 ${all.length} 位 · 已收藏 $favCount 位',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                LibraryIndexSegment(
                  tab: widget.tab,
                  onChanged: widget.onTabChanged,
                ),
                const SizedBox(height: 9),
                _scopeSeg(),
                const SizedBox(height: 8),
                _searchBox(),
                const SizedBox(height: 8),
                _sortRow(),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              child: LayoutBuilder(
                builder: (context, cons) {
                  final cols = context.actorGridColumns;
                  const spacing = 10.0;
                  final cellW =
                      (cons.maxWidth - (cols - 1) * spacing) / cols;
                  final aspect = context.isPhone ? 0.72 : 0.82;
                  final cellH = cellW / aspect;
                  final cap = context.isPhone ? 78.0 : 104.0;
                  final avatar = math.min(
                    math.min(cellW * 0.9, cap),
                    cellH * 0.66,
                  );
                  if (entries.isEmpty) {
                    return _empty();
                  }
                  return RefreshIndicator(
                    color: AppColors.primary,
                    backgroundColor: const Color(0xF2121828),
                    onRefresh: () async {
                      await widget.state.refresh();
                    },
                    child: GridView.builder(
                      key: const ValueKey('actor-index-grid'),
                      padding: const EdgeInsets.only(bottom: 120),
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: 12,
                        childAspectRatio: aspect,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (c, i) => _tile(
                        entries[i],
                        avatar,
                        state.isPersonFavorite(entries[i].id),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 数据 ----------------

  List<_ActorEntry> _aggregate(AppState state) {
    final map = <String, _ActorEntry>{};
    for (final item in state.items) {
      final t = item.dateCreatedMs ?? 0;
      for (final p in item.people) {
        final name = p.name.trim();
        if (name.isEmpty) continue;
        final key = (p.id != null && p.id!.isNotEmpty)
            ? 'i:${p.id}'
            : 'n:${name.toUpperCase()}';
        final e = map.putIfAbsent(
          key,
          () => _ActorEntry(name: name, id: p.id, imageTag: p.imageTag),
        );
        e.count++;
        if (t > e.latest) e.latest = t;
      }
    }
    return map.values.toList();
  }

  List<_ActorEntry> _apply(List<_ActorEntry> all, AppState state) {
    final q = _query.trim().toUpperCase();
    final out = all.where((e) {
      if (_scope == 1 && !e.hasImage) return false;
      if (_scope == 2 && !state.isPersonFavorite(e.id)) return false;
      if (q.isNotEmpty && !e.name.toUpperCase().contains(q)) return false;
      return true;
    }).toList();
    out.sort((a, b) {
      switch (_sort) {
        case 1:
          return a.name.compareTo(b.name);
        case 2:
          final c = b.latest.compareTo(a.latest);
          return c != 0 ? c : a.name.compareTo(b.name);
        default:
          final c = b.count.compareTo(a.count);
          return c != 0 ? c : a.name.compareTo(b.name);
      }
    });
    return out;
  }

  // ---------------- 头部控件 ----------------

  Widget _scopeSeg() {
    const labels = ['全部', '女演员', '已收藏'];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.09)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: LiquidPress(
                radius: 999,
                scale: 0.96,
                onTap: () => setState(() => _scope = i),
                child: Container(
                  height: 30,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: _scope == i
                        ? Colors.white.withOpacity(0.16)
                        : Colors.transparent,
                  ),
                  child: Center(
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            _scope == i ? FontWeight.w800 : FontWeight.w600,
                        color: _scope == i
                            ? Colors.white
                            : Colors.white.withOpacity(0.55),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchBox() {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _controller,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 12, color: Colors.white),
        cursorColor: AppColors.primary,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          hintText: '搜索演员名字…',
          hintStyle:
              TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.35)),
          prefixIcon: Icon(Icons.search_rounded,
              size: 16, color: Colors.white.withOpacity(0.45)),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close_rounded,
                      size: 15, color: Colors.white.withOpacity(0.45)),
                  onPressed: () {
                    _controller.clear();
                    setState(() => _query = '');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide:
                BorderSide(color: AppColors.primary.withOpacity(0.55)),
          ),
        ),
      ),
    );
  }

  Widget _sortRow() {
    const labels = ['参演最多', '名字 A–Z', '最近参演'];
    // 只有 3 个固定档位：用 Row 而非 ListView.builder，不为几个 chip 建
    // sliver，也不把 setState 写进 itemBuilder（onTap 不随滚动执行）。
    return SizedBox(
      height: 28,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              LiquidPress(
                radius: 14,
                scale: 0.95,
                onTap: () => setState(() => _sort = i),
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: _sort == i
                        ? AppColors.primary.withOpacity(0.20)
                        : Colors.white.withOpacity(0.05),
                    border: Border.all(
                      color: _sort == i
                          ? AppColors.primary.withOpacity(0.5)
                          : Colors.white.withOpacity(0.10),
                    ),
                  ),
                  child: Center(
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight:
                            _sort == i ? FontWeight.w800 : FontWeight.w600,
                        color: _sort == i
                            ? Colors.white
                            : Colors.white.withOpacity(0.6),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    final msg = switch (_scope) {
      1 => '没有带头像的演员',
      2 => '还没有收藏演员',
      _ => '媒体库里还没有演员信息',
    };
    final hint = _query.isEmpty
        ? '换个筛选条件试试，或下拉刷新同步媒体库'
        : '没有匹配「$_query」的演员';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      children: [
        const SizedBox(height: 90),
        Icon(Icons.person_search_rounded,
            size: 40, color: AppColors.muted.withOpacity(0.5)),
        const SizedBox(height: 12),
        Center(
          child: Text(msg,
              style: const TextStyle(fontSize: 13, color: AppColors.muted)),
        ),
        const SizedBox(height: 5),
        Center(
          child: Text(hint,
              style: TextStyle(
                  fontSize: 11, color: AppColors.muted.withOpacity(0.8))),
        ),
      ],
    );
  }

  // ---------------- 卡片 ----------------

  Widget _tile(_ActorEntry e, double size, bool fav) {
    final server = widget.state.server;
    final url = (server != null && e.id != null && e.id!.isNotEmpty)
        ? server.personImageUrl(e.id!, e.imageTag)
        : null;
    return LiquidPress(
      radius: 12,
      scale: 0.97,
      glow: 0.18,
      onTap: () => _openPerson(e),
      child: Column(
        children: [
          Center(
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withOpacity(0.18)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x55000000),
                          blurRadius: 12,
                          offset: Offset(0, 5),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: url != null
                          ? CachedImage(
                              url: url,
                              memWidth: 200,
                              errorWidget: _fallback(e),
                            )
                          : _fallback(e),
                    ),
                  ),
                  if (fav)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.bg,
                          border: Border.all(
                              color: AppColors.danger.withOpacity(0.6)),
                        ),
                        child: const Icon(Icons.favorite_rounded,
                            size: 10, color: AppColors.danger),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            e.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          Text(
            '${e.count} 部',
            style: const TextStyle(fontSize: 9.5, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _fallback(_ActorEntry e) {
    const palettes = [
      [Color(0xFFC98F7A), Color(0xFF6D4356)],
      [Color(0xFF8F9FC9), Color(0xFF3C4A72)],
      [Color(0xFFD3A07F), Color(0xFF7A4F4A)],
      [Color(0xFF9B8FBF), Color(0xFF4B426E)],
      [Color(0xFF7FB0A8), Color(0xFF375A5C)],
    ];
    final p = palettes[e.name.hashCode.abs() % palettes.length];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: p,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        e.name.isEmpty ? '?' : e.name.substring(0, 1),
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: Colors.white70,
        ),
      ),
    );
  }

  void _openPerson(_ActorEntry e) {
    final person = CastMember(
      name: e.name,
      id: e.id,
      imageTag: e.imageTag,
    );
    Navigator.push(
      context,
      CambyRoutes.fade(
        builder: (_) => PersonPage(
          person: person,
          state: widget.state,
          onOpenDetail: (m, {String? heroTag}) {
            Navigator.pop(context);
            widget.onOpenDetail(m, heroTag: heroTag);
          },
        ),
      ),
    );
  }
}

class _ActorEntry {
  _ActorEntry({required this.name, this.id, this.imageTag});

  final String name;
  final String? id;
  final String? imageTag;
  int count = 0;
  int latest = 0;

  /// A2 规则：有头像近似判定为女演员。
  bool get hasImage => imageTag != null && imageTag!.isNotEmpty;
}
