import 'dart:convert';

import 'package:http/http.dart' as http;

/// NFO 侧车文件读取（v2.0.54）。
///
/// 电影条目的 NFO 常由刮削器写入 `<series>` / `<set><name>`（例如
/// 「濃厚な接吻とSEX」），但 Emby 对 Movie 类型不会把它映射成 `SeriesName`，
/// 详情页「系列」因此一直显示「无」。这里在客户端做一层兜底：从
/// `MediaSources[0].Path` 派生同目录 `.nfo` 并解析系列名。
///
/// 只在路径是 http(s) 直链（strm + AList 这类部署）时才尝试——本地文件系统
/// 路径客户端访问不到，直接跳过。请求异步、3 秒超时、失败静默、结果按 URL
/// 缓存，不阻塞渲染也不重复发请求。

/// 进程内缓存：同一部影片反复进详情页不再重复拉取。
final Map<String, String?> _seriesCache = <String, String?>{};

/// 从媒体文件路径派生同目录 `.nfo` 地址；无法派生时返回 null。
///
/// 保留 query（AList 直链常带签名参数，丢掉会 403），只替换 path 的扩展名。
String? nfoUrlFromMediaPath(String path) {
  final uri = Uri.tryParse(path.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final p = uri.path;
  if (p.isEmpty || p.endsWith('/')) return null;
  final ext = RegExp(r'\.[A-Za-z0-9]{1,5}$').firstMatch(p);
  final nfoPath = ext != null
      ? p.replaceRange(ext.start, p.length, '.nfo')
      : '$p.nfo';
  return uri.replace(path: nfoPath).toString();
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
  final cdata =
      RegExp(r'^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$').firstMatch(s);
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
Future<String?> loadNfoSeries(String url) async {
  if (_seriesCache.containsKey(url)) return _seriesCache[url];
  String? result;
  try {
    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 3));
    if (res.statusCode == 200) {
      result = parseNfoSeries(utf8.decode(res.bodyBytes, allowMalformed: true));
    }
  } catch (_) {
    result = null;
  }
  _seriesCache[url] = result;
  return result;
}

/// 仅供测试：清空进程内缓存。
void clearNfoSeriesCache() => _seriesCache.clear();
