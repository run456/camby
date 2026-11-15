/// 绿联影视中心资源地址自适应（v2.0.89）。
///
/// v2.0.88 把资源地址固定成「根路径 + api_key + tag」，但真机上仍然裂图；
/// 而第三方播放器能拿到海报。差别可能落在三个互斥的地方：资源端点要不要
/// `/emby` 前缀、鉴权是 `api_key` query 还是 `X-Emby-Token` header、
/// 以及 tag 参数是否被固件接受。真机抓包拿不到，与其继续猜，不如把几种
/// 组合都列出来，让 App 自己逐个试并记住能用的那一个。
library;

import 'models.dart';

const String kEmbyPathPrefix = '/emby';

/// 一次资源探测的结果。
class ResourceProbeResult {
  const ResourceProbeResult({
    required this.label,
    required this.url,
    this.statusCode,
    this.contentType,
    this.error,
  });

  final String label;
  final String url;
  final int? statusCode;
  final String? contentType;
  final String? error;

  bool get ok =>
      error == null &&
      statusCode != null &&
      statusCode! >= 200 &&
      statusCode! < 400;

  String get summary {
    if (error != null) return '✗ $label：$error';
    final ct = contentType == null ? '' : ' · $contentType';
    return '${ok ? '✓' : '✗'} $label：HTTP $statusCode$ct';
  }
}

/// 全局资源策略。连接绿联后跑一次自检，把可用模板记下来；之后所有海报
/// 直接从该候选开始，不必每张图都从失败的组合重试一遍。
class ResourcePolicy {
  ResourcePolicy._();

  static final ResourcePolicy instance = ResourcePolicy._();

  /// 是否处于绿联模式（AppState 连接 / 断开时同步）。
  /// 关闭时候选生成器只返回原 URL，标准 Emby 行为完全不变。
  bool ugreenMode = false;

  /// 探测成功、或实际加载成功的候选下标。
  int? preferredImageIndex;

  /// 最近一次自检结果（诊断面板展示）。
  List<ResourceProbeResult> lastProbe = const <ResourceProbeResult>[];

  /// 自检用的样例海报 URL（库里没有海报时可能为 null）。
  String? sampleImageUrl;

  bool get probingDone => lastProbe.isNotEmpty;

  String get probeReport {
    if (lastProbe.isEmpty) return '（尚未自检，点「重新自检」开始）';
    final lines = lastProbe.map((e) => e.summary).toList();
    lines.add('');
    if (preferredImageIndex != null) {
      lines.add('→ 已采用候选 ${preferredImageIndex! + 1} 作为默认图片模板。');
    } else {
      lines.add('→ 全部候选失败，按错误归类排查：');
      lines.add('   TLS / Handshake：确认设置里已勾选「忽略 SSL 证书校验」；');
      lines.add('   403：影视中心 → 设置 → 媒体服务器，检查媒体库账号权限；');
      lines.add('   404：固件版本的图片路径不同，把上面的 URL 反馈给我。');
    }
    return lines.join('\n');
  }

  /// 最近一次改走本地局域网的网络自检结论（v2.0.91）。
  ///
  /// 有些网络里，手机与本机相同网段的请求会被系统 VPN / 分流规则接管，
  /// 走远端出口再绕回来，表现为「登录能通、取流 404」。这里记录对比结果。
  String localNetworkNote = '';

  void reset() {
    ugreenMode = false;
    preferredImageIndex = null;
    lastProbe = const <ResourceProbeResult>[];
    sampleImageUrl = null;
    localNetworkNote = '';
  }
}

bool _isEmbyImagePath(String path) =>
    path.contains('/Items/') && path.contains('/Images/');

/// 从 App 拼出的图片 URL 派生候选。顺序按「最可能成功」排：
/// 根路径优先，其次 `/emby` 前缀；`api_key` 优先，其次 `X-Emby-Token`；
/// 最后各来一次不带 tag 的最简形式。
///
/// [enabled] 为 false 时原样返回，标准 Emby / Jellyfin 不受影响。
List<String> imageUrlCandidates(String rawUrl, {bool enabled = false}) {
  if (!enabled) return <String>[rawUrl];
  final uri = Uri.tryParse(rawUrl);
  if (uri == null || !uri.hasScheme) return <String>[rawUrl];
  final path = uri.path;
  if (!_isEmbyImagePath(path)) return <String>[rawUrl];

  final q = Map<String, String>.from(uri.queryParameters);
  final token = q['api_key'] ?? q['X-Emby-Token'] ?? '';
  final tag = q['tag'];
  final width = q['maxWidth'] ?? '400';
  final base = '${uri.scheme}://${uri.host}:${uri.port}';
  final hasPrefix = path.startsWith('$kEmbyPathPrefix/');
  final clean = hasPrefix ? path.substring(kEmbyPathPrefix.length) : path;
  final paths = hasPrefix
      ? <String>[path, clean]
      : <String>[clean, '$kEmbyPathPrefix$clean'];

  final result = <String>[];
  void add(String p, Map<String, String> params) {
    final u = Uri.parse('$base$p').replace(queryParameters: params).toString();
    if (!result.contains(u)) result.add(u);
  }

  for (final auth in <String>['api_key', 'X-Emby-Token']) {
    for (final p in paths) {
      add(p, <String, String>{
        'maxWidth': width,
        if (tag != null && tag.isNotEmpty) 'tag': tag,
        auth: token,
      });
    }
  }
  // 部分固件不认 tag，最后各试一次无 tag 的最简形式
  for (final p in paths) {
    add(p, <String, String>{'maxWidth': width, 'api_key': token});
  }
  return result;
}

/// 播放地址候选（诊断面板列出，供浏览器 / VLC 逐个验证）。
/// 绿联不同固件的 stream 端点路径与 Static 参数宽容度不一致。
List<String> streamUrlCandidates(String rawUrl, {bool enabled = false}) {
  if (!enabled) return <String>[rawUrl];
  final uri = Uri.tryParse(rawUrl);
  if (uri == null || !uri.hasScheme || !uri.path.contains('/Videos/')) {
    return <String>[rawUrl];
  }
  final token = uri.queryParameters['api_key'] ?? '';
  final base = '${uri.scheme}://${uri.host}:${uri.port}';
  final path = uri.path;
  final hasPrefix = path.startsWith('$kEmbyPathPrefix/');
  final clean = hasPrefix ? path.substring(kEmbyPathPrefix.length) : path;
  final paths = hasPrefix
      ? <String>[path, clean]
      : <String>[clean, '$kEmbyPathPrefix$clean'];
  final out = <String>[];
  for (final p in paths) {
    for (final query in <String>[
      'api_key=$token',
      'Static=true&api_key=$token',
    ]) {
      final u = '$base$p?$query';
      if (!out.contains(u)) out.add(u);
    }
  }
  return out;
}

/// 给图片 / 播放请求补上 Emby 系鉴权头。
///
/// v2.0.88 的图片请求只有 `api_key` query，没有任何 Emby 头；绿联兼容层
/// 很可能只认 `X-Emby-Token` header（API 请求之所以通，是因为登录/拉库
/// 一直带着 `X-Emby-Authorization`）。两种都发，标准 Emby 也接受。
Map<String, String> embyAuthHeaders(String url, {bool enabled = false}) {
  if (!enabled) return const <String, String>{};
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return const <String, String>{};
  final token =
      uri.queryParameters['api_key'] ?? uri.queryParameters['X-Emby-Token'];
  if (token == null || token.isEmpty) return const <String, String>{};
  return <String, String>{
    'X-Emby-Token': token,
    'X-Emby-Authorization':
        'MediaBrowser Client="Camby", Device="Camby", DeviceId="camby01", '
        'Version="$kClientVersion", Token="$token"',
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };
}

/// 目标地址是否落在服务器自身（v2.0.90）。
///
/// 决定「要不要给这个请求带 Emby 鉴权头」：strm 片源普遍指向第三方 CDN /
/// 网盘反代，把访问令牌递过去既无必要也不安全。协议不同也算跨源。
bool sameOrigin(String url, String rootUrl) {
  final a = Uri.tryParse(url);
  final b = Uri.tryParse(rootUrl);
  if (a == null || b == null) return false;
  if (a.scheme != b.scheme) return false;
  if (a.host != b.host) return false;
  // Uri.port 会把默认端口补齐（https→443），两侧都取解析值即可直接比
  return a.port == b.port;
}

/// 取流 HTTP 状态的含义（v2.0.91）。
///
/// **404 不等于「路径写错」**：绿联这类兼容实现只在
/// Item 的 `MediaSources[].SupportedStreamingProtocols` 里登记了某种协议时
/// 才暴露对应的流端点，未登记就直接 404（而不是 403）。所以点播放前必须先
/// 看服务端声明支持什么，不能再按「几个常见 URL 挨个试」的思路处理。
String describeStreamStatus(int? code) {
  switch (code) {
    case 200:
      return '可用';
    case 206:
      return '可用（分段）';
    case 401:
      return '未授权 —— 令牌失效或该账号无此库权限';
    case 403:
      return '被拒 —— 检查「允许第三方软件访问 / 直链播放」';
    case 404:
      return '端点不可用 —— 该片源未声明这种取流协议（不是路径拼错）';
    case 405:
      return '方法不允许 —— 端点存在但不接受 GET';
    case 416:
      return '分段越界 —— 端点通常是通的，可忽略';
    case 500:
      return '服务端错误 —— 多半在尝试转码';
    default:
      return '未知状态';
  }
}

/// 是否属于「可以再试下一个地址」的状态（v2.0.91）。
///
/// 401/403 是账号权限问题，换路径没用；404 是协议未登记，换同协议的其它
/// 路径同样没用。只有 5xx / 416 / 超时这类才值得继续试。
bool shouldTryNextStream(int? code) {
  if (code == null) return true;
  return code >= 500 || code == 416 || code == 405;
}

/// 一次取流能力探测的完整结果（v2.0.91）。
///
/// 与 [ResourceProbeResult] 的区别：这里除了状态码，还要保留**服务端到底
/// 声明了什么**——`MediaSources[0]` 的 `SupportedStreamingProtocols` 是全网
/// 唯一能解释「为什么 404」的证据，必须原样展示给用户。
class StreamCapability {
  const StreamCapability({
    this.protocols = const <String>[],
    this.statusCode,
    this.contentType,
    this.error,
    this.mediaSourceCount = 0,
    this.reason = '',
    this.verifiedUrl,
  });

  /// v2.0.94：探测时**实际返回 200/206 的那条地址**。
  ///
  /// 这是「诊断里 206、起播却全 404」的关键：v2.0.91~93 把服务端
  /// `MediaSources` 给的直取地址只拿去探测、没往下游传，`resolveStreamUrls`
  /// 又按空的 `SupportedStreamingProtocols` 重新拼出 `/Videos/{id}/stream`，
  /// 于是探测和播放用的是两条不同 URL。留下这条，播放必须原样复用它。
  final String? verifiedUrl;

  /// 是否已经拿到一条实测能出数据的地址。
  bool get hasVerifiedUrl => verifiedUrl != null && verifiedUrl!.isNotEmpty;

  /// 服务端声明的取流协议，例如 `Http` / `Hls` / `File`。
  final List<String> protocols;

  /// 服务端能拿到的 `MediaSources` 条数。
  final int mediaSourceCount;

  /// 依据协议实际发出的探测请求状态（全部候选里最好的那个）。
  final int? statusCode;
  final String? contentType;
  final String? error;

  /// 结论：direct / hls / file / none。
  final String reason;

  /// 是否能直接播（Http 或 File 任一可用）。
  bool get canPlayDirect =>
      statusCode != null && statusCode! >= 200 && statusCode! < 300;

  bool get hasAnyProtocol => protocols.isNotEmpty;

  /// 给用户与管理端看的一句话结论。
  String get verdict {
    if (!hasAnyProtocol && mediaSourceCount == 0) {
      return '服务端没有返回 MediaSources —— 换用管理员账号，或该条目的'
          '媒体源对当前账号不可见。';
    }
    if (!hasAnyProtocol) {
      // v2.0.94：协议没声明不等于取不了流 —— 服务端把可直取地址放在
      // MediaSources 的 DirectStreamUrl / Url 里，但不写协议字段。
      // 真机 v2.0.93 的诊断就是「能力探测 HTTP 206 + video/x-matroska，
      // 起播却全 404」：探测用了服务端给的地址，播放却自己重新拼了一条
      // `/Videos/{id}/stream`。结论必须点明这是**地址没传下去**，不能再说
      // 成「内核取流方式问题」，否则会一直朝错误的方向排查。
      if (hasVerifiedUrl && (statusCode == 200 || statusCode == 206)) {
        return '未声明取流协议，但 MediaSources 给出了可直取地址，'
            '实测可用（HTTP $statusCode · '
            '${(contentType ?? '').isEmpty ? '未知类型' : contentType}）。'
            '此前起播误用了另拼的 stream 端点（404），现已改为直接使用'
            '服务端返回的地址。';
      }
      if (statusCode == 200 || statusCode == 206) {
        return '未声明取流协议，但取流端点实测可用（HTTP $statusCode · '
            '${(contentType ?? '').isEmpty ? '未知类型' : contentType}）—— '
            '地址和鉴权都没问题，请把这条诊断连同取流地址发回。';
      }
      return 'MediaSources 里没有 SupportedStreamingProtocols 字段 —— '
          '这台固件未声明取流协议，需要抓一次影视中心自身的播放请求。';
    }
    if (protocols.contains('file')) {
      return statusCode == null
          ? '服务端只声明了 File 协议，正在尝试 /Items/{id}/File。'
          : '服务端只提供 File 协议（点播原文），已按该端点播放。';
    }
    switch (statusCode) {
      case 200:
      case 206:
        return '服务端声明 ${protocols.join(' / ')}，对应端点可用。';
      case 401:
      case 403:
        return '服务端声明 ${protocols.join(' / ')}，但返回 $statusCode：'
            '请在影视中心 → 设置 → 媒体服务器，为当前账号开启'
            '「允许第三方软件访问 / 直链播放」。';
      case 404:
        return '服务端声明 ${protocols.join(' / ')}，探测却 404 —— '
            '说明声明与实现不一致，请把这段发给开发者。';
      default:
        return '服务端声明 ${protocols.join(' / ')}，探测结果：'
            '${error ?? 'HTTP $statusCode'}。';
    }
  }

  /// 给诊断面板看的脱敏地址：只留路径 + 关键 query，不把 api_key 整串
  /// 印到界面上（诊断文字可被复制/截图外传）。
  String? get verifiedUrlLabel {
    final raw = verifiedUrl;
    if (raw == null || raw.isEmpty) return null;
    final u = Uri.tryParse(raw);
    if (u == null) return raw;
    final q = u.queryParameters;
    final keep = <String>[
      if (q['Static'] != null) 'Static=${q['Static']}',
      if (q['MediaSourceId'] != null) 'ms',
    ];
    return '${u.path}${keep.isEmpty ? '' : '?${keep.join('&')}'}';
  }

  String get summary {
    final p = hasAnyProtocol ? protocols.join(' / ') : '（未声明）';
    final s = error != null
        ? '✗ $error'
        : (statusCode == null ? '未探测' : 'HTTP $statusCode');
    final ct = contentType == null ? '' : ' · $contentType';
    return '声明协议：$p · 探测：$s$ct · MediaSources $mediaSourceCount 条';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocols': protocols,
    'mediaSourceCount': mediaSourceCount,
    'statusCode': statusCode,
    'contentType': contentType,
    'error': error,
    'reason': reason,
    if (verifiedUrl != null) 'verifiedUrl': verifiedUrl,
  };
}

/// 从 `MediaSources` 里读出 `SupportedStreamingProtocols`（v2.0.91）。
///
/// 该字段在标准 Emby 里是 `Http,Http,Sync` 这样的逗号串（可能是大小写混杂、
/// 也可能是数组），绿联只认它登记过的协议。任何形态都归一成小写去重列表。
List<String> parseStreamingProtocols(dynamic mediaSources) {
  final out = <String>[];
  final list = mediaSources is List ? mediaSources : const <dynamic>[];
  for (final ms in list) {
    if (ms is! Map) continue;
    final raw = ms['SupportedStreamingProtocols'];
    final parts = <String>[];
    if (raw is String) {
      parts.addAll(raw.split(','));
    } else if (raw is List) {
      parts.addAll(raw.map((e) => '$e'));
    }
    for (final p in parts) {
      final v = p.trim().toLowerCase();
      if (v.isEmpty) continue;
      if (!out.contains(v)) out.add(v);
    }
  }
  return out;
}

/// 依据服务端声明的协议决定取流端点（v2.0.91）。
///
/// 这是「全 404」的正解：不再猜路径，而是**按服务端登记过的协议**去请求。
///
///  · 声明 `http` → `<root>/Videos/{id}/stream`（+ `Static=true` 两种）
///  · 声明 `hls`  → `<root>/Videos/{id}/master.m3u8`
///  · 只声明 `file` → `<root>/Items/{id}/File`（点播原文，无 stream 路由）
///  · 一个都没声明 → 返回空列表，交给调用方走「诊断 + 提示」而不是瞎试
///
/// [enabled] 为 false 且未声明协议时原样返回 [fallback]，标准 Emby 不受影响。
List<String> urlsForProtocols({
  required List<String> protocols,
  required String rootUrl,
  required String itemId,
  String apiKey = '',
  String? fallback,
  bool enabled = false,
}) {
  final q = apiKey.isEmpty ? '' : '?api_key=$apiKey';
  final out = <String>[];
  void add(String u) {
    if (!out.contains(u)) out.add(u);
  }

  final hasHttp = protocols.contains('http');
  final hasHls = protocols.contains('hls');
  final hasFile = protocols.contains('file');

  if (hasHttp) {
    add('$rootUrl/Videos/$itemId/stream$q');
    add(
      '$rootUrl/Videos/$itemId/stream?Static=true'
      '${apiKey.isEmpty ? '' : '&api_key=$apiKey'}',
    );
  }
  if (hasHls) add('$rootUrl/Videos/$itemId/master.m3u8$q');
  if (hasFile || (!enabled && out.isEmpty))
    add('$rootUrl/Items/$itemId/File$q');

  if (out.isEmpty && fallback != null && fallback.isNotEmpty) add(fallback);
  return out;
}

/// 绿联取流候选（v2.0.90 引入，v2.0.91 起**已退出取流链路**）。
///
/// ⚠️ 不要再在业务代码里调用它。v2.0.90 装包实测：四条候选（根路径 /
/// `/emby` 前缀 × 带不带 `Static`）全部 404 —— 绿联对「没登记协议」的端点
/// 返回 404 而非 403，意味着枚举路径永远试不出来，只会拖慢起播、把诊断
/// 搅成一团 noise。v2.0.91 起取流一律走 `urlsForProtocols()`：
/// 先读 `MediaSources[].SupportedStreamingProtocols`，只拼服务端声明过的端点。
///
/// 保留本函数仅为兼容既有测试与历史记录，后续版本会移除。
@Deprecated('v2.0.91 起改走 urlsForProtocols()：先读 SupportedStreamingProtocols 再取址')
List<String> playbackCandidates({
  required String streamUrl,
  String filePath = '',
  String? hlsUrl,
  bool enabled = false,
}) {
  final out = <String>[];
  void add(String? u) {
    if (u == null || u.isEmpty) return;
    if (!out.contains(u)) out.add(u);
  }

  if (!enabled) {
    add(streamUrl);
    return out;
  }

  final p = filePath.trim();
  if (p.startsWith('http://') || p.startsWith('https://')) add(p);
  for (final u in streamUrlCandidates(streamUrl, enabled: true)) {
    add(u);
  }
  add(hlsUrl);
  return out;
}

/// 播放信息里「取流鉴权」一行的文案（v2.0.101）。
///
/// 以前只看「服务器有没有配置 streamHeaders」，与本次实际取流地址无关：
/// 一旦能力探测或回退把第三方直链排到第一位，明明一个头都没带，弹窗仍
/// 显示「X-Emby-Token 已注入」。真正的注入由 headersFor 按 sameOrigin 决定
/// —— 只有同源才带令牌，把访问令牌递给外部域既无必要也不安全。
///
/// 注意标准 Emby 的 strm 条目第一跳仍是服务器自己的 /Videos/{id}/stream，
/// 属于同源，注入令牌是**正确且必要**的；服务端再去读 strm 指向的直链，
/// 那一步由服务端发起，令牌不会外泄。这里按**本次取流地址**如实描述。
String describeStreamAuth({
  required bool connected,
  required bool hasUrl,
  required bool sameOrigin,
  required bool hasToken,
}) {
  if (!connected) return '未连接服务器';
  if (!hasUrl) return '尚未取流';
  if (!sameOrigin) return '外部直链 · 不注入令牌';
  if (!hasToken) return '未注入（服务器未配置令牌）';
  return 'X-Emby-Token 已注入';
}

/// 把海报地址里的 maxWidth 换成指定宽度，其余参数（tag / api_key）原样保留。
///
/// imageCacheKey 会保留 maxWidth，所以换成大尺寸后大图会落到**独立的**磁盘
/// 缓存项，不会被列表里 120px 的小图抢先写入后污染。原本没有 maxWidth 的
/// 第三方图地址不做改写，避免给它凭空加一个对方不认的参数。
String? posterUrlAtWidth(String? url, int maxWidth) {
  if (url == null || url.isEmpty) return url;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  if (!uri.queryParameters.containsKey('maxWidth')) return url;
  final q = Map<String, String>.from(uri.queryParameters)
    ..['maxWidth'] = '$maxWidth';
  return uri.replace(queryParameters: q).toString();
}
