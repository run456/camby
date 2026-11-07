import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../layout.dart';
import '../models.dart';
import '../widgets/liquid_press.dart';
import '../theme.dart';
import '../widgets/media_poster.dart';
import '../widgets/sort_chip_row.dart';

/// 聚合筛选页：列出全库中符合某个「键」的影片。
///
/// [TagPageMode.tag] 沿用原有标签 / 分辨率语义；v2.0.55 增加
/// [TagPageMode.director] / [TagPageMode.studio]，供详情页点导演、
/// 制造商胶囊时按该条目筛出同导演 / 同制造商的全部影片；
/// v2.0.58 增加 [TagPageMode.series]，供详情页点「系列」胶囊筛同系列影片。
///
/// 四种模式共用同一套 年份/标题/评分 排序胶囊与海报网格。
/// 数据源是 [AppState.items]（全库，已带 People / Studios 字段），
/// 因此是客户端过滤，不额外打服务端请求。
enum TagPageMode { tag, director, studio, series }

class TagPage extends StatefulWidget {
  const TagPage({
    super.key,
    required this.tag,
    this.mode = TagPageMode.tag,
    required this.state,
    required this.onOpenDetail,
  });

  /// 要匹配的值：标签名 / 分辨率 / 导演名 / 制造商名
  final String tag;
  final TagPageMode mode;
  final AppState state;
  final OpenDetail onOpenDetail;

  @override
  State<TagPage> createState() => _TagPageState();
}

class _TagPageState extends State<TagPage> {
  SortField _field = SortField.year;
  bool _asc = false; // 默认倒序（新年份在前）

  static final RegExp _res = RegExp(r'^(2160|1080|720|480|360)[pP]$');

  List<MediaItem> get _items {
    final tag = widget.tag;
    final key = tag.trim().toUpperCase();
    final isRes = _res.hasMatch(tag.trim());
    bool hit(String v) => v.trim().toUpperCase() == key;
    // v2.0.58 系列模式：系列名去掉所有空白（含全角空格 / 不换行空格）后转
    // 大写，做「包含」而不是精确相等。因为 NFO 里的系列名常带全角空格 / 换行，
    // 与其它影片标题或标签里的写法未必逐字一致；包含匹配能把
    // 「10番中出し、するまで…」这类同系列片捞全。
    final _ws = RegExp(r'[\s\u3000\u00A0]+');
    final seriesKey = key.replaceAll(_ws, '');
    bool seriesHit(String v) =>
        v.toUpperCase().replaceAll(_ws, '').contains(seriesKey);
    final list = widget.state.items.where((e) {
      switch (widget.mode) {
        case TagPageMode.director:
          return hit(e.director);
        case TagPageMode.studio:
          return hit(e.studio);
        case TagPageMode.series:
          if (seriesKey.isEmpty) return false;
          // 优先 seriesName，再退到标签 / 类型 / 标题（Emby 对 Movie 常不给
          // SeriesName，全库列表里该字段多为空，只靠它会筛出空白页）
          return seriesHit(e.seriesName) ||
              e.tags.any(seriesHit) ||
              e.genres.any(seriesHit) ||
              seriesHit(e.name);
        case TagPageMode.tag:
          if (isRes) {
            if (!e.resolutionKnown) return false;
            final r = e.isTrue4K ? '2160P' : '${e.videoHeight}P';
            return r == key;
          }
          // 标签/类型比较统一去空格 + 忽略大小写，避免 NFO 里多余空格查不到
          return e.tags.any(hit) || e.genres.any(hit);
      }
    }).toList();
    sortItemsBy(list, _field, _asc);
    return list;
  }

  String get _title => switch (widget.mode) {
    TagPageMode.tag => '#${widget.tag}',
    TagPageMode.director => '导演 · ${widget.tag}',
    TagPageMode.studio => '制造商 · ${widget.tag}',
    TagPageMode.series => '系列 · ${widget.tag}',
  };

  String get _heroPrefix => switch (widget.mode) {
    TagPageMode.tag => 'tag',
    TagPageMode.director => 'director',
    TagPageMode.studio => 'studio',
    TagPageMode.series => 'series',
  };

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(14, top + 8, 16, 8),
            child: Row(
              children: [
                LiquidPress(
                  onTap: () => Navigator.of(context).pop(),
                  radius: 19,
                  semanticLabel: '返回',
                  child: ClipOval(
                    // 真磨砂玻璃：与各页顶栏圆钮统一
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        width: 38,
                        height: 38,
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
                          border: Border.all(
                            color: Colors.white.withOpacity(0.24),
                          ),
                        ),
                        child: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${items.length} 部',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
          SortChipRow(
            field: _field,
            ascending: _asc,
            onChanged: (f, asc) => setState(() {
              _field = f;
              _asc = asc;
            }),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      '没有相关影片',
                      style: TextStyle(fontSize: 13, color: AppColors.muted),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      // 平板（≥840）：与媒体库一致 6 列
                      crossAxisCount: context.mediaGridColumns,
                      crossAxisSpacing: 11,
                      mainAxisSpacing: 16,
                      childAspectRatio: 0.53,
                    ),
                    itemCount: items.length,
                    itemBuilder: (c, i) => PosterCard(
                      item: items[i],
                      width: double.infinity,
                      heroTag: '${_heroPrefix}-${widget.tag}-${items[i].id}',
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.onOpenDetail(
                          items[i],
                          heroTag: '${_heroPrefix}-${widget.tag}-${items[i].id}',
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
