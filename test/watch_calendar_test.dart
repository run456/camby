import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/watch_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camby/pages/stats_page.dart';

/// v2.0.86：「最近添加」虚拟媒体库 + 观影日历的回归守卫。
///
/// 两条最容易悄悄退化的链路：
/// ① 虚拟库绝不能变成一次真实网络请求，也不能混进 state.views；
/// ② 活动日志解析出来的逐次观看明细必须活到日历页，而不是算完日级
///    分钟数就被丢掉。
String src(String path) => File(path).readAsStringSync();

List<WatchEvent> _days(
  int n, {
  double minutes = 60,
  int hour = 20,
  String? sameId,
}) => [
  for (var d = 1; d <= n; d++)
    WatchEvent(
      itemId: sameId ?? 'm$d',
      name: '片$d',
      date: '2026-10-${d.toString().padLeft(2, '0')}',
      minutes: minutes,
      startAt: DateTime(2026, 10, d, hour),
    ),
];

void main() {
  group('虚拟媒体库 · 常量与身份', () {
    test('哨兵 ID 不会被误判成真实 UserView', () {
      expect(kRecentViewId, '__camby_recent__');
      expect(isVirtualViewId(kRecentViewId), isTrue);
      expect(isVirtualViewId(null), isFalse);
      expect(isVirtualViewId(''), isFalse);
      expect(isVirtualViewId('6f1b6c'), isFalse);
      expect(kRecentView.id, kRecentViewId);
      expect(kRecentView.name, '最近添加');
      // Emby Id 是 GUID / 数字，演示库 Id 是 demo-N，都不会撞上双下划线哨兵。
      for (final e in demoLibrary) {
        expect(isVirtualViewId(e.id), isFalse);
      }
    });

    test('虚拟库不进 AppState.views', () {
      final s = AppState();
      expect(s.views.any((v) => v.id == kRecentViewId), isFalse);
      s.selectedViewId = kRecentViewId;
      expect(s.selectedViewId, kRecentViewId);
      expect(s.views.any((v) => v.id == kRecentViewId), isFalse);
      s.dispose();
    });
  });

  group('WatchEvent · 序列化与纯计算', () {
    test('日期键与合法性', () {
      expect(watchDayKey(DateTime(2026, 10, 1)), '2026-10-01');
      expect(watchDayKey(DateTime(2024, 2, 29)), '2024-02-29');
      expect(isWatchDayKey('2026-10-01'), isTrue);
      expect(isWatchDayKey('2026-1-1'), isFalse);
      expect(isWatchDayKey(''), isFalse);
    });

    test('JSON 往返保留来源 / 进度 / 起播时刻', () {
      const e = WatchEvent(
        itemId: 'x1',
        name: '星际穿越',
        date: '2026-10-03',
        minutes: 88.5,
        startAt: null,
        progress: 0.62,
        source: WatchSource.activity,
        isEpisode: true,
      );
      final back = WatchEvent.fromJson(e.toJson());
      expect(back.itemId, 'x1');
      expect(back.minutes, closeTo(88.5, 0.001));
      expect(back.progress, closeTo(0.62, 0.001));
      expect(back.source, WatchSource.activity);
      expect(back.isEpisode, isTrue);
      expect(back.isEstimated, isFalse);
      expect(back.day, DateTime(2026, 10, 3));
    });

    test('脏缓存的来源下标越界不会崩，安全降级为 local', () {
      final e = WatchEvent.fromJson({
        'id': 'x',
        'n': 'n',
        'd': '2026-10-01',
        's': 99,
        'p': 5,
      });
      expect(e.source, WatchSource.local);
      expect(e.progress, 1.0);
    });

    test('进度文案：看完 / 看到 N% / 只有时长', () {
      expect(
        const WatchEvent(
          itemId: 'a',
          name: 'a',
          date: '2026-10-01',
          minutes: 100,
          progress: 1,
        ).progressLabel,
        '已看完',
      );
      expect(
        const WatchEvent(
          itemId: 'a',
          name: 'a',
          date: '2026-10-01',
          minutes: 50,
          progress: 0.5,
        ).progressLabel,
        '看到 50%',
      );
      expect(
        const WatchEvent(
          itemId: 'a',
          name: 'a',
          date: '2026-10-01',
          minutes: 0,
          progress: 0,
        ).progressLabel,
        '看过',
      );
    });

    test('观看时长优先用播放器 tick 差，并按片长封顶', () {
      // 100 分钟片，从 0 播到 50 分钟位置
      expect(
        resolveWatchMinutes(
          positionTicks: 50 * 60 * 10000000,
          startTicks: 0,
          elapsedMinutes: 55,
          runtimeMinutes: 100,
        ),
        closeTo(50, 0.001),
      );
      // 续播：从 40 分钟开始，播到 90 分钟 → 本次只算 50 分钟
      expect(
        resolveWatchMinutes(
          positionTicks: 90 * 60 * 10000000,
          startTicks: 40 * 60 * 10000000,
          elapsedMinutes: 90,
          runtimeMinutes: 100,
        ),
        closeTo(50, 0.001),
      );
      // 没有 tick 差时退回墙钟，但不能超过片长
      expect(
        resolveWatchMinutes(
          positionTicks: 0,
          startTicks: 0,
          elapsedMinutes: 300,
          runtimeMinutes: 100,
        ),
        closeTo(100, 0.001),
      );
      // 负数 tick 不产生负时长
      expect(
        resolveWatchMinutes(
          positionTicks: 0,
          startTicks: 10000000,
          elapsedMinutes: 0,
          runtimeMinutes: 100,
        ),
        0,
      );
    });

    test('进度换算与片长缺失', () {
      expect(resolveWatchProgress(0, 100), 0);
      expect(resolveWatchProgress(1000, 0), 0);
      expect(
        resolveWatchProgress(50 * 60 * 10000000, 100),
        closeTo(0.5, 0.001),
      );
      expect(resolveWatchProgress(999 * 60 * 10000000, 100), 1.0);
    });

    test('合并：本地优先、活动日志补漏、补片名、按日期倒序', () {
      const local = WatchEvent(
        itemId: 'a',
        name: '本地片名',
        date: '2026-10-03',
        minutes: 30,
        source: WatchSource.local,
      );
      const log = WatchEvent(
        itemId: 'a',
        name: '',
        date: '2026-10-03',
        minutes: 28,
        source: WatchSource.activity,
      );
      const other = WatchEvent(
        itemId: 'b',
        name: '',
        date: '2026-10-05',
        minutes: 40,
        source: WatchSource.activity,
      );
      final out = mergeWatchEvents(
        local: const [local],
        activity: const [log, other],
        names: const {'b': '补出来的片名'},
      );
      expect(out.length, 2);
      expect(out.first.date, '2026-10-05');
      expect(out.first.name, '补出来的片名');
      expect(out.last.name, '本地片名');
      expect(out.last.source, WatchSource.local);
    });

    test('历史回填只取最近一年，统一标估算', () {
      final now = DateTime(2026, 10, 15);
      final evs = eventsFromHistory(
        [
          HistorySeed(
            id: 'a',
            name: '三个月前',
            when: now.subtract(const Duration(days: 90)),
            minutes: 120,
          ),
          HistorySeed(
            id: 'b',
            name: '太久以前',
            when: now.subtract(const Duration(days: 400)),
            minutes: 120,
          ),
          HistorySeed(
            id: 'c',
            name: '未来',
            when: now.add(const Duration(days: 2)),
            minutes: 120,
          ),
          HistorySeed(
            id: '',
            name: '空 Id',
            when: now.subtract(const Duration(days: 1)),
            minutes: 120,
          ),
        ],
        now: now,
      );
      expect(evs.length, 1);
      expect(evs.single.itemId, 'a');
      expect(evs.single.source, WatchSource.imported);
      expect(evs.single.isEstimated, isTrue);
      expect(evs.single.minutes, 120);
      expect(kWatchBackfillDays, 365);
    });
  });

  group('WatchCalendar · 月历聚合与徽章', () {
    test('空日历', () {
      final c = WatchCalendar(const []);
      expect(c.isEmpty, isTrue);
      expect(c.month(2026, 10).badge, MonthBadge.none);
      expect(c.month(2026, 10).isEmpty, isTrue);
      expect(c.firstDay, isNull);
      expect(c.lastDay, isNull);
    });

    test('按日分组、时长累加、单日明细按起播倒序', () {
      final c = WatchCalendar([
        ..._days(2, minutes: 45, hour: 20),
        WatchEvent(
          itemId: 'z',
          name: '深夜那部',
          date: '2026-10-01',
          minutes: 20,
          startAt: DateTime(2026, 10, 1, 23),
        ),
      ]);
      expect(c.isEmpty, isFalse);
      expect(c.countOn(DateTime(2026, 10, 1)), 2);
      expect(c.minutesOn(DateTime(2026, 10, 1)), closeTo(65, 0.001));
      expect(c.eventsOn(DateTime(2026, 10, 1)).first.itemId, 'z');
      expect(c.minutesOn(DateTime(2026, 10, 9)), 0);
      expect(c.firstDay, DateTime(2026, 10, 1));
      expect(c.lastDay, DateTime(2026, 10, 2));
    });

    test('月度概览：时长 / 天数 / 电影 / 剧集 / 去重作品数', () {
      final c = WatchCalendar([
        ..._days(3, minutes: 60, sameId: 'same'),
        const WatchEvent(
          itemId: 'ep1',
          name: '第一集',
          date: '2026-10-02',
          minutes: 45,
          isEpisode: true,
        ),
        const WatchEvent(
          itemId: 'out',
          name: '上个月',
          date: '2026-09-30',
          minutes: 999,
        ),
      ]);
      final m = c.month(2026, 10);
      expect(m.minutes, closeTo(225, 0.001));
      expect(m.activeDays, 3);
      expect(m.movies, 3);
      expect(m.episodes, 1);
      expect(m.titles, 2);
      expect(m.bestStreak, 3);
      expect(m.topDayMinutes, closeTo(105, 0.001));
      expect(c.month(2026, 9).minutes, 999);
    });

    test('徽章优先级：连续 > 马拉松 > 阅片 > 深夜 > 开张', () {
      expect(
        WatchCalendar(_days(7)).month(2026, 10).badge,
        MonthBadge.streak,
      );
      expect(
        WatchCalendar(const [
          WatchEvent(
            itemId: 'a',
            name: 'a',
            date: '2026-10-04',
            minutes: 200,
          ),
        ]).month(2026, 10).badge,
        MonthBadge.marathon,
      );
      expect(
        WatchCalendar(_days(1, minutes: 10, sameId: null)..addAll([
              for (var i = 0; i < 9; i++)
                WatchEvent(
                  itemId: 'x$i',
                  name: 'x$i',
                  date: '2026-10-01',
                  minutes: 10,
                ),
            ])).month(2026, 10).badge,
        MonthBadge.explorer,
      );
      expect(
        WatchCalendar(_days(3, minutes: 10, hour: 23))
            .month(2026, 10)
            .badge,
        MonthBadge.nightOwl,
      );
      expect(
        WatchCalendar(_days(1)).month(2026, 10).badge,
        MonthBadge.kickoff,
      );
      expect(monthBadgeLabel(MonthBadge.streak, streak: 9), '连续 9 天');
      expect(monthBadgeIcon(MonthBadge.none), '○');
    });

    test('闰年 2 月天数不会越界', () {
      final c = WatchCalendar([
        ..._days(1),
        const WatchEvent(
          itemId: 'f',
          name: '闰日',
          date: '2024-02-29',
          minutes: 30,
        ),
      ]);
      expect(c.month(2024, 2).activeDays, 1);
      expect(c.month(2024, 2).minutes, 30);
    });
  });

  group('ActivitySummary · 逐次明细不再被丢弃', () {
    test('events 默认为空，构造可注入', () {
      final a = ActivitySummary(
        itemPlays: const {'a': 2},
        hourHist: List<int>.filled(24, 0),
        total: 2,
      );
      expect(a.events, isEmpty);
      const e = WatchEvent(
        itemId: 'a',
        name: 'a',
        date: '2026-10-01',
      );
      final b = ActivitySummary(
        itemPlays: const {'a': 2},
        hourHist: List<int>.filled(24, 0),
        total: 2,
        events: const [e],
      );
      expect(b.events.length, 1);
      expect(b.isEmpty, isFalse);
    });
  });

  group('AppState · 本机事件与回填', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppState.disablePersistence = true;
    });

    test('起播 + 退出落一条带进度与真实时长的本机事件', () async {
      final s = AppState();
      s.installTestItems([
        MediaItem(
          id: 'real-1',
          name: '测试片',
          type: MediaType.movie,
          overview: '',
          colors: const [Color(0xFF112233)],
          runtimeMin: 100,
        ),
      ]);
      await s.reportServerPlaybackStart('real-1', positionTicks: 0);
      await s.reportServerPlaybackStop(
        'real-1',
        50 * 60 * 10000000,
        played: false,
      );
      expect(s.localWatchEvents.length, 1);
      final e = s.localWatchEvents.single;
      expect(e.itemId, 'real-1');
      expect(e.name, '测试片');
      expect(e.source, WatchSource.local);
      expect(e.minutes, closeTo(50, 0.001));
      expect(e.progress, closeTo(0.5, 0.001));
      expect(s.watchEvents.length, 1);
      s.dispose();
    });

    test('演示条目不污染日历；没有服务器时回填返回 0', () async {
      final s = AppState();
      await s.reportServerPlaybackStart('demo-1', positionTicks: 0);
      await s.reportServerPlaybackStop('demo-1', 1000);
      expect(s.localWatchEvents, isEmpty);
      expect(await s.backfillWatchHistory(), 0);
      expect(s.watchBackfillDone, isFalse);
      s.dispose();
    });
  });

  group('源码守卫（真机/服务端难以稳定复现的结构性错误）', () {
    test('models：哨兵常量与虚拟判定都在，且未写进 views', () {
      final s = src('lib/models.dart');
      expect(s.contains("const String kRecentViewId = '__camby_recent__';"), isTrue);
      expect(s.contains("const String kContinueViewId = '__camby_continue__';"), isTrue);
      expect(s.contains('bool isVirtualViewId(String? id)'), isTrue);
      expect(s.contains('bool isContinueViewId(String? id)'), isTrue);
      expect(s.contains('final List<WatchEvent> events;'), isTrue);
    });

    test('main / home：最近添加与继续观看各回各家虚拟库', () {
      final main = src('lib/main.dart');
      expect(main.contains('void _openRecentLibrary()'), isTrue);
      expect(main.contains('void _openContinueLibrary()'), isTrue);
      expect(main.contains('_state.selectedViewId = kRecentViewId;'), isTrue);
      expect(main.contains('_state.selectedViewId = kContinueViewId;'), isTrue);
      expect(main.contains('onOpenRecent: _openRecentLibrary,'), isTrue);
      expect(main.contains('onOpenContinue: _openContinueLibrary,'), isTrue);
      // v2.0.88：不再有「点更多一律打回全部」的兜底回调
      expect(main.contains('void _openAllLibrary()'), isFalse);
      final home = src('lib/pages/home_page.dart');
      expect(home.contains('required this.onOpenRecent,'), isTrue);
      expect(home.contains('required this.onOpenContinue,'), isTrue);
      expect(home.contains('onAction: widget.onOpenRecent'), isTrue);
      expect(home.contains('onAction: widget.onOpenContinue'), isTrue);
      expect(home.contains("action: '查看全部'"), isTrue);
      expect(home.contains('onOpenAll:'), isFalse);
    });

    test('library：虚拟库零网络请求、走本地派生列表、按入库时间排', () {
      final s = src('lib/pages/library_page.dart');
      expect(s.contains('if (isVirtualViewId(vid))'), isTrue);
      expect(s.contains('return widget.state.recentlyAdded;'), isTrue);
      expect(s.contains('return widget.state.continueWatching;'), isTrue);
      expect(s.contains('itemCount: state.views.length + 3'), isTrue);
      expect(s.contains('if (i == 1)'), isTrue);
      expect(s.contains('if (i == 2)'), isTrue);
      expect(s.contains('_selectView(kRecentViewId)'), isTrue);
      expect(s.contains('_selectView(kContinueViewId)'), isTrue);
      expect(s.contains('state.views[i - 3]'), isTrue);
      expect(s.contains('_DashedOvalPainter'), isTrue);
      expect(s.contains('· 虚拟媒体库 · '), isTrue);
      expect(s.contains('_sort = 0;'), isTrue);
      expect(s.contains('是 Camby 按入库时间生成的虚拟媒体库'), isTrue);
      // 虚拟库分支必须出现在任何 itemsForView 调用之前
      expect(
        s.indexOf('if (isVirtualViewId(vid))') <
            s.indexOf('await state.itemsForView(view)'),
        isTrue,
      );
    });

    test('emby_client：活动日志把配对结果留成 events 而不是丢掉', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains('final events = <WatchEvent>[];'), isTrue);
      expect(s.contains('events: events,'), isTrue);
      expect(s.contains('source: WatchSource.activity'), isTrue);
      expect(s.contains('只起播、没有 Stop 配对的观看'), isTrue);
      expect(s.contains("import 'watch_history.dart';"), isTrue);
    });

    test('app_state：起播/退出配对、落盘、恢复、一年回填都在', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('_watchSessions[itemId] = _WatchSession('), isTrue);
      expect(s.contains('_recordLocalWatch(itemId, positionTicks'), isTrue);
      expect(s.contains("itemId.startsWith('demo-')"), isTrue);
      expect(s.contains("'watch_events_json'"), isTrue);
      expect(s.contains('await _loadWatchEvents();'), isTrue);
      expect(s.contains('Future<int> backfillWatchHistory()'), isTrue);
      expect(s.contains('s.playedHistory(limit: 400)'), isTrue);
      expect(s.contains('eventsFromHistory(seeds)'), isTrue);
      expect(s.contains('mergeWatchEvents('), isTrue);
      expect(s.contains('_watchEvents.length > 2000'), isTrue);
    });

    test('stats / calendar：默认日历、双分段、分享成图、同步 CTA', () {
      final stats = src('lib/pages/stats_page.dart');
      expect(stats.contains('StatsMode _mode = StatsMode.calendar;'), isTrue);
      expect(stats.contains('if (_mode == StatsMode.calendar)'), isTrue);
      expect(stats.contains('StatsModeSegment('), isTrue);
      final page = src('lib/pages/watch_calendar_page.dart');
      expect(page.contains('enum StatsMode { calendar, insight }'), isTrue);
      expect(page.contains('RepaintBoundary('), isTrue);
      expect(page.contains('toImage(pixelRatio: 2.0)'), isTrue);
      expect(page.contains('SharePlus.instance.share('), isTrue);
      expect(page.contains('backfillWatchHistory()'), isTrue);
      expect(page.contains('最近一年'), isTrue);
      expect(page.contains('数据口径：本机播放记录'), isTrue);
      // 明确不做的东西不能偷偷混进来
      expect(page.contains('桌面小组件'), isFalse);
      expect(page.contains('追剧更新'), isFalse);
    });

    test('版本与文档同步到 v2.0.90', () {
      expect(src('pubspec.yaml').contains('version: 2.0.93+293'), isTrue);
      expect(src('README.md').contains('v2.0.93 (293)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.93 (293)'), isTrue);
      expect(src('VERIFICATION.md').contains('§100'), isTrue);
      expect(
        src('lib/dlna/dlna_protocol.dart').contains("'Camby/2.0.93 "),
        isTrue,
      );
    });
  });

  group('统计页 · 双分段（widget）', () {
    testWidgets('默认落观影日历，切到数据洞察才显示原卡片', (tester) async {
      SharedPreferences.setMockInitialValues({});
      AppState.disablePersistence = true;
      final state = AppState();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: StatsPage(state: state)),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(find.text('观影日历'), findsWidgets);
      expect(find.text('数据洞察'), findsOneWidget);
      expect(find.text('数据总结'), findsNothing);

      await tester.tap(find.text('数据洞察'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(find.text('数据总结'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
