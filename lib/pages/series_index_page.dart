import 'package:flutter/material.dart';

import '../app_state.dart';
import '../layout.dart';
import '../metadata/boxset_series.dart';
import '../models.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/glass_toast.dart';
import '../widgets/cached_image.dart';
import '../widgets/library_index_segment.dart';
import '../widgets/liquid_press.dart';
import '../widgets/media_filter_sheet.dart';
import 'tag_page.dart';

/// 系列总览（v2.0.60 设计稿方案 A 的「系列」二级分段）。
///
/// 数据来源与媒体库「系列」筛选一致：[MediaFilter.seriesCountsOf] 统计全库
/// `seriesName`。点击某一行打开 [TagPage] 的 series 模式，用「系列名 / 标签 /
/// 类型 / 标题」去空白包含匹配列出同系列影片。
///
/// v2.0.63：系列名改由服务端「合集 / BoxSet」同步而来（[BoxSetSeriesSync]）。
/// 之前两版直读 .nfo 是走错路：Emby 把 `<set><name>` 建成了独立的 BoxSet
/// 对象，网页端影片详情的「所属合集」就是证据，服务端 API 直接可读，
/// 不需要影片文件路径、不需要 HTTP 直链。右上角「同步合集」主动扫全库
/// 并批量写回 seriesName；NFO 只留在详情页作最后的兜底。
class SeriesIndexPage extends StatefulWidget {
  const SeriesIndexPage({
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
  State<SeriesIndexPage> createState() => _SeriesIndexPageState();
}

class _SeriesIndexPageState extends State<SeriesIndexPage> {
  /// 0 部数最多 / 1 名字 A–Z
  int _sort = 0;
  String _query = '';
  final TextEditingController _controller = TextEditingController();

  // v2.0.63：主动从服务端「合集 / BoxSet」同步全库系列名。
  bool _scanning = false;
  int _scanDone = 0;
  int _scanTotal = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final counts = MediaFilter.seriesCountsOf(state.items);
    final covers = _covers(state.items);
    final all = counts.keys.toList();
    final q = _query.trim().toUpperCase();
    final names = all
        .where((s) => q.isEmpty || s.toUpperCase().contains(q))
        .toList()
      ..sort((a, b) {
        if (_sort == 1) return a.compareTo(b);
        final c = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
        return c != 0 ? c : a.compareTo(b);
      });
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
                    const Icon(Icons.collections_bookmark_outlined,
                        size: 20, color: AppColors.ink),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '系列',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          Text(
                            '共 ${all.length} 个系列 · ${state.items.length} 部影片',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _backfillButton(),
                  ],
                ),
                const SizedBox(height: 10),
                LibraryIndexSegment(
                  tab: widget.tab,
                  onChanged: widget.onTabChanged,
                ),
                const SizedBox(height: 9),
                _searchBox(),
                const SizedBox(height: 8),
                _sortRow(),
                if (_scanning) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _scanTotal > 0
                                ? (_scanDone / _scanTotal).clamp(0.0, 1.0)
                                : null,
                            minHeight: 4,
                            backgroundColor: Colors.white.withOpacity(0.10),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                AppColors.primary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$_scanDone / $_scanTotal',
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.muted),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              child: names.isEmpty ? _empty(q) : _list(names, counts, covers),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, MediaItem> _covers(Iterable<MediaItem> items) {
    final m = <String, MediaItem>{};
    for (final item in items) {
      final s = item.seriesName.trim();
      if (s.isEmpty) continue;
      m.putIfAbsent(s, () => item);
    }
    return m;
  }

  Widget _list(
    List<String> names,
    Map<String, int> counts,
    Map<String, MediaItem> covers,
  ) {
    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: const Color(0xF2121828),
      onRefresh: () async {
        await widget.state.refresh();
      },
      child: ListView.builder(
        key: const ValueKey('series-index-list'),
        padding: const EdgeInsets.only(bottom: 120),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        itemCount: names.length,
        itemBuilder: (c, i) {
          final name = names[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SeriesTile(
              name: name,
              count: counts[name] ?? 0,
              cover: covers[name],
              onTap: () => _openSeries(name),
            ),
          );
        },
      ),
    );
  }

  void _openSeries(String name) {
    Navigator.push(
      context,
      CambyRoutes.fade(
        builder: (_) => TagPage(
          tag: name,
          mode: TagPageMode.series,
          state: widget.state,
          onOpenDetail: widget.onOpenDetail,
        ),
      ),
    );
  }

  Widget _backfillButton() {
    return LiquidPress(
      radius: 12,
      onTap: _scanning ? null : () => _syncBoxSets(),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: AppColors.primary.withOpacity(_scanning ? 0.08 : 0.16),
          border: Border.all(color: AppColors.primary.withOpacity(0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _scanning
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.collections_bookmark_outlined,
                    size: 14, color: AppColors.primary),
            const SizedBox(width: 5),
            Text(
              _scanning ? '同步中' : '同步合集',
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 从服务端「合集 / BoxSet」同步全库系列名（v2.0.63）。
  Future<void> _syncBoxSets() async {
    if (_scanning) return;
    final server = widget.state.server;
    if (server == null) {
      showToast(context, '请先连接服务器', icon: Icons.wifi_off_rounded);
      return;
    }
    setState(() {
      _scanning = true;
      _scanDone = 0;
      _scanTotal = 0;
    });
    final r = await BoxSetSeriesSync.run(
      state: widget.state,
      server: server,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _scanDone = done;
          _scanTotal = total;
        });
      },
    );
    if (!mounted) return;
    setState(() => _scanning = false);
    await _showResult(r);
  }

  Future<void> _showResult(BoxSetSyncResult r) async {
    final lines = <String>[];
    if (r.failed) {
      lines.add(r.error ?? '读取合集失败。');
      lines.add('请确认服务器可访问，且账号有查看合集的权限。');
    } else if (r.targets == 0) {
      lines.add('全部影片都已有系列名，无需同步。');
    } else if (r.boxSets == 0) {
      lines.add('服务端没有返回任何合集（BoxSet）。');
      lines.add('请在服务端影片详情确认能看到「所属合集」区块。');
    } else {
      lines.add('服务端合集 ${r.boxSets} 个 · 待补 ${r.targets} 部 · '
          '成功写入 ${r.filled} 部。');
      if (r.noCollection > 0) lines.add('未关联合集 ${r.noCollection} 部');
      if (r.usedItemLookup) lines.add('已启用 ListItemIds 反查兜底。');
      if (r.cancelled) lines.add('（已中途取消）');
    }
    final notes = r.notes;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF171C29),
        title: const Text('同步服务端合集',
            style: TextStyle(fontSize: 15, color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(l,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white, height: 1.5)),
                ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('说明',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary)),
                const SizedBox(height: 5),
                for (final n in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('· $n',
                        style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white60,
                            height: 1.4)),
                  ),
              ],
              const SizedBox(height: 12),
              const Text(
                '「系列」现在取自服务端的「所属合集」（BoxSet），与 Emby 网页端'
                '影片详情页的「所属合集」一致。只有服务端没有合集数据时，'
                '详情页才会退回直读 NFO。',
                style: TextStyle(
                    fontSize: 10.5, color: Colors.white54, height: 1.5),
              ),
            ],
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
          hintText: '搜索系列名…',
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
    const labels = ['部数最多', '名字 A–Z'];
    // 只有 2 个固定档位：用 Row 而非 ListView.builder，不为几个 chip 建
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

  Widget _empty(String q) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      children: [
        const SizedBox(height: 90),
        Icon(Icons.collections_bookmark_outlined,
            size: 40, color: AppColors.muted.withOpacity(0.5)),
        const SizedBox(height: 12),
        Center(
          child: Text(
            q.isEmpty ? '还没有识别到系列' : '没有匹配「${_query.trim()}」的系列',
            style: const TextStyle(fontSize: 13, color: AppColors.muted),
          ),
        ),
        if (q.isEmpty) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '系列名取自服务端的「所属合集」（BoxSet）。'
              '点右上角「同步合集」可一次性扫描全库并回填。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.muted.withOpacity(0.8),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 单个系列行：小封面 + 系列名（不限行，完整显示）+ 部数 + 右箭头。
class _SeriesTile extends StatelessWidget {
  const _SeriesTile({
    required this.name,
    required this.count,
    required this.cover,
    required this.onTap,
  });

  final String name;
  final int count;
  final MediaItem? cover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final poster = cover?.posterUrlFor(300);
    return LiquidPress(
      radius: 13,
      scale: 0.985,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          color: Colors.white.withOpacity(0.045),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 46,
                height: 66,
                child: (poster != null && poster.isNotEmpty)
                    ? CachedImage(
                        url: poster,
                        memWidth: 300,
                        errorWidget: _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFFFA347),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$count 部影片',
                    style:
                        const TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: Icon(Icons.chevron_right_rounded,
                  size: 17, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3A2A1E), Color(0xFF161320)],
      ),
    ),
    alignment: Alignment.center,
    child: const Icon(Icons.movie_outlined, size: 20, color: Colors.white24),
  );
}
