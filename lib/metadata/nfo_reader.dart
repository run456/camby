import 'dart:convert';

import 'package:http/http.dart' as http;

/// NFO 侧车文件读取（v2.0.54 起）。
///
/// 电影条目的 NFO 常含 `<series>` / `<set><name>`（如「彼女の姉貴とイケナイ関係」），
/// 但 Emby 对 Movie 不会把它映射成 `SeriesName`，详情页「系列」因此显示「无」。
///
/// 兜底按优先级尝试两种取 NFO 的方式（详情见 [buildNfoUrls]）：
///  1. Emby 服务端代理 `/Items/{id}/File?Path=...`：复用播放时 Emby 已能访问的
///     同一个 Path 去取文件，最可靠——不依赖 AList / WebDAV 直链是否暴露 .nfo。
///  2. 媒体直链同目录同名 `.nfo`：适用于直链本身可读 .nfo 的场景。
///
/// 两者都异步、可失败静默、不做永久 null 缓存（网络抖动或 NFO 尚未补齐后能重试）。

/// 进程内缓存：仅缓存命中值。null 不缓存，避免对「暂无 NFO」永久卡死。
final Map<String, String?> _seriesCache = <String, String?>{};

/// 把媒体文件路径末尾扩展名换成 .nfo，返回完整的新 URL 字符串。
///
/// 与 [nfoUrlFromMediaPath] 不同，这里不限制 scheme：即使 filePath 是本地路径
///（如 `/volume1/.../x.mp4`），也能得到 `.../x.nfo`，便于作为 Emby 代理的
/// `Path` 参数。无法识别（无路径 / 是目录）时返回 null。
String? nfoPathFromMediaPath(String path) {
  final uri = Uri.tryParse(path.trim());
  if (uri == null) return null;
  final p = uri.path;
  if (p.isEmpty || p.endsWith('/')) return null;
  final ext = RegExp(r'\.[A-Za-z0-9]{1,5}$').firstMatch(p);
  final nfoPath = ext != null ? p.replaceRange(ext.start, p.length, '.nfo') : '$p.nfo';
  return uri.replace(path: nfoPath).toString();
}

/// 原 v2.0.54 入口：仅从 http(s) 直链派生同目录 .nfo（保留 query）。
String? nfoUrlFromMediaPath(String path) {
  final uri = Uri.tryParse(path.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final p = uri.path;
  if (p.isEmpty || p.endsWith('/')) return null;
  final ext = RegExp(r'\.[A-Za-z0-9]{1,5}$').firstMatch(p);
  final nfoPath = ext != null ? p.replaceRange(ext.start, p.length, '.nfo') : '$p.nfo';
  return uri.replace(path: nfoPath).toString();
}

/// 生成 NFO 候选 URL（按优先级，去重）：
///  1. Emby 服务端代理 `/Items/{id}/File?Path=...`（需 base / token / id 齐全）
///  2. 媒体直链同名 `.nfo`
///
/// Emby 代理优先：它复用播放时已能访问的同一 Path 取文件，不受直链是否暴露
/// `.nfo` 的限制；直链兜底覆盖代理不可用的场景（如离线 / 直链库但代理失败）。
List<String> buildNfoUrls(
  String filePath, {
  String? embyBase,
  String? embyToken,
  String? itemId,
}) {
  final out = <String>{};
  final nfoPath = nfoPathFromMediaPath(filePath);
  if (nfoPath != null &&
      embyBase != null &&
      embyBase.isNotEmpty &&
      embyToken != null &&
      embyToken.isNotEmpty &&
      itemId != null &&
      itemId.isNotEmpty) {
    out.add(
      '$embyBase/Items/$itemId/File'
      '?Path=${Uri.encodeQueryComponent(nfoPath)}&api_key=$embyToken',
    );
  }
  final direct = nfoUrlFromMediaPath(filePath);
  if (direct != null) out.add(direct);
  return out.toList();
}

String _decodeEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    // &amp; 必须最后替换，避免把 &amp;lt; 解成 <
    .replaceAll('&amp;', '&');

String _clean(String raw) {
  var s = raw.trim();
  final cdata = RegExp(r'^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$').firstMatch(s);
  if (cdata != null) s = cdata.group(1) ?? '';
  // 去掉嵌套标签（例如 <name><b>x</b></name>）
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  return _decodeEntities(s).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 从 NFO XML 提取系列名：优先 `<series>`，回退 `<set><name>`。
/// 取不到返回 null。用正则而非 XML 解析器：NFO 常有不闭合标签 / 非法字符，
/// 严格解析会整份失败，这里只需取两个字段，容错更重要。
String? parseNfoSeries(String xml) {
  final series = RegExp(
    r'<series\b[^>]*>([\s\S]*?)</series>',
    caseSensitive: false,
  ).firstMatch(xml);
  if (series != null) {
    final v = _clean(series.group(1) ?? '');
    if (v.isNotEmpty) return v;
  }
  final set = RegExp(
    r'<set\b[^>]*>([\s\S]*?)</set>',
    caseSensitive: false,
  ).firstMatch(xml);
  if (set != null) {
    final name = RegExp(
      r'<name\b[^>]*>([\s\S]*?)</name>',
      caseSensitive: false,
    ).firstMatch(set.group(1) ?? '');
    if (name != null) {
      final v = _clean(name.group(1) ?? '');
      if (v.isNotEmpty) return v;
    }
  }
  return null;
}

/// 拉取并解析 NFO，失败一律返回 null（保持「系列：无」的既有表现）。
///
/// 防御点：
/// - 5 秒超时（AList 首次响应常偏慢，3 秒易误判为「无」）。
/// - 仅解析前 256KB，避免把被代理成的登录页 / HTML 整页塞进正则
///   （这类响应 statusCode 也是 200，但正文不是 NFO）。
/// - 仅缓存命中值；null 不缓存，以便网络恢复后能重试。
Future<String?> loadNfoSeries(String url) async {
  if (_seriesCache.containsKey(url)) return _seriesCache[url];
  String? result;
  try {
    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode == 200) {
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      if (body.length <= 256 * 1024) {
        result = parseNfoSeries(body);
      }
    }
  } catch (_) {
    result = null;
  }
  if (result != null) _seriesCache[url] = result;
  return result;
}

/// 仅供测试：清空进程内缓存。
void clearNfoSeriesCache() => _seriesCache.clear();
