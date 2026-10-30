import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emby_client.dart';
import 'models.dart';

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
    final list = _items
        .where(
          (e) =>
              e.resumeProgress != null &&
              e.resumeProgress! > 0.01 &&
              e.resumeProgress! < 0.99,
        )
        // 刚看过的排最前：Emby 原生「继续观看」同样是 LastPlayedDate 倒序
        .toList()
      ..sort((a, b) => (b.lastPlayedAt ?? 0).compareTo(a.lastPlayedAt ?? 0));
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
    );
    _folders = [..._folders, f];
    notifyListeners();
    await _saveFolders();
    return f;
  }

  Future<void> renameFolder(String id, String name) async {
    final t = name.trim();
    if (t.isEmpty) return;
    _folders = _folders
        .map((f) => f.id == id ? f.copyWith(name: t) : f)
        .toList();
    notifyListeners();
    await _saveFolders();
  }

  Future<void> deleteFolder(String id) async {
    _folders = _folders.where((f) => f.id != id).toList();
    notifyListeners();
    await _saveFolders();
  }

  /// 设置某影片归属的收藏夹集合（多选）
  Future<void> setItemFolders(String itemId, Set<String> folderIds) async {
    _folders = _folders.map((f) {
      final has = f.itemIds.contains(itemId);
      final want = folderIds.contains(f.id);
      if (want && !has) {
        return f.copyWith(itemIds: [...f.itemIds, itemId]);
      }
      if (!want && has) {
        return f.copyWith(
          itemIds: f.itemIds.where((e) => e != itemId).toList(),
        );
      }
      return f;
    }).toList();
    notifyListeners();
    await _saveFolders();
  }

  Future<void> _removeItemFromFolders(String itemId) async {
    if (_folders.isEmpty) return;
    var changed = false;
    _folders = _folders.map((f) {
      if (!f.itemIds.contains(itemId)) return f;
      changed = true;
      return f.copyWith(itemIds: f.itemIds.where((e) => e != itemId).toList());
    }).toList();
    if (changed) await _saveFolders();
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

  /// 刷新条目
  Future<void> refresh() async {
    final s = _server;
    if (s == null) return;
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
    } catch (e) {
      _error = e.toString();
    }
    _loading = false;
    notifyListeners();
    _loadPlayback();
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

  Future<File> _foldersFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/camby_folders.json');
  }

  Future<bool> _loadFolders() async {
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
