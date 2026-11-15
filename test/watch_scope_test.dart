import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:camby/ugreen_resource.dart';
import 'package:camby/watch_history.dart';
import 'package:camby/widgets/cached_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.102：用户反馈「观影数据还是没有做隔离，现在把两个媒体库的信息
/// 都显示了」。v2.0.99 只按服务器隔离，但活动日志 / 已看历史都是服务器级
/// 接口，一台服务器挂两个媒体库时照样全混在一起。这组测试锁住：
///  ① 事件带媒体库归属且能序列化；② 按范围过滤（含老事件现场反查）；
///  ③ 概览统计跟着范围走；④ 海报不再被降采样。
String src(String path) => File(path).readAsStringSync();

class _StubServer extends EmbyServer {
  _StubServer()
    : super(
        host: 'h',
        port: 8096,
        secure: false,
        username: 'u',
        password: 'p',
        kind: ServerKind.emby,
      );

  @override
  Future<List<MediaItem>> libraryItems(
    String viewId, {
    String sortBy = 'DateCreated',
  }) async => const <MediaItem>[];
}

MediaItem _movieIn(String id, String viewId) => MediaItem(
  id: id,
  name: '片 $id',
  type: MediaType.movie,
  overview: '',
  colors: const [Color(0xFF112233)],
  runtimeMin: 100,
  parentId: viewId,
);

WatchEvent _ev(
  String id,
  String lib, {
  double minutes = 10,
  String date = '2026-11-15',
}) => WatchEvent(
  itemId: id,
  name: '片 $id',
  date: date,
  minutes: minutes,
  source: WatchSource.local,
  serverId: 'srv-A',
  libraryId: lib,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppState.disablePersistence = true;
  });
  tearDown(() {
    AppState.disablePersistence = false;
  });

  group('媒体库归属 · 数据层', () {
    test('范围常量就是「全部影片」的哨兵值', () {
      expect(kWatchScopeAll, '__camby_scope_all__');
    });

    test('WatchEvent 的 libraryId 走 JSON 往返，老缓存缺字段降级为 null', () {
      final e = _ev('m1', 'lib-a');
      final back = WatchEvent.fromJson(e.toJson());
      expect(back.libraryId, 'lib-a');
      expect(back.serverId, 'srv-A');
      expect(back.minutes, 10);
      expect(e.toJson()['lid'], 'lib-a');

      final legacy = WatchEvent.fromJson(<String, dynamic>{
        'id': 'm2',
        'n': '老片',
        'd': '2026-11-15',
        'm': 3,
        'sid': 'srv-A',
      });
      expect(legacy.libraryId, isNull);
    });

    test('copyWith 能补上归属且不丢其它字段', () {
      final old = WatchEvent(
        itemId: 'm1',
        name: '片',
        date: '2026-11-15',
        minutes: 7,
        serverId: 'srv-A',
      );
      final next = old.copyWith(libraryId: 'lib-a', name: '新片名');
      expect(next.libraryId, 'lib-a');
      expect(next.name, '新片名');
      expect(next.minutes, 7);
      expect(next.serverId, 'srv-A');
      expect(old.libraryId, isNull);
    });

    test('历史回填种子把库归属带到事件里', () {
      final events = eventsFromHistory([
        HistorySeed(
          id: 'm1',
          name: '片',
          when: DateTime(2026, 11, 15),
          minutes: 100,
          serverId: 'srv-A',
          libraryId: 'lib-a',
        ),
      ], now: DateTime(2026, 11, 20));
      expect(events.single.libraryId, 'lib-a');
      expect(events.single.isEstimated, isTrue);
    });

    test('去重键刻意不含 libraryId，避免升级前后同一条记录去不掉重', () {
      final a = _ev('m1', 'lib-a');
      final b = _ev('m1', 'lib-b');
      expect(watchEventKey(a), watchEventKey(b));
    });
  });

  group('按媒体库范围过滤', () {
    test('scope 为 null 时全部放行', () {
      final events = [_ev('m1', 'lib-a'), _ev('m2', 'lib-b')];
      expect(filterWatchEventsForScope(events, null), hasLength(2));
    });

    test('指定库只留该库的事件，另一个库一条都不漏进来', () {
      final events = [
        _ev('m1', 'lib-a'),
        _ev('m2', 'lib-b'),
        _ev('m3', 'lib-a', date: '2026-11-16'),
      ];
      final out = filterWatchEventsForScope(events, 'lib-a');
      expect(out.map((e) => e.itemId), ['m1', 'm3']);
    });

    test('老事件没有 libraryId 时用 resolve 现场反查，升级不丢数据', () {
      final legacy = WatchEvent(
        itemId: 'm1',
        name: '老片',
        date: '2026-11-15',
        serverId: 'srv-A',
      );
      final events = [legacy, _ev('m2', 'lib-b')];
      final out = filterWatchEventsForScope(
        events,
        'lib-a',
        resolve: (id) => id == 'm1' ? 'lib-a' : null,
      );
      expect(out.single.itemId, 'm1');
    });

    test('反查不出归属的「库外影片」在指定库隐藏，全部范围仍可见', () {
      final orphan = WatchEvent(
        itemId: 'outside',
        name: '库外影片',
        date: '2026-11-15',
        serverId: 'srv-A',
      );
      expect(
        filterWatchEventsForScope([orphan], 'lib-a', resolve: (_) => null),
        isEmpty,
      );
      expect(filterWatchEventsForScope([orphan], null), hasLength(1));
    });
  });

  group('AppState 端到端 · 一台服务器两个媒体库', () {
    AppState buildState() {
      final s = AppState();
      s.installTestServer(_StubServer(), 'srv-A', const []);
      s.installTestItems([
        _movieIn('m1', 'lib-movie'),
        _movieIn('m2', 'lib-jp'),
      ]);
      s.installTestViews([
        const LibraryView(id: 'lib-movie', name: '电影'),
        const LibraryView(id: 'lib-jp', name: '日韩'),
      ]);
      return s;
    }

    test('切库后 watchEvents 与概览统计各归各，互不混算', () async {
      final s = buildState();
      await s.reportServerPlaybackStart('m1', positionTicks: 0);
      await s.reportServerPlaybackStop('m1', 10 * 60 * 10000000, played: false);
      await s.reportServerPlaybackStart('m2', positionTicks: 0);
      await s.reportServerPlaybackStop('m2', 20 * 60 * 10000000, played: false);
      expect(s.localWatchEvents, hasLength(2));
      expect(s.localWatchEvents.map((e) => e.libraryId), [
        'lib-movie',
        'lib-jp',
      ]);

      await s.setWatchScope('lib-movie');
      expect(s.effectiveWatchScopeId, 'lib-movie');
      expect(s.watchScopeLabel, '电影');
      expect(s.watchEvents.map((e) => e.itemId), ['m1']);
      expect(s.scopedStats.movieCount, 1);

      await s.setWatchScope('lib-jp');
      expect(s.watchEvents.map((e) => e.itemId), ['m2']);
      expect(s.scopedStats.movieCount, 1);

      await s.setWatchScope(kWatchScopeAll);
      expect(s.effectiveWatchScopeId, isNull);
      expect(s.watchEvents, hasLength(2));
      expect(s.scopedStats.movieCount, 2);
      s.dispose();
    });

    test('「跟随媒体库选择」联动 selectedViewId，虚拟库按全部处理', () async {
      final s = buildState();
      await s.setWatchScope(null);
      s.selectedViewId = 'lib-jp';
      expect(s.effectiveWatchScopeId, 'lib-jp');
      expect(s.watchScopeLabel, '日韩');

      s.selectedViewId = kRecentViewId;
      expect(s.effectiveWatchScopeId, isNull);
      expect(s.watchScopeLabel, '全部影片');
      s.dispose();
    });

    test('手动指定范围优先于媒体库页当前选择', () async {
      final s = buildState();
      s.selectedViewId = 'lib-jp';
      await s.setWatchScope('lib-movie');
      expect(s.effectiveWatchScopeId, 'lib-movie');
      s.dispose();
    });
  });

  group('海报清晰度 · 大图与独立缓存', () {
    test('posterUrlAtWidth 改到 1200 且换宽度就换 cacheKey', () {
      const small =
          'https://h:8096/Items/m1/Images/Primary?maxWidth=400&tag=t&api_key=k';
      final big = posterUrlAtWidth(small, 1200)!;
      expect(big, contains('maxWidth=1200'));
      expect(big, contains('tag=t'));
      expect(imageCacheKey(big), isNot(imageCacheKey(small)));
      expect(imageCacheKey(big), contains('maxWidth=1200'));
    });

    test('没有 maxWidth 的第三方图不凭空加参数', () {
      const u = 'https://cdn.example.com/p.jpg';
      expect(posterUrlAtWidth(u, 1200), u);
    });

    test('0 分钟返回空串，由页面显示「时长未记」而不是假数', () {
      expect(formatWatchMinutes(0), '');
      expect(formatWatchMinutes(double.nan), '');
      expect(formatWatchMinutes(17), '17 分钟');
    });
  });

  group('源码守卫', () {
    test('数据层与状态层的隔离链路都在', () {
      final wh = src('lib/watch_history.dart');
      expect(wh.contains("if (libraryId != null) 'lid': libraryId"), isTrue);
      expect(wh.contains('libraryId: j[\'lid\'] as String?'), isTrue);
      expect(
        wh.contains('List<WatchEvent> filterWatchEventsForScope('),
        isTrue,
      );
      expect(wh.contains("e.libraryId ?? resolve?.call(e.itemId)"), isTrue);

      final st = src('lib/app_state.dart');
      expect(st.contains('filterWatchEventsForScope('), isTrue);
      expect(st.contains('libraryIdFor(e.itemId)'), isTrue);
      expect(st.contains('libraryId: libraryIdFor(itemId)'), isTrue);
      expect(st.contains('_rebuildLibraryIndex()'), isTrue);
      expect(st.contains('installTestViews('), isTrue);
      expect(st.contains("'watch_scope_view'"), isTrue);
      expect(st.contains('_ensureDefaultWatchScope()'), isTrue);
      expect(st.contains('scopedStats'), isTrue);
    });

    test('页面层：范围选择器、按范围取数、海报不降采样', () {
      final page = src('lib/pages/watch_calendar_page.dart');
      expect(page.contains('_scopeChip()'), isTrue);
      expect(page.contains('class _WatchScopeSheet'), isTrue);
      expect(page.contains('kWatchScopeAll'), isTrue);
      expect(page.contains('_pickWatchScope()'), isTrue);
      expect(page.contains('服务器 + 媒体库双重隔离'), isTrue);
      expect(page.contains('posterUrlAtWidth(e.posterUrl, 1200)'), isTrue);
      expect(page.contains('FilterQuality.high'), isTrue);
      expect(page.contains('memWidth: 1200'), isTrue);
      expect(page.contains('fullResDiskCache: true'), isTrue);
      expect(page.contains('memWidth: 480'), isFalse);
      expect(page.contains("durationLabel.isEmpty ? '时长未记'"), isTrue);
      expect(page.contains('toImage(pixelRatio: 3.0)'), isTrue);

      final stats = src('lib/pages/stats_page.dart');
      expect(stats.contains('widget.state.scopedStats'), isTrue);
      expect(stats.contains('widget.state.scopedItems'), isTrue);
    });

    test('版本与验证文档同步到 v2.0.102', () {
      expect(src('pubspec.yaml').contains('version: 2.0.105+305'), isTrue);
      expect(src('README.md').contains('v2.0.105 (305)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.105 (305)'), isTrue);
      expect(src('VERIFICATION.md').contains('§112'), isTrue);
      expect(
        src('lib/dlna/dlna_protocol.dart').contains('Camby/2.0.105'),
        isTrue,
      );
    });

    test('磁盘缓存可单独豁免降采样，内存解码仍受控', () {
      final s = src('lib/widgets/cached_image.dart');
      expect(s.contains('memCacheWidth: widget.memWidth'), isTrue);
      expect(
        s.contains('widget.fullResDiskCache ? null : widget.memWidth'),
        isTrue,
      );
      // 海报墙：内存按 1200 解码（满足性能审计），磁盘那份不二次编码
      final page = src('lib/pages/watch_calendar_page.dart');
      expect(page.contains('memWidth: 1200'), isTrue);
      expect(page.contains('fullResDiskCache: true'), isTrue);
      expect(page.contains('memWidth: 480'), isFalse);
    });
  });
}
