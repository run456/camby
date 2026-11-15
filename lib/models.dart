import 'package:flutter/material.dart';

import 'watch_history.dart';

/// 打开详情页（heroTag 用于「封面 → 头图」共享元素转场）
typedef OpenDetail = void Function(MediaItem item, {String? heroTag});

/// 条目类型。
///
/// v2.0.92 补 `season`：剧集详情页要「选季 → 选集」，Season 条目在标准
/// Emby / Jellyfin 里是独立 Item（`/Shows/{id}/Seasons` 的返回项）。
/// 以前没这个类型，Season 会被当成电影塞进列表，季选集无从下手。
enum MediaType { movie, series, episode, season }

/// 客户端版本号，写进 Emby `X-Emby-Authorization` 头。
///
/// 单独抽出来是因为鉴权字符串在播放内核、图片加载、资源自检三处都要拼，
/// 以前每处各自硬编码一个版本号，发版时必漏一处（v2.0.89 的图片头里就
/// 还留着上一版号）。**发版时只改这里和 pubspec 两处。**
const String kClientVersion = '2.0.93';

/// 服务器类型：决定默认基础路径
/// - emby：`/emby`（绿联等 Emby 兼容实现也选它）
/// - jellyfin：根路径
/// 服务器类型。v2.0.88 起 [ugreen] 是**独立入口**：绿联影视中心只是
/// Emby 接口子集，图片 / 流地址与标准 Emby 不同（见兼容方案文档第五节），
/// 必须靠类型标记走不同的资源 URL 拼法，不能继续当普通 Emby 猜端口。
enum ServerKind { emby, jellyfin, ugreen }

/// 视频动态范围（Emby `MediaStreams[].VideoRangeType`）。
///
/// v2.0.83：以前 `hasDolbyVision` 是用音轨里的 TrueHD/ATMOS 猜出来的，
/// 真 HDR10 片一律显示 SDR、带 TrueHD 音轨的 SDR 片反倒显示 Dolby Vision。
/// 动态范围只可能来自**视频流**，与音轨无关，这里作为唯一判据。
enum VideoRange { sdr, hdr10, hdr10Plus, hlg, dovi, unknown }

/// 兼容 Emby 各版本的 `VideoRangeType` / 旧 `VideoRange` 字段取值：
/// SDR / HDR10 / HDR10Plus / HLG / DOVI / DOVIWithHDR10 / DOVIWithHLG …
/// 大小写、下划线、连字符、空格一律归一；认不出来返回 unknown（不猜）。
VideoRange parseVideoRange(String? raw) {
  if (raw == null) return VideoRange.unknown;
  final s = raw.toUpperCase().replaceAll(RegExp(r'[\s_\-+]'), '');
  if (s.isEmpty || s == 'UNKNOWN' || s == 'NONE') return VideoRange.unknown;
  // DOVIWithHDR10 同时含 DOVI 与 HDR10，必须先判 DV。
  if (s.contains('DOVI') || s.contains('DOLBYVISION') || s == 'DV') {
    return VideoRange.dovi;
  }
  if (s.contains('HDR10PLUS')) return VideoRange.hdr10Plus;
  if (s.contains('HDR10')) return VideoRange.hdr10;
  if (s.contains('HLG')) return VideoRange.hlg;
  if (s == 'HDR') return VideoRange.hdr10; // 旧版 VideoRange 字段
  if (s == 'SDR') return VideoRange.sdr;
  return VideoRange.unknown;
}

extension VideoRangeX on VideoRange {
  bool get isHdr => this != VideoRange.sdr && this != VideoRange.unknown;

  bool get isDolbyVision => this == VideoRange.dovi;

  /// DV Profile 5 用 IPTPQc2 色彩空间，必须靠 vo=gpu-next + libplacebo
  /// 读 RPU 做 IPT→BT.2020 转换；普通 vo=gpu 会把它当 YCbCr 解码，
  /// 表现就是整屏发绿发紫。
  bool get needsGpuNext => isDolbyVision;

  String get label => switch (this) {
    VideoRange.sdr => 'SDR',
    VideoRange.hdr10 => 'HDR10',
    VideoRange.hdr10Plus => 'HDR10+',
    VideoRange.hlg => 'HLG',
    VideoRange.dovi => 'Dolby Vision',
    VideoRange.unknown => 'SDR',
  };
}

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
    this.ignoreSsl = false,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final bool secure;
  final String username;
  final String password;
  final ServerKind kind;

  /// v2.0.87：是否跳过 TLS 证书校验。**默认关闭**，仅绿联影视中心这类
  /// 局域网自签 HTTPS 源需要手动打开；见 `server_address.dart` 的风险说明。
  final bool ignoreSsl;

  String get kindLabel => switch (kind) {
    ServerKind.jellyfin => 'Jellyfin',
    ServerKind.emby => 'Emby',
    ServerKind.ugreen => '绿联影视中心',
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
    bool? ignoreSsl,
  }) => ServerProfile(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    secure: secure ?? this.secure,
    username: username ?? this.username,
    password: password ?? this.password,
    kind: kind ?? this.kind,
    ignoreSsl: ignoreSsl ?? this.ignoreSsl,
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
    'ignore_ssl': ignoreSsl,
  };

  factory ServerProfile.fromJson(Map<String, dynamic> j) {
    final port = j['port'] as int? ?? 8096;
    final secure = j['secure'] as bool? ?? false;
    final ignoreSsl = j['ignore_ssl'] as bool? ?? false;
    var kind = switch (j['kind'] as String?) {
      'jellyfin' => ServerKind.jellyfin,
      'ugreen' => ServerKind.ugreen,
      // 旧版本没有 ugreen 这个值，历史配置仍按 Emby 还原。
      _ => ServerKind.emby,
    };
    // v2.0.87 的绿联配置是「Emby + HTTPS 9443 + 忽略证书」。升级到 88
    // 时自动识别为独立类型，否则旧配置仍会拼 /emby 资源地址而继续裂图。
    // 条件足够窄：9443 是影视中心固定端口，标准 Emby 不会同时满足。
    if (kind == ServerKind.emby && ignoreSsl && secure && port == 9443) {
      kind = ServerKind.ugreen;
    }
    return ServerProfile(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      host: j['host'] as String? ?? '',
      port: port,
      secure: secure,
      username: j['username'] as String? ?? '',
      password: j['password'] as String? ?? '',
      kind: kind,
      // 旧配置没有这个键 → 默认关闭，不会把旧版「隐式全开」继承过来
      ignoreSsl: ignoreSsl,
    );
  }
}

/// 归一后的性别取值（v2.0.61 / G4）。
const String kGenderFemale = 'female';
const String kGenderMale = 'male';

/// 性别归一：**只有服务端明确给了才认**，其余一律返回 null，UI 走中性，
/// 绝不按名字、角色或「有没有头像」去猜性别。
///
/// 标准 Emby 的 `People[]` / Person item 没有性别字段；部分刮削器 / 插件会
/// 写 `Gender` / `Sex`，这里只做保守的字符串归一，识别不了就当「未知」。
/// 之前详情页把每个演员都写死 ♀，才导致男优被全标成女性（v2.0.61 修）。
String? normalizeGender(dynamic raw) {
  if (raw == null) return null;
  final s = raw.toString().trim().toLowerCase();
  if (s.isEmpty) return null;
  const females = {'female', 'f', 'woman', 'girl', '女', '女性', '女优'};
  const males = {'male', 'm', 'man', 'boy', '男', '男性', '男优'};
  if (females.contains(s)) return kGenderFemale;
  if (males.contains(s)) return kGenderMale;
  return null;
}

/// 演职人员（含图片信息，头像走 Emby 图片接口）
class CastMember {
  const CastMember({
    required this.name,
    this.role = '',
    this.id,
    this.imageTag,
    this.gender,
  });
  final String name;
  final String role;
  final String? id; // Emby Person ItemId
  final String? imageTag; // PrimaryImageTag

  /// 归一后的性别：[kGenderFemale] / [kGenderMale] / null。
  /// null = 服务端没给，UI 必须走中性（G4），不得自行推断。
  final String? gender;

  Map<String, dynamic> toJson() => {
    'name': name,
    'role': role,
    'id': id,
    'imageTag': imageTag,
    'gender': gender,
  };

  factory CastMember.fromJson(Map<String, dynamic> j) => CastMember(
    name: j['name'] as String? ?? '',
    role: j['role'] as String? ?? '',
    id: j['id'] as String?,
    imageTag: j['imageTag'] as String?,
    // 归一一次：兼容旧缓存（无 gender）与任何脏值
    gender: normalizeGender(j['gender']),
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
    this.serverId,
    this.playlistId,
    this.pendingSync = false,
  });

  final String id;
  final String name;
  final List<String> itemIds;
  final int createdAt;

  /// 归属的服务器 profile id（v1.7.65 新增）。
  /// 旧版收藏夹无此字段，多服务器时会把 A 的收藏夹渲染到 B 上；
  /// connect 时若为空会回填为当前激活服务器 id。
  final String? serverId;

  /// 同步到的服务端播放列表 Id（null = 仅本地，未上云）
  final String? playlistId;

  /// 上行标记：本收藏夹的「创建/改名/增删影片」上云失败时置位，
  /// 下次同步会重试并清除（v1.7.68，避免静默丢失）。
  final bool pendingSync;

  FavoriteFolder copyWith({
    String? name,
    List<String>? itemIds,
    String? serverId,
    String? playlistId,
    bool? pendingSync,
  }) => FavoriteFolder(
    id: id,
    name: name ?? this.name,
    itemIds: itemIds ?? this.itemIds,
    createdAt: createdAt,
    serverId: serverId ?? this.serverId,
    playlistId: playlistId ?? this.playlistId,
    pendingSync: pendingSync ?? this.pendingSync,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'itemIds': itemIds,
    'createdAt': createdAt,
    if (serverId != null) 'serverId': serverId,
    if (playlistId != null) 'playlistId': playlistId,
    if (pendingSync) 'pendingSync': true,
  };

  factory FavoriteFolder.fromJson(Map<String, dynamic> j) => FavoriteFolder(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '未命名收藏夹',
    itemIds: (j['itemIds'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(),
    createdAt: j['createdAt'] as int? ?? 0,
    serverId: j['serverId'] as String?,
    playlistId: j['playlistId'] as String?,
    pendingSync: j['pendingSync'] as bool? ?? false,
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
    this.sourcePath = '',
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

  /// 字幕文件在服务器上的绝对路径（`MediaStreams[].Path`）。
  ///
  /// strm 片源上它是唯一还能拿到字幕的线索 —— `/Videos/…/Subtitles/…` 那几条
  /// 路由对 strm 常常 404，只能用 `/Items/{id}/File?Path=` 直取文件。
  final String sourcePath;

  /// 是否为中文字幕。
  ///
  /// v1.7.23 起判定链改为三级：语言代码 → 显示名 → 文件路径/文件名，
  /// 因为外挂字幕在 Emby 里经常 `Language` 为空、`DisplayTitle` 只有 `(SRT)`，
  /// 只看语言会把它们全判成「未知」。
  ///
  /// v1.7.27 补了一条兜底：**完全没有语言标记的文本字幕默认当中文**。
  /// 中文用户的片源以中字为主，漏判的代价（标签不出现、不自动预选）远大于
  /// 误判的代价（多一个标签，用户还能自己换）。
  bool get isChinese {
    const zhLangs = {
      'chi',
      'zho',
      'zh',
      'zh-cn',
      'zh-hans',
      'zh-hant',
      'chs',
      'cht',
    };
    final lang = language.toLowerCase().trim();
    if (zhLangs.contains(lang)) return true;

    // 明确是外语的不翻转（保真）
    const foreign = {
      'eng',
      'en',
      'jpn',
      'ja',
      'kor',
      'ko',
      'fre',
      'fra',
      'fr',
      'ger',
      'deu',
      'de',
      'spa',
      'es',
      'rus',
      'ru',
      'ita',
      'it',
      'por',
      'pt',
      'tha',
      'th',
      'vie',
      'vi',
    };
    final knownForeign = foreign.contains(lang);

    // 第二级：显示名里的中文标记（用分段匹配，避免 "scene" 里的 "en" 之类误伤）
    if (_hasZhMarker(displayTitle)) return true;
    // 第三级：外挂字幕的文件名 / 路径
    if (_hasZhMarker(sourcePath)) return true;
    if (_hasZhMarker(url ?? '')) return true;

    if (knownForeign) return false;

    // 兜底：无语言标记的文本字幕（srt/ass/ssa/vtt/sub/smi）默认中文。
    // pgs/sup 是图片字幕，无法叠加渲染，不参与兜底。
    final c = codec.toLowerCase();
    final isText =
        c.contains('srt') ||
        c.contains('subrip') ||
        c.contains('ass') ||
        c.contains('ssa') ||
        c.contains('vtt') ||
        c.contains('smi') ||
        c.contains('text');
    return isText;
  }

  /// 在一段文本里找中文标记。按分隔符切段后再比对，避免 `scene` 命中 `en`、
  /// `menu` 命中 `en` 这类子串误判。
  static bool _hasZhMarker(String s) {
    if (s.isEmpty) return false;
    // 直接含中日韩统一表意文字 → 一定是中文（显示名常写成「简体中文」）
    for (final r in s.runes) {
      if (r >= 0x4E00 && r <= 0x9FFF) return true;
    }
    final lower = s.toLowerCase();
    // 先按常见分隔符切成「词」，再做全词/前后缀比对
    final tokens = lower.split(RegExp(r'[^a-z0-9]+'));
    const zhTokens = {'chs', 'cht', 'chi', 'zho', 'zh', 'cn', 'gb', 'big5'};
    for (final t in tokens) {
      if (t.isEmpty) continue;
      if (zhTokens.contains(t)) return true;
      // zh-cn 会被切成 zh 和 cn，上面的集合已覆盖；这里补 chinese/zh_cn 之类
      if (t == 'chinese' ||
          t == 'mandarin' ||
          t == 'simplified' ||
          t == 'traditional') {
        return true;
      }
    }
    return false;
  }

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
    'sourcePath': sourcePath,
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
        sourcePath: j['sourcePath'] as String? ?? '',
      );
}

/// 从文件名 / 名称推断分辨率高度（2160 / 1440 / 1080 / 720 / 576 / 480 / 360 / 4320）。
///
/// 部分自建库的 MediaStreams / MediaSource 缺宽高（刮削失败、strm、NFO 导入，
/// 或某些 Emby 兼容实现只回文件名不回尺寸），Height 会落空。只要名字里带
/// `Movie.2160p.WEB-DL`、`4K`、`UHD` 这类标记就采信，避免版本选择器 / 播放页
/// 把 4K 源误显示成主版本的 1080p。返回 null 表示名字里没有可靠标记，
/// 调用方继续走 MediaStreams / 默认值。
///
/// v2.0.69：从 [EmbyClient._heightFromName] 抽出在此共享，让 [MediaExtraPart]
/// 的版本解析与主条目解析共用同一套推断，不再各写一遍。
int? heightFromName(String name) {
  final s = name.toLowerCase();
  final m = RegExp(r'(?<![0-9])(2160|1440|1080|720|576|480|360)p(?![0-9a-z])')
      .firstMatch(s);
  if (m != null) return int.parse(m.group(1)!);
  if (RegExp(r'(?<![0-9a-z])8k(?![0-9a-z])').hasMatch(s)) return 4320;
  if (RegExp(r'(?<![0-9a-z])4k(?![0-9a-z])').hasMatch(s)) return 2160;
  if (RegExp(r'(?<![0-9a-z])(uhd|uhdrip)(?![0-9a-z])').hasMatch(s)) return 2160;
  if (RegExp(r'(?<![0-9a-z])hdrip(?![0-9a-z])').hasMatch(s)) return 720;
  return null;
}

/// 「额外部分」：影片同一条目下的其它 MediaSource（Emby 网页版的「额外部分」）。
///
/// 典型场景：`xxx-Cd1.mkv` + `xxx-Cd2.mkv` 被识别成同一影片的两个来源，
/// 或同一部片的不同分辨率/版本。详情页列出后可单独起播。
class MediaExtraPart {
  const MediaExtraPart({
    required this.id,
    required this.name,
    this.path = '',
    this.runtimeTicks = 0,
    this.container = '',
    this.width = 0,
    this.height = 0,
    this.videoCodec = '',
    this.audioCodec = '',
    this.audioChannels = 0,
    this.audioLanguage = '',
    this.audioDefault = false,
    this.subtitleTracks = const <String>[],
    this.sizeBytes = 0,
    this.isPrimary = false,
  });

  /// MediaSource 的 Id（起播时作为 `MediaSourceId` 传参）
  final String id;

  /// 展示名：优先 `Name`，为空时退化为文件名（去掉扩展名）
  final String name;

  /// 源文件路径（服务器未开放时为空）
  final String path;
  final int runtimeTicks;
  final String container;

  /// v2.0.65「版本」选择器用：视频宽高、音频声道 / 语言 / 默认轨、字幕轨。
  /// 全部取自 `MediaSources[i].MediaStreams`，服务端缺字段时保持空值。
  final int width;
  final int height;
  final String videoCodec;
  final String audioCodec;
  final int audioChannels;
  final String audioLanguage;
  final bool audioDefault;
  final List<String> subtitleTracks;
  final int sizeBytes;

  /// 是否为主版本（主版本不进「额外部分」列表，仅用于排序判断）
  final bool isPrimary;

  /// 仅用于媒体源解析时给排序后的第一条打主版本标记。
  MediaExtraPart copyWith({bool? isPrimary}) => MediaExtraPart(
    id: id,
    name: name,
    path: path,
    runtimeTicks: runtimeTicks,
    container: container,
    width: width,
    height: height,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    audioChannels: audioChannels,
    audioLanguage: audioLanguage,
    audioDefault: audioDefault,
    subtitleTracks: subtitleTracks,
    sizeBytes: sizeBytes,
    isPrimary: isPrimary ?? this.isPrimary,
  );

  /// 时长（分钟）
  int get runtimeMin =>
      runtimeTicks <= 0 ? 0 : (runtimeTicks / 600000000).round();

  /// 规格文案：`1080P H264 · AAC · 2小时32分钟`
  String get specLine {
    final parts = <String>[
      if (height > 0) '${height}P',
      if (videoCodec.isNotEmpty) videoCodec.toUpperCase(),
      if (audioCodec.isNotEmpty) audioCodec.toUpperCase(),
    ];
    final spec = parts.join(' ');
    final m = runtimeMin;
    final dur = m <= 0 ? '' : (m >= 60 ? '${m ~/ 60}小时${m % 60}分钟' : '$m分钟');
    return [spec, dur].where((e) => e.isNotEmpty).join(' · ');
  }

  /// 人类可读体积：`20.31 GB` / `820 MB`。
  String get sizeLabel {
    if (sizeBytes <= 0) return '';
    final gb = sizeBytes / 1073741824;
    if (gb >= 1) return '${gb.toStringAsFixed(2)} GB';
    final mb = sizeBytes / 1048576;
    if (mb >= 1) return '${mb.round()} MB';
    return '${(sizeBytes / 1024).round()} KB';
  }

  /// 分辨率档位：2160 及以上统一写「4K」，与网页端版本下拉一致。
  String get resolutionLabel {
    if (height >= 2160) return '4K';
    if (height >= 1080) return '1080P';
    if (height >= 720) return '720P';
    if (height > 0) return '${height}P';
    return '';
  }

  /// 版本框下方的视频规格胶囊：`4K HEVC`、`1080P H264`。
  String get videoLabel => [
    resolutionLabel,
    if (videoCodec.isNotEmpty) videoCodec.toUpperCase(),
  ].where((e) => e.isNotEmpty).join(' ');

  /// 音频规格胶囊：`AAC stereo (默认)`、`TrueHD 5.1`。
  String get audioLabel {
    if (audioCodec.isEmpty && audioChannels == 0) return '';
    String ch = '';
    if (audioChannels == 1) {
      ch = 'mono';
    } else if (audioChannels == 2) {
      ch = 'stereo';
    } else if (audioChannels == 6) {
      ch = '5.1';
    } else if (audioChannels == 8) {
      ch = '7.1';
    } else if (audioChannels > 0) {
      ch = '${audioChannels}ch';
    }
    final base = [
      audioCodec.toUpperCase(),
      ch,
    ].where((e) => e.isNotEmpty).join(' ');
    return audioDefault ? '$base (默认)' : base;
  }

  /// 字幕规格胶囊：`(SRT)` / `(SRT / ASS)`；无字幕轨时为空（不渲染胶囊）。
  String get subtitleLabel =>
      subtitleTracks.isEmpty ? '' : '(${subtitleTracks.join(' / ')})';

  /// 版本下拉每一项右侧的副标题：`4K · MKV · 20.31 GB`。
  String get versionSubtitle => [
    resolutionLabel,
    if (container.isNotEmpty) container.toUpperCase(),
    sizeLabel,
  ].where((e) => e.isNotEmpty).join(' · ');

  /// 从 Emby `MediaSources[i]` 解析；解析失败返回 null（由调用方过滤）。
  static MediaExtraPart? fromJson(Map<String, dynamic> j) {
    final id = (j['Id'] as String?)?.trim() ?? '';
    final path = ((j['Path'] as String?) ?? '').trim();
    if (id.isEmpty && path.isEmpty) return null;

    // 名称优先级：Name → 文件名去扩展名
    var name = ((j['Name'] as String?) ?? '').trim();
    if (name.isEmpty && path.isNotEmpty) {
      final seg = path.split(RegExp(r'[\\/]')).last;
      final dot = seg.lastIndexOf('.');
      name = dot > 0 ? seg.substring(0, dot) : seg;
    }
    if (name.isEmpty) name = '分段 ${id.isEmpty ? '?' : id}';

    // 分辨率 / 编码：优先取视频流，退化到源级字段，最后从名字兜底（v2.0.69）。
    // 部分服务端不回版本源的宽高，直接读会是 0，导致版本选择器 / 播放页把 4K
    // 源误显示成主版本的 1080p。名字里带 `2160p`/`4K`/`UHD` 就采信。
    var width = (j['Width'] as num?)?.toInt() ?? 0;
    var height = (j['Height'] as num?)?.toInt() ?? 0;
    if (height == 0) {
      final h = heightFromName(name) ?? heightFromName(path);
      if (h != null) height = h;
    }
    var vcodec = ((j['VideoCodec'] as String?) ?? '');
    var acodec = ((j['AudioCodec'] as String?) ?? '');
    var channels = 0;
    var language = '';
    var audioDefault = false;
    final subs = <String>[];
    final streams = j['MediaStreams'];
    if (streams is List) {
      for (final s in streams) {
        if (s is! Map) continue;
        final t = ((s['Type'] as String?) ?? '').toLowerCase();
        if (t == 'video') {
          if (width == 0) width = (s['Width'] as num?)?.toInt() ?? 0;
          if (height == 0) height = (s['Height'] as num?)?.toInt() ?? 0;
          if (vcodec.isEmpty) vcodec = (s['Codec'] as String?) ?? '';
        } else if (t == 'audio') {
          if (acodec.isEmpty) acodec = (s['Codec'] as String?) ?? '';
          if (channels == 0) channels = (s['Channels'] as num?)?.toInt() ?? 0;
          if (language.isEmpty) {
            language = ((s['Language'] as String?) ?? '').trim();
          }
          if (s['IsDefault'] == true) audioDefault = true;
        } else if (t == 'subtitle' && subs.length < 4) {
          var label = ((s['DisplayTitle'] as String?) ?? '').trim();
          if (label.isEmpty) {
            label = ((s['Codec'] as String?) ?? '').trim().toUpperCase();
          }
          if (label.isEmpty) {
            label = ((s['Language'] as String?) ?? '').trim().toUpperCase();
          }
          // DisplayTitle 常自带括号（如「(SRT)」），统一去掉后由
          // subtitleLabel 自己包一层，避免「((SRT))」。
          label = label.replaceAll(RegExp(r'^\(+|\)+$'), '').trim();
          if (label.isNotEmpty && !subs.contains(label)) subs.add(label);
        }
      }
    }

    return MediaExtraPart(
      id: id,
      name: name,
      path: path,
      runtimeTicks: (j['RunTimeTicks'] as num?)?.toInt() ?? 0,
      container: ((j['Container'] as String?) ?? '').trim(),
      width: width,
      height: height,
      videoCodec: vcodec,
      audioCodec: acodec,
      audioChannels: channels,
      audioLanguage: language,
      audioDefault: audioDefault,
      subtitleTracks: List<String>.unmodifiable(subs),
      sizeBytes: (j['Size'] as num?)?.toInt() ?? 0,
    );
  }
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
    this.videoRange = VideoRange.unknown,
    this.audioStreamIndex,
    this.mediaSourceId,
    this.resumeProgress,
    this.resumeSeconds,
    this.episodeTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.parentId,
    this.childCount = 0,
    this.seriesId,
    this.videoUrl,
    this.posterUrl,
    this.posterAspect = 0.6667,
    this.backdropUrl,
    this.backdrops = const [],
    this.trailerUrls = const [],
    this.extraParts = const [],
    this.resolutionKnown = true,
    this.reason,
    this.addedDaysAgo = 0,
    this.filePath = '',
    this.fileSizeBytes = 0,
    this.dateCreatedMs,
    this.premiereDate = '',
    this.seriesName = '',
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

  /// 视频动态范围（v2.0.83）。unknown 表示老缓存 / 服务端未给，
  /// 展示与播放决策统一走 [effectiveRange] 降级，不直接读这个字段。
  final VideoRange videoRange;

  /// 首选音轨在 MediaStreams 里的 Index，构造转码 URL 时要精确指定。
  final int? audioStreamIndex;

  /// MediaSources[0].Id，直连与转码 URL 都需要（Emby 文档列为必需参数）。
  final String? mediaSourceId;
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

  /// 直接父条目 Id。分集是 Season 的 `ParentId`，Season 是 Series 的。
  /// v2.0.92 起用它判断「这一集属于哪一季」，比只靠 `ParentIndexNumber`
  /// 更可靠（有些固件 `ParentIndexNumber` 给 0 或干脆不给）。
  final String? parentId;

  /// 子条目数量（Season 条的 `ChildCount` = 该季集数）。
  /// 分集还没拉回来时，季标签能先显示「10集」。
  final int childCount;

  final String? seriesId;
  final String? videoUrl;
  final String? posterUrl;

  /// 海报原始宽高比（Emby PrimaryImageAspectRatio，缺省 2:3）
  final double posterAspect;
  final String? backdropUrl;

  /// 全部横版剧照地址（Backdrop 0..n）
  final List<String> backdrops;

  /// 远程预告片地址（Emby RemoteTrailers，通常是 YouTube 等外链）
  final List<String> trailerUrls;

  /// 「额外部分」：同一影片的其它 MediaSource（如 `xxx-Cd1` / `xxx-Cd2`）。
  ///
  /// Emby 把同一部片的多个分段/多版本挂在一个条目下的 `MediaSources` 列表里，
  /// 网页版详情页会列出其余的作为「额外部分」并可直接播放。这里只保存除
  /// 「主版本」之外的其余来源，按 `Index` / `Id` 排序。
  final List<MediaExtraPart> extraParts;

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

  /// 发行日期（Emby `PremiereDate`，如 2021-12-23）。
  /// 详情页「信息区」展示；缺失时回退到 [year]。
  final String premiereDate;

  /// 所属系列（Emby `SeriesName`）。电影条目常为空，详情页为空时不显示该格。
  final String seriesName;

  final int userPlayCount;
  final bool userPlayed;
  final bool userFavorite;
  final int? lastPlayedAt; // ms 时间戳

  bool get isMovie => type == MediaType.movie;
  bool get isSeries => type == MediaType.series;
  bool get isSeason => type == MediaType.season;
  bool get isEpisode => type == MediaType.episode;
  bool get isTrue4K => videoHeight >= 2160;

  /// 是否为 strm 片源。
  ///
  /// strm 只是一行 URL 的占位文件，Emby 扫库时**不探测远端**，媒体信息
  /// （时长 / 分辨率 / 码率）要等首次播放才临时 ffprobe —— 这是它首播慢、
  /// 且经常读不到时长的根源。识别出来才能在播放策略上单独对待。
  ///
  /// 判据用 `MediaSources[0].Path` 的后缀：Emby 对 strm 条目的 Path 仍是
  /// 那个 `.strm` 文件本身，不是它指向的 URL。服务端隐藏 Path 时退化为
  /// 「容器名是 STRM」这一条（部分版本会这么填）。
  bool get isStrm {
    final p = filePath.toLowerCase();
    return p.endsWith('.strm') || container.toUpperCase() == 'STRM';
  }

  /// 兼容老缓存：没有 videoRange 时由旧的 isHdr / hasDolbyVision 反推。
  /// 新数据一律以 [videoRange] 为准，两个旧 bool 只作为统计与筛选的镜像值。
  VideoRange get effectiveRange {
    if (videoRange != VideoRange.unknown) return videoRange;
    if (hasDolbyVision) return VideoRange.dovi;
    if (isHdr) return VideoRange.hdr10;
    return VideoRange.sdr;
  }

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
    // v2.0.83：DV 是视频动态范围，ATMOS 是音轨，不能混成一个标签。
    if (effectiveRange.isHdr) effectiveRange.label,
    if (audioChannels >= 8) '${(audioChannels / 2).toStringAsFixed(1)}',
    videoCodec.toUpperCase() == 'H265' ? 'HEVC' : videoCodec.toUpperCase(),
  ];

  MediaItem copyWith({
    bool? userFavorite,
    double? resumeProgress,
    double? resumeSeconds,
    bool? userPlayed,
    int? lastPlayedAt,
    int? userPlayCount,
    List<MediaExtraPart>? extraParts,
    String? seriesName,
    // v2.0.66：媒体源规格，供 [withMediaSource] 覆盖播放页展示信息
    int? videoHeight,
    String? videoCodec,
    String? audioCodec,
    int? audioChannels,
    String? container,
    int? fileSizeBytes,
    String? filePath,
    bool? resolutionKnown,
    VideoRange? videoRange,
    int? audioStreamIndex,
    String? mediaSourceId,
  }) {
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
      videoHeight: videoHeight ?? this.videoHeight,
      videoCodec: videoCodec ?? this.videoCodec,
      audioCodec: audioCodec ?? this.audioCodec,
      audioChannels: audioChannels ?? this.audioChannels,
      container: container ?? this.container,
      isHdr: isHdr,
      hasDolbyVision: hasDolbyVision,
      videoRange: videoRange ?? this.videoRange,
      audioStreamIndex: audioStreamIndex ?? this.audioStreamIndex,
      mediaSourceId: mediaSourceId ?? this.mediaSourceId,
      resumeProgress: resumeProgress ?? this.resumeProgress,
      resumeSeconds: resumeSeconds ?? this.resumeSeconds,
      episodeTitle: episodeTitle,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      parentId: parentId,
      childCount: childCount,
      seriesId: seriesId,
      videoUrl: videoUrl,
      posterUrl: posterUrl,
      posterAspect: posterAspect,
      backdropUrl: backdropUrl,
      backdrops: backdrops,
      extraParts: extraParts ?? this.extraParts,
      resolutionKnown: resolutionKnown ?? this.resolutionKnown,
      reason: reason,
      addedDaysAgo: addedDaysAgo,
      userPlayCount: userPlayCount ?? this.userPlayCount,
      userPlayed: userPlayed ?? this.userPlayed,
      userFavorite: userFavorite ?? this.userFavorite,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      filePath: filePath ?? this.filePath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      dateCreatedMs: dateCreatedMs,
      premiereDate: premiereDate,
      seriesName: seriesName ?? this.seriesName,
    );
  }

  /// v2.0.66：把某个 MediaSource 的规格覆盖到「展示用」item 上。
  ///
  /// 播放页顶栏副行（`内核 · 分辨率 · 编码 · 声道`）与「播放信息」面板读的
  /// 都是 item 级字段。以前切到非主版本只透传 `MediaSourceId`，item 仍是
  /// 主版本，于是选了 4K 却依旧显示 1080p。起播前覆盖一次即可全联动。
  ///
  /// 服务端缺字段时保留 item 原值，避免出现 `0p` / 空编码 / 0 B。
  /// 动态范围（Dolby Vision / HDR）是 Item 级元数据，MediaSources 未给，
  /// 这里不动。
  MediaItem withMediaSource(MediaExtraPart p) => copyWith(
    videoHeight: p.height > 0 ? p.height : null,
    videoCodec: p.videoCodec.isNotEmpty ? p.videoCodec : null,
    audioCodec: p.audioCodec.isNotEmpty ? p.audioCodec : null,
    audioChannels: p.audioChannels > 0 ? p.audioChannels : null,
    container: p.container.isNotEmpty ? p.container.toUpperCase() : null,
    fileSizeBytes: p.sizeBytes > 0 ? p.sizeBytes : null,
    filePath: p.path.isNotEmpty ? p.path : null,
    resolutionKnown: p.height > 0 ? true : null,
  );

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
    'videoRange': videoRange.name,
    'audioStreamIndex': audioStreamIndex,
    'mediaSourceId': mediaSourceId,
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
    'premiereDate': premiereDate,
    'seriesName': seriesName,
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
      videoRange: _videoRangeFromJson(j),
      audioStreamIndex: (j['audioStreamIndex'] as num?)?.toInt(),
      mediaSourceId: j['mediaSourceId'] as String?,
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
      trailerUrls: ((j['trailerUrls'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      // 额外部分：仅用于内存中的详情页展示，序列化时带上不影响其它逻辑
      extraParts: ((j['extraParts'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MediaExtraPart.fromJson)
          .whereType<MediaExtraPart>()
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
      premiereDate: j['premiereDate'] as String? ?? '',
      seriesName: j['seriesName'] as String? ?? '',
    );
  }
}

/// v2.0.86：首页「最近添加」的「更多」要落到一个**虚拟媒体库**。
///
/// 它不是 Emby 的 UserView，所以刻意用一个带双下划线的哨兵 ID —— 服务器
/// 返回的 Id 全是 GUID / 数字，永不冲突。虚拟库不进 [AppState.views]，
/// 由媒体库页在 chip 行单独拼一项，取数直接走本地 `recentlyAdded`。
const String kRecentViewId = '__camby_recent__';

/// v2.0.88：首页「继续观看 → 查看全部」的落点。以前这个入口跳「全部」
/// 媒体库，语义不对（会看到所有影片而不是没看完的那几部）。
const String kContinueViewId = '__camby_continue__';

const LibraryView kRecentView = LibraryView(
  id: kRecentViewId,
  name: '最近添加',
);

const LibraryView kContinueView = LibraryView(
  id: kContinueViewId,
  name: '继续观看',
);

bool isVirtualViewId(String? id) =>
    id == kRecentViewId || id == kContinueViewId;

bool isRecentViewId(String? id) => id == kRecentViewId;

bool isContinueViewId(String? id) => id == kContinueViewId;

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
    required this.topMovies,
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

  /// 偏好影片 Top（本地 App 播放次数取前 10 部电影）
  final List<Map<String, dynamic>> topMovies;

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

  /// [localPlayCounts]：App 本地记录的播放次数（起播一次 +1，落盘持久化，
  /// 跨设备不共享）。与服务器 `userPlayCount` 取较大值，作为「有效播放次数」，
  /// 这样本机看过的片一定能进「偏好影片」，其它设备/官方客户端看过的也能纳入。
  static LibraryStats compute(
    List<MediaItem> items, [
    Map<String, int>? localPlayCounts,
  ]) {
    final movies = items.where((e) => e.isMovie).length;
    final series = items.where((e) => e.isSeries).length;
    final totalMin = items.fold<int>(0, (a, e) => a + e.runtimeMin);
    bool _isWatched(MediaItem e) =>
        e.userPlayed || (e.resumeProgress ?? 0) > 0.9;
    final watched = items.where(_isWatched).toList();
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

    // 偏好演员：统计对象 = 「继续观看」∪「完成观看」的影片（v2.0.26 起，在
    // 继续观看基础上并入已完成观看的影片，两种都算「真正看过的片」，演员各
    // 计 1 次；同一部片不会重复计数）。去掉了 v2.0.25 之前的本地累计时长规则。
    final includedActorIds = <String>{};
    final actorSource = <MediaItem>[];
    for (final e in items) {
      final r = e.resumeProgress ?? 0;
      final continuing = r > 0.01 && r < 0.99;
      final watched = e.userPlayed || r > 0.9;
      if ((continuing || watched) && includedActorIds.add(e.id)) {
        actorSource.add(e);
      }
    }
    final personFreq = <String, int>{};
    for (final e in actorSource) {
      for (final p in e.people.take(5)) {
        personFreq[p.name] = (personFreq[p.name] ?? 0) + 1;
      }
    }
    final topP = personFreq.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxP = topP.isEmpty ? 1 : topP.first.value;
    final topPeople = topP
        .take(5)
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

    // ── 偏好影片：有效播放次数取前 10 部影片（仅电影）──
    // 有效播放次数 = max(服务器 userPlayCount, 本机本地播放次数)。
    // 这样：① 在 App 里点开看过的片必然进榜（v2.0.27 只认服务器 PlayCount，
    //   而很多服务器不会自动给普通播放 +1，导致榜单永远空）；② 其它设备 /
    //   官方客户端看过的（服务端有 PlayCount）也照常计入；③ 取两者较大值，
    //   不会因为本机与服务器各记一遍而重复膨胀。
    // 先筛「电影 + 有效次数 >0」再排序取前 10，保证榜单始终是 10 部影片，
    // 不会被高播放次数的剧集挤掉名额。
    final playRanked = <Map<String, dynamic>>[];
    {
      final moviePlays = <Map<String, dynamic>>[];
      for (final e in items) {
        if (!e.isMovie) continue;
        final local = localPlayCounts?[e.id] ?? 0;
        final c = e.userPlayCount > local ? e.userPlayCount : local;
        if (c > 0) {
          moviePlays.add({'item': e, 'count': c});
        }
      }
      moviePlays.sort(
        (a, b) => (b['count'] as int).compareTo(a['count'] as int),
      );
      final maxPC = moviePlays.isEmpty ? 1 : moviePlays.first['count'] as int;
      for (final e in moviePlays.take(10)) {
        playRanked.add({
          'item': e['item'],
          'count': e['count'],
          'weight': (e['count'] as int) / maxPC,
        });
      }
    }

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
      // v2.0.16 修复：计数必须与标题列表同一套条件。旧实现 missingOverview
      // 只判 overview.isEmpty，而解析层把空简介替换成了「暂无简介」占位符，
      // 计数永远 0、列表却能列出条目（「缺简介 0 部」+ 8 条清单的矛盾）。
      missingPoster: missPoster.length,
      missingOverview: missOverview.length,
      tagCounts: tagCounts,
      tagDistribution: tagDist,
      topCast: topCast,
      topMovies: playRanked,
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
    this.events = const [],
  });

  final Map<String, int> itemPlays; // ItemId → 播放次数
  final List<int> hourHist; // 24 档
  final int total;

  /// 由 PlaybackStart/PlaybackStop 事件配对推算的观看时长（分钟）
  final double totalMinutes;

  /// 按日期聚合的观看分钟数（yyyy-MM-dd → 分钟）
  final Map<String, double> dailyMinutes;

  /// v2.0.86：PlaybackStart/Stop 配对后的逐次观看明细。
  /// 以前这份数据在 `activityLog()` 里算完日级分钟数就被丢掉了，
  /// 现在保留下来供观影日历回答「那天看了什么」。
  /// 片名由上层用库条目 / activityItemNames 反查（日志里只有 ItemId）。
  final List<WatchEvent> events;

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
///
/// 判定逻辑收敛到 [SubtitleTrackInfo.isChinese]：语言代码 → 显示名 → 文件路径
/// 三级匹配，并对外挂字幕做「无语言标记默认中文」兜底（v1.7.23 / v1.7.27）。
bool itemHasChineseSubtitle(MediaItem item) {
  for (final s in item.subtitles) {
    if (s.isChinese) return true;
  }
  return false;
}

/// v2.0.83 老缓存兼容：没有 videoRange 字段时，用旧的 isHdr /
/// hasDolbyVision 反推，避免全库条目一夜之间统一显示成 SDR。
VideoRange _videoRangeFromJson(Map<String, dynamic> j) {
  final raw = j['videoRange'];
  if (raw is String && raw.isNotEmpty) {
    return VideoRange.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => parseVideoRange(raw),
    );
  }
  if (j['hasDolbyVision'] == true) return VideoRange.dovi;
  if (j['isHdr'] == true) return VideoRange.hdr10;
  return VideoRange.unknown;
}

// ─────────────────────────────────────────────────────────────────────────
// 剧集「选季 → 选集」（v2.0.92）
//
// 剧集详情页原来只有一条横向分集条，混着所有季、按服务端返回顺序排，集数
// 一多就变成「一条永远划不到头的带子」，也分不清哪集属于哪季。这里改成
// 绿联影视中心那套交互：季标签行 + 每一季自己的集号网格，任何一集都能
// 直接点到。下面几个纯函数是那套面板的全部数据来源，方便单测覆盖。
// ─────────────────────────────────────────────────────────────────────────

/// 一季的分集集合。
class SeasonGroup {
  const SeasonGroup({
    required this.index,
    this.name = '',
    this.id,
    this.posterUrl,
    this.episodeCount = 0,
    this.episodes = const [],
    this.seriesId,
    this.seriesName = '',
  });

  /// 季号：`ParentIndexNumber` / `Season.IndexNumber`，特别篇为 0
  final int index;

  /// 服务端给的季名（如「第 1 季」「Specials」），为空时按季号生成
  final String name;

  /// Season 条目的 Id（标准 Emby/Jellyfin 有；绿联推导出来的为 null）
  final String? id;
  final String? posterUrl;

  /// 该季集数（分集未加载时用 Season 条的 `ChildCount` 兜底）
  final int episodeCount;

  /// 该季分集（已按 [compareEpisodes] 排好）
  final List<MediaItem> episodes;

  /// 这一季挂在哪个 Series 条目下（v2.0.93）。
  ///
  /// 标准 Emby / Jellyfin 一个剧集一个 Series，所有季都在同一个 id 下，
  /// 这里恒为当前剧的 id。**绿联影视中心不同**：它把每一季登记成独立的
  /// Series 条目（`瑞克和莫蒂 第5季`、`瑞克和莫蒂 第7季` 各是一个），
  /// 于是「同一部剧」在库里是好几条。合并展示时，点某一季必须知道该去
  /// 哪个 Series 拉分集 —— 就是靠这个字段。
  final String? seriesId;

  /// 该季所属 Series 的显示名（诊断与合并去重用）
  final String seriesName;

  /// 是否已经拿到分集（合并来的兄弟季初始为空，点开时才拉）
  bool get hasEpisodes => episodes.isNotEmpty;

  /// 是否为特别篇（`Season 0`）。Emby 惯例：0 季是花絮/特别篇。
  bool get isSpecial => index == 0;

  /// 标签文案：绿联是「第1季」，服务端给了名字就用名字
  String get label {
    final n = name.trim();
    if (n.isEmpty) return index == 0 ? '特别篇' : '第$index季';
    return n;
  }

  /// 「10集」这种短标签，绿联原版就写在季标签旁边
  String get countLabel {
    final n = episodes.isNotEmpty ? episodes.length : episodeCount;
    return n > 0 ? '$n集' : '';
  }
}

/// 按季号升序、集号升序排列分集。
///
/// 服务端（尤其绿联这类子集实现）不保证顺序，画面上「第 3 集」排在
/// 「第 1 集」前面会直接让人怀疑数据错了。缺集号时退到名字里的数字，
/// 再不行保持原序（`sort` 是稳定排序）。
int compareEpisodes(MediaItem a, MediaItem b) {
  final sa = a.seasonNumber ?? 0;
  final sb = b.seasonNumber ?? 0;
  if (sa != sb) return sa.compareTo(sb);
  final ea = a.episodeNumber ?? _leadingNumber(a.name);
  final eb = b.episodeNumber ?? _leadingNumber(b.name);
  if (ea != eb) return ea.compareTo(eb);
  return 0;
}

int _leadingNumber(String s) {
  final m = RegExp(r'\d+').firstMatch(s);
  return m == null ? 0 : (int.tryParse(m.group(0)!) ?? 0);
}

/// 把扁平分集列表切成按季分组的 [SeasonGroup] 列表（季号升序）。
///
/// 没有季号的条目（部分固件连 `ParentIndexNumber` 都不给）归到第 1 季 ——
/// 宁可让它出现在第 1 季里，也不能因为缺字段就从面板上消失。
List<SeasonGroup> seasonGroups(List<MediaItem> episodes) {
  final map = <int, List<MediaItem>>{};
  for (final e in episodes) {
    final k = e.seasonNumber ?? 1;
    (map[k] ??= <MediaItem>[]).add(e);
  }
  final keys = map.keys.toList()..sort();
  return [
    for (final k in keys)
      SeasonGroup(
        index: k,
        episodes: map[k]!..sort(compareEpisodes),
        episodeCount: map[k]!.length,
      ),
  ];
}

/// 从一集里解析出「下一集要播什么」。
///
/// 越过当前季边界时顺延到下一季的第 1 集；已是最后一集则返回 null，
/// 由调用方决定是否提示「已是最后一集」。
MediaItem? nextEpisode(List<MediaItem> all, MediaItem current) {
  if (all.isEmpty) return null;
  final sorted = [...all]..sort(compareEpisodes);
  final i = sorted.indexWhere((e) => e.id == current.id);
  if (i < 0 || i + 1 >= sorted.length) return null;
  return sorted[i + 1];
}

/// 给一个分集打上「S1E3」这种角标。
///
/// 集号缺失时用列表内序号兜底，保证任何服务端都不会出现 `S1E0`。
String episodeBadge(MediaItem e, {int fallbackIndex = 0}) {
  final s = e.seasonNumber ?? 1;
  final n = e.episodeNumber ?? (fallbackIndex + 1);
  return 'S${s}E$n';
}

// ─────────────────────────────────────────────────────────────────────────
// 「同一部剧被拆成多条」的识别与合并（v2.0.93）
//
// 标准 Emby / Jellyfin：一个 Series 下面挂 Season 1..N，库里只有一条记录。
// 绿联影视中心：把**每一季登记成一条独立的 Series**（「瑞克和莫蒂 第5季」
// 与「瑞克和莫蒂 第7季」是两条），于是打开第 5 季的详情页，季标签只有
// 第 5 季，看不到第 7 季 —— 用户说的「同一部剧没有合起来」就是这个。
//
// 合并靠名字：剥掉「第N季 / Season N / Sxx」后缀得到基名，基名相同的
// Series 认为是同一部剧的不同季。基名必须归一化后**完全相等**才合并，
// 宁可漏合也不能把《梦魇绝镇》和《梦魇绝镇：起源》错并成一部。
// ─────────────────────────────────────────────────────────────────────────

/// 季/部后缀的正则（结尾锚定）。
///
/// 覆盖中英常见写法：`第5季` `第五季` `5季` `Season 2` `season2`
/// `S02` `S2`。刻意**不**匹配 `Part 2` / `下` 这种语义模糊的尾巴。
/// 注意：Dart 的 RegExp 基于 ECMAScript，**不支持 lookbehind**，
/// 所以 `Sxx` 那支把前置分隔符写进匹配里（靠 `m.start` 一并剥掉）。
final RegExp _seasonSuffixRe = RegExp(
  // 分隔符是可选的：中文剧名常写成「瑞克和莫蒂第7季」，中间没有空格
  r'(?:[\s\-_·:：.()（）]+)?'
  r'(?:'
  r'第\s*[0-9０-９一二三四五六七八九十]+\s*[季部]'
  r'|season\s*[0-9]+'
  r'|[0-9]+\s*季'
  r'|[sS][0-9]{1,2}'
  r')'
  r'[\s\-_·:：.()（）]*$',
  caseSensitive: false,
);

/// 剥掉季后缀，得到「这部剧叫什么」。
///
/// 大写/小写、全角括号、尾部空白一并归一；只有确实剥掉了后缀才返回新值，
/// 否则原样返回（避免把 `S.W.A.T.` 这种名字啃掉）。
String seriesBaseName(String name) {
  var s = name.trim();
  if (s.isEmpty) return s;
  // 尾部若只剩一个孤零零的括号，先去掉
  s = s.replaceAll(RegExp(r'[\s\-_·]+$'), '');
  final m = _seasonSuffixRe.firstMatch(s);
  if (m == null || m.start == 0) return s;
  final base = s.substring(0, m.start).trim();
  // 剥完只剩空串说明整个名字就是「第5季」，那不算季后缀
  if (base.isEmpty) return s;
  return base;
}

/// 从 Series 名字里取季号；没有季后缀时返回 null。
///
/// `瑞克和莫蒂 第5季` → 5、`From Season 2` → 2、`某剧 S03` → 3、
/// `梦魇绝镇` → null（标准 Emby 的剧名，季信息在 Season 条目里）。
int? seasonFromSeriesName(String name) {
  final s = name.trim();
  if (s.isEmpty) return null;
  final m = _seasonSuffixRe.firstMatch(s);
  if (m == null) return null;
  final raw = m.group(0) ?? '';
  final ascii = RegExp(r'[0-9]+').firstMatch(raw);
  if (ascii != null) {
    final n = int.tryParse(ascii.group(0)!);
    if (n != null && n >= 0 && n <= 99) return n;
  }
  // 中文数字：只做到 19，再多也不会是「第几季」了。
  // 必须**先**判「十X」再判单字，否则「第十二季」会先命中「十」直接返回 10。
  const cn = '零一二三四五六七八九';
  final teen = RegExp(r'十([一二三四五六七八九])').firstMatch(raw);
  if (teen != null) return 10 + cn.indexOf(teen.group(1)!);
  if (raw.contains('十')) return 10;
  final c = RegExp(r'[一二三四五六七八九]').firstMatch(raw);
  if (c != null) return cn.indexOf(c.group(0)!) ;
}

/// 合并「本剧的季」与「同剧其它季的 Series」，按季号升序去重。
///
/// [current] 是当前 Series 的季（已带分集），[siblings] 是从其它 Series
/// 推导出来的季（分集为空，靠 [SeasonGroup.seriesId] 按需拉取）。
/// 同季号以 [current] 为准 —— 它一定带分集，且是用户点进来的那一条。
List<SeasonGroup> mergeSeasonGroups(
  List<SeasonGroup> current,
  List<SeasonGroup> siblings,
) {
  final byIndex = <int, SeasonGroup>{};
  for (final g in current) {
    byIndex[g.index] = g;
  }
  for (final g in siblings) {
    final exist = byIndex[g.index];
    if (exist == null) {
      byIndex[g.index] = g;
      continue;
    }
    // 同季号：保留带分集的那一份；两份都空就保留先到的
    if (!exist.hasEpisodes && g.hasEpisodes) byIndex[g.index] = g;
  }
  final keys = byIndex.keys.toList()..sort();
  return [for (final k in keys) byIndex[k]!];
}

/// 从全库列表里找出「同一部剧的其它季」，转成待合并的 [SeasonGroup]。
///
/// 只在 [pool] 里找 `type == series` 且基名与 [current] 相同的条目 ——
/// 不额外发请求，直接用 AppState 已加载的全量列表。基名归一化后必须
/// **完全相等**，`《梦魇绝镇》` 与 `《梦魇绝镇：起源》` 不会被并到一起。
///
/// 季号优先取名字里的后缀（`第5季` → 5）；名字里没有季号的 Series
/// 不参与合并（无法判断它属于哪一季，硬塞进去只会多出一个错标签）。
List<SeasonGroup> siblingSeasonGroups(
  MediaItem current,
  List<MediaItem> pool,
) {
  if (!current.isSeries) return const [];
  final base = seriesBaseName(current.name);
  if (base.isEmpty) return const [];
  final out = <SeasonGroup>[];
  final seen = <int>{};
  for (final p in pool) {
    if (p.id == current.id || !p.isSeries) continue;
    if (seriesBaseName(p.name) != base) continue;
    final idx = seasonFromSeriesName(p.name);
    if (idx == null) continue;
    if (!seen.add(idx)) continue;
    out.add(
      SeasonGroup(
        index: idx,
        name: p.name,
        id: p.id,
        // 兄弟季的季号与 Series id 都记下来：点开时才知道去哪一季拉分集
        seriesId: p.id,
        seriesName: p.name,
        posterUrl: p.posterUrl,
        episodeCount: p.childCount,
      ),
    );
  }
  out.sort((a, b) => a.index.compareTo(b.index));
  return out;
}
