import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emby_client.dart';
import 'models.dart';
import 'player/native_ssl.dart';
import 'ugreen_resource.dart';
import 'watch_history.dart';
import 'widgets/haptics.dart';
import 'widgets/image_ssl.dart';

/// 待上报进度（持久化队列用）
class _PendingProgress {
  const _PendingProgress(this.ticks, this.played);
  final int ticks;
  final bool played;
}

/// v2.0.86：一次本机播放会话。起播记下时刻与位置，退出时才能算出
/// 「这次到底看了多久 / 看到哪里」，而不是把整部片长算进去。
class _WatchSession {
  const _WatchSession(this.startedAt, this.startTicks);
  final DateTime startedAt;
  final int startTicks;
}

/// 应用数据源状态
/// demoMode=true  → 使用内置演示库
/// demoMode=false → 使用真实 Emby 服务器的条目
class AppState extends ChangeNotifier {
  List<MediaItem> _items = demoLibrary;
  EmbyServer? _server;
  bool _demoMode = true;
  bool _loading = false;
  String? _error;

  /// v2.0.87：当前服务器是否支持进度同步。绿联影视中心（HTTPS 9443）不开放
  /// `/Sessions/*` 与进度接口，判成 false 后跳过上报与重试队列，只保留本机
  /// 观影日历记录；避免无效请求堆积，也避免用户以为「进度丢了是 bug」。
  bool _progressSyncSupported = true;
  String? _userName;
  List<LibraryView> _views = [];
  String? _selectedViewId;
  final Map<String, List<MediaItem>> _viewCache = {};
  final Map<String, List<MediaItem>> _previewCache = {};

  /// v2.0.102：观影数据的媒体库范围。
  /// null = 跟随媒体库页选中的库；[kWatchScopeAll] = 全部影片；
  /// 其它字符串 = 指定的 LibraryView.id。持久化在 `watch_scope_view`。
  String? _watchScopeId;
  bool _watchScopeLoaded = false;

  /// itemId → LibraryView.id。来源：全库条目的 ParentId + 已加载的库缓存。
  /// 活动日志 / 已看历史都是**服务器级**接口，只能靠它反查条目属于哪个库。
  Map<String, String> _itemLibraryIndex = const {};
  LibraryStats? _scopedStatsCache;
  String? _scopedStatsKey;
  PlaybackReport? _playback;
  ActivitySummary? _activity;
  List<MediaItem> _recentPlayedItems = const [];

  /// 服务器「已看」历史（/Users/{id}/PlayedItems），跨端、不依赖活动日志权限
  List<MediaItem> _playedHistory = const [];
  bool _playbackLoading = false;

  /// v2.0.86：本机观看事件（精确）+ 历史回填事件（估算），持久化到 SharedPreferences。
  List<WatchEvent> _watchEvents = const [];
  final Map<String, _WatchSession> _watchSessions = {};
  bool _watchBackfillDone = false;

  /// 是否处于「离线（使用本地缓存）」状态
  bool _offline = false;
  Timer? _saveTimer;

  bool get offline => _offline;

  /// 播放报告（Playback Reporting 插件，失败时为 null）
  PlaybackReport? get playback => _playback;

  /// 内置活动日志聚合（无插件时的行为数据来源）
  ActivitySummary? get activity => _activity;

  /// 活动日志账号匹配诊断（v2.0）：如「日志播放 128 条，本账号 128 条」。
  /// 统计页空态直接展示，用于区分「确实没数据」与「账号/权限没匹配上」。
  String get activityDiag => _server?.lastActivityDiag ?? '';

  /// 会话型播放上报的失败原因（v2.0.1）：空字符串 = 上报正常。
  /// 统计页空态展示，避免再出现「服务端没 APP 记录」却查不到原因。
  String get sessionDiag => _server?.lastSessionError ?? '';

  /// 最近播放的条目（服务端 DatePlayed 倒序）
  List<MediaItem> get recentPlayedItems => _recentPlayedItems;

  /// 服务器标记为「已看了」的历史条目（v2.0.2）
  List<MediaItem> get playedHistory => _playedHistory;
  bool get playbackLoading => _playbackLoading;

  // ---------------- 观影日历事件流（v2.0.86） ----------------

  /// 本机记录 + 历史回填（不含服务器活动日志），只读。
  List<WatchEvent> get localWatchEvents => _watchEvents;

  /// 是否已经做过「首次同步历史观看」；UI 用它决定要不要显示同步 CTA。
  bool get watchBackfillDone => _watchBackfillDone;

  /// 日历页唯一的取数入口。v2.0.107 起改为**服务器为准 · 自动统一**：
  ///
  /// 用户实测手机看一部、平板看一部，两端「本月观看 / 看了什么」对不上。
  /// 根因是旧口径以本机精确事件为主（[localWatchEvents]，各设备一份 JSON、
  /// 从不共享），服务器数据只做补漏——于是每台设备都拿自己的本机记录算账。
  /// 新口径把真相源换成服务器，两端连同一服务器/账号即读到同一份：
  /// 1. 服务器活动日志逐条明细（PlaybackStart/Stop 配对，精确时长 + 片名）；
  /// 2. 服务器「已看历史」近 30 天按片长估算（活动日志不可用时兜底）；
  /// 3. 仅当服务器两项皆空，才退回本机事件——避免空窗，且来源仍标 local，
  ///    UI 会显示「本机记录」让用户知道这是这台设备独有的、不会跨端。
  ///
  /// 隔离：v2.0.99 只看当前服务器（本机 JSON 全服共用一份，必须按
  /// [activeServerId] 过滤，否则切服串台）；v2.0.102 再按当前媒体库过滤
  /// （活动日志 / 已看历史都是服务器级，会把所有库的播放一起返回）。
  /// 老事件没有 libraryId，用 [libraryIdFor] 现场反查，升级不丢数据。
  List<WatchEvent> get watchEvents {
    final sid = _activeServerId;
    final scope = effectiveWatchScopeId;
    String? resolve(String id) => libraryIdFor(id);
    final byId = {for (final e in _items) e.id: e};
    final names = <String, String>{
      for (final e in _items) e.id: e.name,
      ..._activityNames,
    };

    // ① 服务器活动日志明细：跨端同一份，优先。
    final fromLog = filterWatchEventsForScope(
      <WatchEvent>[
        for (final e in _activity?.events ?? const <WatchEvent>[])
          e.copyWith(
            name: e.name.isNotEmpty ? e.name : (names[e.itemId] ?? '库外影片'),
            posterUrl: e.posterUrl ?? byId[e.itemId]?.posterUrl,
            isEpisode: byId[e.itemId]?.type == MediaType.episode,
            serverId: sid,
            libraryId: libraryIdFor(e.itemId),
          ),
      ],
      scope,
      resolve: resolve,
    );
    if (fromLog.isNotEmpty) return fromLog;

    // ② 服务器已看历史估算：活动日志不可读（普通用户权限 / 超 800 条）时兜底，
    //    同样是服务器级，两端一致；时长按片长估算，来源标 imported。
    final fromHistory = filterWatchEventsForScope(
      eventsFromHistory(_historySeeds(), days: 30),
      scope,
      resolve: resolve,
    );
    if (fromHistory.isNotEmpty) return fromHistory;

    // ③ 服务器完全无数据才用本机事件兜底，避免日历一片空白。
    //    这部分是本机独有的，UI 会以「本机记录」标出，不冒充跨端数据。
    return filterWatchEventsForScope(
      <WatchEvent>[
        for (final e in _watchEvents)
          if (e.serverId == sid) e,
      ],
      scope,
      resolve: resolve,
    );
  }

  Iterable<HistorySeed> _historySeeds() sync* {
    for (final e in _playedHistory) {
      final t = e.lastPlayedAt;
      if (t == null || t <= 0) continue;
      yield HistorySeed(
        id: e.id,
        name: e.name,
        when: DateTime.fromMillisecondsSinceEpoch(t),
        minutes: e.runtimeMin.toDouble(),
        isEpisode: e.type == MediaType.episode,
        posterUrl: e.posterUrl,
        serverId: _activeServerId,
        libraryId: libraryIdFor(e.id),
      );
    }
  }

  Future<void> _loadWatchEvents() async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _watchBackfillDone = prefs.getBool('watch_backfill_done') ?? false;
      final raw = prefs.getString('watch_events_json');
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as List<dynamic>;
      _watchEvents = data
          .whereType<Map<String, dynamic>>()
          .map(WatchEvent.fromJson)
          .where((e) => e.itemId.isNotEmpty && isWatchDayKey(e.date))
          .toList();
    } catch (_) {
      _watchEvents = const [];
    }
  }

  Future<void> _persistWatchEvents() async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'watch_events_json',
        jsonEncode(_watchEvents.map((e) => e.toJson()).toList()),
      );
      await prefs.setBool('watch_backfill_done', _watchBackfillDone);
    } catch (_) {}
  }

  /// v2.0.99：升级前所有服务器的事件共用一份 JSON、没有归属字段。
  /// 这里把无归属的老事件归给当前激活服务器 —— 原始归属已无法追溯，
  /// 但至少不再让 A 的记录跟着用户跑到 B 的日历里。
  /// 必须在 [restore] 确定 activeServerId 之后调用。
  Future<void> _migrateLegacyWatchEvents() async {
    final sid = _activeServerId;
    if (sid == null || sid.isEmpty) return;
    if (!_watchEvents.any((e) => e.serverId == null || e.libraryId == null)) {
      return;
    }
    _watchEvents = assignServerToOrphans(_watchEvents, sid)
        .map(
          (e) => e.libraryId == null
              ? e.copyWith(libraryId: libraryIdFor(e.itemId))
              : e,
        )
        .toList();
    await _persistWatchEvents();
  }

  /// 首次同步：把服务器「已看」历史最近一年回填成估算事件。
  /// 逐条按「日期 + 条目 Id」去重，绝不覆盖已有的本机精确记录。
  /// 返回新增条数，供 UI 弹 toast。
  Future<int> backfillWatchHistory() async {
    final s = _server;
    if (s == null) return 0;
    List<MediaItem> history;
    try {
      history = await s.playedHistory(limit: 400);
    } catch (_) {
      return 0;
    }
    final byId = {for (final e in _items) e.id: e};
    final sid = _activeServerId;
    final seeds = <HistorySeed>[];
    for (final e in history) {
      final t = e.lastPlayedAt;
      if (t == null || t <= 0) continue;
      seeds.add(
        HistorySeed(
          id: e.id,
          name: e.name,
          when: DateTime.fromMillisecondsSinceEpoch(t),
          minutes: e.runtimeMin.toDouble(),
          isEpisode: e.type == MediaType.episode,
          posterUrl: e.posterUrl ?? byId[e.id]?.posterUrl,
          serverId: sid,
          libraryId: libraryIdFor(e.id),
        ),
      );
    }
    // 回填只跟「同一台服务器」已有的记录比，避免 A 的已看历史
    // 因为 B 那天也看过同一部片而被跳过。
    final existing = <String>{
      for (final e in _watchEvents) watchEventKey(e),
      for (final e in _activity?.events ?? const <WatchEvent>[])
        watchEventKey(e.copyWith(serverId: sid)),
    };
    final added = <WatchEvent>[
      for (final e in eventsFromHistory(seeds))
        if (!existing.contains(watchEventKey(e))) e,
    ];
    if (added.isNotEmpty) {
      _watchEvents = [..._watchEvents, ...added]
        ..sort((a, b) => a.date.compareTo(b.date));
    }
    _watchBackfillDone = true;
    await _persistWatchEvents();
    notifyListeners();
    return added.length;
  }

  /// 活动日志条目 Id → 片名（不在库列表里的条目，服务器反查结果）
  Map<String, String> _activityNames = const {};
  Map<String, String> get activityItemNames => _activityNames;

  /// 反查活动日志里、当前库列表中找不到的条目名
  Future<void> _resolveActivityNames() async {
    final items = _items;
    if (_activity == null || items.isEmpty) {
      _activityNames = const {};
      return;
    }
    final known = {for (final e in items) e.id};
    final missing = _activity!.itemPlays.keys
        .where((id) => !known.contains(id))
        .toList();
    if (missing.isEmpty) {
      _activityNames = const {};
      return;
    }
    try {
      _activityNames = await _server!.itemNamesByIds(missing);
    } catch (_) {
      _activityNames = const {};
    }
  }

  Future<void> _loadPlayback() async {
    final s = _server;
    if (s == null) {
      _playback = null;
      _activity = null;
      _recentPlayedItems = const [];
      _playedHistory = const [];
      return;
    }
    _playbackLoading = true;
    // v2.0.10：四项请求各自独立 try —— 以前串在一个 try 里，插件接口
    // （playbackReport）一失败，活动日志/最近播放/已看历史全被连坐置空，
    // 统计页「每日观看时长 / 播放时段 / 最常看作品」整版没数据（实测反馈）。
    // Playback Reporting 插件不可用是常态（普通 Emby 没装），不该影响
    // 任何用户权限都能访问的活动日志与已看历史。
    try {
      _playback = await s.playbackReport(days: 30);
    } catch (_) {
      _playback = null;
    }
    try {
      // 内置活动日志：条目级播放次数 + 小时分布（插件不可用时兜底）
      _activity = await s.activityLog();
      // v1.7.72：活动日志里出现、但不在当前库列表的条目（被删除/其它类型），
      // 向服务器反查片名；查不到的 UI 显示「库外影片」而不是裸 Id
      await _resolveActivityNames();
    } catch (_) {
      _activity = null;
    }
    try {
      // 最近播放 10 部（普通用户权限即可，用于完成率卡名单）
      _recentPlayedItems = await s.recentPlayed(limit: 10);
    } catch (_) {
      _recentPlayedItems = const [];
    }
    try {
      // v2.0.2：服务器「已看」历史（/Users/{id}/PlayedItems，任何客户端写过
      // Played=true 都会出现在这里）。首页「继续观看」原本只看本地库条目的
      // resumeProgress —— 片源播放离开本机 App 后一无所知；补上这份列表，
      // 就有了不依赖活动日志的跨端播放历史。
      _playedHistory = await s.playedHistory(limit: 30);
    } catch (_) {
      _playedHistory = const [];
    }
    _playbackLoading = false;
    notifyListeners();
  }

  /// 首页按库分组的预览（每库只取一页，带缓存）
  ///
  /// 关键：**空结果绝不写缓存**。以前一次超时/服务端扫描中拿到空列表，
  /// 就会被永久记住，首页那一行永远是「暂无内容」，只能重装才好。
  /// `force` 用于下拉刷新/重试用，跳过缓存直接问服务端。
  Future<List<MediaItem>> previewForView(
    LibraryView view, {
    int limit = 12,
    bool force = false,
  }) async {
    final cached = _previewCache[view.id];
    // 先读缓存：这样离线时首页各媒体库行仍能显示上次内容
    if (!force && cached != null && cached.isNotEmpty) return cached;
    final s = _server;
    if (s == null) return cached ?? const [];
    try {
      final list = await s.libraryPreview(view.id, limit: limit);
      if (list.isNotEmpty) {
        _previewCache[view.id] = list;
        _scheduleSave();
        return list;
      }
      // 服务端返回空：可能是刚扫描/刚重建索引，保留旧缓存并让上层可重试
      return cached ?? const [];
    } catch (_) {
      return cached ?? const [];
    }
  }

  /// v2.0.103：媒体库选择弹窗的封面 / 数量来源。
  ///
  /// 弹窗以前只按 `MediaItem.parentId == view.id` 找海报；标准 Emby 里条目的
  /// ParentId 常常指向库内文件夹而不是 UserView，于是一律匹配不上、卡片全
  /// 退化成「库名首字」。这里复用首页已有的 [previewForView] 缓存（按
  /// DateCreated 倒序 = 最近入库的影片），不新增接口、不拉全库。
  Future<void> prewarmViewPreviews({int limit = 6}) async {
    if (_server == null || _views.isEmpty) return;
    final pending = <Future<void>>[];
    for (final v in _views) {
      final cached = _previewCache[v.id];
      if (cached != null && cached.isNotEmpty) continue;
      pending.add(
        previewForView(v, limit: limit)
            .timeout(const Duration(seconds: 3))
            .then<void>((_) {})
            .catchError((Object _) {}),
      );
    }
    if (pending.isEmpty) return;
    await Future.wait(pending);
  }

  /// 某库最近影片的海报（已缓存优先，按入库时间新→旧，去重，最多 limit 张）。
  List<String> viewPosterUrls(String viewId, {int limit = 3}) {
    final pool = <MediaItem>[];
    final preview = _previewCache[viewId];
    if (preview != null && preview.isNotEmpty) pool.addAll(preview);
    final full = _viewCache[viewId];
    if (full != null && full.isNotEmpty) pool.addAll(full);
    for (final e in _items) {
      if (e.parentId == viewId || _itemLibraryIndex[e.id] == viewId) {
        pool.add(e);
      }
    }
    final seen = <String>{};
    final sorted = <MediaItem>[];
    for (final e in pool) {
      if (seen.add(e.id)) sorted.add(e);
    }
    sorted.sort((a, b) => a.addedDaysAgo.compareTo(b.addedDaysAgo));
    final out = <String>[];
    for (final e in sorted) {
      final u = e.posterUrl;
      if (u == null || u.isEmpty) continue;
      if (!out.contains(u)) out.add(u);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 某库条目数：只有拉过全量或 ParentId 能命中时才报数，不拿预览条数假报。
  int viewCountFor(String viewId) {
    final full = _viewCache[viewId];
    if (full != null && full.isNotEmpty) return full.length;
    var n = 0;
    for (final e in _items) {
      if (e.parentId == viewId || _itemLibraryIndex[e.id] == viewId) n++;
    }
    return n;
  }

  // 派生列表缓存：上千部影片时避免每次 build 重新排序
  List<MediaItem>? _recentCache;
  LibraryStats? _statsCache;

  void _invalidateDerived() {
    _recentCache = null;
    _statsCache = null;
    _scopedStatsCache = null;
    _scopedStatsKey = null;
  }

  List<MediaItem> get items => _items;

  /// 测试专用：直接替换全库条目（不写缓存、不发通知以外的副作用），
  /// 便于驱动「按导演 / 制造商聚合」这类依赖全库数据的页面。
  @visibleForTesting
  void installTestItems(List<MediaItem> items) {
    _items = List<MediaItem>.of(items);
    _invalidateDerived();
    notifyListeners();
  }

  /// 测试专用：注入服务器活动日志聚合，驱动「服务器为准」的观影日历。
  /// 生产代码里由 `_loadPlayback()` 从 `/System/ActivityLog/Entries` 拉取。
  @visibleForTesting
  void installTestActivity(ActivitySummary? activity) {
    _activity = activity;
    _invalidateDerived();
    notifyListeners();
  }

  /// 测试专用：注入服务器「已看历史」，驱动活动日志不可用时的一致兜底。
  /// 生产代码里由 `_loadPlayback()` 从 `/Users/{id}/PlayedItems` 拉取。
  @visibleForTesting
  void installTestPlayedHistory(List<MediaItem> items) {
    _playedHistory = List<MediaItem>.of(items);
    _invalidateDerived();
    notifyListeners();
  }

  /// 测试专用：注入媒体库视图并重建「条目 → 媒体库」归属索引。
  /// 生产代码里视图来自 `userViews()`，索引由 connect / refresh 重建。
  @visibleForTesting
  void installTestViews(List<LibraryView> views) {
    _views = List<LibraryView>.of(views);
    _rebuildLibraryIndex();
    _invalidateDerived();
    notifyListeners();
  }

  bool get demoMode => _demoMode;
  bool get loading => _loading;
  String? get error => _error;
  EmbyServer? get server => _server;

  /// 当前服务器是否支持播放进度同步（绿联兼容源为 false）。
  bool get progressSyncSupported => _progressSyncSupported;

  /// 当前连接是否跳过了 TLS 证书校验（诊断 / 设置页提示用）。
  bool get ignoreSslErrors => _server?.ignoreSsl ?? false;

  /// 绿联接入诊断文本（设置页「连接诊断」入口展示，含拼好的图片/播放 URL）。
  String get serverDiagnostics =>
      _server?.diagnostics(
        sampleItemId: _items.isEmpty ? null : _items.first.id,
        samplePosterUrl: _items.isEmpty ? null : _items.first.posterUrl,
      ) ??
      '尚未连接服务器。';

  /// 当前是否为绿联影视中心（独立服务器类型，v2.0.88）。
  bool get isUgreenServer => _server?.isUgreen ?? false;

  /// Exo 在这个服务器上是否已被证实拉不动流（v2.0.93）。
  ///
  /// 绿联 / 自签 HTTPS 下有个反复出现的现象：`Range: bytes=0-0` 探测能拿
  /// 到 206，但 ExoPlayer 的 `DefaultHttpDataSource` 用开放区间取流就报
  /// `Source error`。既然 Exo 这条栈跟它合不来，就没必要**每次**都先陪它
  /// 失败一轮（每次黑屏十几秒）。第一次失败后记住，后续直接走 MPV。
  ///
  /// 只在「同一台服务器 + 同一次连接」内有效，连接 / 切换 / 断开都会重置
  /// —— 换了服务器或换了网络环境后不该沿用旧结论。
  bool exoStreamUnavailable = false;

  /// 标记 Exo 在本服务器上取流失败（见 [exoStreamUnavailable]）。
  void markExoStreamUnavailable() {
    if (exoStreamUnavailable) return;
    exoStreamUnavailable = true;
    notifyListeners();
  }

  /// v2.0.89：绿联资源自检报告（设置页「连接诊断」展示）。
  String get resourceProbeReport => ResourcePolicy.instance.probeReport;

  /// v2.0.89：用与图片组件**完全相同**的证书策略和鉴权头，逐个探测
  /// 图片 / 播放候选，把第一个真正返回图片的模板记进 [ResourcePolicy]。
  ///
  /// 只取响应头就立刻取消 body 订阅，不会下载海报或视频内容。
  /// 连接成功后自动跑一次，也可在诊断面板点「重新自检」手动跑。
  Future<void> runResourceProbe() async {
    final policy = ResourcePolicy.instance;
    policy.preferredImageIndex = null;
    policy.lastProbe = const <ResourceProbeResult>[];
    if (_items.isEmpty) {
      policy.lastProbe = const <ResourceProbeResult>[
        ResourceProbeResult(label: '图片候选', url: '', error: '媒体库为空，没有可用于自检的条目'),
      ];
      return;
    }
    final first = _items.first;
    final poster = first.posterUrl;
    final results = <ResourceProbeResult>[];
    void publish() =>
        policy.lastProbe = List<ResourceProbeResult>.unmodifiable(results);

    if (poster == null || poster.isEmpty) {
      results.add(
        const ResourceProbeResult(
          label: '图片候选',
          url: '',
          error: '首条条目没有海报 URL（ImageTags.Primary 缺失）',
        ),
      );
      publish();
    } else {
      policy.sampleImageUrl = poster;
      final candidates = imageUrlCandidates(poster, enabled: true);
      for (var i = 0; i < candidates.length; i++) {
        final r = await ImageSsl.probe(candidates[i], label: '图片候选 ${i + 1}');
        results.add(r);
        publish();
        final ct = r.contentType ?? '';
        if (r.ok && (ct.startsWith('image/') || ct.isEmpty)) {
          policy.preferredImageIndex = i;
          break;
        }
      }
      // 2xx 但 content-type 是 HTML（多半被重定向到登录页）时，
      // 仍留一个兜底下标，避免每张海报都把整条候选链重走一遍。
      if (policy.preferredImageIndex == null) {
        for (var i = 0; i < results.length; i++) {
          if (results[i].ok) {
            policy.preferredImageIndex = i;
            break;
          }
        }
      }
    }

    final server = _server;
    if (server != null) {
      // v2.0.91：不再猜路径。先问服务端「这个条目声明了哪些取流协议」，
      // 按声明拼端点再验证；协议一个都没声明时直接给出结论，而不是拿
      // 一串注定 404 的 URL 让用户白看。
      if (server.isUgreen) {
        final cap = await server.probeStreamCapability(first.id);
        results.add(
          ResourceProbeResult(
            label: '取流能力',
            url: '${cap.summary}｜${cap.verdict}',
          ),
        );
        publish();
        final urls = await server.resolveStreamUrls(first);
        if (urls.isEmpty) {
          results.add(
            const ResourceProbeResult(
              label: '播放端点',
              url: '',
              error: '服务端未声明任何取流协议，且该条目没有可直连地址',
            ),
          );
          publish();
          return;
        }
        for (var i = 0; i < urls.length; i++) {
          final r = await ImageSsl.probe(urls[i], label: '播放候选 ${i + 1}');
          results.add(r);
          publish();
          if (r.ok) break;
        }
      } else {
        final candidates = streamUrlCandidates(
          server.streamUrl(first.id),
          enabled: true,
        );
        for (var i = 0; i < candidates.length; i++) {
          final r = await ImageSsl.probe(candidates[i], label: '播放候选 ${i + 1}');
          results.add(r);
          publish();
          if (r.ok) break;
        }
      }
    }
  }

  List<LibraryView> get views => _views;
  String? get selectedViewId => _selectedViewId;
  String? get watchScopeId => _watchScopeId;
  String get sourceLabel =>
      _demoMode ? '演示媒体库' : '$_userName · ${_server?.host ?? ''}';

  /// 实际生效的观影数据范围：null = 全部影片，其它 = 指定媒体库 id。
  ///
  /// 优先级：手动指定的范围 > 媒体库页当前选中的库 > 全部影片。
  /// 虚拟库（最近添加 / 继续观看）不是真实媒体库，一律按「全部」处理。
  String? get effectiveWatchScopeId {
    final s = _watchScopeId;
    if (s == kWatchScopeAll) return null;
    if (s != null && s.isNotEmpty && !isVirtualViewId(s)) return s;
    final sel = _selectedViewId;
    if (sel == null || isVirtualViewId(sel)) return null;
    return sel;
  }

  String get watchScopeLabel {
    final id = effectiveWatchScopeId;
    if (id == null) return '全部影片';
    for (final v in _views) {
      if (v.id == id) return v.name;
    }
    return '指定媒体库';
  }

  set selectedViewId(String? v) {
    _selectedViewId = v;
    _invalidateDerived();
    notifyListeners();
    unawaited(_savePrefString('selected_view', v));
  }

  /// 切换观影数据范围。传 null = 跟随媒体库选择，[kWatchScopeAll] = 全部影片。
  Future<void> setWatchScope(String? id) async {
    _watchScopeId = id;
    _watchScopeLoaded = true;
    _invalidateDerived();
    notifyListeners();
    await _savePrefString('watch_scope_view', id);
    unawaited(_prewarmScope(effectiveWatchScopeId));
  }

  Future<void> _savePrefString(String key, String? value) async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    } catch (_) {}
  }

  Future<void> _loadWatchScope() async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _watchScopeLoaded = prefs.containsKey('watch_scope_view');
      _watchScopeId = prefs.getString('watch_scope_view');
      _selectedViewId = prefs.getString('selected_view');
    } catch (_) {}
  }

  /// 首次升级到 v2.0.102：多库服务器默认选中第一个真实库，让「一个媒体库
  /// 一份观影数据」装上就生效。用户随时可以在日历顶部切回「全部影片」。
  void _ensureDefaultWatchScope() {
    if (_watchScopeLoaded) return;
    _watchScopeLoaded = true;
    if (_views.length <= 1) return;
    final first = _views.first.id;
    if (first.isEmpty) return;
    _watchScopeId = first;
    unawaited(_savePrefString('watch_scope_view', first));
  }

  void _rebuildLibraryIndex() {
    final viewIds = <String>{for (final v in _views) v.id};
    final m = <String, String>{};
    for (final e in _items) {
      final p = e.parentId;
      if (p != null && viewIds.contains(p)) m[e.id] = p;
    }
    // 已加载过的库缓存更准（能覆盖「库里再分文件夹」的情况）。
    _viewCache.forEach((vid, list) {
      if (!viewIds.contains(vid)) return;
      for (final e in list) m[e.id] = vid;
    });
    _itemLibraryIndex = m;
  }

  String? libraryIdFor(String itemId) => _itemLibraryIndex[itemId];

  /// 切到某个范围时预拉该库条目，把归属索引补全再刷新页面。
  Future<void> _prewarmScope(String? scopeId) async {
    if (scopeId == null || _server == null) return;
    // ParentId 已经能把条目归到这个库就别再打一次全库请求；只有
    // 「库里再分文件夹」导致零命中时才需要按库拉一次补全索引。
    if (_itemLibraryIndex.values.contains(scopeId)) return;
    LibraryView? view;
    for (final v in _views) {
      if (v.id == scopeId) {
        view = v;
        break;
      }
    }
    if (view == null) return;
    try {
      await itemsForView(view);
      _rebuildLibraryIndex();
      _invalidateDerived();
      notifyListeners();
    } catch (_) {}
  }

  /// 按当前媒体库范围过滤后的库条目（概览 / 完成率 / 偏好统计都用它）。
  List<MediaItem> get scopedItems {
    final scope = effectiveWatchScopeId;
    if (scope == null) return _items;
    final cached = _viewCache[scope];
    if (cached != null && cached.isNotEmpty) return cached;
    final filtered = <MediaItem>[
      for (final e in _items)
        if (_itemLibraryIndex[e.id] == scope) e,
    ];
    // 索引还没预热好时别谎报成 0 部，先退回全库，等异步结果刷新。
    return filtered.isEmpty ? _items : filtered;
  }

  LibraryStats get scopedStats {
    final key =
        '${effectiveWatchScopeId ?? ''}|${_items.length}|'
        '${_itemLibraryIndex.length}|${_viewCache.length}|${_playCount.length}';
    final hit = _scopedStatsCache;
    if (_scopedStatsKey == key && hit != null) return hit;
    final s = LibraryStats.compute(scopedItems, _playCount);
    _scopedStatsKey = key;
    _scopedStatsCache = s;
    return s;
  }

  /// 数据总结：真实统计（带缓存，收藏/刷新等变更时自动失效）
  LibraryStats get stats =>
      _statsCache ??= LibraryStats.compute(_items, _playCount);

  /// 本机播放次数：每次在 App 内起播记一次，落盘持久化。
  /// 与服务器 `userPlayCount` 取较大值用于「偏好影片」统计（见 models.dart）。
  final Map<String, int> _playCount = {};

  /// 某条目本机累计播放次数（只读查询用）。
  int localPlayCountOf(String id) => _playCount[id] ?? 0;

  /// 起播一次记一次数（幂等于「本次打开播放页只记一次」由播放页控制）。
  /// 改内存 + 失效派生缓存 + 落盘；播放页在首次成功起播后调用一次。
  void addLocalPlay(String id) {
    if (id.isEmpty) return;
    _playCount[id] = (_playCount[id] ?? 0) + 1;
    _invalidateDerived();
    notifyListeners();
    unawaited(_persistPlayCount());
  }

  Future<void> _persistPlayCount() async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('play_count_json', jsonEncode(_playCount));
    } catch (_) {}
  }

  Future<void> _loadPlayCount() async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('play_count_json');
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _playCount
        ..clear()
        ..addAll({
          for (final e in data.entries)
            if (e.value is int) e.key: e.value as int,
        });
    } catch (_) {}
  }

  List<MediaItem> get recentlyAdded {
    final cached = _recentCache;
    if (cached != null) return cached;
    final list = List<MediaItem>.from(_items)
      ..sort((a, b) => a.addedDaysAgo.compareTo(b.addedDaysAgo));
    _recentCache = list;
    return list;
  }

  List<MediaItem> get continueWatching {
    // 不做长期缓存：重拉库 / 播放完一部之后要立刻反映，缓存按构建好了
    final list =
        _items
            .where(
              (e) =>
                  e.resumeProgress != null &&
                  e.resumeProgress! > 0.01 &&
                  e.resumeProgress! < 0.99,
            )
            // 刚看过的排最前：Emby 原生「继续观看」同样是 LastPlayedDate 倒序
            .toList()
          ..sort(
            (a, b) => (b.lastPlayedAt ?? 0).compareTo(a.lastPlayedAt ?? 0),
          );
    // 2) v2.0.2：本地库没有续播点、但服务端「已看」历史里有的，补在后面。
    //    本 APP 重装/换设备后，库条目的 UserData 还没重拉时，这一步能立刻
    //    找回跨端的播放记录，不至于整块「继续观看」空着。
    final seen = {for (final e in list) e.id};
    final extra = _playedHistory.where((e) => !seen.contains(e.id)).take(6);
    if (extra.isNotEmpty) list.addAll(extra);
    return list;
  }

  List<MediaItem> get unplayed => _items
      .where((e) => e.resumeProgress == null || e.resumeProgress! < 0.01)
      .toList();

  /// 已收藏的条目
  List<MediaItem> get favorites => _items.where((e) => e.userFavorite).toList();

  /// 近 [days] 天新增的收藏影片数（v2.0.97 · 收藏页统计条）。
  ///
  /// 服务端不给「收藏时间」，这里用条目自带的入库时间（`dateCreatedMs`，
  /// 退化时用 `addedDaysAgo`）近似 —— 用来把统计条的结构撑起来，不当作
  /// 精确的收藏时间用；拿不到时间的条目一律不计。
  int recentFavoriteCount(int days) {
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    var n = 0;
    for (final e in _items) {
      if (!e.userFavorite) continue;
      final ms = e.dateCreatedMs;
      if (ms != null && ms > 0) {
        if (ms >= cutoff) n++;
      } else if (e.addedDaysAgo > 0 && e.addedDaysAgo <= days) {
        n++;
      }
    }
    return n;
  }

  /// 用最新的条目信息替换列表中的同 id 项（详情页刷新后同步全局）
  void replaceItem(MediaItem item) {
    var hit = false;
    _items = _items.map((e) {
      if (e.id != item.id) return e;
      hit = true;
      return item;
    }).toList();
    if (!hit) return;
    _invalidateDerived();
    notifyListeners();
  }

  /// v2.0.62：全库 NFO 系列回填批量写回。
  ///
  /// 逐条 [replaceItem] 会 notify 上千次、把整页重建上千次；这里一次 map
  /// 一次通知。只填 seriesName 为空的条目，绝不覆盖服务端已有值。
  void replaceSeriesNames(Map<String, String> updates) {
    if (updates.isEmpty) return;
    var hit = false;
    _items = _items.map((e) {
      final v = updates[e.id];
      if (v == null || v.trim().isEmpty || e.seriesName.trim().isNotEmpty) {
        return e;
      }
      hit = true;
      return e.copyWith(seriesName: v.trim());
    }).toList();
    if (!hit) return;
    _invalidateDerived();
    notifyListeners();
  }

  /// 播放中 / 退出时把进度写回本地列表。
  ///
  /// 只改内存 + 重建派生缓存，不发请求：服务端的 `PlaybackPositionTicks`
  /// 由播放页单独上报，两边取同一个播放头位置，避免本地与服务端打架。
  /// 进度只增不减（用 max），防止退出瞬间拿到 0 把已看进度清掉。
  void updateProgress(
    String itemId, {
    required double seconds,
    required double total,
    bool played = false,
  }) {
    if (total <= 0) return;
    final ratio = (seconds / total).clamp(0.0, 1.0);
    var hit = false;
    _items = _items.map((e) {
      if (e.id != itemId) return e;
      hit = true;
      final prev = e.resumeProgress ?? 0;
      final next = ratio > prev ? ratio : prev;
      return e.copyWith(
        resumeProgress: next,
        resumeSeconds: seconds > 0 ? seconds : e.resumeSeconds,
        userPlayed: played || next >= 0.95,
        lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }).toList();
    if (!hit) return;
    _invalidateDerived();
    notifyListeners();
  }

  // ---------------- 进度上报到服务端（含失败重试队列，v1.7.65） ----------------
  //
  // 「另一台手机看不到播放记录」的根因：旧上报只在播放页直接调 server，失败被
  // 静默吞掉、且从不标 Played，断网/切网瞬间丢的进度就再也补不回来。
  // 这里在 AppState 层维护一个**持久化待上报队列**：成功就出队，失败就留下，
  // 下次成功上报 / 连接 / 刷新时统一冲刷。队列落盘，App 被杀也不丢。

  /// itemId -> 待上报的进度（ticks + 是否已看完）
  final Map<String, _PendingProgress> _pendingProgress = {};

  /// 把一次进度上报到服务端（统一入口，带重试队列）。
  /// [played] 为 true 时同步标「已看完」（之前从不标，是跨端不同步的主因）。
  Future<void> reportServerProgress(
    String itemId,
    int positionTicks, {
    bool played = false,
  }) async {
    final s = _server;
    // v2.0.87：绿联影视中心不开放进度接口，直接跳过，避免每次播放都往
    // 持久化重试队列里堆一条永远发不出去的记录。
    if (s == null || !_progressSyncSupported) return;
    final ok = await s.reportProgress(itemId, positionTicks, played: played);
    // v1.7.73：UserData 直写之外同步发一次会话心跳，让服务器活动日志
    // 记录本 APP 的播放事件（统计页「每日观看时长/播放时段」的数据源）。
    // v2.0.2：**不再依赖 UserData 是否成功** —— 两条链路互相独立，
    // UserData 被服务端拒绝（比如权限/条目不可写）时，会话事件照样要发，
    // 否则活动日志永远空白。失败只是尽力而为，不进重试队列。
    unawaited(s.reportPlaybackProgress(itemId, positionTicks));
    if (ok) {
      if (_pendingProgress.remove(itemId) != null) _persistPendingProgress();
    } else {
      _pendingProgress[itemId] = _PendingProgress(positionTicks, played);
      await _persistPendingProgress();
    }
  }

  /// 冲刷待上报队列：连接成功 / 下拉刷新 / 回到前台时调用。
  Future<void> flushPendingProgress() async {
    final s = _server;
    if (s == null || !_progressSyncSupported || _pendingProgress.isEmpty) {
      return;
    }
    final pending = Map<String, _PendingProgress>.from(_pendingProgress);
    for (final entry in pending.entries) {
      final ok = await s.reportProgress(
        entry.key,
        entry.value.ticks,
        played: entry.value.played,
      );
      if (ok) {
        _pendingProgress.remove(entry.key);
        await _persistPendingProgress();
      }
    }
  }

  /// 当前还有多少进度待上报（设置页/调试用）
  int get pendingProgressCount => _pendingProgress.length;

  // ---------------- 会话型播放事件（v1.7.73） ----------------
  //
  // 起播 / 退出时各发一次，配合 reportServerProgress 里的心跳，让服务器
  // 活动日志完整记录本 APP 的 PlaybackStart/Stop —— 统计页「每日观看时长、
  // 播放时段统计、常看作品 Top」从此有本账号的真实数据。

  /// 起播上报：POST /Sessions/Playing（活动日志出现「开始播放」条目）
  ///
  /// [positionTicks] 必须带当前续播位置，否则服务端可能把进度重置为 0，
  /// 「继续观看」在别的设备上就没了。
  Future<void> reportServerPlaybackStart(
    String itemId, {
    int positionTicks = 0,
    String? playMethod,
    String? mediaSourceId,
    int? audioStreamIndex,
  }) {
    // v2.0.86：起播先记会话，退出时与 Stop 配对成一条本地观看事件。
    // 这条**与服务端无关**：绿联源关掉上报后，观影日历仍要能记下这一场。
    _watchSessions[itemId] = _WatchSession(DateTime.now(), positionTicks);
    if (!_progressSyncSupported) return Future.value();
    return _server?.reportPlaybackStart(
          itemId,
          positionTicks: positionTicks,
          playMethod: playMethod,
          mediaSourceId: mediaSourceId,
          audioStreamIndex: audioStreamIndex,
        ) ??
        Future.value();
  }

  /// 退出播放上报：POST /Sessions/Stopped（活动日志出现「停止播放」条目，
  /// 与 Start 配对后统计页才能推算观看时长）
  Future<void> reportServerPlaybackStop(
    String itemId,
    int positionTicks, {
    bool played = false,
    double? watchedSeconds,
  }) {
    _recordLocalWatch(
      itemId,
      positionTicks,
      played: played,
      watchedSeconds: watchedSeconds,
    );
    if (!_progressSyncSupported) return Future.value();
    return _server?.reportPlaybackStop(itemId, positionTicks, played: played) ??
        Future.value();
  }

  /// 把一次播放会话落成本地 WatchEvent。不依赖服务端是否在线 —— 断网看片
  /// 也要能在日历里留下记录。演示条目不写（否则演示库会污染真实日历）。
  void _recordLocalWatch(
    String itemId,
    int positionTicks, {
    required bool played,
    double? watchedSeconds,
  }) {
    if (itemId.isEmpty || itemId.startsWith('demo-')) return;
    final sess = _watchSessions.remove(itemId);
    final startedAt = sess?.startedAt ?? DateTime.now();
    final elapsed = DateTime.now().difference(startedAt).inMinutes;
    MediaItem? item;
    for (final e in _items) {
      if (e.id == itemId) {
        item = e;
        break;
      }
    }
    final runtime = item?.runtimeMin ?? 0;
    final minutes = resolveWatchMinutes(
      positionTicks: positionTicks,
      startTicks: sess?.startTicks ?? 0,
      elapsedMinutes: elapsed,
      runtimeMinutes: runtime,
      watchedSeconds: watchedSeconds,
    );
    // 试看几秒（既没进度也没时长）不记，避免日历被误触点亮。
    if (minutes < 0.5 && positionTicks <= 0) return;
    final ev = WatchEvent(
      itemId: itemId,
      name: item?.name ?? '库外影片',
      date: watchDayKey(startedAt),
      minutes: minutes,
      startAt: startedAt,
      progress: played ? 1.0 : resolveWatchProgress(positionTicks, runtime),
      source: WatchSource.local,
      isEpisode: item?.type == MediaType.episode,
      posterUrl: item?.posterUrl,
      serverId: _activeServerId,
      libraryId: libraryIdFor(itemId),
    );
    _watchEvents = [..._watchEvents, ev];
    // 只保留最近 2000 条，长期使用的 JSON 不能无限膨胀。
    if (_watchEvents.length > 2000) {
      _watchEvents = _watchEvents.sublist(_watchEvents.length - 2000);
    }
    unawaited(_persistWatchEvents());
    notifyListeners();
  }

  /// 当前还有多少收藏夹上云待重试（pendingSync 标记）
  int get pendingSyncCount => _folders.where((f) => f.pendingSync).length;

  /// 最近一次收藏夹同步的失败诊断（空 = 全部成功）。
  /// 形如「「哈哈」创建失败：请求失败 (500)」，收藏页 toast 展示（v1.7.69）。
  String folderSyncDiag = '';

  Future<void> _persistPendingProgress() async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _pendingProgress.map(
        (k, v) => MapEntry(k, {'t': v.ticks, 'p': v.played}),
      );
      await prefs.setString('pending_progress_json', jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _loadPendingProgress() async {
    if (disablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('pending_progress_json');
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _pendingProgress
        ..clear()
        ..addAll({
          for (final e in data.entries)
            e.key: _PendingProgress(
              (e.value['t'] as int?) ?? 0,
              (e.value['p'] as bool?) ?? false,
            ),
        });
    } catch (_) {}
  }

  // ---------------- 收藏夹（本地索引） + 演员收藏 ----------------

  List<FavoriteFolder> _folders = const [];
  List<CastMember> _favPersons = const [];
  bool _favPersonsLoading = false;

  List<FavoriteFolder> get folders => _folders;

  /// 仅当前服务器名下的收藏夹。
  ///
  /// v2.0.24：多服务器切换后，收藏页/收藏夹只展示「当前服务器」的收藏夹，
  /// 不再把上一台服务器的缓存夹混进来（之前切换 Jellyfin 后仍显示 Emby 的夹）。
  /// 旧版 serverId 为 null 的夹归到「当前服务器」以兼容历史数据。
  List<FavoriteFolder> get activeFolders {
    final sid = _activeServerId;
    return _folders
        .where((f) => f.serverId == sid || (sid == null && f.serverId == null))
        .toList();
  }

  List<CastMember> get favoritePersons => _favPersons;
  bool get favPersonsLoading => _favPersonsLoading;

  FavoriteFolder? folderById(String? id) {
    if (id == null) return null;
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// 夹内条目（按加入顺序，末尾最新）
  List<MediaItem> itemsOfFolder(FavoriteFolder f) {
    final map = {for (final e in _items) e.id: e};
    return f.itemIds.map((id) => map[id]).whereType<MediaItem>().toList();
  }

  /// 封面候选：从最新加入往前取 n 部（用于海报堆叠）
  List<MediaItem> coverCandidates(FavoriteFolder f, int n) {
    final map = {for (final e in _items) e.id: e};
    final out = <MediaItem>[];
    for (final id in f.itemIds.reversed) {
      final it = map[id];
      if (it != null) out.add(it);
      if (out.length >= n) break;
    }
    return out;
  }

  Set<String> folderIdsOfItem(String itemId) => {
    for (final f in _folders)
      if (f.itemIds.contains(itemId)) f.id,
  };

  Future<FavoriteFolder> createFolder(String name) async {
    final f = FavoriteFolder(
      id: 'f${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '未命名收藏夹' : name.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      serverId: _activeServerId,
    );
    _folders = [..._folders, f];
    notifyListeners();
    await _saveFolders();
    // 上云：映射到服务端播放列表（失败标记 pending，下次同步重试）
    if (_server != null) {
      final pid = await _server!.createPlaylist(f.name, const []);
      if (pid != null) {
        _folders = _folders
            .map(
              (e) => e.id == f.id
                  ? e.copyWith(playlistId: pid, pendingSync: false)
                  : e,
            )
            .toList();
        await _saveFolders();
        notifyListeners();
      } else {
        _folders = _folders
            .map((e) => e.id == f.id ? e.copyWith(pendingSync: true) : e)
            .toList();
        await _saveFolders();
        notifyListeners();
      }
    }
    return folderById(f.id) ?? f;
  }

  Future<void> renameFolder(String id, String name) async {
    final t = name.trim();
    if (t.isEmpty) return;
    _folders = _folders
        .map((f) => f.id == id ? f.copyWith(name: t) : f)
        .toList();
    notifyListeners();
    await _saveFolders();
    final pid = folderById(id)?.playlistId;
    if (pid != null && _server != null) {
      // v2.0.20：renamePlaylist 现在返回「可能变化的最终 Id」，null 表示失败
      final ok = await _server!.renamePlaylist(pid, t);
      if (ok == null) {
        _folders = _folders
            .map((e) => e.id == id ? e.copyWith(pendingSync: true) : e)
            .toList();
        await _saveFolders();
        notifyListeners();
      }
    }
  }

  Future<void> deleteFolder(String id) async {
    final pid = folderById(id)?.playlistId;
    _folders = _folders.where((f) => f.id != id).toList();
    notifyListeners();
    await _saveFolders();
    if (pid != null && _server != null) await _server!.deletePlaylist(pid);
  }

  /// 设置某影片归属的收藏夹集合（多选），并同步到服务端播放列表
  Future<void> setItemFolders(String itemId, Set<String> folderIds) async {
    final oldById = {for (final f in _folders) f.id: f};
    var changed = false;
    _folders = _folders.map((f) {
      final has = f.itemIds.contains(itemId);
      final want = folderIds.contains(f.id);
      if (want && !has) {
        changed = true;
        return f.copyWith(itemIds: [...f.itemIds, itemId]);
      }
      if (!want && has) {
        changed = true;
        return f.copyWith(
          itemIds: f.itemIds.where((e) => e != itemId).toList(),
        );
      }
      return f;
    }).toList();
    notifyListeners();
    await _saveFolders();
    if (!changed || _server == null) return;
    // 计算增减并同步到对应服务端播放列表
    final failedFids = <String>{};
    for (final f in _folders) {
      final pid = f.playlistId;
      if (pid == null) continue;
      final oldHas = oldById[f.id]?.itemIds.contains(itemId) ?? false;
      final newHas = f.itemIds.contains(itemId);
      if (newHas && !oldHas) {
        if (!await _server!.addToPlaylist(pid, [itemId])) failedFids.add(f.id);
      }
      if (!newHas && oldHas) {
        if (!await _server!.removeFromPlaylist(pid, [itemId])) {
          failedFids.add(f.id);
        }
      }
    }
    if (failedFids.isNotEmpty) {
      _folders = _folders
          .map(
            (e) =>
                failedFids.contains(e.id) ? e.copyWith(pendingSync: true) : e,
          )
          .toList();
      await _saveFolders();
      notifyListeners();
    }
  }

  Future<void> _removeItemFromFolders(String itemId) async {
    if (_folders.isEmpty) return;
    final affected = <String>{};
    for (final f in _folders) {
      if (f.itemIds.contains(itemId)) affected.add(f.id);
    }
    var changed = false;
    _folders = _folders.map((f) {
      if (!f.itemIds.contains(itemId)) return f;
      changed = true;
      return f.copyWith(itemIds: f.itemIds.where((e) => e != itemId).toList());
    }).toList();
    if (changed) await _saveFolders();
    if (changed && _server != null) {
      for (final fid in affected) {
        final pid = folderById(fid)?.playlistId;
        if (pid != null) await _server!.removeFromPlaylist(pid, [itemId]);
      }
    }
  }

  /// 把服务端播放列表与本地收藏夹合并（纯函数，便于单测）。
  ///
  /// 这是**下行模式**（本地无内容 / 新装）的合并规则，服务端为准：
  /// - 以 playlistId 为主键。服务端有、本地也有的 → 名称仅在**服务端非空**时
  ///   覆盖本地（v1.7.68 决策①：空名是脏数据，不能把本地好名字冲掉）；
  /// - 影片取并集（v1.7.65 起）；
  /// - 服务端有、本地没有的 → 在本地新建一个收藏夹（**自动恢复**场景）；
  ///   但**服务端空名**播放列表一律跳过（v1.7.68 决策②：那是事故脏数据，不该建成本地收藏夹）；
  /// - 本地有 playlistId、服务端已删除的 → 本地一并移除（保持两端一致）；
  /// - 本地纯本地（playlistId==null）的收藏夹一律保留，不动。
  static List<FavoriteFolder> reconcileFolders(
    List<FavoriteFolder> local,
    List<ServerPlaylist> remote,
    String serverId,
  ) {
    final byPlaylist = <String, ServerPlaylist>{};
    for (final p in remote) byPlaylist[p.id] = p;
    final result = <FavoriteFolder>[];
    for (final f in local) {
      // 纯本地、或归属其它服务器的收藏夹：不参与合并，原样保留
      // （避免不同服务器的 playlistId 字符串撞名时互相串号）
      if (f.playlistId == null || f.serverId != serverId) {
        result.add(f);
        continue;
      }
      final p = byPlaylist.remove(f.playlistId);
      if (p == null) continue; // 服务端已删，本地移除
      final merged = <String>{...p.itemIds, ...f.itemIds}.toList();
      // 决策①：仅服务端名非空才覆盖本地
      final name = p.name.isNotEmpty ? p.name : f.name;
      result.add(f.copyWith(name: name, itemIds: merged));
    }
    // 服务端新增、本地未匹配的播放列表 → 建本地收藏夹
    // 决策②：空名播放列表是脏数据，跳过（真正的清理在 syncFoldersFromServer）
    for (final p in byPlaylist.values) {
      if (p.name.isEmpty) continue;
      result.add(
        FavoriteFolder(
          id: 'pl_${p.id}',
          name: p.name,
          itemIds: p.itemIds,
          serverId: serverId,
          playlistId: p.id,
        ),
      );
    }
    return result;
  }

  /// 下载「覆盖」模式（服务端 → 本地）的纯函数：本机该服务器的收藏夹完全
  /// 以服务端播放列表为准。
  ///
  /// - 服务端非空名播放列表 → 本地收藏夹，名称与片单都取服务端的值；
  /// - 本地该服务器的其余收藏夹（含未上云的纯本地夹）一律移除——「覆盖」
  ///   的语义就是让本机变成服务端快照；
  /// - 其它服务器的收藏夹原样保留（多服隔离）；
  /// - 服务端空名播放列表是历史脏数据，不建成本地收藏夹。
  static List<FavoriteFolder> reconcileFoldersOverwrite(
    List<FavoriteFolder> local,
    List<ServerPlaylist> remote,
    String serverId,
  ) {
    final result = local.where((f) => f.serverId != serverId).toList();
    for (final p in remote) {
      if (p.name.isEmpty) continue;
      final i = result.indexWhere(
        (f) => f.serverId == serverId && f.playlistId == p.id,
      );
      final folder = FavoriteFolder(
        id: i >= 0 ? result[i].id : 'pl_${p.id}',
        name: p.name,
        itemIds: p.itemIds,
        createdAt: i >= 0 ? result[i].createdAt : 0,
        serverId: serverId,
        playlistId: p.id,
      );
      if (i >= 0) {
        result[i] = folder;
      } else {
        result.add(folder);
      }
    }
    return result;
  }

  /// 从服务端拉回播放列表并与本地收藏夹双向同步。
  ///
  /// 连接成功 / 重装后登录 / 设置页手动「从服务器恢复」/ 收藏页刷新按钮时调用。
  ///
  /// v1.7.68 同步策略（按"以谁为准"决策③）：
  /// - **上行模式（APP 为准）**：本地对该服务器已有收藏夹 → 把本地名称、片单
  ///   全部推到服务端（改名 + 增删条目），本地未上云的先建播放列表；服务端独
  ///   有的**非空名**播放列表（多半来自另一台设备）拉回本地，避免丢数据；
  ///   服务端独有的**空名**播放列表（事故脏数据）删除。
  /// - **下行模式（服务端为准）**：本地对该服务器没有任何收藏夹（新装 / 已清空）
  ///   → 用 reconcileFolders 把服务端播放列表拉回本地做自动恢复。
  ///
  /// 两种模式结束后都会清理服务端空名播放列表。
  /// 返回同步完成后当前服务器名下的收藏夹数量（供 UI 提示用）。
  Future<int> syncFoldersFromServer() async {
    final s = _server;
    final sid = _activeServerId;
    if (s == null || sid == null) return 0;
    // 旧版本地收藏夹缺 serverId，先回填为当前服务器
    if (_folders.any((f) => f.serverId == null)) {
      _folders = _folders
          .map((f) => f.serverId == null ? f.copyWith(serverId: sid) : f)
          .toList();
    }
    // v2.0.2：拉列表失败必须**中止**同步，不能当成「服务端没有播放列表」——
    // 否则上行模式会把每个收藏夹都判成「服务器上已被删」→ 逐个重建，
    // 网络一抖就产生一堆重复播放列表，本地 playlistId 也被换成新的。
    // 旧实现在 catch 里塞 const []，是同步反复出问题的隐患之一。
    List<ServerPlaylist> remote;
    try {
      remote = await s.listPlaylists();
    } catch (e) {
      folderSyncDiag =
          '拉取服务端播放列表失败：${s.lastPlaylistError.isNotEmpty ? s.lastPlaylistError : e}';
      notifyListeners();
      return _folders.where((f) => f.serverId == sid).length;
    }

    final localForServer = _folders.where((f) => f.serverId == sid).toList();
    final diag = <String>[];
    if (localForServer.isNotEmpty) {
      // 上行模式（APP 为准）
      _folders = await _reconcileUpload(sid, remote, diag);
    } else {
      // 下行模式（服务端为准，新装自动恢复）
      _folders = reconcileFolders(_folders, remote, sid);
    }

    // 清理服务端空名播放列表（v1.7.67 事故遗留 + 其它脏数据）
    await _deleteJunkPlaylists(s, remote, sid);

    // 失败诊断：供收藏页 toast 显示具体原因（最多 2 条，避免过长）
    folderSyncDiag = diag.take(2).join('；');

    notifyListeners();
    await _saveFolders();
    // 本地可能有刚建立的续播位置变化：清掉「继续观看」缓存，页面立刻反映
    _invalidateDerived();
    return _folders.where((f) => f.serverId == sid).length;
  }

  /// 下载（服务端 → 本地）：把服务端播放列表刷新到本机收藏夹。
  ///
  /// [overwrite] = true：本机以服务端为准，移除本机多余的收藏夹/影片；
  /// [overwrite] = false：两端取并集，保留本机独有的收藏夹/影片。
  ///
  /// 与旧的 [syncFoldersFromServer] 不同，这里**绝不**把本机数据写回服务端，
  /// 是「平板一点就把手机改的刷新下来」的安全入口。
  Future<int> downloadFoldersFromServer({required bool overwrite}) async {
    final s = _server;
    final sid = _activeServerId;
    if (s == null || sid == null) return 0;
    if (_folders.any((f) => f.serverId == null)) {
      _folders = _folders
          .map((f) => f.serverId == null ? f.copyWith(serverId: sid) : f)
          .toList();
    }
    List<ServerPlaylist> remote;
    try {
      remote = await s.listPlaylists();
    } catch (e) {
      folderSyncDiag =
          '拉取服务端播放列表失败：${s.lastPlaylistError.isNotEmpty ? s.lastPlaylistError : e}';
      notifyListeners();
      return _folders.where((f) => f.serverId == sid).length;
    }
    _folders = overwrite
        ? reconcileFoldersOverwrite(_folders, remote, sid)
        : reconcileFolders(_folders, remote, sid);
    await _deleteJunkPlaylists(s, remote, sid);
    folderSyncDiag = '';
    notifyListeners();
    await _saveFolders();
    _invalidateDerived();
    return _folders.where((f) => f.serverId == sid).length;
  }

  /// 上传（本地 → 服务端）：把本机收藏夹写入服务端播放列表。
  ///
  /// [overwrite] = true：服务端以本机为准，删除服务端多余的收藏夹/影片；
  /// [overwrite] = false：两端取并集，保留服务端独有的收藏夹/影片。
  Future<int> uploadFoldersToServer({required bool overwrite}) async {
    final s = _server;
    final sid = _activeServerId;
    if (s == null || sid == null) return 0;
    if (_folders.any((f) => f.serverId == null)) {
      _folders = _folders
          .map((f) => f.serverId == null ? f.copyWith(serverId: sid) : f)
          .toList();
    }
    List<ServerPlaylist> remote;
    try {
      remote = await s.listPlaylists();
    } catch (e) {
      folderSyncDiag =
          '拉取服务端播放列表失败：${s.lastPlaylistError.isNotEmpty ? s.lastPlaylistError : e}';
      notifyListeners();
      return _folders.where((f) => f.serverId == sid).length;
    }
    final diag = <String>[];
    _folders = await _pushLocalFolders(sid, remote, overwrite, diag);
    await _deleteJunkPlaylists(s, remote, sid);
    folderSyncDiag = diag.take(2).join('；');
    notifyListeners();
    await _saveFolders();
    _invalidateDerived();
    return _folders.where((f) => f.serverId == sid).length;
  }

  /// 上传的核心实现：按覆盖/合并策略把本机收藏夹写入服务端播放列表。
  Future<List<FavoriteFolder>> _pushLocalFolders(
    String sid,
    List<ServerPlaylist> remote,
    bool overwrite,
    List<String> diag,
  ) async {
    final s = _server!;
    final remoteById = <String, ServerPlaylist>{};
    for (final p in remote) {
      remoteById[p.id] = p;
    }
    // 按名收养，避免服务端出现两个同名播放列表
    final remoteByName = <String, ServerPlaylist>{};
    for (final p in remote) {
      if (p.name.isNotEmpty) remoteByName.putIfAbsent(p.name, () => p);
    }
    final out = <FavoriteFolder>[];
    final matched = <String>{};

    Future<FavoriteFolder> upsert(
      FavoriteFolder f,
      ServerPlaylist? existing,
    ) async {
      var pid = existing?.id;
      if (pid == null) {
        final byName = remoteByName[f.name];
        if (byName != null && !matched.contains(byName.id)) {
          pid = byName.id;
          existing = byName;
        } else {
          pid = await s.createPlaylist(f.name, f.itemIds);
          if (pid == null) {
            diag.add('「${f.name}」创建失败：${s.lastPlaylistError}');
            return f.copyWith(pendingSync: true);
          }
          matched.add(pid);
          return f.copyWith(playlistId: pid, pendingSync: false);
        }
      }
      matched.add(pid);

      final oldIds = existing?.itemIds ?? const <String>[];
      final serverSet = Set<String>.from(oldIds);
      final localSet = Set<String>.from(f.itemIds);
      // 覆盖：服务端片单以本机为准；合并：保留两端各自的影片
      final toAdd = f.itemIds.where((e) => !serverSet.contains(e)).toList();
      final toRemove = overwrite
          ? oldIds.where((e) => !localSet.contains(e)).toList()
          : <String>[];
      final finalIds = overwrite
          ? f.itemIds
          : [...f.itemIds, ...oldIds.where((e) => !localSet.contains(e))];

      var ok = true;
      if (existing != null && existing.name != f.name) {
        final newPid = await s.renamePlaylist(
          pid,
          f.name,
          itemIds: finalIds,
        );
        if (newPid == null) {
          ok = false;
          diag.add('「${f.name}」改名失败：${s.lastPlaylistError}');
        } else if (newPid != pid) {
          // 重建式改名已按 finalIds 建好新列表，跳过本轮加/移片
          matched.add(newPid);
          return f.copyWith(
            playlistId: newPid,
            itemIds: finalIds,
            pendingSync: !ok,
          );
        }
      }
      if (toAdd.isNotEmpty && !await s.addToPlaylist(pid, toAdd)) {
        ok = false;
        diag.add('「${f.name}」加片失败：${s.lastPlaylistError}');
      }
      if (toRemove.isNotEmpty && !await s.removeFromPlaylist(pid, toRemove)) {
        ok = false;
        diag.add('「${f.name}」移片失败：${s.lastPlaylistError}');
      }
      return f.copyWith(itemIds: finalIds, pendingSync: !ok);
    }

    for (final f in _folders) {
      if (f.serverId != sid) {
        out.add(f);
        continue;
      }
      final existing = f.playlistId == null ? null : remoteById[f.playlistId];
      out.add(await upsert(f, existing));
    }

    for (final p in remote) {
      if (matched.contains(p.id)) continue;
      if (p.name.isEmpty) continue;
      if (overwrite) {
        if (!await s.deletePlaylist(p.id)) {
          diag.add('删除服务端「${p.name}」失败：${s.lastPlaylistError}');
        }
      } else {
        out.add(
          FavoriteFolder(
            id: 'pl_${p.id}',
            name: p.name,
            itemIds: p.itemIds,
            serverId: sid,
            playlistId: p.id,
          ),
        );
      }
    }

    // 同名去重：历史事故留下的同名夹合并为一个（片单并集）
    final nameIndex = <String, int>{};
    final merged = <FavoriteFolder>[];
    final dupPlaylistIds = <String>{};
    for (final f in out) {
      if (f.serverId != sid) {
        merged.add(f);
        continue;
      }
      final i = nameIndex[f.name];
      if (i == null) {
        nameIndex[f.name] = merged.length;
        merged.add(f);
        continue;
      }
      final kept = merged[i];
      final seen = Set<String>.from(kept.itemIds);
      merged[i] = kept.copyWith(
        itemIds: [
          ...kept.itemIds,
          ...f.itemIds.where((e) => !seen.contains(e)),
        ],
      );
      final pid = f.playlistId;
      if (pid != null && pid != merged[i].playlistId) {
        dupPlaylistIds.add(pid);
      }
    }
    for (final pid in dupPlaylistIds) {
      await s.deletePlaylist(pid);
    }
    return merged;
  }

  /// 上行模式：把本地收藏夹的状态推到服务端（APP 为准）。
  ///
  /// - 未上云（playlistId==null）或已上云但服务端播放列表已不在 → **先按名字
  ///   收养**服务端同名播放列表（v2.0.16 防重复的关键：旧逻辑直接新建，另一台
  ///   设备已建过同名夹时服务端就会出现两个同名播放列表，再被拉回本地变成
  ///   「重复文件夹」）；同名不存在才真正创建；
  /// - 已上云且服务端仍在 → 名称不一致就改名，片单以本地为准做并集
  ///   （补服务端缺的、删服务端多出的）；
  /// - 服务端独有名非空播放列表 → 拉回本地（另一台设备新建的，保数据）；
  ///   空名 → 留给 [_deleteJunkPlaylists] 删除；
  /// - 收尾对当前服务器的收藏夹**按名字去重合并**（v2.0.16：历史同步事故产生的
  ///   本地同名重复夹收敛为一个，片单取并集，多余的服务端播放列表删除）。
  ///
  /// 所有失败都写入 [diag]（含服务端返回的具体错误），不再静默。
  Future<List<FavoriteFolder>> _reconcileUpload(
    String sid,
    List<ServerPlaylist> remote,
    List<String> diag,
  ) async {
    final s = _server!;
    final remoteById = <String, ServerPlaylist>{};
    for (final p in remote) remoteById[p.id] = p;
    // 名字 → 播放列表（非空名，先到先得）：用于按名收养，防止重复创建
    final remoteByName = <String, ServerPlaylist>{};
    for (final p in remote) {
      if (p.name.isNotEmpty && !remoteByName.containsKey(p.name)) {
        remoteByName[p.name] = p;
      }
    }
    final out = <FavoriteFolder>[];
    final matchedRemote = <String>{};

    // 在服务端（重新）创建收藏夹对应的播放列表
    Future<FavoriteFolder> createOnServer(FavoriteFolder f) async {
      final pid = await s.createPlaylist(f.name, f.itemIds);
      if (pid != null) {
        matchedRemote.add(pid);
        return f.copyWith(playlistId: pid, pendingSync: false);
      }
      diag.add('「${f.name}」创建失败：${s.lastPlaylistError}');
      return f.copyWith(pendingSync: true);
    }

    // 按名收养：服务端已有同名播放列表 → 直接绑定它（只补本地缺的片单，
    // 不删服务端多出的，避免误删另一台设备刚加入的片子），不再新建。
    Future<FavoriteFolder> adoptOrCreate(FavoriteFolder f) async {
      final p = remoteByName[f.name];
      if (p == null || matchedRemote.contains(p.id)) return createOnServer(f);
      matchedRemote.add(p.id);
      final toAdd = f.itemIds.where((e) => !p.itemIds.contains(e)).toList();
      var ok = true;
      if (toAdd.isNotEmpty && !await s.addToPlaylist(p.id, toAdd)) {
        ok = false;
        diag.add('「${f.name}」加片失败：${s.lastPlaylistError}');
      }
      return f.copyWith(playlistId: p.id, pendingSync: !ok);
    }

    for (final f in _folders) {
      // 归属其它服务器的收藏夹：原样保留，不参与本次合并
      if (f.serverId != sid) {
        out.add(f);
        continue;
      }
      // 纯本地（未上云）：先按名收养，收养不到再创建
      if (f.playlistId == null) {
        out.add(await adoptOrCreate(f));
        continue;
      }
      matchedRemote.add(f.playlistId!);
      final p = remoteById[f.playlistId];
      if (p == null) {
        // 服务端播放列表已消失 → 先按名收养同名播放列表（v2.0.16：旧逻辑
        // 直接重建，是「服务端出现两个同名播放列表」的直接来源），再退到创建
        out.add(await adoptOrCreate(f));
        continue;
      }
      // 已上云：把本地名称与片单推上去（APP 为准）
      var ok = true;
      if (p.name != f.name) {
        // v2.0.20：renamePlaylist 返回最终 Id（重建式改名会换 Id），换绑后
        // 新列表片单已按本地建好，直接跳过本轮加/移片
        final newPid = await s.renamePlaylist(
          f.playlistId!,
          f.name,
          itemIds: f.itemIds,
        );
        if (newPid == null) {
          ok = false;
          diag.add('「${f.name}」改名失败：${s.lastPlaylistError}');
        } else if (newPid != f.playlistId) {
          matchedRemote.add(newPid);
          out.add(f.copyWith(playlistId: newPid, pendingSync: false));
          continue;
        }
      }
      final serverSet = Set<String>.from(p.itemIds);
      final localSet = Set<String>.from(f.itemIds);
      final toAdd = f.itemIds.where((e) => !serverSet.contains(e)).toList();
      final toRemove = p.itemIds.where((e) => !localSet.contains(e)).toList();
      if (toAdd.isNotEmpty && !await s.addToPlaylist(f.playlistId!, toAdd)) {
        ok = false;
        diag.add('「${f.name}」加片失败：${s.lastPlaylistError}');
      }
      if (toRemove.isNotEmpty &&
          !await s.removeFromPlaylist(f.playlistId!, toRemove)) {
        ok = false;
        diag.add('「${f.name}」移片失败：${s.lastPlaylistError}');
      }
      out.add(f.copyWith(pendingSync: !ok));
    }

    // 服务端独有播放列表
    for (final p in remote) {
      if (matchedRemote.contains(p.id)) continue;
      if (p.name.isEmpty) continue; // 空名脏数据，留给统一清理
      // 非空名（多半来自另一台设备）：拉回本地，避免丢数据
      out.add(
        FavoriteFolder(
          id: 'pl_${p.id}',
          name: p.name,
          itemIds: p.itemIds,
          serverId: sid,
          playlistId: p.id,
        ),
      );
    }

    // 同名去重（v2.0.16）：历史同步 bug 会留下多个同名收藏夹（本地纯本地 +
    // 云端拉回各一份等）。合并为一个：片单按加入顺序取并集；被合并夹若绑着
    // 不同的服务端播放列表，那份多余的播放列表一并删除，保持两端一致。
    final nameIndex = <String, int>{};
    final merged = <FavoriteFolder>[];
    final dupPlaylistIds = <String>{};
    for (final f in out) {
      if (f.serverId != sid) {
        merged.add(f);
        continue;
      }
      final i = nameIndex[f.name];
      if (i == null) {
        nameIndex[f.name] = merged.length;
        merged.add(f);
        continue;
      }
      final kept = merged[i];
      final seen = Set<String>.from(kept.itemIds);
      final union = [
        ...kept.itemIds,
        ...f.itemIds.where((e) => !seen.contains(e)),
      ];
      merged[i] = kept.copyWith(itemIds: union);
      // 被合并夹绑着不同的服务端播放列表 → 多余的那份一并删除
      final pid = f.playlistId;
      if (pid != null && pid != merged[i].playlistId) {
        dupPlaylistIds.add(pid);
      }
    }
    for (final pid in dupPlaylistIds) {
      await s.deletePlaylist(pid);
    }
    return merged;
  }

  /// 删除服务端上"空名且本地无对应"的播放列表（事故脏数据清理）。
  Future<void> _deleteJunkPlaylists(
    EmbyServer s,
    List<ServerPlaylist> remote,
    String sid,
  ) async {
    final liveIds = <String>{};
    for (final f in _folders) {
      if (f.serverId == sid && f.playlistId != null) {
        liveIds.add(f.playlistId!);
      }
    }
    for (final p in remote) {
      if (p.name.isEmpty && !liveIds.contains(p.id)) {
        await s.deletePlaylist(p.id);
      }
    }
  }

  bool isPersonFavorite(String? id) =>
      id != null && _favPersons.any((e) => e.id == id);

  /// 拉取服务端收藏的演员
  Future<void> loadFavoritePersons() async {
    final s = _server;
    if (s == null || _favPersonsLoading) return;
    _favPersonsLoading = true;
    notifyListeners();
    try {
      final list = await s.favoritePersons();
      // 某些 Emby 版本不支持 Person 收藏查询（返回空），此时保留本地缓存
      if (list.isNotEmpty || _favPersons.isEmpty) _favPersons = list;
      await _saveFolders();
    } catch (_) {
      /* 离线时保留本地缓存 */
    }
    _favPersonsLoading = false;
    notifyListeners();
  }

  /// 收藏 / 取消收藏演员
  Future<void> togglePersonFavorite(CastMember p) async {
    final id = p.id;
    if (id == null) return;
    final target = !isPersonFavorite(id);
    if (_server != null) {
      try {
        await _server!.toggleFavorite(id, target);
      } catch (_) {}
    }
    _favPersons = target
        ? [..._favPersons, p]
        : _favPersons.where((e) => e.id != id).toList();
    AppHaptics.medium();
    notifyListeners();
    await _saveFolders();
  }

  /// 指定媒体库的条目（带缓存）
  Future<List<MediaItem>> itemsForView(LibraryView view) async {
    if (_server == null) return items;
    final cached = _viewCache[view.id];
    if (cached != null) return cached;
    final list = await _server!.libraryItems(view.id);
    _viewCache[view.id] = list;
    _rebuildLibraryIndex();
    _invalidateDerived();
    return list;
  }

  /// 收藏 / 取消收藏（服务端 + 本地同步）
  Future<void> toggleFavorite(MediaItem item) async {
    final target = !item.userFavorite;
    if (_server != null) {
      try {
        await _server!.toggleFavorite(item.id, target);
      } catch (_) {
        /* 服务端失败时仍更新本地状态 */
      }
    }
    _items = _items
        .map((e) => e.id == item.id ? e.copyWith(userFavorite: target) : e)
        .toList();
    if (!target) await _removeItemFromFolders(item.id);
    _invalidateDerived();
    AppHaptics.medium();
    notifyListeners();
  }

  /// 标记 / 取消标记「已看」（服务端 UserData.Played + 本地同步）
  /// v2.0.12：详情页横幅的「已看」按钮
  Future<void> togglePlayed(MediaItem item) async {
    final target = !item.userPlayed;
    if (_server != null) {
      try {
        await _server!.markPlayed(item.id, played: target);
      } catch (_) {
        /* 服务端失败时仍更新本地状态 */
      }
    }
    _items = _items
        .map((e) => e.id == item.id ? e.copyWith(userPlayed: target) : e)
        .toList();
    _invalidateDerived();
    notifyListeners();
  }

  // ---------------- 多服务器 ----------------

  List<ServerProfile> _servers = const [];
  String? _activeServerId;
  ServerKind _activeKind = ServerKind.emby;

  List<ServerProfile> get servers => _servers;
  String? get activeServerId => _activeServerId;
  ServerKind get activeKind => _activeKind;

  ServerProfile? get activeProfile {
    for (final s in _servers) {
      if (s.id == _activeServerId) return s;
    }
    return null;
  }

  Future<void> _loadServers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('servers_json');
    if (raw != null && raw.isNotEmpty) {
      try {
        _servers = (jsonDecode(raw) as List)
            .map((e) => ServerProfile.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    _activeServerId = prefs.getString('active_server');
    notifyListeners();
  }

  Future<void> _saveServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'servers_json',
      jsonEncode(_servers.map((e) => e.toJson()).toList()),
    );
    if (_activeServerId != null) {
      await prefs.setString('active_server', _activeServerId!);
    } else {
      await prefs.remove('active_server');
    }
  }

  /// 保存并连接某个服务器配置（即使连接失败也会先保存，便于稍后重试）
  Future<bool> connectProfile(ServerProfile p, {bool silent = false}) async {
    final profile = p;
    _servers = [..._servers.where((e) => e.id != profile.id), profile];
    await _saveServers();
    notifyListeners();
    final ok = await connect(
      host: profile.host,
      port: profile.port,
      secure: profile.secure,
      username: profile.username,
      password: profile.password,
      kind: profile.kind,
      ignoreSsl: profile.ignoreSsl,
      silent: silent,
    );
    if (ok) {
      _activeServerId = profile.id;
      await _saveServers();
      notifyListeners();
    }
    return ok;
  }

  /// 删除已保存的服务器（不影响当前连接，除非删的就是它）
  Future<void> deleteServer(String id) async {
    _servers = _servers.where((e) => e.id != id).toList();
    if (_activeServerId == id) _activeServerId = null;
    await _saveServers();
    notifyListeners();
  }

  /// 恢复上次保存的连接
  ///
  /// 启动时先读本地缓存，保证断网/服务器不可达时也能显示上次的图片与文字。
  Future<void> restore() async {
    await _loadCache();
    await _loadFolders();
    await _loadPendingProgress();
    await _loadPlayCount();
    await _loadWatchEvents();
    await _loadServers();
    await _loadWatchScope();
    if (_servers.isNotEmpty) {
      final active = _servers.firstWhere(
        (e) => e.id == _activeServerId,
        orElse: () => _servers.first,
      );
      _activeServerId = active.id;
      await _migrateLegacyWatchEvents();
      await connectProfile(active, silent: true);
      return;
    }
    // 兼容旧版单服务器配置：迁移成一条 profile
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('emby_host');
    if (host == null || host.isEmpty) return;
    final legacy = ServerProfile(
      id: 's${DateTime.now().microsecondsSinceEpoch}',
      name: host,
      host: host,
      port: prefs.getInt('emby_port') ?? 8096,
      secure: prefs.getBool('emby_secure') ?? false,
      username: prefs.getString('emby_user') ?? '',
      password: prefs.getString('emby_pwd') ?? '',
    );
    if (legacy.username.isEmpty) return;
    _servers = [legacy];
    _activeServerId = legacy.id;
    await _saveServers();
    await _migrateLegacyWatchEvents();
    await connectProfile(legacy, silent: true);
  }

  Future<bool> connect({
    required String host,
    required int port,
    required bool secure,
    required String username,
    required String password,
    bool silent = false,
    ServerKind kind = ServerKind.emby,
    bool ignoreSsl = false,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();
    // v2.0.87：先同步 Android 播放器原生栈的证书策略，再发任何请求。
    // v2.0.88：图片走 Dart 的另一套 HttpClient，必须同步设置，否则自签
    // HTTPS 下海报全部握手失败（文档 5.1 第 3 条）。连接失败也要同步，
    // 所以放在 try 外。
    await NativeSsl.setIgnoreCertificateErrors(ignoreSsl);
    ImageSsl.setIgnoreCertificateErrors(ignoreSsl);
    // v2.0.89：绿联资源端点 / 鉴权方式因固件而异，开启候选自适应；
    // 标准 Emby 保持单 URL，行为不变。
    ResourcePolicy.instance.ugreenMode = kind == ServerKind.ugreen;
    try {
      final server = EmbyServer(
        host: host,
        port: port,
        secure: secure,
        username: username,
        password: password,
        kind: kind,
        ignoreSsl: ignoreSsl,
      );
      await server.authenticate();
      final items = await server.items();
      if (items.isEmpty) throw EmbyException('未获取到任何媒体条目');
      // v2.0.99：换服务器时先清掉上一台的派生数据与未配对会话。
      // _loadPlayback() 是异步的，不清的话旧活动日志会顶着新 serverId
      // 混进这一台的日历；未结束的会话退出时也会记到新服务器头上。
      _activity = null;
      _activityNames = const {};
      _playedHistory = const [];
      _recentPlayedItems = const [];
      _playback = null;
      _watchSessions.clear();
      _server = server;
      // 新连上的服务器从零开始：Exo 是否可用要重新验证一次
      exoStreamUnavailable = false;
      _items = items;
      _demoMode = false;
      _offline = false;
      _userName = username;
      // v2.0.88：绿联是独立的服务器类型，进度能力按类型判定，不再靠
      // 「HTTPS + 9443」猜来源。连上就关掉服务端上报，只留本机观影日历。
      _progressSyncSupported = kind != ServerKind.ugreen;
      _loading = false;
      _invalidateDerived();
      notifyListeners();

      // v2.0.89：连上绿联后异步跑一次资源自检，找出这台 NAS 真正认的
      // 图片 / 播放模板；不阻塞连接流程，结果在「连接诊断」里可查看。
      if (kind == ServerKind.ugreen) unawaited(runResourceProbe());

      // 加载媒体库视图（电影/剧集等库分组）
      try {
        _views = await server.userViews();
      } catch (_) {
        _views = [];
      }
      _viewCache.clear();
      _previewCache.clear();
      // 切服务器时旧范围可能指向上一台服务器的库；先失效再重建索引。
      // selectedViewId 从 prefs 恢复，只在确实指向不存在的库时才清掉，
      // 不能每次启动都无脑置 null（那样「跟随媒体库选择」永远不生效）。
      if (_watchScopeId != null &&
          _watchScopeId != kWatchScopeAll &&
          !_views.any((v) => v.id == _watchScopeId)) {
        _watchScopeId = null;
        _watchScopeLoaded = false;
        unawaited(_savePrefString('watch_scope_view', null));
      }
      if (_selectedViewId != null &&
          !isVirtualViewId(_selectedViewId) &&
          !_views.any((v) => v.id == _selectedViewId)) {
        _selectedViewId = null;
      }
      _itemLibraryIndex = const {};
      _rebuildLibraryIndex();
      _ensureDefaultWatchScope();
      _invalidateDerived();
      notifyListeners();
      unawaited(_prewarmScope(effectiveWatchScopeId));
      await _saveCache();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('emby_host', host);
      await prefs.setInt('emby_port', port);
      await prefs.setBool('emby_secure', secure);
      await prefs.setString('emby_user', username);
      await prefs.setString('emby_pwd', password);
      _activeKind = kind;
      // 后台拉取播放报告（需 Playback Reporting 插件，失败静默）
      _loadPlayback();
      // 演员收藏（Person 收藏在服务端，失败静默保留本地）
      loadFavoritePersons();
      // 收藏夹：连接时只做下行合并（多设备刷新 + 重装自动恢复），绝不用
      // 本机数据覆盖服务端——否则平板一登录就把旧收藏推上去，把手机刚
      // 同步的数据冲掉。上传改由收藏页「上传」按钮显式触发。
      await downloadFoldersFromServer(overwrite: false);
      // 冲刷可能存在的待上报进度
      unawaited(flushPendingProgress());
      return true;
    } catch (e) {
      _loading = false;
      _error = e.toString();
      ResourcePolicy.instance.ugreenMode = false;
      if (!silent) notifyListeners();
      debugPrint('Emby connect failed: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('emby_host');
    await prefs.remove('emby_user');
    await prefs.remove('emby_pwd');
    // 只解除连接，已保存的服务器列表保留
    _activeServerId = null;
    await _saveServers();
    _server = null;
    // 换服务器 / 断开后，上一台的「Exo 拉不动流」结论不能再沿用
    exoStreamUnavailable = false;
    // 断开后恢复系统证书校验，别让「信任任意证书」留在进程里
    unawaited(NativeSsl.setIgnoreCertificateErrors(false));
    ImageSsl.setIgnoreCertificateErrors(false);
    ResourcePolicy.instance.reset();
    _progressSyncSupported = true;
    _items = demoLibrary;
    _views = [];
    _viewCache.clear();
    _previewCache.clear();
    _itemLibraryIndex = const {};
    _selectedViewId = null;
    _invalidateDerived();
    _demoMode = true;
    _offline = false;
    _playback = null;
    _activity = null;
    _recentPlayedItems = const [];
    _playedHistory = const [];
    _invalidateDerived();
    notifyListeners();
  }

  void useDemo() {
    _server = null;
    exoStreamUnavailable = false;
    unawaited(NativeSsl.setIgnoreCertificateErrors(false));
    ImageSsl.setIgnoreCertificateErrors(false);
    ResourcePolicy.instance.reset();
    _progressSyncSupported = true;
    _items = demoLibrary;
    _views = [];
    _viewCache.clear();
    _previewCache.clear();
    _itemLibraryIndex = const {};
    _selectedViewId = null;
    _invalidateDerived();
    _demoMode = true;
    _offline = false;
    _error = null;
    _playback = null;
    _activity = null;
    _recentPlayedItems = const [];
    _playedHistory = const [];
    _invalidateDerived();
    notifyListeners();
  }

  /// 刷新条目，返回同步到的条目数（无服务器 / 失败返回 -1）
  ///
  /// 返回数量是为了让下拉刷新能给用户一句明确反馈（「已同步 N 项」），
  /// 而不是转圈结束就悄无声息。
  Future<int> refresh() async {
    final s = _server;
    if (s == null) return -1;
    _loading = true;
    notifyListeners();
    try {
      _items = await s.items();
      _viewCache.clear();
      _previewCache.clear();
      _invalidateDerived();
      _views = await s.userViews();
      _rebuildLibraryIndex();
      _offline = false;
      await _saveCache();
      _loadPlayback();
      return _items.length;
    } catch (e) {
      _error = e.toString();
      return -1;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ---------------- 本地缓存（文字 + 列表） ----------------

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/camby_cache.json');
  }

  Future<bool> _loadCache() async {
    try {
      final f = await _cacheFile();
      if (!await f.exists()) return false;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final items = (data['items'] as List? ?? [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .toList();
      if (items.isEmpty) return false;
      _items = items;
      _views = (data['views'] as List? ?? [])
          .map((e) => LibraryView.fromJson(e as Map<String, dynamic>))
          .toList();
      _rebuildLibraryIndex();
      _previewCache.clear();
      final previews = (data['previews'] as Map?) ?? const {};
      previews.forEach((k, v) {
        _previewCache[k as String] = (v as List)
            .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
            .toList();
      });
      _demoMode = false;
      _offline = true;
      _invalidateDerived();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveCache() async {
    if (_demoMode || _items.isEmpty) return;
    try {
      final f = await _cacheFile();
      final data = <String, dynamic>{
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'items': _items.map((e) => e.toJson()).toList(),
        'views': _views.map((v) => v.toJson()).toList(),
        'previews': _previewCache.map(
          (k, v) => MapEntry(k, v.map((e) => e.toJson()).toList()),
        ),
      };
      await f.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _saveCache();
    });
  }

  // ---------------- 收藏夹 / 演员收藏 持久化 ----------------

  /// 单元测试开关：path_provider 在 flutter test 里没有实现，`await` 会一直挂起，
  /// 导致「新建收藏夹」这类依赖持久化返回值的流程永远走不到下一步。
  /// 打开后只改内存、不碰磁盘（生产代码从不设置它）。
  @visibleForTesting
  static bool disablePersistence = false;

  /// 测试专用：注入假服务端 + 当前服务器 + 初始收藏夹列表，
  /// 便于不连真实 Emby 也能驱动 syncFoldersFromServer / _reconcileUpload。
  @visibleForTesting
  void installTestServer(
    EmbyServer s,
    String sid,
    List<FavoriteFolder> folders,
  ) {
    _server = s;
    _activeServerId = sid;
    _folders = folders;
  }

  Future<File> _foldersFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/camby_folders.json');
  }

  Future<bool> _loadFolders() async {
    if (disablePersistence) return false;
    try {
      final f = await _foldersFile();
      if (!await f.exists()) return false;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _folders = (data['folders'] as List? ?? const [])
          .map((e) => FavoriteFolder.fromJson(e as Map<String, dynamic>))
          .toList();
      _favPersons = (data['persons'] as List? ?? const [])
          .map((e) => CastMember.fromJson(e as Map<String, dynamic>))
          .toList();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveFolders() async {
    if (disablePersistence) return;
    try {
      final f = await _foldersFile();
      final data = <String, dynamic>{
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'folders': _folders.map((e) => e.toJson()).toList(),
        'persons': _favPersons.map((e) => e.toJson()).toList(),
      };
      await f.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
