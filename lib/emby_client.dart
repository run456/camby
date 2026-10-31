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
const _kItemFields =
    'Genres,People,UserData,MediaStreams,MediaSources,Overview,DateCreated,'
    'CommunityRating,ProductionYear,RunTimeTicks,PremiereDate,OfficialRating,Tags,TagItems,Studios';

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
        'X-Emby-Device-Name': 'Android',
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
        'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", '
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
  ///
  /// [maxBitrate]（bps）为 1.7.38 新增：对应 Emby 的 MaxStreamingBitrate，
  /// 播放页切换码率后，用它让服务端按该码率重新出流（转码链路），
  /// 直连原片时服务端会忽略该参数。
  String streamUrl(
    String itemId, {
    String? mediaSourceId,
    bool direct = true,
    int? maxBitrate,
  }) {
    final ms = mediaSourceId != null ? '&MediaSourceId=$mediaSourceId' : '';
    // "&MaxStreamingBitrate=" 需与 APK libapp.so 中的字符串保持一致
    final mb =
        maxBitrate != null && maxBitrate > 0 ? '&MaxStreamingBitrate=$maxBitrate' : '';
    return direct
        ? '$baseUrl/Videos/$itemId/stream?Static=true$ms$mb&api_key=$_token'
        : '$baseUrl/Videos/$itemId/master.m3u8$ms$mb&api_key=$_token';
  }

  /// 从文件名推断分辨率高度（2160 / 1080 / 720 / 576 / 480 …）。
  ///
  /// 部分自建库的 MediaStreams 缺失（刮削失败、strm、NFO 导入），Height 会
  /// 落到兜底值 1080，媒体库筛选「4K」就永远筛不到这些片。这里在读媒体流信息
  /// 之前先兜一遍文件名：只要名字里带 `Movie.2160p.WEB-DL` 这类标记就采信。
  /// 返回 null 表示名字里没有可靠标记，仍走 MediaStreams / 默认值。
  static int? _heightFromName(String name) {
    final s = name.toLowerCase();
    final m = RegExp(r'(?<![0-9])(2160|1440|1080|720|576|480|360)p(?![0-9a-z])')
        .firstMatch(s);
    if (m != null) return int.parse(m.group(1)!);
    // 4K / 8K 写法
    if (RegExp(r'(?<![0-9a-z])8k(?![0-9a-z])').hasMatch(s)) return 4320;
    if (RegExp(r'(?<![0-9a-z])4k(?![0-9a-z])').hasMatch(s)) return 2160;
    if (RegExp(r'(?<![0-9a-z])(uhd|uhdrip)(?![0-9a-z])').hasMatch(s)) return 2160;
    if (RegExp(r'(?<![0-9a-z])hdrip(?![0-9a-z])').hasMatch(s)) return 720;
    return null;
  }

  /// 测试入口：文件名 → 分辨率兜底推断（实现见 [_heightFromName]）
  @visibleForTesting
  static int? heightFromNameForTest(String name) => _heightFromName(name);

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
        'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", Version="1.0.0", Token="$_token"',
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
  Future<void> reportPlaybackStart(String itemId) async {
    try {
      await _postJson('$baseUrl/Sessions/Playing', {
        'ItemId': itemId,
        'PlayMethod': 'DirectPlay',
      });
    } catch (_) {
      // 会话事件不关键，失败不打扰用户
    }
  }

  /// 播放中心跳（POST /Sessions/Playing/Progress）
  Future<void> reportPlaybackProgress(String itemId, int positionTicks) async {
    try {
      await _postJson('$baseUrl/Sessions/Playing/Progress', {
        'ItemId': itemId,
        'PositionTicks': positionTicks,
      });
    } catch (_) {}
  }

  /// 退出播放时上报（POST /Sessions/Stopped）
  Future<void> reportPlaybackStop(
    String itemId,
    int positionTicks, {
    bool played = false,
  }) async {
    try {
      await _postJson('$baseUrl/Sessions/Stopped', {
        'ItemId': itemId,
        'PositionTicks': positionTicks,
        if (played) 'Played': true,
      });
    } catch (_) {}
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
        'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", Version="1.0.0", Token="$_token"',
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
    final sourceId = (j['MediaSources'] as List<dynamic>? ?? const [])
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
      final delivery = ((m['DeliveryUrl'] as String?) ??
              (m['SubtitleDeliveryUrl'] as String?) ??
              '')
          .trim();
      final subPath = ((m['Path'] as String?) ?? '').trim();
      final stdRoute = '$baseUrl/Videos/$id/$sourceId/Subtitles/$idx/'
          '0/Stream.$fmt?api_key=$_token';
      final noZeroRoute = '$baseUrl/Videos/$id/$sourceId/Subtitles/$idx/'
          'Stream.$fmt?api_key=$_token';
      final oldRoute = '$baseUrl/Videos/$id/Subtitles/$idx/'
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
    final msSize = (ms0['Size'] as num?)?.toInt() ?? 0;
    final msContainer =
        ((ms0['Container'] as String?) ?? (j['Container'] as String?) ?? '')
            .trim();
    final String? posterTag = imageData['Primary'] as String?;
    final backdrops = <String>[
      for (var i = 0; i < backdropTags.length; i++)
        '$baseUrl/Items/$id/Images/Backdrop/$i?maxWidth=1280&api_key=$_token&tag=${backdropTags[i]}',
    ];
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
      resolutionKnown: heightFound,
      videoUrl: '$baseUrl/Videos/$id/stream?Static=true&api_key=$_token',
      addedDaysAgo: _addedDays(j['DateCreated'] as String?),
      filePath: msPath,
      fileSizeBytes: msSize,
      dateCreatedMs: DateTime.tryParse(
        j['DateCreated'] as String? ?? '',
      )?.millisecondsSinceEpoch,
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
          if (t == 'boxsets' || t == 'collections') return false;
          if (v.collectionType == null || v.collectionType!.isEmpty) {
            final n = v.name.trim();
            final ln = n.toLowerCase();
            if (n == '合集' ||
                n.endsWith('合集') ||
                ln == 'collections' ||
                ln == 'boxsets' ||
                ln == 'box sets') {
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
        'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", Version="1.0.0", Token="$_token"',
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
  Future<bool> addToPlaylist(String playlistId, List<String> itemIds) async {
    if (_token == null || itemIds.isEmpty) return false;
    final ids = itemIds.join(',');
    for (final path in [
      '$baseUrl/Playlists/$playlistId/Items/Add',
      '$baseUrl/Playlists/$playlistId/Items',
    ]) {
      try {
        await _postJsonReturning(path, {'Ids': ids});
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
      await _request('$baseUrl/Playlists/$playlistId/Items?Ids=$ids',
          method: 'DELETE');
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
  Future<bool> renamePlaylist(String playlistId, String name) async {
    if (_token == null) return false;
    try {
      final m = await _getJson('$baseUrl/Users/$_userId/Items/$playlistId');
      m['Name'] = name;
      await _postJsonReturning('$baseUrl/Items/$playlistId', m);
      return true;
    } catch (e) {
      lastPlaylistError = '改名失败: $e';
      return false;
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

  /// 演员头像地址
  String personImageUrl(String personId, String? tag) {
    final t = tag != null ? '&tag=$tag' : '';
    return '$baseUrl/Items/$personId/Images/Primary?maxWidth=200&api_key=$_token$t';
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
    if (_token == null || _userId == null) throw EmbyException('请先登录');
    final qp = <String, String>{...?query, 'X-Emby-Token': _token!};
    final uri = Uri.parse(path).replace(queryParameters: qp);
    for (var attempt = 0; ; attempt++) {
      // 连接超时：避免某个库的请求挂起把首页其它行的加载一起堵住
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (_, __, ___) => true;
      try {
        final req = await client.getUrl(uri);
        req.headers.set('X-Emby-Token', _token!);
        req.headers.set(
          'Authorization',
          'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", Version="1.0.0", Token="$_token"',
        );
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200) {
          throw EmbyException('请求失败 (${res.statusCode})');
        }
        return jsonDecode(body) as Map<String, dynamic>;
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
        'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", '
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
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x41 && b[9] == 0x56 && b[10] == 0x49) {
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
      if (json is Map && json['Items'] is List) {
        for (final it in (json['Items'] as List)) {
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
  Future<ActivitySummary?> activityLog({int limit = 800}) async {
    try {
      final json = await _getAny(
        '$baseUrl/System/ActivityLog/Entries',
        query: {'HasUserId': 'true', 'Limit': '$limit'},
      );
      if (json is! Map) return null;
      final list = json['Items'];
      if (list is! List) return null;

      final plays = <String, int>{};
      final hours = List<int>.filled(24, 0);
      final starts = <String, List<DateTime>>{};
      final stops = <String, List<DateTime>>{};
      var total = 0;
      for (final r in list) {
        if (r is! Map) continue;
        final type = (r['Type'] ?? '').toString().toLowerCase();
        if (!type.contains('playback')) continue;
        // v1.7.72：只统计本人账号的播放。管理员账号拉到的日志包含
        // 全家所有用户，不按 UserId 过滤会把别人的播放算进自己的统计
        final uid = (r['UserId'] ?? '').toString();
        if (_userId != null && uid.isNotEmpty && uid != _userId) continue;
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
    } catch (e) {
      debugPrint('ActivityLog unavailable: $e');
      return null;
    }
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<dynamic> _getAny(String path, {Map<String, String>? query}) async {
    if (_token == null || _userId == null) throw EmbyException('请先登录');
    final qp = <String, String>{...?query, 'X-Emby-Token': _token!};
    final uri = Uri.parse(path).replace(queryParameters: qp);
    for (var attempt = 0; ; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = (_, __, ___) => true;
      try {
        final req = await client.getUrl(uri);
        req.headers.set('X-Emby-Token', _token!);
        req.headers.set(
          'Authorization',
          'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", Version="1.0.0", Token="$_token"',
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
        'MediaBrowser Client="Camby", Device="Android", DeviceId="camby01", Version="1.0.0", Token="$_token"',
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
