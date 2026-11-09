import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models.dart';

/// Emby REST API 客户端
/// 文档：https://<host>:<port>/emby/<endpoint>?api_key=<key>
///
/// 本类只做「连接 + 拉取」，不引入第三方依赖。
/// 真实使用时：用户输入 服务器地址 / 端口 / 协议 / 账号密码 → authenticate() 换取 AccessToken → items()

/// 所有条目查询统一携带的字段
/// 注意：Emby 的 /Items 默认只返回精简字段，Overview / Tags 等必须显式声明
// Path 供播放信息与 NFO 兜底使用；v2.0.63 起「系列」主线改读服务端合集，
// 不再依赖影片文件路径。
const _kItemFields =
    'Genres,People,UserData,MediaStreams,MediaSources,Overview,DateCreated,'
    'CommunityRating,ProductionYear,RunTimeTicks,PremiereDate,OfficialRating,'
    'Tags,TagItems,Studios,SeriesName,Path';

/// 服务端「合集 / BoxSet」的精简信息（v2.0.63）。
///
/// Emby 把 NFO 的 `<set><name>` 建成独立的 BoxSet 对象，而不是 Movie 上的
/// 一个字段；电影的 `SeriesName` 因此永远为空。网页端详情页的「所属合集」
/// 区块展示的就是这类对象。
class BoxSetInfo {
  const BoxSetInfo({
    required this.id,
    required this.name,
    this.childCount = 0,
  });

  final String id;
  final String name;
  final int childCount;
}

class EmbyServer {
  EmbyServer({
    required this.host,
    required this.port,
    required this.secure,
    required this.username,
    this.password = '',
    this.kind = ServerKind.emby,
  });

  final String host;
  final int port;
  final bool secure;
  final String username;
  final String password;

  /// Emby / Jellyfin：仅影响基础路径与少量接口差异
  final ServerKind kind;

  String? _token;
  String? _userId;

  bool get isConnected => _token != null;

  /// 当前会话令牌；NFO / 字幕等走服务端代理端点时要用。
  String? get token => _token;

  String get baseUrl =>
      '${secure ? 'https' : 'http'}://$host:$port${kind == ServerKind.jellyfin ? '' : '/emby'}';

  /// 把服务器返回的相对地址补成绝对地址。
  ///
  /// Emby/Jellyfin 的 `DeliveryUrl` 有时是 `/Videos/...` 这样的站内相对路径，
  /// 直接交给下载器会解析失败，必须先拼上主机。
  String _absolutize(String u) {
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    final origin = '${secure ? 'https' : 'http'}://$host:$port';
    final path = u.startsWith('/') ? u : '/$u';
    // 服务器已经带了 /emby 前缀时直接拼 origin，避免出现 /emby/emby
    if (path.startsWith('/emby/')) return '$origin$path';
    final prefix = kind == ServerKind.jellyfin ? '' : '/emby';
    return '$origin$prefix$path';
  }

  /// 认证：POST /Users/AuthenticateByName
  ///
  /// 兼容性要点（缺任一都会报 400 "Value cannot be null. (Parameter 'name）"）：
  /// 1. 旧版 Emby 只认 X-Emby-Authorization 头
  /// 2. Jellyfin 12 / 新版 Emby 默认禁用旧头，只认标准 Authorization 头
  /// 3. 部分版本还会从 URL query 读取 X-Emby-Client 等参数
  /// 因此这里三种方式同时发送。
  Future<void> authenticate() async {
    final uri = Uri.parse('$baseUrl/Users/AuthenticateByName').replace(
      queryParameters: const {
        'X-Emby-Client': 'Camby',
        'X-Emby-Device-Name': 'Camby',
        'X-Emby-Device-Id': 'camby01',
        'X-Emby-Client-Version': '1.0.0',
      },
    );
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    try {
      // 第一轮：JSON body（官方标准方式）
      var res = await _sendAuth(
        client,
        uri,
        jsonEncode({'Username': username, 'Pw': password}),
        ContentType.json,
      );
      // 兜底：部分 Emby 版本（如 4.9 beta）对 JSON body 解析异常，改用表单编码重试
      if (res.statusCode == 400) {
        res = await _sendAuth(
          client,
          uri,
          'Username=${Uri.encodeQueryComponent(username)}'
          '&Pw=${Uri.encodeQueryComponent(password)}',
          ContentType.parse('application/x-www-form-urlencoded'),
        );
      }
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw EmbyException('登录失败 (${res.statusCode})：$body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      _token = json['AccessToken'] as String?;
      _userId = (json['User'] as Map<String, dynamic>?)?['Id'] as String?;
      if (_token == null || _userId == null) {
        throw EmbyException('服务端未返回令牌');
      }
    } finally {
      client.close();
    }
  }

  Future<HttpClientResponse> _sendAuth(
    HttpClient client,
    Uri uri,
    String body,
    ContentType contentType,
  ) async {
    const auth =
        'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", '
        'Version="1.0.0"';
    final req = await client.postUrl(uri);
    req.headers.contentType = contentType;
    req.headers.set('X-Emby-Authorization', auth);
    req.headers.set('Authorization', auth);
    req.write(body);
    return req.close();
  }

  /// 拉取媒体库条目：GET /Users/{userId}/Items
  /// 分页拉取（每页 500）直到 TotalRecordCount 拉满，支持上千部影片的库
  Future<List<MediaItem>> items({
    List<String> types = const ['Movie', 'Series'],
  }) async {
    if (_token == null || _userId == null) {
      throw EmbyException('请先登录');
    }
    const pageSize = 500;
    final all = <MediaItem>[];
    var start = 0;
    var total = 1 << 30;
    while (start < total && start < 10000) {
      final json = await _getJson(
        '$baseUrl/Users/$_userId/Items',
        query: {
          'Recursive': 'true',
          'IncludeItemTypes': types.join(','),
          'Fields': _kItemFields,
          'SortBy': 'DateCreated,SortName',
          'SortOrder': 'Descending',
          'StartIndex': '$start',
          'Limit': '$pageSize',
        },
      );
      total = (json['TotalRecordCount'] as int?) ?? all.length;
      final list = (json['Items'] as List<dynamic>? ?? []);
      if (list.isEmpty) break;
      all.addAll(list.map((e) => _fromJson(e as Map<String, dynamic>)));
      start += list.length;
      if (list.length < pageSize) break;
    }
    return all;
  }

  /// 拼接图片地址
  String imageUrl(
    String itemId, {
    String type = 'Primary',
    int maxWidth = 400,
  }) =>
      '$baseUrl/Items/$itemId/Images/$type?maxWidth=$maxWidth&api_key=$_token';

  /// 播放地址
  /// direct=true  → 直连原片（省服务端资源，适合客户端能解码的容器）
  /// direct=false → HLS 自适应流（兼容性最好）
  String streamUrl(String itemId, {String? mediaSourceId, bool direct = true}) {
    final ms = mediaSourceId != null ? '&MediaSourceId=$mediaSourceId' : '';
    return direct
        ? '$baseUrl/Videos/$itemId/stream?Static=true$ms&api_key=$_token'
        : '$baseUrl/Videos/$itemId/master.m3u8$ms&api_key=$_token';
  }

  /// 从文件名推断分辨率高度（2160 / 1080 / 720 / 576 / 480 …）。
  ///
  /// 部分自建库的 MediaStreams 缺失（刮削失败、strm、NFO 导入），Height 会
  /// 落到兜底值 1080，媒体库筛选「4K」就永远筛不到这些片。这里在读媒体流信息
  /// 之前先兜一遍文件名：只要名字里带 `Movie.2160p.WEB-DL` 这类标记就采信。
  /// 返回 null 表示名字里没有可靠标记，仍走 MediaStreams / 默认值。
  /// v2.0.69：实现抽到 [heightFromName]（models.dart）共享，避免与主条目解析漂移。
  static int? _heightFromName(String name) => heightFromName(name);

  /// 测试入口：文件名 → 分辨率兜底推断（实现见 [heightFromName]）
  @visibleForTesting
  static int? heightFromNameForTest(String name) => heightFromName(name);

  /// 写回播放进度（1.7.38 新增，1.7.65 强化）
  ///
  /// Emby 有两条写进度的官方路线：
  /// 1. `Sessions/Playing` + `/Progress` + `/Stopped` —— 会话型，需要维护
  ///    会话生命周期，顺便把播放状态挂到服务器 dashboard 上；
  /// 2. `/Users/{UserId}/Items/{ItemId}/UserData` —— 直接改条目的 UserData，
  ///    一次请求同时更新 PlaybackPositionTicks。
  ///
  /// APK 的 `libapp.so` 里只有 `/Users/` + `/Items/` + `/UserData` 这三个
  /// 插值片段、没有任何 `Sessions` / `Playing/` 字面量，因此 1.7.38 走的是
  /// 第 2 条。
  ///
  /// 1.7.65 升级：
  /// - [played] 为 true 时额外写 `Played` 字段，让服务端「已看完」状态与本地一致
  ///   （之前从不标 Played，导致「另一台手机看不到已看记录」）；
  /// - 瞬时网络错误（Wi-Fi/数据切换、锁屏唤醒）自动重试一次，不再被静默吞掉；
  /// - 返回是否成功，供调用方决定是否进入重试队列（跨会话兜底）。
  Future<bool> reportProgress(
    String itemId,
    int positionTicks, {
    bool played = false,
  }) async {
    final uid = _userId;
    if (_token == null || uid == null) return false;
    final body = <String, dynamic>{
      'ItemId': itemId,
      'PlaybackPositionTicks': positionTicks,
      if (played) 'Played': true,
    };
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _postJson('$baseUrl/Users/$uid/Items/$itemId/UserData', body);
        return true;
      } catch (e) {
        // 瞬时网络错误重试一次（GET 同样的处理），其余失败直接以 false 收场
        if (attempt == 0 && _isTransientNetworkError(e)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        return false;
      }
    }
    return false;
  }

  /// 标记 / 取消标记「已看」（v2.0.12：详情页横幅的「已看」操作）。
  /// 走与 reportProgress 相同的 UserData 直写端点，只写 Played 字段。
  Future<bool> markPlayed(String itemId, {required bool played}) async {
    final uid = _userId;
    if (_token == null || uid == null) return false;
    final body = <String, dynamic>{'ItemId': itemId, 'Played': played};
    try {
      await _postJson('$baseUrl/Users/$uid/Items/$itemId/UserData', body);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 带鉴权头 + 忽略自签证书的 JSON POST（仅上报进度使用）
  ///
  /// 与旧实现的关键差异：**校验 HTTP 状态码**。旧版 `await res.drain()` 把
  /// 500/503 也当成「成功」，于是服务端实际没写进进度、App 却以为写好了 ——
  /// 正是「另一台手机没记录」的隐性根因之一。现在非 2xx 直接抛异常，让重试
  /// 与状态上报能真正生效。
  Future<void> _postJson(String url, Map<String, dynamic> body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set(
        'Authorization',
        'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", Version="1.0.0", Token="$_token"',
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        await res.drain();
        throw EmbyException('上报播放进度失败 (${res.statusCode})');
      }
      await res.drain();
    } finally {
      client.close();
    }
  }

  // ---------------- 会话型播放上报（v1.7.73） ----------------
  //
  // 统计页「每日观看时长 / 播放时段 / 常看作品」的数据源是服务器活动日志
  // （/System/ActivityLog/Entries），只有**会话型播放**（网页端、TV 端等）
  // 才会写入。此前本 APP 只走 UserData 直写，活动日志里根本没有本 APP 的
  // 播放事件 —— 1.7.72 按账号过滤后统计页全空，根因即此。
  //
  // 现在起播 / 心跳 / 退出时补发标准会话事件，APP 播放从此与其他客户端
  // 一样进入活动日志（带本账号 UserId），统计页数据真实且只属于本人。
  // 全部尽力而为（失败静默），不影响播放本身，也不进重试队列。

  /// 起播时上报（POST /Sessions/Playing）
  ///
  /// 必须带上 `PlaySessionId` 与**当前续播位置**：
  /// - 不带 PlaySessionId 时，部分 Emby 版本会直接 400（参数不能为空），
  ///   而旧实现把异常静默吞掉 → 活动日志里始终没有 APP 的记录；
  /// - 不带 PositionTicks 时按 0 处理，会把服务端已有续播位置**重置为 0**，
  ///   导致「继续观看」在别的设备上消失。
  Future<void> reportPlaybackStart(
    String itemId, {
    int positionTicks = 0,
  }) async {
    _playSessionId = 'camby_${DateTime.now().microsecondsSinceEpoch}';
    _sessionItemId = itemId;
    await _postSession(
      itemId,
      'Playing',
      label: '开始播放上报',
      extra: {
        'PositionTicks': positionTicks,
        'PlayMethod': 'DirectPlay',
        'CanSeek': true,
      },
    );
  }

  /// 播放中心跳（POST /Sessions/Playing/Progress）
  Future<void> reportPlaybackProgress(
    String itemId,
    int positionTicks, {
    bool paused = false,
  }) async {
    // 会话还没建立（例如起播事件丢失）时补发一次 Playing，避免服务端
    // 收到孤立心跳而忽略；PlaySessionId 保持一致才能算同一段播放。
    if (_playSessionId == null) {
      await reportPlaybackStart(itemId, positionTicks: positionTicks);
    }
    await _postSession(
      itemId,
      'Playing/Progress',
      label: '播放进度上报',
      extra: {
        'PositionTicks': positionTicks,
        'IsPaused': paused,
        'CanSeek': true,
      },
    );
  }

  /// 退出播放时上报（POST /Sessions/Stopped）
  Future<void> reportPlaybackStop(
    String itemId,
    int positionTicks, {
    bool played = false,
  }) async {
    // 停止事件依赖已建立的会话：没有 PlaySessionId 时服务端会直接忽略，
    // 活动日志里就只剩「开始」没有「停止」，观看时长永远算不出来。
    if (_playSessionId == null) {
      await reportPlaybackStart(itemId, positionTicks: positionTicks);
    }
    await _postSession(
      itemId,
      'Stopped',
      label: '停止播放上报',
      extra: {'PositionTicks': positionTicks, if (played) 'Played': true},
    );
    _playSessionId = null;
    _sessionItemId = null;
  }

  /// 会话事件的统一发送：**先按 query 发，再按 JSON body 兜底**。
  ///
  /// v2.0.2：Emby 10.9 起这些接口用 `[FromQuery]` 绑定模型，只认 query 参数，
  /// body JSON 会被忽略 → ItemId 为空 → 大概率 400/204 但不落活动日志
  /// （和 addToPlaylist 踩的是同一个坑）。Jellyfin 与旧版 Emby 则习惯 body。
  /// 两种都试一遍，任一成功即算成功，并把失败原因写进 [lastSessionError]。
  Future<void> _postSession(
    String itemId,
    String action, {
    required String label,
    required Map<String, dynamic> extra,
  }) async {
    final path = '$baseUrl/Sessions/$action';
    final errors = <String>[];

    // ① query 形态（Emby 10.9+）
    try {
      await _postQueryReturning(path, {
        'ItemId': itemId,
        if (_playSessionId != null) 'PlaySessionId': _playSessionId!,
        ...extra.map((k, v) => MapEntry(k, '$v')),
      });
      lastSessionError = '';
      return;
    } catch (e) {
      errors.add('query: $e');
    }

    // ② body 形态（Jellyfin / 旧版 Emby）
    try {
      await _postJson(path, {
        'ItemId': itemId,
        if (_playSessionId != null) 'PlaySessionId': _playSessionId,
        ...extra,
      });
      lastSessionError = '';
      return;
    } catch (e) {
      errors.add('body: $e');
    }

    lastSessionError = '$label失败（${errors.join(' / ')}）';
    debugPrint('$label failed: ${errors.join(' / ')}');
  }

  /// 会话最后一拍的兜底：应用退出 / 播放页被系统回收时也要把 Stopped 发出去，
  /// 否则活动日志里只有「开始播放」，统计页的观看时长永远配不上对。
  Future<void> flushPlaybackStop(
    int positionTicks, {
    bool played = false,
  }) async {
    final id = _sessionItemId;
    if (id == null || _playSessionId == null) return;
    await reportPlaybackStop(id, positionTicks, played: played);
  }

  /// 带鉴权头的 JSON POST，并返回解码后的响应体（播放列表等写操作后拿回 Id）
  Future<Map<String, dynamic>> _postJsonReturning(
    String url,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set(
        'Authorization',
        'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", Version="1.0.0", Token="$_token"',
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw EmbyException('请求失败 (${res.statusCode})');
      }
      if (text.isEmpty) return const {};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  static String _overviewOf(Map<String, dynamic> j) {
    final raw = (j['Overview'] as String?)?.trim() ?? '';
    return raw.isEmpty ? '暂无简介' : raw;
  }

  MediaItem _fromJson(Map<String, dynamic> j) {
    final userData = (j['UserData'] as Map<String, dynamic>?) ?? {};
    final streams = (j['MediaStreams'] as List<dynamic>? ?? []);
    String videoCodec = 'H264';
    String audioCodec = 'AAC';
    int channels = 2;
    int height = 1080;
    bool heightFound = false;
    bool hdr = false;
    for (final s in streams) {
      final m = s as Map<String, dynamic>;
      final t = m['Type'] as String?;
      if (t == 'Video') {
        videoCodec = (m['Codec'] as String? ?? videoCodec).toUpperCase();
        final h = (m['Height'] as num?)?.toInt() ?? 0;
        if (h > 0) {
          height = h;
          heightFound = true;
        }
        final range = m['VideoRangeType'] as String?;
        hdr = range == 'HDR10' || range == 'DOVI';
      } else if (t == 'Audio') {
        audioCodec = m['Codec'] as String? ?? audioCodec;
        channels = (m['Channels'] as int?) ?? channels;
      }
    }
    // MediaStreams 里没有有效 Height（刮削失败 / strm / NFO 导入的条目很常见）：
    // 退一步从文件名认 `xxx.2160p.WEB-DL` 这类标记。名字里也认不出才用兜底 1080，
    // 否则媒体库按 4K 筛选会永远漏掉这一批片子。
    if (!heightFound) {
      final h = _heightFromName(
        (j['Path'] as String?) ?? (j['Name'] as String?) ?? '',
      );
      if (h != null) {
        height = h;
        heightFound = true;
      }
    }
    final genres = (j['Genres'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    // 标签（对应 NFO 的 <tag></tag>）
    // Emby 部分版本 Fields=Tags 时 Tags 是空数组，真实数据放在 TagItems（对象数组 {Name}）
    final tags = <String>[];
    void addTag(Object? v) {
      final t = (v ?? '').toString().trim();
      if (t.isNotEmpty && !tags.contains(t)) tags.add(t);
    }

    for (final e in (j['Tags'] as List<dynamic>? ?? const [])) {
      addTag(e);
    }
    if (tags.isEmpty) {
      for (final e in (j['TagItems'] as List<dynamic>? ?? const [])) {
        if (e is Map) {
          addTag(e['Name']);
        } else {
          addTag(e);
        }
      }
    }
    final peopleRaw = (j['People'] as List<dynamic>? ?? []);
    final people = <CastMember>[];
    String director = '';
    for (final p in peopleRaw.take(12)) {
      final m = p as Map<String, dynamic>;
      final role = m['Type'] as String?;
      final name = m['Name'] as String? ?? '';
      if (role == 'Director') {
        director = name;
        continue;
      }
      if (role == 'Actor' || role == 'GuestStar') {
        people.add(
          CastMember(
            name: name,
            role: m['Role'] as String? ?? '',
            id: m['Id'] as String?,
            imageTag: m['PrimaryImageTag'] as String?,
            // G4：标准 Emby 无性别字段，只有服务端明确给了 Gender/Sex 才认，
            // 归一不了就是 null，UI 走中性，绝不猜。
            gender: normalizeGender(m['Gender'] ?? m['Sex']),
          ),
        );
      }
    }
    final studios = (j['Studios'] as List<dynamic>? ?? []);
    final studio = studios.isEmpty
        ? ''
        : (((studios.first as Map<String, dynamic>)['Name'] as String?) ?? '');
    final id = j['Id'] as String? ?? '';

    // 字幕轨：Type=Subtitle 的媒体流
    final subtitles = <SubtitleTrackInfo>[];
    // Emby 的 MediaSourceId：字幕路由带上它才算「精确指定来源」，
    // 无此参数的部分服务器版本会直接 404
    final sourceId =
        (j['MediaSources'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((e) => e['Id'] as String?)
            .firstWhere((e) => e != null && e.isNotEmpty, orElse: () => null) ??
        id;
    for (final s in streams) {
      final m = s as Map<String, dynamic>;
      if (m['Type'] != 'Subtitle') continue;
      final idx = (m['Index'] as num?)?.toInt() ?? 0;
      final codec = ((m['Codec'] as String?) ?? 'srt').toLowerCase();
      final fmt = (codec.contains('ass') || codec.contains('ssa'))
          ? 'ass'
          : (codec.contains('vtt') ? 'vtt' : 'srt');

      // ---- 字幕地址五级候选（v1.7.22 起草，v1.7.25 补齐） ----
      // 各版本 Emby 的字幕提取路由不统一，而且 strm 片源经常只有其中一条能通，
      // 所以这里一次性把所有能想到的路径按可靠性排序列出来，交给 Subtitles.load 逐个试。
      //   1) DeliveryUrl —— 服务器自己给的，最权威
      //   2) /Videos/{id}/{srcId}/Subtitles/{idx}/0/Stream.ext —— 标准路由（带 0 段）
      //   3) 同上去掉 0 段 —— 少数 Emby 版本只认这条
      //   4) /Videos/{id}/Subtitles/{idx}/Stream.ext —— 旧路由
      //   5) /Items/{id}/File?Path=… —— 文件直取，strm 的保底路径
      final delivery =
          ((m['DeliveryUrl'] as String?) ??
                  (m['SubtitleDeliveryUrl'] as String?) ??
                  '')
              .trim();
      final subPath = ((m['Path'] as String?) ?? '').trim();
      final stdRoute =
          '$baseUrl/Videos/$id/$sourceId/Subtitles/$idx/'
          '0/Stream.$fmt?api_key=$_token';
      final noZeroRoute =
          '$baseUrl/Videos/$id/$sourceId/Subtitles/$idx/'
          'Stream.$fmt?api_key=$_token';
      final oldRoute =
          '$baseUrl/Videos/$id/Subtitles/$idx/'
          'Stream.$fmt?api_key=$_token';
      final fileRoute = subPath.isEmpty
          ? ''
          : '$baseUrl/Items/$id/File'
                '?Path=${Uri.encodeQueryComponent(subPath)}&api_key=$_token';

      final ordered = <String>[
        if (delivery.isNotEmpty) _absolutize(delivery),
        stdRoute,
        noZeroRoute,
        oldRoute,
        if (fileRoute.isNotEmpty) fileRoute,
      ];
      // 去重但保持优先级：Set 会打乱顺序，这里手工过滤
      final seen = <String>{};
      final uniq = <String>[
        for (final u in ordered)
          if (u.isNotEmpty && seen.add(u)) u,
      ];
      subtitles.add(
        SubtitleTrackInfo(
          index: idx,
          language: ((m['Language'] as String?) ?? '').trim(),
          displayTitle: ((m['DisplayTitle'] ?? m['Title'] ?? '') as String)
              .trim(),
          codec: codec,
          isDefault: m['IsDefault'] as bool? ?? false,
          isForced: m['IsForced'] as bool? ?? false,
          url: uniq.first,
          altUrls: uniq.skip(1).toList(growable: false),
          sourcePath: subPath,
        ),
      );
    }

    final imageData = (j['ImageTags'] as Map<String, dynamic>?) ?? {};
    final backdropTags = (j['BackdropImageTags'] as List<dynamic>? ?? []);
    // 文件信息：MediaSources[0] 的路径/大小/封装格式（服务器未开放 Path 时为空）
    final sources = (j['MediaSources'] as List<dynamic>? ?? const []);
    final ms0 = sources.isNotEmpty
        ? sources.first as Map<String, dynamic>
        : <String, dynamic>{};
    final msPath = (ms0['Path'] as String?) ?? '';
    // v2.0.62：顶层 Path 与 MediaSources[0].Path 都试一遍。Emby 对非管理员
    // 常隐藏后者但保留前者；两者都空时 NFO 候选为空，系列只能停在「无」。
    final itemPath = (j['Path'] as String?) ?? '';
    final effectivePath = itemPath.trim().isNotEmpty ? itemPath : msPath;
    final msSize = (ms0['Size'] as num?)?.toInt() ?? 0;
    final msContainer =
        ((ms0['Container'] as String?) ?? (j['Container'] as String?) ?? '')
            .trim();
    final String? posterTag = imageData['Primary'] as String?;
    final backdrops = <String>[
      for (var i = 0; i < backdropTags.length; i++)
        '$baseUrl/Items/$id/Images/Backdrop/$i?maxWidth=1280&api_key=$_token&tag=${backdropTags[i]}',
    ];
    // 远程预告片（Emby RemoteTrailers，多为 YouTube 外链）
    final remoteTrailers =
        (j['RemoteTrailers'] as List<dynamic>? ?? const []);
    final trailerUrls = <String>[
      for (final t in remoteTrailers)
        if (t is Map && (t['Url'] as String?)?.isNotEmpty == true)
          t['Url'] as String,
    ];
    // 额外部分：同一影片的其余 MediaSource（-Cd1/-Cd2 分段、多版本等）。
    // Emby 网页版把「主版本以外的来源」列成「额外部分」。批量 /Items 列表
    // 常只回主版本，详情页会再用 mediaSources() 补一次单条详情，这里先按
    // 列表已带的数据解析（没有就不加）。解析逻辑见 [_extraPartsFromSources]。
    final extraParts = _extraPartsFromSources(sources);
    return MediaItem(
      id: id,
      name: j['Name'] as String? ?? '未命名',
      type: (j['Type'] as String?) == 'Series'
          ? MediaType.series
          : MediaType.movie,
      overview: _overviewOf(j),
      colors: _colorsFor(id),
      year: j['ProductionYear'] as int? ?? 0,
      rating: ((j['CommunityRating'] as num?) ?? 0).toDouble(),
      runtimeMin: (((j['RunTimeTicks'] as int?) ?? 0) / 600000000).round(),
      genres: genres,
      people: people,
      tags: tags,
      subtitles: subtitles,
      studio: studio,
      director: director,
      videoHeight: height,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      audioChannels: channels,
      container: msContainer.isNotEmpty ? msContainer.toUpperCase() : 'MKV',
      isHdr: hdr,
      hasDolbyVision:
          audioCodec.contains('TrueHD') || audioCodec.contains('ATMOS'),
      seriesId: j['SeriesId'] as String?,
      seasonNumber: j['ParentIndexNumber'] as int?,
      episodeNumber: j['IndexNumber'] as int?,
      posterAspect:
          (j['PrimaryImageAspectRatio'] as num?)?.toDouble() ?? 0.6667,
      posterUrl: posterTag != null
          ? '$baseUrl/Items/$id/Images/Primary?maxWidth=800&api_key=$_token&tag=$posterTag'
          : null,
      backdropUrl: backdrops.isNotEmpty ? backdrops.first : null,
      backdrops: backdrops,
      trailerUrls: trailerUrls,
      extraParts: extraParts,
      resolutionKnown: heightFound,
      videoUrl: '$baseUrl/Videos/$id/stream?Static=true&api_key=$_token',
      addedDaysAgo: _addedDays(j['DateCreated'] as String?),
      filePath: effectivePath,
      fileSizeBytes: msSize,
      dateCreatedMs: DateTime.tryParse(j['DateCreated'] as String? ?? '')
          ?.millisecondsSinceEpoch,
      // 发行日期：Emby 给 ISO8601（2021-12-23T00:00:00.0000000Z），
      // 这里只截到「YYYY-MM-DD」供详情页信息区展示
      premiereDate: _dateOnly(j['PremiereDate'] as String?),
      seriesName: (j['SeriesName'] as String?) ?? '',
      userPlayCount: (userData['PlayCount'] as int?) ?? 0,
      userPlayed: userData['Played'] == true,
      userFavorite: userData['IsFavorite'] == true,
      lastPlayedAt: _parseDate(userData['LastPlayedDate'] as String?),
      resumeProgress: _resumeProgress(
        userData,
        (j['RunTimeTicks'] as int?) ?? 0,
      ),
      resumeSeconds: _resumeSeconds(userData),
    );
  }

  /// 把 Emby 的 ISO8601 日期截成 `YYYY-MM-DD`。
  ///
  /// Emby 常见形态：`2021-12-23T00:00:00.0000000Z`。直接 `substring(0,10)`
  /// 比 `DateTime.parse` 稳（后者遇到 7 位小数秒会抛异常）。形态不对时原样返回。
  static String _dateOnly(String? iso) {
    final s = (iso ?? '').trim();
    if (s.length < 10) return '';
    final head = s.substring(0, 10);
    // 只接受 2021-12-23 这种形态，防止把别的字符串误截
    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(head) ? head : '';
  }

  /// 上次播放位置（秒）：PlaybackPositionTicks 以 100ns 为单位
  static double? _resumeSeconds(Map<String, dynamic> userData) {
    final pos = (userData['PlaybackPositionTicks'] as int?) ?? 0;
    if (pos <= 0) return null;
    final sec = pos / 10000000.0;
    return sec < 5 ? null : sec;
  }

  static int? _parseDate(String? iso) {
    if (iso == null) return null;
    return DateTime.tryParse(iso)?.millisecondsSinceEpoch;
  }

  /// 媒体库列表：GET /Users/{id}/Views
  ///
  /// 「合集 / BoxSets」是虚拟聚合库，首页不展示。
  /// v2.0.21：收藏夹同步出的「播放列表」视图（collectionType=playlists）
  /// 同样不是媒体库，首页一并隐藏。
  /// 名称判断只对 collectionType 缺失的库生效，避免误伤名字里带「合集」的正常库。
  Future<List<LibraryView>> userViews() async {
    final json = await _getJson('$baseUrl/Users/$_userId/Views');
    final list = (json['Items'] as List<dynamic>? ?? []);
    return list
        .map((e) {
          final m = e as Map<String, dynamic>;
          final imageTags = (m['ImageTags'] as Map<String, dynamic>? ?? {});
          return LibraryView(
            id: m['Id'] as String? ?? '',
            name: m['Name'] as String? ?? '',
            collectionType: m['CollectionType'] as String?,
            imageTag: imageTags['Primary'] as String?,
          );
        })
        .where((v) {
          final t = (v.collectionType ?? '').toLowerCase();
          if (t == 'boxsets' || t == 'collections' || t == 'playlists') {
            return false;
          }
          if (v.collectionType == null || v.collectionType!.isEmpty) {
            final n = v.name.trim();
            final ln = n.toLowerCase();
            if (n == '合集' ||
                n.endsWith('合集') ||
                n == '播放列表' ||
                ln == 'collections' ||
                ln == 'boxsets' ||
                ln == 'box sets' ||
                ln == 'playlists') {
              return false;
            }
          }
          return true;
        })
        .toList();
  }

  /// 指定媒体库内的条目（分页拉全量）
  Future<List<MediaItem>> libraryItems(
    String viewId, {
    String sortBy = 'DateCreated',
  }) async {
    const pageSize = 500;
    final all = <MediaItem>[];
    var start = 0;
    var total = 1 << 30;
    while (start < total && start < 10000) {
      final json = await _getJson(
        '$baseUrl/Users/$_userId/Items',
        query: {
          'ParentId': viewId,
          'Recursive': 'true',
          'IncludeItemTypes': 'Movie,Series',
          'Fields': _kItemFields,
          'SortBy': sortBy,
          'SortOrder': 'Descending',
          'StartIndex': '$start',
          'Limit': '$pageSize',
        },
      );
      total = (json['TotalRecordCount'] as int?) ?? all.length;
      final list = (json['Items'] as List<dynamic>? ?? []);
      if (list.isEmpty) {
        // 兜底：文件夹/混合库里的条目可能不是 Movie/Series 类型，
        // 第一次（带 IncludeItemTypes）拉不到时，去掉类型过滤再拉一次
        if (start == 0 && all.isEmpty) {
          final retry = await _getJson(
            '$baseUrl/Users/$_userId/Items',
            query: {
              'ParentId': viewId,
              'Recursive': 'true',
              'ExcludeItemTypes': 'Folder,Year,Genre',
              'Fields': _kItemFields,
              'SortBy': sortBy,
              'SortOrder': 'Descending',
              'StartIndex': '$start',
              'Limit': '$pageSize',
            },
          );
          final rlist = (retry['Items'] as List<dynamic>? ?? []);
          if (rlist.isEmpty) break;
          all.addAll(_parseItems(retry));
          start += rlist.length;
          if (rlist.length < pageSize) break;
          continue;
        }
        break;
      }
      all.addAll(_parseItems(json));
      start += list.length;
      if (list.length < pageSize) break;
    }
    return all;
  }

  /// 媒体库预览（单页，供首页按库分组行使用，避免拉全量）
  Future<List<MediaItem>> libraryPreview(
    String viewId, {
    int limit = 12,
  }) async {
    Future<List<MediaItem>> fetch(Map<String, String> extra) async {
      final json = await _getJson(
        '$baseUrl/Users/$_userId/Items',
        query: {
          'ParentId': viewId,
          'Recursive': 'true',
          'Fields': _kItemFields,
          'SortBy': 'DateCreated',
          'SortOrder': 'Descending',
          'Limit': '$limit',
          ...extra,
        },
      );
      return _parseItems(json);
    }

    final list = await fetch(const {'IncludeItemTypes': 'Movie,Series'});
    if (list.isNotEmpty) return list;
    // 兜底：文件夹/混合库里的条目可能不是 Movie/Series 类型（如 Video/Folder），
    // 去掉类型过滤再试一次，避免首页整行「暂无内容」
    return fetch(const {'ExcludeItemTypes': 'Folder,Year,Genre'});
  }

  /// 相似推荐（服务端基于标签/演职员/类型关联）
  Future<List<MediaItem>> similar(String itemId) async {
    final json = await _getJson(
      '$baseUrl/Items/$itemId/Similar',
      query: {'UserId': _userId!, 'Limit': '12', 'Fields': _kItemFields},
    );
    return _parseItems(json);
  }

  /// 某演员的作品
  Future<List<MediaItem>> personItems(String personId) async {
    final json = await _getJson(
      '$baseUrl/Users/$_userId/Items',
      query: {
        'PersonIds': personId,
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series',
        'Fields': _kItemFields,
        'SortBy': 'ProductionYear,SortName',
        'SortOrder': 'Descending',
        'Limit': '500',
      },
    );
    return _parseItems(json);
  }

  // ---------------------------------------------------------------------------
  // v2.0.63：服务端合集（BoxSet）—— 电影「系列」的真正来源
  //
  // 网页端影片详情「所属合集」用的就是 [boxSetNamesForItem] 里那条
  // `ListItemIds` 查询。前两版直读 .nfo 属于绕远路：服务器只有本地路径、
  // 没有可用的 sidecar 代理，候选必然全部超时。
  // ---------------------------------------------------------------------------

  /// 列出服务器上所有合集。
  Future<List<BoxSetInfo>> allBoxSets() async {
    final json = await _getJson(
      '$baseUrl/Users/$_userId/Items',
      query: {
        'IncludeItemTypes': 'BoxSet',
        'Recursive': 'true',
        'Fields': 'Name,ChildCount,RecursiveItemCount',
        'SortBy': 'SortName',
        'Limit': '2000',
      },
    );
    final items = json['Items'] as List<dynamic>? ?? const <dynamic>[];
    final out = <BoxSetInfo>[];
    for (final m in items) {
      if (m is! Map<String, dynamic>) continue;
      final id = m['Id']?.toString() ?? '';
      final name = (m['Name'] as String? ?? '').trim();
      if (id.isEmpty || name.isEmpty) continue;
      final count = (m['ChildCount'] as num?)?.toInt() ??
          (m['RecursiveItemCount'] as num?)?.toInt() ??
          0;
      out.add(BoxSetInfo(id: id, name: name, childCount: count));
    }
    return out;
  }

  /// 某个合集内的影片 Id（`ParentId` 查询）。
  ///
  /// 注意：部分 Emby 版本对 BoxSet 的 ParentId 查询不返回成员，此时
  /// [BoxSetSeriesSync] 会自动降级到 [boxSetNamesForItem] 逐条反查。
  Future<List<String>> boxSetMemberIds(String boxSetId) async {
    final json = await _getJson(
      '$baseUrl/Users/$_userId/Items',
      query: {
        'ParentId': boxSetId,
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series',
        'Fields': 'Name',
        'Limit': '2000',
      },
    );
    final items = json['Items'] as List<dynamic>? ?? const <dynamic>[];
    return <String>[
      for (final m in items)
        if (m is Map<String, dynamic>) m['Id']?.toString() ?? '',
    ].where((s) => s.isNotEmpty).toList();
  }

  /// 反查单部影片所属的合集名。
  ///
  /// `ListItemIds` 是 Emby 网页客户端在「所属合集」区块使用的查询参数：
  /// `Users/{uid}/Items?IncludeItemTypes=BoxSet&Recursive=true&ListItemIds={id}`。
  /// 未加入任何合集、或服务端不支持该参数时返回空列表。
  Future<List<String>> boxSetNamesForItem(String itemId) async {
    final json = await _getJson(
      '$baseUrl/Users/$_userId/Items',
      query: {
        'IncludeItemTypes': 'BoxSet',
        'Recursive': 'true',
        'ListItemIds': itemId,
        'Fields': 'Name',
        'Limit': '50',
      },
    );
    final items = json['Items'] as List<dynamic>? ?? const <dynamic>[];
    final out = <String>[];
    for (final m in items) {
      if (m is! Map<String, dynamic>) continue;
      final n = (m['Name'] as String? ?? '').trim();
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }
    return out;
  }

  /// 单条详情（详情页「刷新」用）
  Future<MediaItem?> itemDetail(String itemId) async {
    try {
      final json = await _getJson(
        '$baseUrl/Users/$_userId/Items/$itemId',
        query: {'Fields': _kItemFields},
      );
      return _fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// 演员详情（简介、出生日期），失败返回 null 不影响页面
  Future<Map<String, dynamic>?> personDetails(String personId) async {
    try {
      return await _getJson('$baseUrl/Users/$_userId/Items/$personId');
    } catch (_) {
      return null;
    }
  }

  /// 剧集的分集列表
  Future<List<MediaItem>> episodes(String seriesId) async {
    final json = await _getJson(
      '$baseUrl/Shows/$seriesId/Episodes',
      query: {'UserId': _userId!, 'Fields': _kItemFields},
    );
    final eps = _parseItems(json);
    return eps.map((e) {
      // 分集统一标记为 Episode 类型
      return MediaItem(
        id: e.id,
        name: e.name,
        type: MediaType.episode,
        overview: e.overview,
        colors: e.colors,
        year: e.year,
        rating: e.rating,
        runtimeMin: e.runtimeMin,
        genres: e.genres,
        people: e.people,
        tags: e.tags,
        director: e.director,
        videoHeight: e.videoHeight,
        videoCodec: e.videoCodec,
        audioCodec: e.audioCodec,
        audioChannels: e.audioChannels,
        container: e.container,
        isHdr: e.isHdr,
        hasDolbyVision: e.hasDolbyVision,
        resumeProgress: e.resumeProgress,
        resumeSeconds: e.resumeSeconds,
        episodeTitle: e.episodeTitle,
        seasonNumber: e.seasonNumber,
        episodeNumber: e.episodeNumber,
        seriesId: e.seriesId,
        videoUrl: e.videoUrl,
        posterUrl: e.posterUrl,
        backdropUrl: e.backdropUrl,
        addedDaysAgo: e.addedDaysAgo,
        userPlayCount: e.userPlayCount,
        userPlayed: e.userPlayed,
        userFavorite: e.userFavorite,
        lastPlayedAt: e.lastPlayedAt,
      );
    }).toList();
  }

  /// 构造请求 URI：**保留 path 里已内嵌的查询参数**，再叠加显式 [query]，
  /// 最后补 token。
  ///
  /// 旧实现用 `Uri.parse(path).replace(queryParameters: qp)`，会把内嵌的
  /// `?ParentId=..&Recursive=true` 整体覆盖掉，导致过滤条件静默失效
  /// （v2.0.34 修正）。抽成方法便于单测回归。
  @visibleForTesting
  static Uri buildRequestUri(
    String path,
    Map<String, String>? query,
    String token,
  ) {
    final base = Uri.parse(path);
    final qp = <String, String>{
      ...base.queryParameters,
      ...?query,
      'X-Emby-Token': token,
    };
    return base.replace(queryParameters: qp);
  }

  /// 判断一个子条目是否是「本地预告片」。
  ///
  /// Emby 对本地 trailer 文件的识别结果有两种形态：`Type=Trailer`，或
  /// `Type=Video` + `ExtraType=Trailer`；放在 `trailer/` 子目录时路径里也带
  /// `trailer`。任一命中即视为预告片。抽成静态方法便于单测。
  @visibleForTesting
  static bool looksLikeTrailer(Map<String, dynamic> j) {    final type = ((j['Type'] as String?) ?? '').toLowerCase();
    final extra = ((j['ExtraType'] as String?) ?? '').toLowerCase();
    if (extra == 'trailer' || type == 'trailer') return true;
    // 路径 / 名称 / 媒体源路径任一含 trailer（覆盖 trailer(s)/ 子目录、
    // 以及服务端不回 Path 但 Name 或 MediaSources.Path 带 trailer 的情况）
    final path = ((j['Path'] as String?) ?? '').toLowerCase();
    final name = ((j['Name'] as String?) ?? '').toLowerCase();
    if (path.contains('trailer') || name.contains('trailer')) return true;
    final sources = j['MediaSources'];
    if (sources is List) {
      for (final s in sources) {
        if (s is Map) {
          final p = ((s['Path'] as String?) ?? '').toLowerCase();
          if (p.contains('trailer')) return true;
        }
      }
    }
    return false;
  }

  /// 把 Emby 的 `MediaSources` 列表解析为「非主版本的额外分段」。
  ///
  /// 规律：第一条（或 `Index` 最小、`Id` 与 `MediaSources[0]` 相同）是主版本，
  /// 其余（`-Cd2`、`-Cd3`、另一个分辨率版本…）才是「额外部分」。列表不足 2
  /// 条视为「没有分段」，返回空。抽成静态方法便于 [_fromJson] 与
  /// [mediaSources] / 诊断共用，避免三处逻辑漂移。
  static List<MediaExtraPart> _extraPartsFromSources(dynamic raw) {
    final sources = raw is List ? raw : const <dynamic>[];
    if (sources.length <= 1) return const [];
    final list = sources.whereType<Map<String, dynamic>>().toList()
      ..sort(
        (a, b) => ((a['Index'] as num?)?.toInt() ?? 0).compareTo(
          (b['Index'] as num?)?.toInt() ?? 0,
        ),
      );
    final primaryId = (list.first['Id'] as String?) ?? '';
    final out = <MediaExtraPart>[];
    for (final s in list) {
      final sid = (s['Id'] as String?) ?? '';
      if (sid == primaryId) continue; // 主版本
      final part = MediaExtraPart.fromJson(s);
      if (part != null) out.add(part);
    }
    return out;
  }

  /// 预告片候选入口清单。
  ///
  /// 服务端实现差异极大：标准 Emby、Jellyfin，以及各种兼容实现（会出现纯数字
  /// 条目 id、`/emby` 前缀只转发部分路由等情况）。与其猜哪条路通，不如把所有
  /// 「可能取到预告片」的入口都列出来逐个试，命中即用：
  /// 1. `/Items/{id}/LocalTrailers`、`/Items/{id}/Trailer`、`/Items/{id}/SpecialFeatures`
  /// 2. 老版本 Emby 的用户级路径 `/Users/{uid}/Items/{id}/LocalTrailers`
  /// 3. 子项查询（`ParentId` × `Recursive=false/true`），`/Users/{uid}/Items`
  ///    与 `/Items` 两种写法都试
  ///
  /// 每条都同时试「带 /emby 前缀」与「站点根路径」——不少服务端的 `/emby`
  /// 只是部分路由的别名，专用端点只在根路径下通。
  List<_TrailerProbe> _trailerProbes(String itemId) {
    final origin = '${secure ? 'https' : 'http'}://$host:$port';
    final bases = <String>[baseUrl];
    if (origin != baseUrl) bases.add(origin);
    const childFields = 'Path,ExtraType,MediaSources,MediaStreams,Overview';
    final probes = <_TrailerProbe>[];
    for (final b in bases) {
      final tag = b == baseUrl ? '' : '[根] ';
      probes
        ..add(_TrailerProbe(
          '${tag}Items/{id}/LocalTrailers',
          '$b/Items/$itemId/LocalTrailers',
        ))
        ..add(_TrailerProbe(
          '${tag}Items/{id}/Trailer',
          '$b/Items/$itemId/Trailer',
        ))
        ..add(_TrailerProbe(
          '${tag}Items/{id}/SpecialFeatures',
          '$b/Items/$itemId/SpecialFeatures',
          filter: true,
        ))
        ..add(_TrailerProbe(
          '${tag}Users/{uid}/Items/{id}/LocalTrailers',
          '$b/Users/$_userId/Items/$itemId/LocalTrailers',
        ))
        ..add(_TrailerProbe(
          '${tag}Users/{uid}/Items/{id}/SpecialFeatures',
          '$b/Users/$_userId/Items/$itemId/SpecialFeatures',
          filter: true,
        ));
      for (final rec in const ['false', 'true']) {
        probes
          ..add(_TrailerProbe(
            '${tag}子项 Users/Items Recursive=$rec',
            '$b/Users/$_userId/Items',
            query: {
              'ParentId': itemId,
              'Recursive': rec,
              'Fields': childFields,
            },
            filter: true,
          ))
          ..add(_TrailerProbe(
            '${tag}子项 Items Recursive=$rec',
            '$b/Items',
            query: {
              'ParentId': itemId,
              'Recursive': rec,
              'userId': _userId!,
              'Fields': childFields,
            },
            filter: true,
          ));
      }
    }
    return probes;
  }

  /// 容错解析任意形态的响应：裸数组 / `{Items:[...]}` / 单个条目 DTO。
  ///
  /// [filterTrailer] 为 true 时只保留「看起来像预告片」的条目（花絮集合与
  /// 子项查询用；专用 Trailer/LocalTrailers 端点则整批信任）。
  List<MediaItem> _parseAnyItems(
    dynamic resp, {
    bool filterTrailer = false,
    bool excludeTrailer = false,
    String excludeId = '',
  }) {
    final res = <MediaItem>[];
    for (final e in _rawItems(resp)) {
      if (excludeId.isNotEmpty && (e['Id'] as String?) == excludeId) continue;
      final isTrailer = looksLikeTrailer(e);
      if (filterTrailer && !isTrailer) continue;
      if (excludeTrailer && isTrailer) continue;
      try {
        res.add(_fromJson(e));
      } catch (_) {/* 跳过脏数据 */}
    }
    return res;
  }

  /// 把任意形态的响应摊平成条目 Map 列表（裸数组 / `{Items:[...]}` / 单条目）。
  List<Map<String, dynamic>> _rawItems(dynamic resp) {
    final List<dynamic> raw = resp is List
        ? resp
        : resp is Map
        ? ((resp['Items'] as List<dynamic>?) ??
              (resp['Id'] == null ? const [] : [resp]))
        : const [];
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  /// 跑单个候选入口。任何异常（404 / 超时 / 脏数据）都退化为空列表。
  ///
  /// 单条 3s 硬超时：候选入口有十几条，若某条把连接挂住，不能让它把详情页
  /// 的预告片区块一起拖住。
  Future<List<MediaItem>> _runProbe(
    _TrailerProbe p, {
    String excludeId = '',
  }) async {
    try {
      final resp = await _getJsonAny(
        p.path,
        query: {...?p.query, 'api_key': _token!},
      ).timeout(const Duration(seconds: 3));
      return _parseAnyItems(
        resp,
        filterTrailer: p.filter,
        excludeTrailer: p.excludeTrailer,
        excludeId: excludeId,
      );
    } catch (_) {
      return const <MediaItem>[];
    }
  }

  /// 全库扫 `Trailer` / `Video`，按影片所在目录前缀过滤。
  ///
  /// Emby 的 `/Items` **忽略 `PathStartsWith`**（实测传了仍返回全库），所以只能
  /// 把库里的 Trailer（通常很少）拉回来在客户端比路径；没有再退回 Video。
  Future<List<MediaItem>> _libraryTrailers(String movieDir) async {
    if (movieDir.isEmpty) return const <MediaItem>[];
    final prefix = movieDir.toLowerCase();
    for (final types in const ['Trailer', 'Video']) {
      try {
        final resp = await _getJsonAny(
          '$baseUrl/Items',
          query: {
            'userId': _userId!,
            'Recursive': 'true',
            'IncludeItemTypes': types,
            'Fields': 'Path,ExtraType',
          },
        );
        final hits = _parseAnyItems(resp, filterTrailer: true)
            .where((e) => e.filePath.toLowerCase().startsWith(prefix))
            .toList();
        if (hits.isNotEmpty) return hits;
      } catch (_) {/* 该类型查询失败，退下一个 */}
    }
    return const <MediaItem>[];
  }

  /// 影片的预告片（本地文件 / 远程外链来源均可）。
  ///
  /// 策略：按 [_trailerProbes] 逐个入口探测，命中即停；全部落空且服务端自称
  /// `LocalTrailerCount > 0` 时，退化为「全库扫 Trailer/Video + 按影片目录
  /// 前缀筛」。任何一步失败都只退化为空，绝不抛异常。
  Future<List<MediaItem>> trailers(
    String itemId, {
    bool includeLocalChildren = true,
  }) async {
    final out = <MediaItem>[];
    final seen = <String>{};

    // 详情一次取回：Path（推导目录）+ LocalTrailerCount（权威信号）。
    // 同时试 `Fields=LocalTrailers`：部分服务端会把预告片子条目直接内嵌在
    // 条目 DTO 里，这是唯一「不用额外端点」就能拿到 id 的途径。
    var localTrailerCount = 0;
    var movieDir = '';
    try {
      final item = await _getJson(
        '$baseUrl/Users/$_userId/Items/$itemId',
        query: {
          'Fields':
              'Path,ParentId,LocalTrailerCount,LocalTrailers,RemoteTrailers',
        },
      );
      localTrailerCount = (item['LocalTrailerCount'] as num?)?.toInt() ?? 0;
      final path = (item['Path'] as String?) ?? '';
      final sep = path.contains('\\') ? '\\' : '/';
      final idx = path.lastIndexOf(sep);
      // 保留结尾分隔符，避免 ABP-01 误配 ABP-018
      if (idx > 0) movieDir = path.substring(0, idx + 1);
      // 内嵌的预告片 DTO（有就先用，id 直接可播）
      final embedded = item['LocalTrailers'];
      if (embedded is List) {
        for (final e in embedded) {
          if (e is Map<String, dynamic>) {
            try {
              final m = _fromJson(e);
              if (m.id.isNotEmpty && seen.add(m.id)) out.add(m);
            } catch (_) {/* 跳过脏数据 */}
          }
        }
      }
    } catch (_) {/* 详情拿不到就只靠入口探测 */}
    if (out.isNotEmpty) return out;

    for (final p in _trailerProbes(itemId)) {
      if (!includeLocalChildren && p.filter) continue;
      for (final e in await _runProbe(p)) {
        if (e.id.isNotEmpty && seen.add(e.id)) out.add(e);
      }
      if (out.isNotEmpty) break; // 命中即停，不再浪费请求
    }

    if (out.isEmpty && includeLocalChildren && localTrailerCount > 0) {
      for (final e in await _libraryTrailers(movieDir)) {
        if (e.id.isNotEmpty && seen.add(e.id)) out.add(e);
      }
    }
    return out;
  }

  /// 「额外部分」候选入口。
  ///
  /// Emby 的「额外部分」有两种来源，两种都要覆盖：
  /// 1. **同一影片的多个 MediaSource**（`-Cd1/-Cd2` 被识别成同一部的分段）——
  ///    由 `MediaItem.extraParts` 承载，不在这里查；
  /// 2. **独立子条目**（分段/花絮被扫成 Extra，`ParentId` 指向本片）——
  ///    网页版的「额外部分」就是列这些，走 `/Items/{id}/SpecialFeatures`
  ///    或子项查询。
  ///
  /// 端点与 `/emby` 前缀的差异和预告片一样大，所以同样两套 baseUrl 都试。
  List<_TrailerProbe> _extraProbes(String itemId) {
    final origin = '${secure ? 'https' : 'http'}://$host:$port';
    final bases = <String>[baseUrl];
    if (origin != baseUrl) bases.add(origin);
    const childFields = 'Path,ExtraType,MediaSources,MediaStreams,'
        'Overview,RunTimeTicks';
    final probes = <_TrailerProbe>[];
    for (final b in bases) {
      final tag = b == baseUrl ? '' : '[根] ';
      probes
        // Emby 官方的「附加内容」接口：网页版详情页「附加媒体」就是取它。
        // 分段（-cd1/-cd2）若被服务端登记成 AdditionalPart，只有这里能拿到，
        // 而 MediaSources / SpecialFeatures 都可能是空的。
        ..add(_TrailerProbe(
          '${tag}Videos/{id}/AdditionalParts',
          '$b/Videos/$itemId/AdditionalParts',
          query: {'Fields': childFields},
          excludeTrailer: true,
        ))
        ..add(_TrailerProbe(
          '${tag}Items/{id}/AdditionalParts',
          '$b/Items/$itemId/AdditionalParts',
          query: {'Fields': childFields},
          excludeTrailer: true,
        ))
        ..add(_TrailerProbe(
          '${tag}Items/{id}/SpecialFeatures',
          '$b/Items/$itemId/SpecialFeatures',
          excludeTrailer: true,
        ))
        ..add(_TrailerProbe(
          '${tag}Users/{uid}/Items/{id}/SpecialFeatures',
          '$b/Users/$_userId/Items/$itemId/SpecialFeatures',
          excludeTrailer: true,
        ));
      for (final rec in const ['false', 'true']) {
        probes
          ..add(_TrailerProbe(
            '${tag}子项 Users/Items Recursive=$rec',
            '$b/Users/$_userId/Items',
            query: {
              'ParentId': itemId,
              'Recursive': rec,
              'Fields': childFields,
            },
            excludeTrailer: true,
          ))
          ..add(_TrailerProbe(
            '${tag}子项 Items Recursive=$rec',
            '$b/Items',
            query: {
              'ParentId': itemId,
              'Recursive': rec,
              'userId': _userId!,
              'Fields': childFields,
            },
            excludeTrailer: true,
          ));
      }
    }
    return probes;
  }

  /// 影片的「额外部分」：分段 / 花絮等**独立子条目**。
  ///
  /// 只负责第 2 类来源；第 1 类（同一条目的多个 MediaSource）由
  /// `MediaItem.extraParts` 承载，详情页会把两者合并展示。
  /// 预告片会被排除（它们出现在「预告片」栏目）。
  Future<List<MediaItem>> extraParts(String itemId) async {
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final p in _extraProbes(itemId)) {
      for (final e in await _runProbe(p, excludeId: itemId)) {
        if (e.id.isNotEmpty && seen.add(e.id)) out.add(e);
      }
      if (out.isNotEmpty) break; // 命中即停
    }
    if (out.isNotEmpty) return out;

    // 兜底：按影片所在目录前缀全库反查。
    // 这条路不依赖「子条目关系」——只要文件被扫进库，且物理上跟正片同目录，
    // 就能捞到（跳过影片自身与预告片，预告片归「预告片」栏目）。
    //
    // ⚠️ 不能用 `ChildCount == 0` 当闸门：`-cd1`/`-cd2` 这种分段影片，两个文件
    // 属于**同一个条目**，ChildCount 天然就是 0，闸门一卡整条兜底永远不跑——
    // 这正是 15607 一直取不到 cd2 的原因。改为只看目录前缀（精确到影片所在
    // 文件夹，前缀命中率极低，全库扫一次开销可接受），且仅在没有其它来源时跑。
    final (dir, _) = await _movieDirInfo(itemId);
    if (dir.isEmpty) return out;
    final prefix = dir.toLowerCase();
    try {
      final resp = await _getJsonAny(
        '$baseUrl/Items',
        query: {
          'userId': _userId!,
          'Recursive': 'true',
          'IncludeItemTypes': 'Video,Movie,Episode,MusicVideo',
          'Fields': 'Path,ExtraType,MediaSources,MediaStreams,RunTimeTicks',
        },
      ).timeout(const Duration(seconds: 10));
      for (final e in _rawItems(resp)) {
        if (looksLikeTrailer(e)) continue;
        final id = (e['Id'] as String?) ?? '';
        if (id.isEmpty || id == itemId || seen.contains(id)) continue;
        // 路径必须落在**同一个影片文件夹**里（前缀含结尾分隔符），
        // 防止 ABP-01 误配 ABP-018 之类的同级串味
        final p = ((e['Path'] as String?) ?? '').toLowerCase();
        if (!p.startsWith(prefix)) continue;
        try {
          final m = _fromJson(e);
          if (seen.add(m.id)) out.add(m);
        } catch (_) {/* 跳过脏数据 */}
      }
    } catch (_) {/* 全库扫描不可用，返回已拿到的 */}
    return out;
  }

  /// 影片的「分段」（同一影片的多个 MediaSource，`-Cd1`/`-Cd2`）。
  ///
  /// 与 [extraParts]（独立子条目）是一条影片「额外部分」的两类互补来源：
  /// 分段是**同一个 Emby 条目**下的多个媒体源；子条目是被扫成独立 Extra 的
  /// 分段/花絮（走 [extraParts]）。
  ///
  /// Emby 在批量 `/Items` 列表查询里常常只回「主版本」那一条 MediaSource，
  /// 完整的多分段只有单条详情 `/Users/{uid}/Items/{id}` 才给全。详情页用这条
  /// 方法补一次单条详情，保证能列出 cd2 及后续分段（网页版能切、App 之前不显
  /// 示的根因即此）。任何失败都退化为空列表。
  Future<List<MediaExtraPart>> mediaSources(String itemId) async {
    try {
      final item = await _getJson(
        '$baseUrl/Users/$_userId/Items/$itemId',
        query: {'Fields': 'MediaSources,MediaStreams,RunTimeTicks'},
      );
      return _extraPartsFromSources(item['MediaSources']);
    } catch (_) {
      return const [];
    }
  }

  /// 把 Emby `MediaSources` **完整**解析为版本列表（含主版本，v2.0.65）。
  ///
  /// 与 [_extraPartsFromSources] 的区别：那个只给「额外部分」（跳过主版本），
  /// 这个按 `Index` 排序后全量返回，并把第一条标记为 `isPrimary`。
  /// 抽成公开静态方法是为了让守卫测试能直接喂 JSON，不依赖网络。
  static List<MediaExtraPart> versionsFromSources(dynamic raw) {
    final sources = raw is List ? raw : const <dynamic>[];
    final list = sources.whereType<Map<String, dynamic>>().toList()
      ..sort(
        (a, b) => ((a['Index'] as num?)?.toInt() ?? 0).compareTo(
          (b['Index'] as num?)?.toInt() ?? 0,
        ),
      );
    final out = <MediaExtraPart>[];
    for (var i = 0; i < list.length; i++) {
      final part = MediaExtraPart.fromJson(list[i]);
      if (part != null) out.add(part.copyWith(isPrimary: i == 0));
    }
    return out;
  }

  /// 影片的「版本」列表（Emby 网页端详情页那个 `版本 UHD · 20.31 GB` 下拉）。
  ///
  /// Emby 把同一部片的多个文件（4K / 1080p / 不同压制）合并成**一个 Item
  /// 下的多个 MediaSource**；批量 `/Items` 查询往往只回主版本，完整列表必须
  /// 走单条详情。这里一次请求同时供「版本选择器」与「额外部分」使用：
  /// 详情页拿到结果后按 `isPrimary` 拆成两份，避免为同一份数据发两次请求。
  ///
  /// 少于 2 条时调用方不渲染选择器（单版本没有可切换的东西）。
  /// 任何失败静默返回空列表，不影响原有详情页。
  Future<List<MediaExtraPart>> mediaVersions(String itemId) async {
    try {
      final item = await _getJson(
        '$baseUrl/Users/$_userId/Items/$itemId',
        query: {'Fields': 'MediaSources,MediaStreams,RunTimeTicks,Path'},
      );
      return versionsFromSources(item['MediaSources']);
    } catch (_) {
      return const <MediaExtraPart>[];
    }
  }

  /// 影片所在目录（**带结尾分隔符**，避免 ABP-01 误配 ABP-018）+ 子条目数。
  ///
  /// `childCount` 为 0 表示服务端明确说「没有子条目」；拿不到详情时返回
  /// `('', 0)`，调用方据此跳过全库扫描。
  Future<(String, int)> _movieDirInfo(String itemId) async {
    try {
      final item = await _getJson(
        '$baseUrl/Users/$_userId/Items/$itemId',
        query: {'Fields': 'Path,ChildCount'},
      );
      final path = (item['Path'] as String?) ?? '';
      final sep = path.contains('\\') ? '\\' : '/';
      final idx = path.lastIndexOf(sep);
      final dir = idx > 0 ? path.substring(0, idx + 1) : '';
      // ChildCount 缺省时按 -1（未知）处理，避免误判成「没有子条目」
      final cc = (item['ChildCount'] as num?)?.toInt() ?? -1;
      return (dir, cc);
    } catch (_) {/* 读不到就当没有 */}
    return ('', 0);
  }

  /// 预告片抓取诊断：逐条列出每个候选入口的真实结果，供详情页展示。
  Future<List<String>> trailerDiag(String itemId) async {
    final log = <String>[];
    // ── 分段（同一影片的 MediaSources：-Cd1/-Cd2）──
    // 放在最前面：这是「额外部分」最常见的一类来源，而且只依赖单条详情，
    // 不受下面 SpecialFeatures/子项一堆 404 的干扰。若这里是 0 条，说明服务端
    // 根本没把 cd2 作为 MediaSource 返回，App 侧无从显示，需另找入口。
    try {
      final item = await _getJson(
        '$baseUrl/Users/$_userId/Items/$itemId',
        query: {'Fields': 'MediaSources,MediaStreams,RunTimeTicks,Path'},
      ).timeout(const Duration(seconds: 4));
      final raws = (item['MediaSources'] as List<dynamic>?) ?? const [];
      final parts = _extraPartsFromSources(raws);
      log.add('[分段] MediaSources=${raws.length} 条 · 额外分段 ${parts.length} 个');
      for (final p in parts.take(6)) {
        log.add('    • ${p.name} | ${p.path}');
      }
    } on EmbyException catch (e) {
      log.add('[分段] 读取失败: ${e.message}');
    } catch (e) {
      log.add('[分段] 读取失败: $e');
    }

    try {
      final item = await _getJson(
        '$baseUrl/Users/$_userId/Items/$itemId',
        query: {
          'Fields':
              'Path,LocalTrailerCount,RemoteTrailerCount,RemoteTrailers,'
              'LocalTrailers',
        },
      );
      log.add(
        'LocalTrailerCount=${item['LocalTrailerCount'] ?? '-'} · '
        'RemoteTrailerCount=${item['RemoteTrailerCount'] ?? '-'}\n'
        '内嵌 LocalTrailers=${(item['LocalTrailers'] as List?)?.length ?? 0} 条\n'
        'Path=${item['Path'] ?? '-'}',
      );
    } catch (e) {
      log.add('详情读取失败: $e');
    }

    var hitLabel = '';
    for (final p in _trailerProbes(itemId)) {
      try {
        final resp = await _getJsonAny(
          p.path,
          query: {...?p.query, 'api_key': _token!},
        ).timeout(const Duration(seconds: 4));
        final int total = resp is List
            ? resp.length
            : resp is Map
            ? ((resp['Items'] as List<dynamic>?)?.length ??
                  (resp['Id'] == null ? 0 : 1))
            : 0;
        final items = _parseAnyItems(resp, filterTrailer: p.filter);
        log.add(
          '${items.isNotEmpty ? '✅' : '·'} ${p.label} · $total 项 · 命中 ${items.length}',
        );
        if (items.isNotEmpty) {
          if (hitLabel.isEmpty) hitLabel = p.label;
          for (final e in items.take(2)) {
            log.add('    • ${e.name} | ${e.filePath}');
          }
        }
      } on EmbyException catch (e) {
        log.add('· ${p.label} · ${e.message}');
      } catch (e) {
        log.add('· ${p.label} · ${e.runtimeType}');
      }
    }
    log.add(hitLabel.isEmpty ? '❌ 所有入口均未取到预告片' : '✅ 可用入口: $hitLabel');

    // 额外部分（分段/花絮）探测：与预告片同一套思路，单独一段
    var extraLabel = '';
    for (final p in _extraProbes(itemId)) {
      try {
        final resp = await _getJsonAny(
          p.path,
          query: {...?p.query, 'api_key': _token!},
        ).timeout(const Duration(seconds: 4));
        final raws = _rawItems(
          resp,
        ).where((e) => (e['Id'] as String?) != itemId).toList();
        final got = _parseAnyItems(
          resp,
          excludeTrailer: true,
          excludeId: itemId,
        );
        log.add(
          '${got.isNotEmpty ? '✅' : '·'} [额外] ${p.label} · ${raws.length} 项 · 命中 ${got.length}',
        );
        if (got.isNotEmpty) {
          if (extraLabel.isEmpty) extraLabel = p.label;
          for (final e in got.take(2)) {
            log.add('    • ${e.name} | ${e.filePath}');
          }
        }
      } on EmbyException catch (e) {
        log.add('· [额外] ${p.label} · ${e.message}');
      } catch (e) {
        log.add('· [额外] ${p.label} · ${e.runtimeType}');
      }
    }
    log.add(extraLabel.isEmpty ? '❌ 额外部分：所有入口均未取到' : '✅ 额外部分可用入口: $extraLabel');

    // ── [同目录] 全库反查：和正片同一个文件夹里的其它视频 ──
    // 分段（-cd2）无论被服务端存成 AdditionalPart、Extra 还是独立条目，
    // 只要文件进了库就一定落在这里。这一段最能一锤定音。
    try {
      final (dir, _) = await _movieDirInfo(itemId).timeout(
        const Duration(seconds: 4),
      );
      if (dir.isEmpty) {
        log.add('[同目录] 读取影片路径失败，跳过');
      } else {
        final resp = await _getJsonAny(
          '$baseUrl/Items',
          query: {
            'userId': _userId!,
            'Recursive': 'true',
            'IncludeItemTypes': 'Video,Movie,Episode,MusicVideo',
            'Fields': 'Path,ExtraType,Name',
          },
        ).timeout(const Duration(seconds: 12));
        final prefix = dir.toLowerCase();
        final sibs = _rawItems(resp).where((e) {
          final id = (e['Id'] as String?) ?? '';
          if (id.isEmpty || id == itemId) return false;
          final p = ((e['Path'] as String?) ?? '').toLowerCase();
          return p.startsWith(prefix);
        }).toList();
        log.add('[同目录] $dir → 其它视频 ${sibs.length} 个');
        for (final e in sibs.take(8)) {
          final type = (e['Type'] as String?) ?? '-';
          final extra = (e['ExtraType'] as String?) ?? '';
          log.add(
            '    • ${e['Name'] ?? '-'} [$type${extra.isEmpty ? '' : '/$extra'}] '
            '| ${e['Path'] ?? '-'}',
          );
        }
      }
    } on EmbyException catch (e) {
      log.add('[同目录] 读取失败: ${e.message}');
    } catch (e) {
      log.add('[同目录] 读取失败: $e');
    }
    return log;
  }

  /// 收藏 / 取消收藏
  Future<bool> toggleFavorite(String itemId, bool favorite) async {
    final path = favorite ? 'FavoriteItems' : 'FavoriteItems/Delete';
    final method = favorite ? 'POST' : 'DELETE';
    await _request(
      '$baseUrl/Users/$_userId/$path/$itemId?X-Emby-Token=$_token',
      method: method,
    );
    return favorite;
  }

  /// 收藏的演员（Emby 中 Person 也可被收藏）
  /// 不同 Emby 版本参数支持不一致，做两次探测：
  /// 1) Filters=IsFavorite  2) IsFavorite=true
  Future<List<CastMember>> favoritePersons() async {
    Future<List<CastMember>> query(Map<String, String> extra) async {
      final json = await _getJson(
        '$baseUrl/Users/$_userId/Items',
        query: {
          'Recursive': 'true',
          'IncludeItemTypes': 'Person',
          'Fields': 'PrimaryImageAspectRatio',
          'Limit': '300',
          ...extra,
        },
      );
      final raw = json['Items'] as List? ?? const [];
      return raw
          .map((e) {
            final m = e as Map<String, dynamic>;
            final tags = m['ImageTags'] as Map<String, dynamic>?;
            return CastMember(
              name: m['Name'] as String? ?? '',
              role: m['Role'] as String? ?? '',
              id: m['Id'] as String?,
              imageTag: tags?['Primary'] as String?,
              gender: normalizeGender(m['Gender'] ?? m['Sex']),
            );
          })
          .where((e) => e.id != null && e.name.isNotEmpty)
          .toList();
    }

    try {
      var list = await query({'Filters': 'IsFavorite'});
      if (list.isEmpty) list = await query({'IsFavorite': 'true'});
      return list;
    } catch (_) {
      return const [];
    }
  }

  // ---------------- 收藏夹 ↔ 服务端播放列表（v1.7.65） ----------------
  //
  // Emby 没有「收藏夹」概念，最接近的是 **Playlist（播放列表）**：网页端可见、
  // 可重命名、随账号存在于服务端，换设备/重装登录后自动回来。因此 App 把自建
  // 收藏夹映射到服务端 Playlist，实现多设备同步 + 自动恢复。
  //
  // 各版本 Emby 的播放列表路由不完全一致（/Playlists 与 /Users/{uid}/Playlists
  // 两种基址、/Items 与 /Items/Add 两种追加路由），这里逐个端点探测，任一环节
  // 失败都**静默回退为「仅本地收藏夹」**，绝不影响正常播放。

  /// 最近一次播放列表操作（创建/改名/增删条目）的失败原因。
  /// 空字符串 = 没有失败或未发生过操作。同步流程读取它给用户提示（v1.7.69）。
  String lastPlaylistError = '';

  /// 最近一次活动日志统计的账号匹配诊断（v2.0）。
  /// 形如「日志播放 128 条，本账号 128 条」；匹配为 0 时统计页空态会原样展示，
  /// 便于确认是权限、日志保留期还是账号格式问题。
  String lastActivityDiag = '';

  /// 最近一次会话型播放上报的失败原因（v2.0.1）。
  /// 空字符串 = 没有失败。会话事件是尽力而为的，但失败要让用户看得见，
  /// 否则又会出现「活动日志里没有 APP 记录」却无从排查的情况。
  String lastSessionError = '';

  /// 本次播放的会话 Id（Emby 用它把 Start/Progress/Stop 串成同一次播放）
  String? _playSessionId;

  /// 当前会话正在播的条目 Id（Stopped 事件与应用退出时的兜底上报用）
  String? _sessionItemId;

  /// 创建播放列表，返回服务端 Id（失败返回 null，具体原因见 [lastPlaylistError]）
  ///
  /// v1.7.68 关键修正：**Emby 创建播放列表的参数在 URL query 上，不在 JSON body**。
  /// 之前把 `Name`/`Ids` 放进 body，服务端读不到 → 创建出"成功但空名空片"的播放列表，
  /// 并返合法 Id，最终把本地好名字用空壳覆盖掉（v1.7.67 事故根因）。
  /// 现在改为 `POST /Playlists?Name=..&Ids=..&UserId=..`（body 留空）。
  ///
  /// v1.7.69：① 补 `MediaType=Video`；② 部分 Emby 版本 2xx 但**空 body 不回 Id**——
  /// 此时重新拉播放列表按名字匹配兜底；③ 失败原因写入 [lastPlaylistError]，
  /// 不再"静默失败只说待重试"。
  Future<String?> createPlaylist(String name, List<String> itemIds) async {
    final uid = _userId;
    if (_token == null || uid == null) {
      lastPlaylistError = '未登录';
      return null;
    }
    lastPlaylistError = '';
    final query = <String, String>{
      'Name': name,
      'UserId': uid,
      'MediaType': 'Video',
    };
    if (itemIds.isNotEmpty) query['Ids'] = itemIds.join(',');
    Object? lastErr;
    for (final path in [
      '$baseUrl/Users/$uid/Playlists',
      '$baseUrl/Playlists',
    ]) {
      try {
        final json = await _postQueryReturning(path, query);
        final id = (json['Id'] ?? json['ItemId'])?.toString();
        if (id != null && id.isNotEmpty) return id;
        // 2xx 但没回 Id：可能已创建（空 body 版本），按名字找一遍
        final byName = await _findPlaylistIdByName(name);
        if (byName != null) return byName;
        lastErr = EmbyException('服务端已响应但未返回播放列表 Id');
      } catch (e) {
        lastErr = e;
      }
    }
    lastPlaylistError = lastErr?.toString() ?? '未知错误';
    return null;
  }

  /// 按名字查找服务端播放列表 Id（找不到返回 null）
  Future<String?> _findPlaylistIdByName(String name) async {
    try {
      for (final p in await listPlaylists()) {
        if (p.name == name) return p.id;
      }
    } catch (_) {}
    return null;
  }

  /// POST 带 query 参数、body 留空（Emby 部分端点如创建播放列表只认 query）。
  Future<Map<String, dynamic>> _postQueryReturning(
    String path,
    Map<String, String> query,
  ) async {
    final qp = <String, String>{...query, 'X-Emby-Token': _token!};
    final uri = Uri.parse(path).replace(queryParameters: qp);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.postUrl(uri);
      req.headers.set(
        'Authorization',
        'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", Version="1.0.0", Token="$_token"',
      );
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw EmbyException('请求失败 (${res.statusCode})');
      }
      if (text.isEmpty) return const {};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// 向播放列表追加条目（失败返回 false，原因见 [lastPlaylistError]）
  ///
  /// v2.0.1 关键修正：Emby 的加片接口 `POST /Playlists/{id}/Items` 只认
  /// **query 参数**（`Ids` / `UserId`），旧实现把 `Ids` 放在 JSON body 里，
  /// 服务端照样返回 2xx 但一条都没加 —— 表现就是「播放列表建出来了、片单
  /// 却是空的」。与 v1.7.68 修 `createPlaylist` 是同一类问题。
  Future<bool> addToPlaylist(String playlistId, List<String> itemIds) async {
    if (_token == null || itemIds.isEmpty) return false;
    final query = <String, String>{
      'Ids': itemIds.join(','),
      if (_userId != null) 'UserId': _userId!,
    };
    // 标准端点优先；/Items/Add 是部分版本的别名，留作兜底
    for (final path in [
      '$baseUrl/Playlists/$playlistId/Items',
      '$baseUrl/Playlists/$playlistId/Items/Add',
    ]) {
      try {
        await _postQueryReturning(path, query);
        lastPlaylistError = '';
        return true;
      } catch (e) {
        lastPlaylistError = '加片失败: $e';
      }
    }
    return false;
  }

  /// 从播放列表移除条目
  Future<bool> removeFromPlaylist(
    String playlistId,
    List<String> itemIds,
  ) async {
    if (_token == null || itemIds.isEmpty) return false;
    try {
      final ids = itemIds.map(Uri.encodeQueryComponent).join(',');
      await _request(
        '$baseUrl/Playlists/$playlistId/Items?Ids=$ids',
        method: 'DELETE',
      );
      return true;
    } catch (e) {
      lastPlaylistError = '移片失败: $e';
      return false;
    }
  }

  /// 重命名播放列表（Emby 把播放列表当 Item）
  ///
  /// v1.7.68：先 `GET /Users/{uid}/Items/{id}` 取完整对象，只改 `Name` 再
  /// `POST /Items/{id}` 写回——避免只发 `{Id,Name}` 把其它字段（如
  /// PlaylistItems 的引用）整包覆盖导致丢片。
  ///
  /// v2.0.4 修复：Emby 的 `ItemUpdateService.UpdateItem` 会对
  /// `request.ProviderIds` 直接 `.ToList()`，而 GET 默认不返回 `ProviderIds`
  /// → null → 400。补空字典/空集合。
  /// v2.0.16 兜底：最小 body 重试。
  /// v2.0.20：用户服务器对 `POST /Items/{id}` 两种 body 都仍 400（实测
  /// 「人妻」改名永远失败）。补两层：
  /// ③ **完整字段回传** —— GET 带 `Fields=ProviderIds,PlaylistItems,…`
  ///    （引用/集合字段给真实值而非补空，部分 Emby 版本只认这个）；
  /// ④ **重建式改名**（终极兜底，必成）—— 用创建/删除接口（实测可用）
  ///    新建目标名列表（片单按 [itemIds]，即本地片单）→ 删除旧列表。
  ///    播放列表 Id 会变，调用方（_reconcileUpload）拿到返回的新 Id 换绑。
  ///    若服务端已有目标名残留列表（上轮删旧失败）则复用它并补差集，幂等。
  ///
  /// 成功返回（可能变化的）播放列表 Id；失败返回 null（原因见
  /// [lastPlaylistError]）。
  Future<String?> renamePlaylist(
    String playlistId,
    String name, {
    List<String>? itemIds,
  }) async {
    if (_token == null) return null;
    Object? lastErr;
    // ① 整包回传（保其它元数据字段原样）
    try {
      final m = await _getJson('$baseUrl/Users/$_userId/Items/$playlistId');
      m['Name'] = name;
      // Emby 的 UpdateItem 对集合字段直接解引用，DTO 缺省为 null 即 400：
      // 补空值保证形态完整（播放列表无这些元数据，补空不会丢数据）
      m['ProviderIds'] ??= <String, String>{};
      for (final f in const [
        'Genres',
        'Tags',
        'Studios',
        'People',
        'GenreItems',
        'ArtistItems',
        'AlbumArtists',
        'AirDays',
        'LockedFields',
        'ProductionLocations',
        'Taglines',
      ]) {
        m[f] ??= const [];
      }
      await _postJsonReturning('$baseUrl/Items/$playlistId', m);
      return playlistId;
    } catch (e) {
      lastErr = e;
    }
    // ② 最小 body 重试（仅名字 + 空集合）
    try {
      await _postJsonReturning('$baseUrl/Items/$playlistId', {
        'Id': playlistId,
        'Name': name,
        'ProviderIds': <String, String>{},
        'LockedFields': const [],
        'Genres': const [],
        'Tags': const [],
        'Studios': const [],
        'People': const [],
      });
      return playlistId;
    } catch (e) {
      lastErr = e;
    }
    // ③ 完整字段回传：GET 带 Fields 让服务端吐出真实的集合/引用值
    //   （PlaylistItems 引用原样带回，UpdateItem 才不挑刺）
    try {
      final m = await _getJson(
        '$baseUrl/Users/$_userId/Items/$playlistId',
        query: const {
          'Fields':
              'ProviderIds,Genres,Tags,Studios,People,GenreItems,'
                  'ArtistItems,AlbumArtists,PlaylistItems',
        },
      );
      m['Name'] = name;
      m['ProviderIds'] ??= <String, String>{};
      await _postJsonReturning('$baseUrl/Items/$playlistId', m);
      return playlistId;
    } catch (e) {
      lastErr = e;
    }
    // ④ 重建式改名：绕开 UpdateItem 端点（该服务器上永远 400）。
    //    创建/删除/加片接口均为独立端点，实测可用。
    try {
      final lists = await listPlaylists();
      final old = lists.where((p) => p.id == playlistId).toList();
      final oldItems = old.isEmpty ? const <String>[] : old.first.itemIds;
      // 上轮「新列表已建但删旧失败」的残留 → 复用，防止每次重试都新建
      String? target;
      for (final p in lists) {
        if (p.name == name && p.id != playlistId) {
          target = p.id;
          break;
        }
      }
      if (target != null) {
        final have = Set<String>.from(
          lists.firstWhere((p) => p.id == target).itemIds,
        );
        final missing = (itemIds ?? oldItems)
            .where((e) => !have.contains(e))
            .toList();
        if (missing.isNotEmpty) await addToPlaylist(target, missing);
      } else {
        target = await createPlaylist(name, itemIds ?? oldItems);
      }
      if (target == null) {
        lastPlaylistError =
            '改名失败: 重建播放列表失败（$lastErr / $lastPlaylistError）';
        return null;
      }
      if (!await deletePlaylist(playlistId)) {
        lastPlaylistError =
            '改名失败: 新列表已建但删除旧列表失败（$lastPlaylistError），'
                '下轮同步自动重试';
        return null;
      }
      return target;
    } catch (e) {
      lastPlaylistError = '改名失败: $lastErr / $e';
      return null;
    }
  }

  /// 删除播放列表
  Future<bool> deletePlaylist(String playlistId) async {
    if (_token == null) return false;
    try {
      await _request('$baseUrl/Items/$playlistId', method: 'DELETE');
      return true;
    } catch (e) {
      lastPlaylistError = '删除失败: $e';
      return false;
    }
  }

  /// 拉取服务端所有播放列表（含其子条目 Id）。失败返回空列表。
  Future<List<ServerPlaylist>> listPlaylists() async {
    final uid = _userId;
    if (_token == null || uid == null) return const [];
    try {
      final json = await _getJson(
        '$baseUrl/Users/$uid/Items',
        query: {
          'IncludeItemTypes': 'Playlist',
          'Fields': 'PlaylistItems,ChildCount',
          'Recursive': 'true',
          'Limit': '100',
        },
      );
      final out = <ServerPlaylist>[];
      for (final e in (json['Items'] as List? ?? const [])) {
        final m = e as Map<String, dynamic>;
        final id = (m['Id'] as String?) ?? '';
        if (id.isEmpty) continue;
        final name = (m['Name'] as String?) ?? '';
        // 优先读 PlaylistItems 内联字段；部分版本不返回则逐个回拉（更可靠）
        final ids = <String>[];
        final rawItems = m['PlaylistItems'];
        if (rawItems is List) {
          for (final it in rawItems) {
            if (it is Map && it['Id'] != null) ids.add(it['Id'].toString());
          }
        }
        if (ids.isEmpty && (m['ChildCount'] as int? ?? 0) > 0) {
          try {
            final pj = await _getJson('$baseUrl/Playlists/$id/Items');
            for (final it in (pj['Items'] as List? ?? const [])) {
              if (it is Map && it['Id'] != null) ids.add(it['Id'].toString());
            }
          } catch (_) {}
        }
        out.add(ServerPlaylist(id, name, ids));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 演员头像地址。
  /// [maxWidth] 按使用场景给：网格 / 小头像沿用默认 200；演员详情资料卡把
  /// 头像框成 82×102 卡片后需要更清晰的图，传 400（v2.0.61）。此前详情页
  /// 把 200px 缩略图放大铺成满幅 340dp banner，既发糊又构图被切。
  String personImageUrl(String personId, String? tag, {int maxWidth = 200}) {
    final t = tag != null ? '&tag=$tag' : '';
    return '$baseUrl/Items/$personId/Images/Primary?maxWidth=$maxWidth&api_key=$_token$t';
  }

  /// 是否为可自动重试的网络瞬断。
  /// Android 上 Wi-Fi/移动数据切换、锁屏唤醒、服务器重启瞬间，dart:io 常抛
  /// ECONNABORTED("Software caused connection abort") / ECONNRESET，
  /// GET 幂等，稍候重试一次通常即可恢复，不必直接把错误甩给用户。
  bool _isTransientNetworkError(Object e) {
    if (e is SocketException || e is HttpException) {
      final m = e.toString().toLowerCase();
      return m.contains('connection abort') ||
          m.contains('connection reset') ||
          m.contains('connection closed') ||
          m.contains('broken pipe') ||
          m.contains('network is unreachable');
    }
    return false;
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final d = await _getJsonAny(path, query: query);
    return d as Map<String, dynamic>;
  }

  /// 与 [_getJson] 同款（鉴权 + 超时 + 瞬断重试），但**不强制返回 Map**：
  /// 有些 Emby 端点（如 `/Items/{id}/Trailer`）直接返回 JSON 数组，
  /// 强行 `as Map` 会抛错被上层吞掉，这里原样返回 `dynamic`。
  Future<dynamic> _getJsonAny(
    String path, {
    Map<String, String>? query,
  }) async {
    if (_token == null || _userId == null) throw EmbyException('请先登录');
    final uri = buildRequestUri(path, query, _token!);
    for (var attempt = 0; ; attempt++) {
      // 连接超时：避免某个库的请求挂起把首页其它行的加载一起堵住
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (_, __, ___) => true;
      try {
        final req = await client.getUrl(uri);
        req.headers.set('X-Emby-Token', _token!);
        // 部分服务端只认 `X-Emby-Authorization`（而非 `Authorization`），
        // 缺这个头时中间件会直接 404 隐藏路由。两个都带上最稳。
        const authHdr =
            'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", Version="1.0.0"';
        req.headers.set('X-Emby-Authorization', '$authHdr, Token="$_token"');
        req.headers.set(
          'Authorization',
          'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", Version="1.0.0", Token="$_token"',
        );
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200) {
          throw EmbyException('请求失败 (${res.statusCode})');
        }
        return jsonDecode(body);
      } catch (e) {
        // 网络瞬断自动重试一次（GET 幂等，安全）
        if (attempt == 0 && _isTransientNetworkError(e)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        rethrow;
      } finally {
        client.close();
      }
    }
  }

  /// 下载原始字节（外挂字幕 / 图片等）。与 _getJson 同款鉴权头 + 忽略自签证书，
  /// 让字幕叠加层等非 video_player 通道的下载，与视频一样能过 LAN 证书与头鉴权。
  /// 字幕响应的体积上限（v1.7.28）。
  ///
  /// 8MB 对任何文本字幕都绰绰有余（一集 45 分钟的对白 SRT 通常 50–80KB），
  /// 而 `/Items/{id}/File` 这类端点在 strm 片源上偶尔会**直接返回视频本体**，
  /// 几 GB 一次性读进内存就是 OOM 闪退。这里把上限当硬闸门。
  static const int kMaxSubtitleBytes = 8 * 1024 * 1024;

  /// 最近一次字幕下载的诊断信息，供播放页提示「字幕：xx（失败原因）」
  String subtitleDiag = '';

  Future<List<int>?> fetchBytes(String url) async {
    subtitleDiag = '';
    var r = await _fetchBytesOnce(url);
    if (r == null) {
      // 偶发失败（连接被复用到已关闭的 socket、服务器瞬时 5xx）
      // 在 600ms 后重试一次 —— 对应「字幕有时加载不出来，重开 App 才好」
      await Future<void>.delayed(const Duration(milliseconds: 600));
      r = await _fetchBytesOnce(url);
      if (r != null) subtitleDiag = '';
    }
    return r;
  }

  Future<List<int>?> _fetchBytesOnce(String url) async {
    if (_token == null) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('X-Emby-Token', _token!);
      req.headers.set(
        'Authorization',
        'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", '
            'Version="1.0.0", Token="$_token"',
      );
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        subtitleDiag = 'HTTP ${res.statusCode}';
        return null;
      }

      // ① 先看声明长度，超限一个字节都不收
      final declared = res.contentLength;
      if (declared > kMaxSubtitleBytes) {
        subtitleDiag = '响应 ${_mb(declared)} 超过上限，判定不是字幕';
        return null;
      }

      // ② 流式读取，边读边查上限
      final buf = <int>[];
      var over = false;
      await for (final chunk in res.timeout(const Duration(seconds: 15))) {
        buf.addAll(chunk);
        if (buf.length > kMaxSubtitleBytes) {
          over = true;
          break;
        }
      }
      if (over) {
        subtitleDiag = '响应超过 ${_mb(kMaxSubtitleBytes)} 上限，判定不是字幕';
        return null;
      }

      // ③ 视频魔数嗅探：MKV 的 EBML 头 / MP4 的 ftyp box
      final magic = _videoMagic(buf);
      if (magic != null) {
        subtitleDiag = '服务器返回的是 $magic 视频本体，不是字幕';
        return null;
      }
      return buf;
    } catch (e) {
      subtitleDiag = '下载失败：$e';
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';

  /// 返回命中的视频格式名，不是视频则返回 null
  static String? _videoMagic(List<int> b) {
    if (b.length >= 4 &&
        b[0] == 0x1A &&
        b[1] == 0x45 &&
        b[2] == 0xDF &&
        b[3] == 0xA3) {
      return 'MKV/WebM';
    }
    // MP4/MOV：offset 4 起是 "ftyp"
    if (b.length >= 8 &&
        b[4] == 0x66 && // f
        b[5] == 0x74 && // t
        b[6] == 0x79 && // y
        b[7] == 0x70) {
      return 'MP4';
    }
    // AVI: "RIFF" + "AVI "
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x41 &&
        b[9] == 0x56 &&
        b[10] == 0x49) {
      return 'AVI';
    }
    return null;
  }

  /// 下载文本（字幕叠加层用），自动处理 UTF-8 / GBK 容错
  Future<String?> fetchText(String url) async {
    final bytes = await fetchBytes(url);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 最近播放的条目（按 DatePlayed 倒序，普通用户权限即可）
  Future<List<MediaItem>> recentPlayed({int limit = 10}) async {
    final json = await _getJson(
      '$baseUrl/Users/$_userId/Items',
      query: {
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series',
        'Fields': _kItemFields,
        'SortBy': 'DatePlayed',
        'SortOrder': 'Descending',
        'Limit': '$limit',
        'Filters': 'IsPlayed',
      },
    );
    return _parseItems(json);
  }

  /// 服务器「已看」历史（v2.0.2）
  ///
  /// `GET /Users/{UserId}/Items?Filters=IsPlayed&SortBy=DatePlayed` —— 各客户端
  /// 通用的已看标记，**不依赖活动日志权限**（普通用户也能读），用于在活动日志
  /// 不可用时给「继续观看 / 播放记录」兜底。
  Future<List<MediaItem>> playedHistory({int limit = 30}) async {
    final json = await _getJson(
      '$baseUrl/Users/$_userId/Items',
      query: {
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Episode,Video',
        'Fields': _kItemFields,
        'SortBy': 'DatePlayed',
        'SortOrder': 'Descending',
        'Limit': '$limit',
        'Filters': 'IsPlayed',
      },
    );
    return _parseItems(json);
  }

  /// 按 Id 批量反查片名（活动日志里的条目不在当前库列表时兜底显示用）。
  ///
  /// 返回 {id → name}；已从服务器删除的条目不会出现在结果里。
  /// v1.7.72：修「常看作品 Top 显示裸 Id（如 34847）」——那些 Id 对应的影片
  /// 多半已被删除或不在 APP 拉取的库范围内，原来直接把 Id 当名字显示。
  Future<Map<String, String>> itemNamesByIds(List<String> ids) async {
    if (_token == null || _userId == null || ids.isEmpty) return const {};
    try {
      final json = await _getJson(
        '$baseUrl/Users/$_userId/Items',
        query: {
          'Ids': ids.take(50).join(','),
          'Fields': 'Name',
          'Limit': '${ids.length.clamp(1, 50)}',
        },
      );
      final out = <String, String>{};
      final rawItems = (json as Map)['Items'];
      if (rawItems is List) {
        for (final it in rawItems) {
          if (it is Map) {
            final id = it['Id']?.toString();
            final nm = it['Name']?.toString();
            if (id != null && id.isNotEmpty && nm != null && nm.isNotEmpty) {
              out[id] = nm;
            }
          }
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// 播放报告（需 Playback Reporting 插件）
  ///
  /// GET /emby/user_usage_stats/PlayActivity?days=&end_date=&data_type=time|count
  /// 插件不存在时该端点返回 404，此处静默回退（返回 null，UI 显示近似口径）
  Future<PlaybackReport?> playbackReport({int days = 30}) async {
    try {
      final now = DateTime.now();
      final end =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final timeRaw = await _playActivityRaw(days, end, 'time');
      var timeMap = _dailyFromPlayActivity(timeRaw);
      var countMap = <String, double>{};
      try {
        final countRaw = await _playActivityRaw(days, end, 'count');
        countMap = _dailyFromPlayActivity(countRaw);
      } catch (_) {
        /* count 失败不影响时长 */
      }
      if (timeMap.isEmpty && countMap.isEmpty) return null;

      // 单位自适应：data_type=time 多数插件版本返回「小时」，部分返回「分钟」
      // 用「每次播放平均时长」反推：按小时算若 > 10 小时/次，则真实单位是分钟
      final rawTotal = timeMap.values.fold<double>(0, (a, b) => a + b);
      final rawPlays = countMap.values.fold<double>(0, (a, b) => a + b);
      final perPlayIfHours = rawPlays > 0 ? rawTotal * 60 / rawPlays : 0;
      final toHours = perPlayIfHours > 600 ? (1 / 60) : 1.0;

      final keys = <String>{...timeMap.keys, ...countMap.keys}.toList()..sort();
      final daily = <DailyPlayback>[];
      for (final k in keys) {
        final d = DateTime.tryParse(k);
        if (d == null) continue;
        daily.add(
          DailyPlayback(
            date: d,
            minutes: (timeMap[k] ?? 0) * toHours * 60,
            plays: (countMap[k] ?? 0).round(),
          ),
        );
      }
      final totalMin = rawTotal * toHours * 60;
      final totalPlays = rawPlays.round();
      return PlaybackReport(
        totalMinutes: totalMin,
        totalPlays: totalPlays,
        daily: daily,
      );
    } catch (e) {
      debugPrint('PlaybackReport unavailable: $e');
      return null;
    }
  }

  /// 请求 PlayActivity，兼容「必须带 filter 才返回数据」的插件版本
  Future<dynamic> _playActivityRaw(
    int days,
    String end,
    String dataType,
  ) async {
    final base = {'days': '$days', 'end_date': end, 'data_type': dataType};
    try {
      final raw = await _getAny(
        '$baseUrl/user_usage_stats/PlayActivity',
        query: base,
      );
      if (raw is Map &&
          ((raw['categories'] is List &&
                  (raw['categories'] as List).isNotEmpty) ||
              (raw['series'] is List && (raw['series'] as List).isNotEmpty))) {
        return raw;
      }
      if (raw is List && raw.isNotEmpty) return raw;
    } catch (_) {
      /* 继续尝试带 filter */
    }
    try {
      return await _getAny(
        '$baseUrl/user_usage_stats/PlayActivity',
        query: {...base, 'filter': 'Movie,Episode'},
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 PlayActivity 返回值，兼容两种已知结构：
  /// A. {"categories":["2024-01-01",…],"series":[{"name":…,"data":[…]}]}（图表聚合）
  /// B. [{"Date":"2024-01-01","PlayDuration":123,…}, …]（逐条记录）
  Map<String, double> _dailyFromPlayActivity(dynamic json) {
    final out = <String, double>{};
    if (json is Map) {
      final cats = json['categories'];
      final series = json['series'];
      if (cats is List && series is List) {
        for (var i = 0; i < cats.length; i++) {
          double sum = 0;
          for (final s in series) {
            if (s is! Map) continue;
            final data = s['data'];
            if (data is List && i < data.length && data[i] is num) {
              sum += (data[i] as num).toDouble();
            }
          }
          out[cats[i].toString()] = sum;
        }
        return out;
      }
    }
    if (json is List) {
      for (final r in json) {
        if (r is! Map) continue;
        final raw = (r['Date'] ?? r['date'] ?? r['PlaybackStartDateTime'] ?? '')
            .toString();
        if (raw.isEmpty) continue;
        final key = raw.length >= 10 ? raw.substring(0, 10) : raw;
        final v =
            r['PlayDuration'] ??
            r['Duration'] ??
            r['Count'] ??
            r['PlayCount'] ??
            0;
        if (v is num) out[key] = (out[key] ?? 0) + v.toDouble();
      }
      return out;
    }
    return out;
  }

  /// Emby 内置活动日志（无需插件）
  /// GET /emby/System/ActivityLog/Entries?HasUserId=true&Limit=N
  /// 普通用户可能无权限，失败返回 null
  ///
  /// 账号归属判定（v2.0 修正）：Emby 在日志里写入的 `UserId` 与登录返回的
  /// `User.Id` 可能存在**格式差异**（是否带连字符、大小写不同），而且播放类
  /// 事件常常**根本不带 UserId 字段**（空字符串）。严格 `==` 会把本账号的
  /// 网页/TV 播放全部误判为「非本人」而丢弃 —— 这正是 1.7.72 之后统计页
  /// 三条卡片全空的根因。这里用 `_normId` 归一化后比较，并把空 UserId 视为
  /// 本人（单账号服务器里播放事件没有 UserId 是常态）。
  Future<ActivitySummary?> activityLog({int limit = 800}) async {
    try {
      // v2.0.11：不再传 HasUserId=true —— 部分服务器版本加了该参数后
      // 日志直接为空（实测「统计页又没数据」），且客户端本就自行按
      // UserId 归一化过滤，服务端过滤并非必需
      final json = await _getAny(
        '$baseUrl/System/ActivityLog/Entries',
        query: {'Limit': '$limit'},
      );
      if (json is! Map) return null;
      final list = json['Items'];
      if (list is! List) return null;

      final myId = _userId == null ? null : _normId(_userId!);

      // 解析一轮日志。[mineOnly] = false 时不过滤账号（v2.0.12 兜底通道）。
      ActivitySummary? parse({required bool mineOnly}) {
        final plays = <String, int>{};
        final hours = List<int>.filled(24, 0);
        final starts = <String, List<DateTime>>{};
        final stops = <String, List<DateTime>>{};
        var total = 0;
        var rawPlayback = 0; // 日志里播放类条目总数（不论归属）
        var matched = 0; // 判为本人（归一化匹配或空 UserId）的条目数
        final sampleUserIds = <String>{};
        for (final r in list) {
          if (r is! Map) continue;
          final type = (r['Type'] ?? '').toString().toLowerCase();
          if (!type.contains('playback')) continue;
          rawPlayback++;
          // v1.7.72：只统计本人账号的播放；v2.0 修正匹配口径（见上方注释）
          final uid = (r['UserId'] ?? '').toString();
          if (uid.isNotEmpty) sampleUserIds.add(uid);
          final uidNorm = uid.isEmpty ? null : _normId(uid);
          // 归一化后相等视为本人；日志未带 UserId 也视为本人（单账号服务器常态）
          final mine =
              !mineOnly || myId == null || uidNorm == null || uidNorm == myId;
          if (!mine) continue;
          matched++;
          final d = DateTime.tryParse((r['Date'] ?? '').toString());
          final itemId = (r['ItemId'] ?? '').toString();
          if (type.contains('start')) {
            // 只按开始事件计次，避免 Start/Stop 翻倍
            total++;
            if (d != null) hours[d.hour]++;
            if (itemId.isNotEmpty) {
              plays[itemId] = (plays[itemId] ?? 0) + 1;
              starts.putIfAbsent(itemId, () => []).add(d ?? DateTime.now());
            }
          } else if (type.contains('stop') && itemId.isNotEmpty && d != null) {
            stops.putIfAbsent(itemId, () => []).add(d);
          }
        }
        if (total == 0) return null;
        lastActivityDiag = mineOnly
            ? _activityDiag(rawPlayback, matched, sampleUserIds, myId)
            // v2.0.12：账号一条都没匹配上但日志里有播放（部分服务器的日志
            // UserId 是另一套内部 Id，如纯数字，与登录返回的 GUID 对不上）——
            // 单账号家用服务器直接按全部播放统计，并在诊断里说明口径
            : '日志播放 $rawPlayback 条，账号匹配 0 条（已按全部播放统计）';
        // 配对 Start→Stop 推算观看时长（跳过异常间隔），并按日聚合
        double minutes = 0;
        final dailyMinutes = <String, double>{};
        for (final id in starts.keys) {
          final s = starts[id]!..sort();
          final e = (stops[id] ?? [])..sort();
          for (var i = 0; i < s.length && i < e.length; i++) {
            final diff = e[i].difference(s[i]).inMinutes;
            if (diff > 0 && diff < 24 * 60) {
              minutes += diff;
              final k = _dayKey(s[i]);
              dailyMinutes[k] = (dailyMinutes[k] ?? 0) + diff;
            }
          }
        }
        return ActivitySummary(
          itemPlays: plays,
          hourHist: hours,
          total: total,
          totalMinutes: minutes,
          dailyMinutes: dailyMinutes,
        );
      }

      // 第一轮：只统计本账号；一条都没匹配上时回退为全部播放，
      // 不再把「ID 体系对不上」当成「没有数据」丢给用户
      return parse(mineOnly: true) ?? parse(mineOnly: false);
    } catch (e) {
      debugPrint('ActivityLog unavailable: $e');
      return null;
    }
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// GUID / Id 归一化：去掉连字符等非十六进制字符并转小写（v2.0）。
  /// Emby 同一个账号在不同接口里可能返回「带连字符」与「不带连字符」两种写法，
  /// 严格字符串比较会把本账号的播放误判成别人的。
  static String _normId(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^0-9a-z]'), '');

  String _activityDiag(
    int rawPlayback,
    int matched,
    Set<String> sampleUserIds,
    String? myId,
  ) {
    final buf = StringBuffer('日志播放 $rawPlayback 条，本账号 $matched 条');
    if (rawPlayback > 0 && matched == 0) {
      buf.write('（本账号 Id: ${myId ?? '未知'}');
      if (sampleUserIds.isNotEmpty) {
        // 最多展示 2 个样本，避免空态提示过长
        buf.write('；日志账号样本: ${sampleUserIds.take(2).join(' / ')}');
      }
      buf.write('）');
    }
    return buf.toString();
  }

  Future<dynamic> _getAny(String path, {Map<String, String>? query}) async {
    if (_token == null || _userId == null) throw EmbyException('请先登录');
    final uri = buildRequestUri(path, query, _token!);
    for (var attempt = 0; ; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (_, __, ___) => true;
      try {
        final req = await client.getUrl(uri);
        req.headers.set('X-Emby-Token', _token!);
        req.headers.set(
          'Authorization',
          'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", Version="1.0.0", Token="$_token"',
        );
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200) {
          throw EmbyException('播放报告请求失败 (${res.statusCode})');
        }
        return jsonDecode(body);
      } catch (e) {
        if (attempt == 0 && _isTransientNetworkError(e)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        rethrow;
      } finally {
        client.close();
      }
    }
  }

  Future<void> _request(String url, {String method = 'GET'}) async {
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      req.headers.set(
        'Authorization',
        'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", Version="1.0.0", Token="$_token"',
      );
      final res = await req.close();
      await res.drain();
    } finally {
      client.close();
    }
  }

  List<MediaItem> _parseItems(Map<String, dynamic> json) {
    final list = (json['Items'] as List<dynamic>? ?? []);
    return list.map((e) => _fromJson(e as Map<String, dynamic>)).toList();
  }

  static int _addedDays(String? iso) {
    if (iso == null) return 999;
    final t = DateTime.tryParse(iso);
    if (t == null) return 999;
    return DateTime.now().difference(t).inDays;
  }

  static double? _resumeProgress(
    Map<String, dynamic> userData,
    int runtimeTicks,
  ) {
    final pct = (userData['PlayedPercentage'] as num?)?.toDouble();
    if (pct != null && pct > 0 && pct < 100) return pct / 100;
    final pos = (userData['PlaybackPositionTicks'] as int?) ?? 0;
    if (pos > 0 && runtimeTicks > 0)
      return (pos / runtimeTicks).clamp(0.0, 0.99);
    return null;
  }

  /// 暂无真实图片时代替海报的渐变配色（按 id 稳定散列）
  static List<Color> _colorsFor(String id) {
    const palette = [
      [Color(0xFF3A5BD9), Color(0xFF111A3A)],
      [Color(0xFF1F8F7A), Color(0xFF07241F)],
      [Color(0xFFA03B6D), Color(0xFF241033)],
      [Color(0xFF5B3BD9), Color(0xFF170F3A)],
      [Color(0xFF2F9E5E), Color(0xFF06241A)],
      [Color(0xFF8A2F4A), Color(0xFF2B0A18)],
      [Color(0xFFD97A2B), Color(0xFF3A1A06)],
      [Color(0xFF2B86D9), Color(0xFF071A2E)],
    ];
    final h = id.isEmpty ? 0 : id.codeUnits.fold(0, (a, b) => a + b);
    return palette[h % palette.length];
  }
}

class EmbyException implements Exception {
  EmbyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 服务端播放列表（精简视图，供 reconcile 合并使用）
class ServerPlaylist {
  const ServerPlaylist(this.id, this.name, [this.itemIds = const []]);

  final String id;
  final String name;
  final List<String> itemIds;
}

/// 预告片候选入口（单条探测项）。
///
/// 见 `EmbyClient._trailerProbes`：把「可能取到预告片」的 URL 与查询参数
/// 描述成数据，`trailers()` 与诊断共用同一份清单，避免两边逻辑漂移。
class _TrailerProbe {
  const _TrailerProbe(
    this.label,
    this.path, {
    this.query,
    this.filter = false,
    this.excludeTrailer = false,
  });

  /// 诊断里展示的可读名称（不含 host，方便一行显示）。
  final String label;

  /// 完整 URL（不含鉴权参数）。
  final String path;

  /// 附加查询参数。
  final Map<String, String>? query;

  /// 是否只保留「像预告片」的条目（花絮集合 / 子项查询查预告片时用）。
  final bool filter;

  /// 是否**排除**「像预告片」的条目（查「额外部分」时用，避免与预告片栏目重复）。
  final bool excludeTrailer;
}
