import 'dart:convert';
import 'dart:io';

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
  String streamUrl(String itemId, {String? mediaSourceId, bool direct = true}) {
    final ms = mediaSourceId != null ? '&MediaSourceId=$mediaSourceId' : '';
    return direct
        ? '$baseUrl/Videos/$itemId/stream?Static=true$ms&api_key=$_token'
        : '$baseUrl/Videos/$itemId/master.m3u8$ms&api_key=$_token';
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
    for (final s in streams) {
      final m = s as Map<String, dynamic>;
      if (m['Type'] != 'Subtitle') continue;
      final idx = (m['Index'] as num?)?.toInt() ?? 0;
      final codec = ((m['Codec'] as String?) ?? 'srt').toLowerCase();
      final fmt = (codec.contains('ass') || codec.contains('ssa'))
          ? 'ass'
          : (codec.contains('vtt') ? 'vtt' : 'srt');
      subtitles.add(
        SubtitleTrackInfo(
          index: idx,
          language: ((m['Language'] as String?) ?? '').trim(),
          displayTitle: ((m['DisplayTitle'] ?? m['Title'] ?? '') as String)
              .trim(),
          codec: codec,
          isDefault: m['IsDefault'] as bool? ?? false,
          isForced: m['IsForced'] as bool? ?? false,
          url: '$baseUrl/Videos/$id/Subtitles/$idx/Stream.$fmt?api_key=$_token',
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
  Future<List<int>?> fetchBytes(String url) async {
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
      if (res.statusCode != 200) return null;
      return await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
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
