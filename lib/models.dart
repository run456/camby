import 'package:flutter/material.dart';

/// 打开详情页（heroTag 用于「封面 → 头图」共享元素转场）
typedef OpenDetail = void Function(MediaItem item, {String? heroTag});

enum MediaType { movie, series, episode }

/// 服务器类型：决定默认基础路径
/// - emby：`/emby`（绿联等 Emby 兼容实现也选它）
/// - jellyfin：根路径
enum ServerKind { emby, jellyfin }

/// 已保存的服务器配置（支持多个）
class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.secure,
    required this.username,
    this.password = '',
    this.kind = ServerKind.emby,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final bool secure;
  final String username;
  final String password;
  final ServerKind kind;

  String get kindLabel => switch (kind) {
    ServerKind.jellyfin => 'Jellyfin',
    ServerKind.emby => 'Emby',
  };
  String get address => '${secure ? 'https' : 'http'}://$host:$port';

  ServerProfile copyWith({
    String? name,
    String? host,
    int? port,
    bool? secure,
    String? username,
    String? password,
    ServerKind? kind,
  }) => ServerProfile(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    secure: secure ?? this.secure,
    username: username ?? this.username,
    password: password ?? this.password,
    kind: kind ?? this.kind,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'secure': secure,
    'username': username,
    'password': password,
    'kind': kind.name,
  };

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    host: j['host'] as String? ?? '',
    port: j['port'] as int? ?? 8096,
    secure: j['secure'] as bool? ?? false,
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    // 旧版本的「绿联 NAS」配置按 Emby 兼容处理
    kind: (j['kind'] as String?) == 'jellyfin'
        ? ServerKind.jellyfin
        : ServerKind.emby,
  );
}

/// 演职人员（含图片信息，头像走 Emby 图片接口）
class CastMember {
  const CastMember({
    required this.name,
    this.role = '',
    this.id,
    this.imageTag,
  });
  final String name;
  final String role;
  final String? id; // Emby Person ItemId
  final String? imageTag; // PrimaryImageTag

  Map<String, dynamic> toJson() => {
    'name': name,
    'role': role,
    'id': id,
    'imageTag': imageTag,
  };

  factory CastMember.fromJson(Map<String, dynamic> j) => CastMember(
    name: j['name'] as String? ?? '',
    role: j['role'] as String? ?? '',
    id: j['id'] as String?,
    imageTag: j['imageTag'] as String?,
  );
}

/// 自定义收藏夹：本地索引（影片是否被收藏仍由 Emby 维护）
/// itemIds 按加入顺序存放，末尾为最新加入（用于取封面）
class FavoriteFolder {
  const FavoriteFolder({
    required this.id,
    required this.name,
    this.itemIds = const [],
    this.createdAt = 0,
  });

  final String id;
  final String name;
  final List<String> itemIds;
  final int createdAt;

  FavoriteFolder copyWith({String? name, List<String>? itemIds}) =>
      FavoriteFolder(
        id: id,
        name: name ?? this.name,
        itemIds: itemIds ?? this.itemIds,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'itemIds': itemIds,
    'createdAt': createdAt,
  };

  factory FavoriteFolder.fromJson(Map<String, dynamic> j) => FavoriteFolder(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '未命名收藏夹',
    itemIds: (j['itemIds'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(),
    createdAt: j['createdAt'] as int? ?? 0,
  );
}

/// 字幕轨（来自 Emby MediaStreams 中的 Subtitle 流）
class SubtitleTrackInfo {
  const SubtitleTrackInfo({
    required this.index,
    this.language = '',
    this.displayTitle = '',
    this.codec = 'srt',
    this.isDefault = false,
    this.isForced = false,
    this.url,
    this.altUrls = const <String>[],
  });

  final int index;
  final String language;
  final String displayTitle;
  final String codec;
  final bool isDefault;
  final bool isForced;

  /// 首选字幕地址（v1.7.22 起优先取服务器返回的 `DeliveryUrl`）
  final String? url;

  /// 备用地址，按优先级排列，由 [url] 失败后逐个尝试。
  ///
  /// 为什么需要多个：Emby 的字幕路由在不同版本/插件下不一致 —— 带
  /// `mediaSourceId`、带 `StartPositionTicks` 的新路由，以及只有
  /// `/Videos/{id}/Subtitles/{idx}/Stream.ext` 的旧路由，各家服务器支持情况
  /// 不同。只拼一种就 404 的话，表现就是「字幕不显示」且没有任何报错。
  final List<String> altUrls;

  /// 所有候选地址：[url] 在前，[altUrls] 依次在后，去重且跳过空串。
  List<String> get candidates => <String>[
        if ((url ?? '').isNotEmpty) url!,
        for (final u in altUrls)
          if (u.isNotEmpty && u != url) u,
      ];

  String get codecLabel {
    final c = codec.toLowerCase();
    if (c.contains('ass') || c.contains('ssa')) return 'ASS';
    if (c.contains('subrip') || c.contains('srt')) return 'SRT';
    if (c.contains('vtt') || c.contains('webvtt')) return 'VTT';
    if (c.contains('pgssub') || c.contains('pgs')) return 'PGS';
    return codec.isEmpty ? 'SUB' : codec.toUpperCase();
  }

  String get languageLabel {
    switch (language.toLowerCase()) {
      case 'chi':
      case 'zho':
      case 'zh':
        return 'Chinese';
      case 'eng':
      case 'en':
        return 'English';
      case 'jpn':
      case 'ja':
        return 'Japanese';
      case 'kor':
      case 'ko':
        return 'Korean';
      case 'fre':
      case 'fra':
      case 'fr':
        return 'French';
      case 'ger':
      case 'deu':
      case 'de':
        return 'German';
      case 'spa':
      case 'es':
        return 'Spanish';
      default:
        return language.isEmpty
            ? (displayTitle.isEmpty ? '字幕' : displayTitle)
            : language.toUpperCase();
    }
  }

  String get label => isDefault
      ? '${languageLabel} (默认 ${codecLabel})'
      : '${languageLabel} (${codecLabel})';

  /// 弹层里用的短标签：语言 + 字幕格式，避免出现「(SRT) · SRT」这种重复
  String get menuLabel {
    final lang = languageLabel.trim();
    final codecName = codecLabel;
    if (lang.isEmpty ||
        lang.toUpperCase() == codecName ||
        lang.toUpperCase().contains('($codecName)')) {
      return codecName;
    }
    return '$lang · $codecName';
  }

  /// 文本叠加渲染用地址：统一请求 SRT（Emby 会按扩展名自动转码，
  /// ASS/PGS/SUP 也能拿到文本流），供 Exo 内核的字幕叠加层使用
  String get textUrl => _asSrtUrl(url ?? '');

  /// 全部候选地址的文本版（与 [candidates] 一一对应，保持优先级）
  List<String> get textCandidates =>
      <String>[for (final u in candidates) _asSrtUrl(u)]
          .where((u) => u.isNotEmpty)
          .toList();

  /// 把地址里的 `Stream.xxx` 换成 `Stream.srt`
  static String _asSrtUrl(String u) {
    if (u.isEmpty) return '';
    return u.replaceFirstMapped(
      RegExp(r'Stream\.(ass|ssa|vtt|sub|pgs|sup|smi)(\?|$)'),
      (m) => 'Stream.srt${m[2] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
    'index': index,
    'language': language,
    'displayTitle': displayTitle,
    'codec': codec,
    'isDefault': isDefault,
    'isForced': isForced,
    'url': url,
    'altUrls': altUrls,
  };

  factory SubtitleTrackInfo.fromJson(Map<String, dynamic> j) =>
      SubtitleTrackInfo(
        index: (j['index'] as num?)?.toInt() ?? 0,
        language: j['language'] as String? ?? '',
        displayTitle: j['displayTitle'] as String? ?? '',
        codec: j['codec'] as String? ?? 'srt',
        isDefault: j['isDefault'] as bool? ?? false,
        isForced: j['isForced'] as bool? ?? false,
        url: j['url'] as String?,
        altUrls: <String>[
          for (final u in (j['altUrls'] as List<dynamic>? ?? const []))
            if (u is String) u,
        ],
      );
}

/// 媒体条目：字段与 Emby REST API 对齐
class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    required this.type,
    required this.overview,
    required this.colors,
    this.year = 2020,
    this.rating = 0,
    this.runtimeMin = 120,
    this.genres = const [],
    this.people = const [],
    this.tags = const [],
    this.subtitles = const [],
    this.director = '',
    this.studio = '',
    this.videoHeight = 1080,
    this.videoCodec = 'H264',
    this.audioCodec = 'AAC',
    this.audioChannels = 2,
    this.container = 'MKV',
    this.isHdr = false,
    this.hasDolbyVision = false,
    this.resumeProgress,
    this.resumeSeconds,
    this.episodeTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.seriesId,
    this.videoUrl,
    this.posterUrl,
    this.posterAspect = 0.6667,
    this.backdropUrl,
    this.backdrops = const [],
    this.resolutionKnown = true,
    this.reason,
    this.addedDaysAgo = 0,
    this.filePath = '',
    this.fileSizeBytes = 0,
    this.dateCreatedMs,
    this.userPlayCount = 0,
    this.userPlayed = false,
    this.userFavorite = false,
    this.lastPlayedAt,
  });

  final String id;
  final String name;
  final MediaType type;
  final String overview;
  final List<Color> colors;
  final int year;
  final double rating;
  final int runtimeMin;
  final List<String> genres;
  final List<CastMember> people;
  final List<String> tags;
  final List<SubtitleTrackInfo> subtitles;
  final String director;
  final String studio;
  final int videoHeight;
  final String videoCodec;
  final String audioCodec;
  final int audioChannels;
  final String container;
  final bool isHdr;
  final bool hasDolbyVision;
  final double? resumeProgress;

  /// 上次播放到的位置（秒），用于「继续播放」时定位；为 null 表示没看过
  final double? resumeSeconds;

  /// 续播位置的可读文案（如 1:23:45）
  String get resumeLabel {
    final v = resumeSeconds;
    if (v == null || v <= 1) return '';
    final t = v.round();
    final h = t ~/ 3600;
    final m = (t % 3600) ~/ 60;
    final sec = t % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  final String? episodeTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? seriesId;
  final String? videoUrl;
  final String? posterUrl;

  /// 海报原始宽高比（Emby PrimaryImageAspectRatio，缺省 2:3）
  final double posterAspect;
  final String? backdropUrl;

  /// 全部横版剧照地址（Backdrop 0..n）
  final List<String> backdrops;

  /// 是否能从 MediaStreams 读到真实视频高度（strm 等可能为 false）
  final bool resolutionKnown;
  final String? reason;
  final int addedDaysAgo;

  /// 文件完整路径（Emby MediaSources[0].Path；服务器未开放时为空）
  final String filePath;

  /// 文件大小（字节），0 表示未知
  final int fileSizeBytes;

  /// 入库时间（毫秒时间戳），媒体信息里展示「添加于」
  final int? dateCreatedMs;
  final int userPlayCount;
  final bool userPlayed;
  final bool userFavorite;
  final int? lastPlayedAt; // ms 时间戳

  bool get isMovie => type == MediaType.movie;
  bool get isSeries => type == MediaType.series;
  bool get isTrue4K => videoHeight >= 2160;
  bool get hasAtmos =>
      audioCodec.contains('TrueHD') ||
      audioCodec.contains('ATMOS') ||
      audioChannels >= 8;

  /// 按需获取指定宽度的海报地址（Emby 服务端动态缩放）。
  /// 网格缩略图用 400，全屏 Hero / 详情大图用 900，避免一律被压成小图。
  String? posterUrlFor(int maxWidth) {
    final u = posterUrl;
    if (u == null || u.isEmpty) return null;
    final uri = Uri.tryParse(u);
    if (uri == null) return u;
    final q = Map<String, String>.from(uri.queryParameters)
      ..['maxWidth'] = '$maxWidth';
    return uri.replace(queryParameters: q).toString();
  }

  List<String> get castNames => people.map((p) => p.name).toList();

  String get metaLine =>
      '$year · ${genres.take(2).join(' / ')} · $runtimeMin 分钟';

  List<String> get specBadges => [
    if (isTrue4K) '真4K',
    if (hasDolbyVision) 'DV+ATMOS',
    if (audioChannels >= 8) '${(audioChannels / 2).toStringAsFixed(1)}',
    videoCodec.toUpperCase() == 'H265' ? 'HEVC' : videoCodec.toUpperCase(),
  ];

  MediaItem copyWith({bool? userFavorite, double? resumeProgress}) {
    return MediaItem(
      id: id,
      name: name,
      type: type,
      overview: overview,
      colors: colors,
      year: year,
      rating: rating,
      runtimeMin: runtimeMin,
      genres: genres,
      people: people,
      tags: tags,
      subtitles: subtitles,
      director: director,
      studio: studio,
      videoHeight: videoHeight,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      audioChannels: audioChannels,
      container: container,
      isHdr: isHdr,
      hasDolbyVision: hasDolbyVision,
      resumeProgress: resumeProgress ?? this.resumeProgress,
      episodeTitle: episodeTitle,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      seriesId: seriesId,
      videoUrl: videoUrl,
      posterUrl: posterUrl,
      posterAspect: posterAspect,
      backdropUrl: backdropUrl,
      backdrops: backdrops,
      resolutionKnown: resolutionKnown,
      reason: reason,
      addedDaysAgo: addedDaysAgo,
      userPlayCount: userPlayCount,
      userPlayed: userPlayed,
      userFavorite: userFavorite ?? this.userFavorite,
      lastPlayedAt: lastPlayedAt,
      filePath: filePath,
      fileSizeBytes: fileSizeBytes,
      dateCreatedMs: dateCreatedMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'overview': overview,
    'colors': colors.map((c) => c.toARGB32()).toList(),
    'year': year,
    'rating': rating,
    'runtimeMin': runtimeMin,
    'genres': genres,
    'people': people.map((p) => p.toJson()).toList(),
    'tags': tags,
    'director': director,
    'studio': studio,
    'videoHeight': videoHeight,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'audioChannels': audioChannels,
    'container': container,
    'isHdr': isHdr,
    'hasDolbyVision': hasDolbyVision,
    'resumeProgress': resumeProgress,
    'resumeSeconds': resumeSeconds,
    'episodeTitle': episodeTitle,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'seriesId': seriesId,
    'videoUrl': videoUrl,
    'posterUrl': posterUrl,
    'posterAspect': posterAspect,
    'backdropUrl': backdropUrl,
    'reason': reason,
    'addedDaysAgo': addedDaysAgo,
    'userPlayCount': userPlayCount,
    'userPlayed': userPlayed,
    'userFavorite': userFavorite,
    'lastPlayedAt': lastPlayedAt,
    'filePath': filePath,
    'fileSizeBytes': fileSizeBytes,
    'dateCreatedMs': dateCreatedMs,
  };

  factory MediaItem.fromJson(Map<String, dynamic> j) {
    final typeName = j['type'] as String? ?? 'movie';
    final type = MediaType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => MediaType.movie,
    );
    final rawColors = (j['colors'] as List?) ?? const [];
    final colors = rawColors.map((e) => Color((e as num).toInt())).toList();
    return MediaItem(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      type: type,
      overview: j['overview'] as String? ?? '',
      colors: colors.isEmpty ? const [Color(0xFF22304A)] : colors,
      year: (j['year'] as num?)?.toInt() ?? 0,
      rating: (j['rating'] as num?)?.toDouble() ?? 0,
      runtimeMin: (j['runtimeMin'] as num?)?.toInt() ?? 0,
      genres: ((j['genres'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      people: ((j['people'] as List?) ?? const [])
          .map((e) => CastMember.fromJson(e as Map<String, dynamic>))
          .toList(),
      tags: ((j['tags'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      subtitles: ((j['subtitles'] as List?) ?? const [])
          .map((e) => SubtitleTrackInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      director: j['director'] as String? ?? '',
      studio: j['studio'] as String? ?? '',
      videoHeight: (j['videoHeight'] as num?)?.toInt() ?? 1080,
      videoCodec: j['videoCodec'] as String? ?? 'H264',
      audioCodec: j['audioCodec'] as String? ?? 'AAC',
      audioChannels: (j['audioChannels'] as num?)?.toInt() ?? 2,
      container: j['container'] as String? ?? 'MKV',
      isHdr: j['isHdr'] as bool? ?? false,
      hasDolbyVision: j['hasDolbyVision'] as bool? ?? false,
      resumeProgress: (j['resumeProgress'] as num?)?.toDouble(),
      resumeSeconds: (j['resumeSeconds'] as num?)?.toDouble(),
      episodeTitle: j['episodeTitle'] as String?,
      seasonNumber: (j['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (j['episodeNumber'] as num?)?.toInt(),
      seriesId: j['seriesId'] as String?,
      videoUrl: j['videoUrl'] as String?,
      posterUrl: j['posterUrl'] as String?,
      posterAspect: (j['posterAspect'] as num?)?.toDouble() ?? 0.6667,
      backdropUrl: j['backdropUrl'] as String?,
      backdrops: ((j['backdrops'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      resolutionKnown: j['resolutionKnown'] as bool? ?? true,
      reason: j['reason'] as String?,
      addedDaysAgo: (j['addedDaysAgo'] as num?)?.toInt() ?? 0,
      userPlayCount: (j['userPlayCount'] as num?)?.toInt() ?? 0,
      userPlayed: j['userPlayed'] as bool? ?? false,
      userFavorite: j['userFavorite'] as bool? ?? false,
      lastPlayedAt: (j['lastPlayedAt'] as num?)?.toInt(),
      filePath: j['filePath'] as String? ?? '',
      fileSizeBytes: (j['fileSizeBytes'] as num?)?.toInt() ?? 0,
      dateCreatedMs: (j['dateCreatedMs'] as num?)?.toInt(),
    );
  }
}

/// 媒体库（Emby UserView）
class LibraryView {
  const LibraryView({
    required this.id,
    required this.name,
    this.collectionType,
    this.imageTag,
  });
  final String id;
  final String name;
  final String? collectionType;
  final String? imageTag;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'collectionType': collectionType,
    'imageTag': imageTag,
  };

  factory LibraryView.fromJson(Map<String, dynamic> j) => LibraryView(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    collectionType: j['collectionType'] as String?,
    imageTag: j['imageTag'] as String?,
  );
}

/// 演示片源
const kVideoSamples = [
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
];

final List<MediaItem> demoLibrary = [
  MediaItem(
    id: 'demo-1',
    name: '星际回响',
    type: MediaType.movie,
    overview:
        '一支探索队穿越虫洞，却在信号另一端听见了自己的声音。当每一次回声都比上一次更接近答案，他们必须决定是继续深入，还是回到那个尚未离开的自己。',
    colors: [const Color(0xFF3A5BD9), const Color(0xFF111A3A)],
    year: 2019,
    rating: 8.6,
    runtimeMin: 108,
    genres: ['科幻', '悬疑'],
    people: const [
      CastMember(name: '黎川', role: '队长'),
      CastMember(name: '苏黎', role: '通讯官'),
      CastMember(name: 'K. Mori', role: '工程师'),
      CastMember(name: '周野', role: '医官'),
    ],
    tags: ['4K收藏', '杜比'],
    director: '陈叙',
    videoHeight: 2160,
    videoCodec: 'H265',
    audioCodec: 'TrueHD',
    audioChannels: 8,
    isHdr: true,
    hasDolbyVision: true,
    addedDaysAgo: 3,
    reason: '你常看科幻',
    videoUrl: kVideoSamples[0],
  ),
  MediaItem(
    id: 'demo-2',
    name: '雨夜长街',
    type: MediaType.movie,
    overview: '一座永远在下雨的城市，一名只会说谎的侦探。当所有证词都指向同一个不可能的答案，他必须在天亮前找到真相。',
    colors: [const Color(0xFF1F8F7A), const Color(0xFF07241F)],
    year: 2021,
    rating: 8.1,
    runtimeMin: 126,
    genres: ['悬疑', '犯罪'],
    people: const [
      CastMember(name: '苏黎', role: '主演'),
      CastMember(name: '周野', role: '主演'),
    ],
    tags: ['悬疑'],
    director: '林越',
    addedDaysAgo: 12,
    reason: '因为你看过 苏黎 的作品',
    videoUrl: kVideoSamples[1],
  ),
  MediaItem(
    id: 'demo-3',
    name: '赤色黎明',
    type: MediaType.movie,
    overview: '边境小镇的最后一位邮差，带着一封无法投递的信走向雪山深处。',
    colors: [const Color(0xFFA03B6D), const Color(0xFF241033)],
    year: 2020,
    rating: 7.4,
    runtimeMin: 98,
    genres: ['剧情', '西部'],
    people: const [
      CastMember(name: '何冬'),
      CastMember(name: 'Mira Lo'),
    ],
    tags: ['剧情'],
    director: '索朗',
    addedDaysAgo: 30,
    reason: '近期高分入库',
    videoUrl: kVideoSamples[2],
  ),
  MediaItem(
    id: 'demo-4',
    name: '深空 Agent',
    type: MediaType.series,
    overview: '空间站的 AI 管理员开始写下不属于它的记忆。十二集连续剧，每一集都是一次身份核验。',
    colors: [const Color(0xFF5B3BD9), const Color(0xFF170F3A)],
    year: 2023,
    rating: 9.0,
    runtimeMin: 52,
    genres: ['科幻', '剧情'],
    people: const [
      CastMember(name: '黎川'),
      CastMember(name: 'K. Mori'),
    ],
    tags: ['连载中'],
    director: '陈叙',
    videoHeight: 2160,
    videoCodec: 'H265',
    isHdr: true,
    addedDaysAgo: 5,
    reason: '你常看科幻',
    seriesId: 'demo-4',
    videoUrl: kVideoSamples[3],
  ),
  MediaItem(
    id: 'demo-5',
    name: '边界之外',
    type: MediaType.movie,
    overview: '一群人在地图上不存在的山谷里，找到了自己丢失的十年。',
    colors: [const Color(0xFF2F9E5E), const Color(0xFF06241A)],
    year: 2022,
    rating: 7.8,
    runtimeMin: 114,
    genres: ['冒险', '剧情'],
    people: const [
      CastMember(name: '周野'),
      CastMember(name: '何冬'),
    ],
    tags: ['冒险'],
    director: 'K. Mori',
    addedDaysAgo: 1,
    videoUrl: kVideoSamples[4],
  ),
  MediaItem(
    id: 'demo-6',
    name: '沉默之海',
    type: MediaType.series,
    overview: '潜艇失去通讯的那三十天里，六个人轮流讲同一个故事。',
    colors: [const Color(0xFF8A2F4A), const Color(0xFF2B0A18)],
    year: 2024,
    rating: 8.4,
    runtimeMin: 46,
    genres: ['悬疑', '剧情'],
    people: const [
      CastMember(name: '苏黎'),
      CastMember(name: '黎川'),
    ],
    tags: ['悬疑'],
    director: '林越',
    videoHeight: 2160,
    videoCodec: 'H265',
    isHdr: true,
    addedDaysAgo: 2,
    seriesId: 'demo-6',
    videoUrl: kVideoSamples[0],
  ),
  MediaItem(
    id: 'demo-7',
    name: '荒野回程',
    type: MediaType.series,
    overview: '两个徒步者走进无人区，只有一个人的背包省下了回程的补给。',
    colors: [const Color(0xFFD97A2B), const Color(0xFF3A1A06)],
    year: 2021,
    rating: 8.0,
    runtimeMin: 44,
    genres: ['惊悚', '冒险'],
    people: const [
      CastMember(name: '何冬'),
      CastMember(name: 'Mira Lo'),
    ],
    tags: ['惊悚'],
    director: '索朗',
    resumeProgress: 0.68,
    seriesId: 'demo-7',
    videoUrl: kVideoSamples[1],
  ),
  MediaItem(
    id: 'demo-8',
    name: '蓝色防线',
    type: MediaType.series,
    overview: '在一座海上城市，工程师们发现了海平面下更古老的防线。',
    colors: [const Color(0xFF2B86D9), const Color(0xFF071A2E)],
    year: 2023,
    rating: 7.9,
    runtimeMin: 50,
    genres: ['科幻', '动作'],
    people: const [
      CastMember(name: '黎川'),
      CastMember(name: '周野'),
    ],
    tags: ['科幻'],
    director: '陈叙',
    resumeProgress: 0.32,
    seriesId: 'demo-8',
    videoUrl: kVideoSamples[2],
  ),
  MediaItem(
    id: 'demo-9',
    name: '无声证词',
    type: MediaType.series,
    overview: '法庭速记员发现自己记录下的证词，比任何人说的都更接近真相。',
    colors: [const Color(0xFF4B4FD9), const Color(0xFF14173A)],
    year: 2022,
    rating: 8.3,
    runtimeMin: 48,
    genres: ['悬疑', '律政'],
    people: const [
      CastMember(name: '苏黎'),
      CastMember(name: '何冬'),
    ],
    tags: ['律政'],
    director: '林越',
    resumeProgress: 0.85,
    seriesId: 'demo-9',
    videoUrl: kVideoSamples[3],
  ),
  MediaItem(
    id: 'demo-10',
    name: '夜航西飞',
    type: MediaType.movie,
    overview: '末班航班上，机长做了一个所有人都同意、却没有人记得的决定。',
    colors: [const Color(0xFF6C4BD9), const Color(0xFF201A52)],
    year: 2018,
    rating: 7.6,
    runtimeMin: 102,
    genres: ['剧情'],
    people: const [
      CastMember(name: 'Mira Lo'),
      CastMember(name: '周野'),
    ],
    tags: ['剧情'],
    director: 'K. Mori',
    videoUrl: kVideoSamples[4],
  ),
  MediaItem(
    id: 'demo-11',
    name: '极昼',
    type: MediaType.movie,
    overview: '北极科考站迎来连续半年的白昼，时间感在极光里彻底失效。',
    colors: [const Color(0xFF2B86D9), const Color(0xFF0A2340)],
    year: 2020,
    rating: 7.2,
    runtimeMin: 96,
    genres: ['纪录', '冒险'],
    people: const [CastMember(name: '何冬')],
    tags: ['纪录'],
    director: '索朗',
    videoUrl: kVideoSamples[0],
  ),
  MediaItem(
    id: 'demo-12',
    name: '纸鹤',
    type: MediaType.movie,
    overview: '一个关于寄不出的信和永远晚点的列车的爱情故事。',
    colors: [const Color(0xFFD95B7A), const Color(0xFF3A0E1E)],
    year: 2017,
    rating: 6.9,
    runtimeMin: 88,
    genres: ['爱情', '剧情'],
    people: const [
      CastMember(name: 'Mira Lo'),
      CastMember(name: '苏黎'),
    ],
    tags: ['爱情'],
    director: '林越',
    videoUrl: kVideoSamples[1],
  ),
];

/// 真实统计：从服务端条目聚合
class LibraryStats {
  const LibraryStats({
    required this.movieCount,
    required this.seriesCount,
    required this.totalLibraryHours,
    required this.watchedHours,
    required this.playCount,
    required this.personCount,
    required this.watchedCount,
    required this.favoriteCount,
    required this.completionRate,
    required this.genreDistribution,
    required this.hourlyHeatmap,
    required this.weeklyTrend,
    required this.topPeople,
    required this.missingPoster,
    required this.missingOverview,
    required this.tagCounts,
    required this.tagDistribution,
    required this.topCast,
    required this.res4kPct,
    required this.res1080Pct,
    required this.res720Pct,
    required this.res480Pct,
    required this.hdrPct,
    required this.dvPct,
    required this.hevcPct,
    required this.atmosPct,
    required this.addedTrend,
    required this.watchCoverage,
    required this.hourBuckets,
    required this.recentPlayed,
    required this.missingPosterTitles,
    required this.missingOverviewTitles,
    this.tagSource = 'Tags',
  });

  final int movieCount;
  final int seriesCount;
  final int totalLibraryHours;
  final int watchedHours;
  final int playCount;
  final int personCount;
  final int watchedCount;
  final int favoriteCount;
  final double completionRate;
  final Map<String, double> genreDistribution;
  final List<List<int>> hourlyHeatmap;
  final List<double> weeklyTrend;
  final List<Map<String, dynamic>> topPeople;
  final int missingPoster;
  final int missingOverview;

  /// 标签维度（Emby Tags 字段，如「痴女」等自定义标签）
  final Map<String, int> tagCounts; // Top 10 标签 → 数量
  final Map<String, double> tagDistribution; // Top 8 归一化
  /// 演员影片 Top（全库按参演影片数）
  final List<Map<String, dynamic>> topCast;

  /// 画质规格占比（0-1）
  final double res4kPct;
  final double res1080Pct;
  final double res720Pct;
  final double res480Pct;
  final double hdrPct;
  final double dvPct;
  final double hevcPct;
  final double atmosPct;

  /// 近 12 个月入库趋势（旧 → 新）
  final List<double> addedTrend;

  /// 库存覆盖率 = 已看 / 库内总量
  final double watchCoverage;

  /// 播放时段分档（每 2 小时一档，共 12 档）
  final List<int> hourBuckets;

  /// 最近播放的影片（按最后播放时间倒序，含完成度）
  final List<Map<String, dynamic>> recentPlayed;

  /// 缺海报 / 缺简介的影片标题（用于数据质量卡）
  final List<String> missingPosterTitles;
  final List<String> missingOverviewTitles;

  /// 标签数据来源：Tags 为空时回退 Genres（部分媒体库把标签写在分类里）
  final String tagSource;

  static LibraryStats compute(List<MediaItem> items) {
    final movies = items.where((e) => e.isMovie).length;
    final series = items.where((e) => e.isSeries).length;
    final totalMin = items.fold<int>(0, (a, e) => a + e.runtimeMin);
    final watched = items
        .where((e) => e.userPlayed || (e.resumeProgress ?? 0) > 0.9)
        .toList();
    final watchedMin = watched.fold<int>(0, (a, e) => a + e.runtimeMin);
    final playCount = items.fold<int>(0, (a, e) => a + e.userPlayCount);
    final fav = items.where((e) => e.userFavorite).length;

    final genreCount = <String, int>{};
    for (final e in items) {
      for (final g in e.genres) {
        genreCount[g] = (genreCount[g] ?? 0) + 1;
      }
    }
    final genreEntries = genreCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxGenre = genreEntries.isEmpty ? 1 : genreEntries.first.value;
    final genreDist = <String, double>{};
    for (final e in genreEntries.take(8)) {
      genreDist[e.key] = e.value / maxGenre;
    }

    // 播放时段热力图：以已看条目的最后播放时间近似
    final heat = List.generate(7, (_) => List.filled(24, 0));
    for (final e in watched) {
      final t = e.lastPlayedAt;
      if (t == null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(t);
      heat[d.weekday - 1][d.hour]++;
    }
    final maxHeat = heat.fold<int>(
      0,
      (a, row) => row.fold(a, (b, v) => v > b ? v : b),
    );
    final heatLevels = heat
        .map(
          (row) => row
              .map(
                (v) => maxHeat == 0 ? 0 : (v / maxHeat * 6).round().clamp(0, 6),
              )
              .toList(),
        )
        .toList();

    // 近 12 周趋势
    final now = DateTime.now();
    final trend = List<double>.filled(12, 0);
    for (final e in watched) {
      final t = e.lastPlayedAt;
      if (t == null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(t);
      final weeksAgo = (now.difference(d).inDays / 7).floor();
      if (weeksAgo >= 0 && weeksAgo < 12) {
        trend[11 - weeksAgo] += 1;
      }
    }

    // 偏好演员
    final personFreq = <String, int>{};
    for (final e in watched) {
      for (final p in e.people.take(5)) {
        personFreq[p.name] = (personFreq[p.name] ?? 0) + 1;
      }
    }
    final topP = personFreq.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxP = topP.isEmpty ? 1 : topP.first.value;
    final topPeople = topP
        .take(4)
        .map((e) => {'name': e.key, 'count': e.value, 'weight': e.value / maxP})
        .toList();

    final allPersons = <String>{};
    for (final e in items) {
      for (final p in e.people) {
        allPersons.add(p.name);
      }
    }

    final ratedMovies = items.where((e) => e.isMovie).length;
    final playedMovies = items.where((e) => e.isMovie && e.userPlayed).length;

    // ── 标签维度（优先 Emby Tags，为空时回退 Genres）──
    // 部分媒体库把「痴女」这类自定义标签存进 Genres，此时 Tags 全空
    final hasTags = items.any((e) => e.tags.isNotEmpty);
    final tagSource = hasTags ? 'Tags' : '分类';
    final tagCount = <String, int>{};
    for (final e in items) {
      for (final t in (hasTags ? e.tags : e.genres)) {
        tagCount[t] = (tagCount[t] ?? 0) + 1;
      }
    }
    final tagEntries = tagCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxTag = tagEntries.isEmpty ? 1 : tagEntries.first.value;
    final tagCounts = {for (final e in tagEntries.take(10)) e.key: e.value};
    final tagDist = {
      for (final e in tagEntries.take(8)) e.key: e.value / maxTag,
    };

    // ── 演员影片 Top（全库按参演影片数）──
    final castCount = <String, int>{};
    for (final e in items) {
      for (final p in e.people) {
        castCount[p.name] = (castCount[p.name] ?? 0) + 1;
      }
    }
    final castEntries = castCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxCast = castEntries.isEmpty ? 1 : castEntries.first.value;
    final topCast = castEntries
        .take(5)
        .map(
          (e) => {'name': e.key, 'count': e.value, 'weight': e.value / maxCast},
        )
        .toList();

    // ── 画质规格占比 ──
    final n = items.isEmpty ? 1 : items.length;
    double pct(bool Function(MediaItem) f) => items.where(f).length / n;
    final res4k = pct((e) => e.videoHeight >= 2160);
    final res1080 = pct((e) => e.videoHeight >= 1080 && e.videoHeight < 2160);
    final res720 = pct((e) => e.videoHeight >= 720 && e.videoHeight < 1080);
    final res480 = pct((e) => e.videoHeight < 720);
    final hdr = pct((e) => e.isHdr);
    final dv = pct((e) => e.hasDolbyVision);
    final hevc = pct(
      (e) =>
          e.videoCodec.toUpperCase() == 'H265' ||
          e.videoCodec.toUpperCase() == 'HEVC',
    );
    final atmos = pct((e) => e.hasAtmos);

    // ── 播放时段分档（每 2 小时）──
    final hourBuckets = List<int>.filled(12, 0);
    for (final e in items) {
      final t = e.lastPlayedAt;
      if (t == null) continue;
      final h = DateTime.fromMillisecondsSinceEpoch(t).hour;
      hourBuckets[h ~/ 2]++;
    }

    // ── 最近播放（按最后播放时间倒序）──
    final recent = <Map<String, dynamic>>[];
    for (final e in items) {
      final t = e.lastPlayedAt;
      if (t == null) continue;
      recent.add({
        'name': e.name,
        'pct': e.userPlayed ? 1.0 : (e.resumeProgress ?? 0),
        't': t,
      });
    }
    recent.sort((a, b) => (b['t'] as int).compareTo(a['t'] as int));

    // 缺海报 / 缺简介的标题
    const noOverview = '暂无简介';
    final missPoster = items
        .where((e) => e.posterUrl == null)
        .map((e) => e.name)
        .toList();
    final missOverview = items
        .where((e) => e.overview.isEmpty || e.overview == noOverview)
        .map((e) => e.name)
        .toList();

    // ── 近 12 个月入库趋势 ──
    final added = List<double>.filled(12, 0);
    for (final e in items) {
      final bucket = (e.addedDaysAgo / 30.4).floor();
      if (bucket >= 0 && bucket < 12) {
        added[11 - bucket] += 1;
      }
    }

    // ── 库存覆盖率（已看 / 库内）──
    final coverage = items.isEmpty ? 0.0 : watched.length / items.length;

    return LibraryStats(
      movieCount: movies,
      seriesCount: series,
      totalLibraryHours: (totalMin / 60).round(),
      watchedHours: (watchedMin / 60).round(),
      playCount: playCount,
      personCount: allPersons.length,
      watchedCount: watched.length,
      favoriteCount: fav,
      completionRate: ratedMovies == 0 ? 0 : playedMovies / ratedMovies,
      genreDistribution: genreDist,
      hourlyHeatmap: heatLevels,
      weeklyTrend: trend,
      topPeople: topPeople,
      missingPoster: items.where((e) => e.posterUrl == null).length,
      missingOverview: items.where((e) => e.overview.isEmpty).length,
      tagCounts: tagCounts,
      tagDistribution: tagDist,
      topCast: topCast,
      res4kPct: res4k,
      res1080Pct: res1080,
      res720Pct: res720,
      res480Pct: res480,
      hdrPct: hdr,
      dvPct: dv,
      hevcPct: hevc,
      atmosPct: atmos,
      addedTrend: added,
      watchCoverage: coverage,
      hourBuckets: hourBuckets,
      recentPlayed: recent.take(10).toList(),
      missingPosterTitles: missPoster.take(6).toList(),
      missingOverviewTitles: missOverview.take(6).toList(),
      tagSource: tagSource,
    );
  }
}

/// 播放报告（Playback Reporting 插件 /emby/user_usage_stats/PlayActivity）
/// 真实逐日播放数据，不落库，进统计页时实时拉取
class DailyPlayback {
  const DailyPlayback({
    required this.date,
    required this.minutes,
    required this.plays,
  });
  final DateTime date;
  final double minutes;
  final int plays;
}

class PlaybackReport {
  const PlaybackReport({
    required this.totalMinutes,
    required this.totalPlays,
    required this.daily,
  });

  final double totalMinutes;
  final int totalPlays;
  final List<DailyPlayback> daily;

  double get totalHours => totalMinutes / 60;
  bool get isEmpty => daily.isEmpty && totalPlays == 0 && totalMinutes == 0;
}

/// Emby 内置活动日志（/System/ActivityLog/Entries）聚合
/// 未装插件时的真实行为数据来源：条目级播放次数 + 小时分布
class ActivitySummary {
  const ActivitySummary({
    required this.itemPlays,
    required this.hourHist,
    required this.total,
    this.totalMinutes = 0,
    this.dailyMinutes = const {},
  });

  final Map<String, int> itemPlays; // ItemId → 播放次数
  final List<int> hourHist; // 24 档
  final int total;

  /// 由 PlaybackStart/PlaybackStop 事件配对推算的观看时长（分钟）
  final double totalMinutes;

  /// 按日期聚合的观看分钟数（yyyy-MM-dd → 分钟）
  final Map<String, double> dailyMinutes;

  double get totalHours => totalMinutes / 60;

  bool get isEmpty => total == 0;

  /// 12 档（每 2 小时）
  List<int> get hourBuckets {
    final out = List<int>.filled(12, 0);
    for (var h = 0; h < 24 && h < hourHist.length; h++) {
      out[h ~/ 2] += hourHist[h];
    }
    return out;
  }
}

/// 演示统计（仅 demo 模式）
final demoStats = LibraryStats.compute(demoLibrary);

/// 分辨率分桶（媒体库筛选与海报角标共用）
/// 分界取常见档位：>=2000 视为 2160P，>=1000 视为 1080P（含 1440P 归并），
/// >=650 为 720P，其余 480P；未知高度归「未知」
String resolutionBucket(MediaItem item) {
  if (!item.resolutionKnown || item.videoHeight <= 0) return '未知';
  final h = item.videoHeight;
  if (h >= 2000) return '2160P';
  if (h >= 1000) return '1080P';
  if (h >= 650) return '720P';
  return '480P';
}

/// 是否含中文字幕轨（详情页「中文字幕」标签与字幕筛选页共用）
bool itemHasChineseSubtitle(MediaItem item) {  for (final s in item.subtitles) {
    final lang = s.language.toLowerCase().replaceAll('_', '-');
    final title = s.displayTitle.toLowerCase();
    if (lang.startsWith('zh') ||
        lang == 'chi' ||
        lang == 'zho' ||
        lang == 'chs' ||
        lang == 'cht' ||
        lang == 'cn') {
      return true;
    }
    if (title.contains('中文') ||
        title.contains('简体') ||
        title.contains('繁体') ||
        title.contains('繁體') ||
        title.contains('中字') ||
        title.contains('chs') ||
        title.contains('cht') ||
        title.contains('chinese')) {
      return true;
    }
  }
  return false;
}
