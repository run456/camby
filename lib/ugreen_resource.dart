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

  void reset() {
    ugreenMode = false;
    preferredImageIndex = null;
    lastProbe = const <ResourceProbeResult>[];
    sampleImageUrl = null;
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
    for (final query in <String>['api_key=$token', 'Static=true&api_key=$token']) {
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

/// 绿联取流候选（v2.0.90）。
///
/// 与图片同理：不同 UGOS 固件对 stream 端点的前缀、`Static` 参数宽容度
/// 不一致，与其猜一个，不如按「最可能成功」排好序逐个试：
///
///  1. **STRM 原始地址** —— Item 的 `Path` 若本身就是 http(s)（.strm 条目），
///     直连原始地址最稳（文档 5.5：绿联的 stream 代理有 403 / 性能限制）。
///  2. 根路径 `/Videos/{id}/stream`（文档 6.3 坑 1 的标准答案）。
///  3. 根路径 + `Static=true`（部分固件要靠它才给原片而不是转码）。
///  4. `/emby` 前缀的两种形式（少数固件把兼容层挂在 Emby 原路径下）。
///  5. 最后兜 HLS `/master.m3u8`（有转码能力的固件才认）。
///
/// [enabled] 为 false 时只回原地址，标准 Emby / Jellyfin 行为不变。
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
