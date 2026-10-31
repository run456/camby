import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emby_client.dart';
import 'models.dart';

/// 待上报进度（持久化队列用）
class _PendingProgress {
  const _PendingProgress(this.ticks, this.played);
  final int ticks;
  final bool played;
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
  String? _userName;
  List<LibraryView> _views = [];
  String? _selectedViewId;
  final Map<String, List<MediaItem>> _viewCache = {};
  final Map<String, List<MediaItem>> _previewCache = {};
  PlaybackReport? _playback;
  ActivitySummary? _activity;
  List<MediaItem> _recentPlayedItems = const [];
  bool _playbackLoading = false;

  /// 是否处于「离线（使用本地缓存）」状态
  bool _offline = false;
  Timer? _saveTimer;

  bool get offline => _offline;

  /// 播放报告（Playback Reporting 插件，失败时为 null）
  PlaybackReport? get playback => _playback;

  /// 内置活动日志聚合（无插件时的行为数据来源）
  ActivitySummary? get activity => _activity;

  /// 最近播放的条目（服务端 DatePlayed 倒序）
  List<MediaItem> get recentPlayedItems => _recentPlayedItems;
  bool get playbackLoading => _playbackLoading;

  Future<void> _loadPlayback() async {
    final s = _server;
    if (s == null) {
      _playback = null;
      _activity = null;
      _recentPlayedItems = const [];
      return;
    }
    _playbackLoading = true;
    try {
      _playback = await s.playbackReport(days: 30);
      // 内置活动日志：条目级播放次数 + 小时分布（插件不可用时兜底）
      _activity = await s.activityLog();
      // 最近播放 10 部（普通用户权限即可，用于完成率卡名单）
      _recentPlayedItems = await s.recentPlayed(limit: 10);
    } catch (_) {
      _playback = null;
      _activity = null;
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

  // 派生列表缓存：上千部影片时避免每次 build 重新排序
  List<MediaItem>? _recentCache;
  List<MediaItem>? _continueCache;
  LibraryStats? _statsCache;

  void _invalidateDerived() {
    _recentCache = null;
    _continueCache = null;
    _statsCache = null;
  }

  List<MediaItem> get items => _items;
  bool get demoMode => _demoMode;
  bool get loading => _loading;
  String? get error => _error;
  EmbyServer? get server => _server;
  List<LibraryView> get views => _views;
  String? get selectedViewId => _selectedViewId;
  String get sourceLabel =>
      _demoMode ? '演示媒体库' : '$_userName · ${_server?.host ?? ''}';

  set selectedViewId(String? v) {
    _selectedViewId = v;
    notifyListeners();
  }

  /// 数据总结：真实统计（带缓存，收藏/刷新等变更时自动失效）
  LibraryStats get stats => _statsCache ??= LibraryStats.compute(_items);

  List<MediaItem> get recentlyAdded {
    final cached = _recentCache;
    if (cached != null) return cached;
    final list = List<MediaItem>.from(_items)
      ..sort((a, b) => a.addedDaysAgo.compareTo(b.addedDaysAgo));
    _recentCache = list;
    return list;
  }

  List<MediaItem> get continueWatching {
    final cached = _continueCache;
    if (cached != null) return cached;
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
    _continueCache = list;
    return list;
  }

  List<MediaItem> get unplayed => _items
      .where((e) => e.resumeProgress == null || e.resumeProgress! < 0.01)
      .toList();

  /// 已收藏的条目
  List<MediaItem> get favorites => _items.where((e) => e.userFavorite).toList();

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
    if (s == null) return;
    final ok = await s.reportProgress(itemId, positionTicks, played: played);
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
    if (s == null || _pendingProgress.isEmpty) return;
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
            .map((e) => e.id == f.id ? e.copyWith(playlistId: pid, pendingSync: false) : e)
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
      final ok = await _server!.renamePlaylist(pid, t);
      if (!ok) {
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
          .map((e) => failedFids.contains(e.id)
              ? e.copyWith(pendingSync: true)
              : e)
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
    List<ServerPlaylist> remote;
    try {
      remote = await s.listPlaylists();
    } catch (_) {
      remote = const [];
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
    return _folders.where((f) => f.serverId == sid).length;
  }

  /// 上行模式：把本地收藏夹的状态推到服务端（APP 为准）。
  ///
  /// - 未上云（playlistId==null）→ 创建播放列表；
  /// - 已上云且服务端仍在 → 名称不一致就改名，片单以本地为准做并集
  ///   （补服务端缺的、删服务端多出的）；
  /// - 已上云但**服务端播放列表已不在**（被别处删除 / 上一版清理掉脏数据）→
  ///   **用本地名称与片单重新创建**（v1.7.69 修复：之前只标 pending 永远卡重试）；
  /// - 服务端独有名非空播放列表 → 拉回本地（另一台设备新建的，保数据）；
  ///   空名 → 留给 [_deleteJunkPlaylists] 删除。
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

    for (final f in _folders) {
      // 归属其它服务器的收藏夹：原样保留，不参与本次合并
      if (f.serverId != sid) {
        out.add(f);
        continue;
      }
      // 纯本地（未上云）：尝试创建到服务端
      if (f.playlistId == null) {
        out.add(await createOnServer(f));
        continue;
      }
      matchedRemote.add(f.playlistId!);
      final p = remoteById[f.playlistId];
      if (p == null) {
        // 服务端播放列表已消失 → 重新创建（v1.7.69：之前只标记，不重建）
        out.add(await createOnServer(f));
        continue;
      }
      // 已上云：把本地名称与片单推上去（APP 为准）
      var ok = true;
      if (p.name != f.name) {
        if (!await s.renamePlaylist(f.playlistId!, f.name)) {
          ok = false;
          diag.add('「${f.name}」改名失败：${s.lastPlaylistError}');
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
    return out;
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
    await _loadServers();
    if (_servers.isNotEmpty) {
      final active = _servers.firstWhere(
        (e) => e.id == _activeServerId,
        orElse: () => _servers.first,
      );
      _activeServerId = active.id;
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
    await _saveServers();
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
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final server = EmbyServer(
        host: host,
        port: port,
        secure: secure,
        username: username,
        password: password,
        kind: kind,
      );
      await server.authenticate();
      final items = await server.items();
      if (items.isEmpty) throw EmbyException('未获取到任何媒体条目');
      _server = server;
      _items = items;
      _demoMode = false;
      _offline = false;
      _userName = username;
      _loading = false;
      _invalidateDerived();
      notifyListeners();

      // 加载媒体库视图（电影/剧集等库分组）
      try {
        _views = await server.userViews();
      } catch (_) {
        _views = [];
      }
      _viewCache.clear();
      _previewCache.clear();
      _selectedViewId = null;
      notifyListeners();
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
      // 收藏夹与服务端播放列表双向同步（多设备同步 + 重装自动恢复）
      await syncFoldersFromServer();
      // 冲刷可能存在的待上报进度
      unawaited(flushPendingProgress());
      return true;
    } catch (e) {
      _loading = false;
      _error = e.toString();
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
    _items = demoLibrary;
    _views = [];
    _viewCache.clear();
    _previewCache.clear();
    _selectedViewId = null;
    _demoMode = true;
    _offline = false;
    _playback = null;
    _activity = null;
    _recentPlayedItems = const [];
    _invalidateDerived();
    notifyListeners();
  }

  void useDemo() {
    _server = null;
    _items = demoLibrary;
    _views = [];
    _viewCache.clear();
    _previewCache.clear();
    _selectedViewId = null;
    _demoMode = true;
    _offline = false;
    _error = null;
    _playback = null;
    _activity = null;
    _recentPlayedItems = const [];
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
