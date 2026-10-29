import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../emby_client.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/cached_image.dart';
import '../widgets/liquid_press.dart';
import '../widgets/media_poster.dart';
import 'person_page.dart';

/// 搜索页：本地联想（片名 / 演员 / 标签）+ 热门关键词 + 热播榜 + 结果网格
///
/// 背景不再用纯黑/纯底色：取「当前结果第一条（无结果取热播榜首）」的海报
/// 做静态预模糊（ImageFiltered，不是 BackdropFilter，不逐帧重算）+ 深色遮罩，
/// 搜索时整页有画面感，同时不影响滚动性能。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.state,
    required this.onOpenDetail,
  });

  final AppState state;
  final OpenDetail onOpenDetail;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// 演员命中：跨影片聚合，带作品数
class _ActorHit {
  const _ActorHit(this.person, this.works);
  final CastMember person;
  final int works;
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _ctl = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _q = '';
  int _mode = 0; // 0=影片 1=演员
  List<MediaItem> _results = const [];
  List<_ActorHit> _actors = const [];
  Timer? _debounce;

  late final List<String> _hotTags;
  late final List<String> _hotCast;
  late final List<MediaItem> _hotPlayed;

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
    _computeHot();
    _hotPlayed =
        (List<MediaItem>.from(widget.state.items)
              ..sort((a, b) => b.userPlayCount.compareTo(a.userPlayCount)))
            .take(8)
            .toList();
  }

  void _computeHot() {
    final tagCount = <String, int>{};
    final castCount = <String, int>{};
    for (final e in widget.state.items) {
      for (final t in e.tags) {
        tagCount[t] = (tagCount[t] ?? 0) + 1;
      }
      for (final p in e.people) {
        castCount[p.name] = (castCount[p.name] ?? 0) + 1;
      }
    }
    final tags = tagCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final cast = castCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    _hotTags = tags.take(12).map((e) => e.key).toList();
    _hotCast = cast.take(10).map((e) => e.key).toList();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      final q = v.trim().toLowerCase();
      if (q.isEmpty) {
        if (mounted) {
          setState(() {
            _results = const [];
            _actors = const [];
          });
        }
        return;
      }
      _runSearch(q);
    });
  }

  /// 一次遍历同时算出「影片命中」与「演员命中」，两栏切换不用重算
  void _runSearch(String q) {
    final items = widget.state.items;
    final matched = <MediaItem>[];
    final castCount = <String, int>{};
    final castFirst = <String, CastMember>{};

    for (final e in items) {
      final hit =
          e.name.toLowerCase().contains(q) ||
          e.genres.any((g) => g.toLowerCase().contains(q)) ||
          e.tags.any((t) => t.toLowerCase().contains(q)) ||
          e.people.any((p) => p.name.toLowerCase().contains(q)) ||
          e.year.toString() == q;
      if (hit) matched.add(e);

      for (final p in e.people) {
        if (p.name.toLowerCase().contains(q)) {
          castCount[p.name] = (castCount[p.name] ?? 0) + 1;
          castFirst.putIfAbsent(p.name, () => p);
        }
      }
    }

    // 排序：片名/人名以关键词开头优先，其次按播放次数
    matched.sort((a, b) {
      final aName = a.name.toLowerCase().startsWith(q) ? 0 : 1;
      final bName = b.name.toLowerCase().startsWith(q) ? 0 : 1;
      if (aName != bName) return aName.compareTo(bName);
      return b.userPlayCount.compareTo(a.userPlayCount);
    });

    final actors = castCount.entries.toList()
      ..sort((a, b) {
        final aName = a.key.toLowerCase().startsWith(q) ? 0 : 1;
        final bName = b.key.toLowerCase().startsWith(q) ? 0 : 1;
        if (aName != bName) return aName.compareTo(bName);
        return b.value.compareTo(a.value);
      });

    if (!mounted) return;
    setState(() {
      _results = matched;
      _actors = actors
          .map((e) => _ActorHit(castFirst[e.key]!, e.value))
          .toList();
    });
  }

  void _submit(String v) {
    _debounce?.cancel();
    final q = v.trim().toLowerCase();
    if (q.isEmpty) return;
    // 点击联想词时不会触发 TextField.onChanged，这里必须同步 _q，
    // 否则界面仍停留在热播榜，看不到搜索结果。
    setState(() => _q = q);
    _runSearch(q);
  }

  /// 结果点击：详情压在搜索页之上（返回后仍在结果里）。
  /// 以前这里多了一句 maybePop，会把刚 push 的详情页立刻弹掉，表现就是「点了没反应」。
  void _open(MediaItem item, {String? heroTag}) {
    widget.onOpenDetail(item, heroTag: heroTag);
  }

  /// 演员页用淡入路由，和详情页一致（不用 Material 缩放转场）
  void _openActor(_ActorHit hit) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, __, ___) => PersonPage(
          person: hit.person,
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _suggestion(String text, {IconData? icon}) => LiquidPress(
    radius: 999,
    scale: 0.96,
    onTap: () {
      _ctl.text = text;
      _submit(text);
      _focus.unfocus();
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: AppColors.muted),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: const TextStyle(fontSize: 12, color: Color(0xFFDCE6F5)),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 背景：结果第一条（无结果取热播榜首）的海报预模糊
  Widget _backdrop() {
    final seed = _results.isNotEmpty
        ? _results.first
        : (_hotPlayed.isNotEmpty
              ? _hotPlayed.first
              : (widget.state.items.isNotEmpty ? widget.state.items.first : null));
    final url = seed?.posterUrl ?? seed?.backdropUrl;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, if (current != null) current],
      ),
      child: KeyedSubtree(
        key: ValueKey('search-bg-${url ?? 'none'}'),
        child: url == null
            ? const ColoredBox(color: AppColors.bg)
            : ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
                child: SizedBox.expand(
                  child: CachedImage(url: url, memWidth: 260),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showTabs = _q.isNotEmpty;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          Positioned.fill(child: _backdrop()),
          // 遮罩：保证文字/海报在模糊背景上依然清晰（顶部略浅，底部加深）
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.52),
                    Colors.black.withOpacity(0.66),
                    Colors.black.withOpacity(0.80),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 44,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.16),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.search_rounded,
                                size: 18,
                                color: AppColors.muted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _ctl,
                                  focusNode: _focus,
                                  onChanged: (v) {
                                    setState(() => _q = v);
                                    _onChanged(v);
                                  },
                                  onSubmitted: _submit,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: AppColors.ink,
                                  ),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    hintText: '搜索片名 / 演员 / 标签',
                                    hintStyle: TextStyle(
                                      fontSize: 14,
                                      color: AppColors.muted,
                                    ),
                                  ),
                                ),
                              ),
                              if (_q.isNotEmpty)
                                LiquidPress(
                                  radius: 10,
                                  semanticLabel: '清空',
                                  onTap: () {
                                    _ctl.clear();
                                    setState(() {
                                      _q = '';
                                      _results = const [];
                                      _actors = const [];
                                    });
                                  },
                                  child: const Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: AppColors.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      LiquidPress(
                        onTap: () => Navigator.of(context).pop(),
                        radius: 8,
                        scale: 0.94,
                        child: const Text(
                          '取消',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 分类：影片 / 演员
                if (showTabs)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: _ModeTabs(
                      mode: _mode,
                      filmCount: _results.length,
                      actorCount: _actors.length,
                      onChanged: (m) => setState(() => _mode = m),
                    ),
                  ),
                Expanded(child: _body()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_q.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (_hotTags.isNotEmpty) ...[
            const _BlockTitle('热门标签'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _hotTags.map((t) => _suggestion(t)).toList(),
            ),
            const SizedBox(height: 18),
          ],
          if (_hotCast.isNotEmpty) ...[
            const _BlockTitle('常看演员'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _hotCast
                  .map((c) => _suggestion(c, icon: Icons.person_rounded))
                  .toList(),
            ),
            const SizedBox(height: 18),
          ],
          const _BlockTitle('热播榜'),
          ..._hotPlayed.asMap().entries.map(
            (e) => _HotRow(
              rank: e.key + 1,
              item: e.value,
              onTap: () => _open(e.value),
            ),
          ),
        ],
      );
    }
    if (_mode == 1) {
      if (_actors.isEmpty) {
        return Center(
          child: Text(
            '没有找到匹配「$_q」的演员',
            style: const TextStyle(color: AppColors.muted, fontSize: 13),
          ),
        );
      }
      return _ActorGrid(
        actors: _actors,
        server: widget.state.server,
        onTap: _openActor,
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          '没有匹配「$_q」的影片',
          style: const TextStyle(color: AppColors.muted, fontSize: 13),
        ),
      );
    }
    return _ResultGrid(results: _results, onOpenDetail: _open);
  }
}

/// 影片 / 演员 分段切换
class _ModeTabs extends StatelessWidget {
  const _ModeTabs({
    required this.mode,
    required this.filmCount,
    required this.actorCount,
    required this.onChanged,
  });

  final int mode;
  final int filmCount;
  final int actorCount;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Row(
        children: [
          _seg(0, '影片', filmCount),
          _seg(1, '演员', actorCount),
        ],
      ),
    );
  }

  Widget _seg(int i, String label, int count) {
    final sel = mode == i;
    return Expanded(
      child: LiquidPress(
        onTap: () => onChanged(i),
        radius: 9,
        scale: 0.97,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            gradient: sel
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.26),
                      Colors.white.withOpacity(0.12),
                    ],
                  )
                : null,
          ),
          child: Center(
            child: Text(
              count > 0 ? '$label · $count' : label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                color: sel ? Colors.white : const Color(0xFFAFC0D8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockTitle extends StatelessWidget {
  const _BlockTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w800,
        color: Color(0xFFD3DDF7),
      ),
    ),
  );
}

class _HotRow extends StatelessWidget {
  const _HotRow({required this.rank, required this.item, required this.onTap});
  final int rank;
  final MediaItem item;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LiquidPress(
    onTap: onTap,
    radius: 10,
    scale: 0.98,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$rank',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: rank <= 3 ? AppColors.primary : AppColors.muted,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE2EAF8),
              ),
            ),
          ),
          if (item.userPlayCount > 0)
            Text(
              '${item.userPlayCount} 次',
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
        ],
      ),
    ),
  );
}

class _ResultGrid extends StatelessWidget {
  const _ResultGrid({required this.results, required this.onOpenDetail});
  final List<MediaItem> results;
  final OpenDetail onOpenDetail;
  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 11,
            mainAxisSpacing: 16,
            childAspectRatio: 0.55,
          ),
          itemCount: results.length,
          itemBuilder: (c, i) => PosterCard(
            item: results[i],
            width: double.infinity,
            heroTag: 'search-${results[i].id}',
            onTap: () =>
                onOpenDetail(results[i], heroTag: 'search-${results[i].id}'),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ],
  );
}

/// 演员结果：圆头像 + 姓名 + 作品数
class _ActorGrid extends StatelessWidget {
  const _ActorGrid({
    required this.actors,
    required this.server,
    required this.onTap,
  });
  final List<_ActorHit> actors;
  final EmbyServer? server;
  final ValueChanged<_ActorHit> onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 11,
        mainAxisSpacing: 16,
        childAspectRatio: 0.78,
      ),
      itemCount: actors.length,
      itemBuilder: (c, i) {
        final hit = actors[i];
        final p = hit.person;
        final pid = p.id;
        final s = server;
        final url = (s != null && pid != null)
            ? s.personImageUrl(pid, p.imageTag)
            : null;
        return LiquidPress(
          onTap: () => onTap(hit),
          radius: 14,
          child: Column(
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.08),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.16),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: url == null
                        ? Center(
                            child: Text(
                              p.name.isEmpty ? '?' : p.name.substring(0, 1),
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFD3DDF7),
                              ),
                            ),
                          )
                        : CachedImage(url: url, memWidth: 200),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE2EAF8),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${hit.works} 部作品',
                style: const TextStyle(fontSize: 10, color: AppColors.muted),
              ),
            ],
          ),
        );
      },
    );
  }
}
