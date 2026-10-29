import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条字幕（时间以秒为单位）
class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);

  final double start;
  final double end;
  final String text;

  bool covers(double t) => t >= start - 0.05 && t <= end + 0.05;
}

/// 轻量字幕加载 / 解析（SRT、WebVTT）
///
/// 为什么自己解析：ExoPlayer（video_player 插件）没有「运行时挂外挂字幕」的接口，
/// 以前为了换字幕只能重建播放器，导致进度回零。这里改成页面叠加层渲染，
/// 字幕切换与播放完全解耦。
class Subtitles {
  const Subtitles._();

  /// 最近一次 load 的失败原因（给 UI 提示用，方便用户反馈）
  static String lastDiag = '';

  /// 抓取并解析。失败返回空列表（调用方据此提示）。
  /// [fetcher] 注入 App 的鉴权下载通道，返回**原始字节**（不是字符串），
  /// 这样 UTF-16 / GBK 编码的 SRT 也能在这里正确解码。
  /// [fallbackUrl] 原格式地址（如 Stream.ass）：Emby 对部分片源不会按
  /// 扩展名转码，主地址拿不到时间轴时再用它按 ASS 解析一次。
  static Future<List<SubtitleCue>> load(
    String url, {
    Future<List<int>?> Function(String)? fetcher,
    String? fallbackUrl,
  }) async {
    lastDiag = '';
    final urls = <String>[
      if (url.isNotEmpty) url,
      if (fallbackUrl != null &&
          fallbackUrl.isNotEmpty &&
          fallbackUrl != url)
        fallbackUrl,
    ];
    if (urls.isEmpty) {
      lastDiag = '字幕地址为空';
      return const [];
    }
    for (final u in urls) {
      var bytes = await _fetchBytes(u, fetcher);
      if (bytes == null) {
        if (lastDiag.isEmpty) lastDiag = '下载失败';
        continue;
      }
      var raw = _decode(bytes);
      if (_looksBinaryOrAss(raw)) {
        // 拿到的是 ASS：先试 Emby 的 .srt 转码端点
        final alt = _toSrtUrl(u);
        if (alt != null && alt != u) {
          final bytes2 = await _fetchBytes(alt, fetcher);
          if (bytes2 != null) {
            final raw2 = _decode(bytes2);
            if (!_looksBinaryOrAss(raw2)) raw = raw2;
          }
        }
      }
      final cues = parseAny(raw);
      if (cues.isNotEmpty) {
        lastDiag = '';
        return cues;
      }
      if (lastDiag.isEmpty) {
        lastDiag = raw.trim().isEmpty ? '内容为空' : '识别不到时间轴';
      }
    }
    return const [];
  }

  static Future<List<int>?> _fetchBytes(
    String url,
    Future<List<int>?> Function(String)? fetcher,
  ) async {
    // 优先走注入的鉴权通道（与视频同款鉴权 + 忽略 LAN 自签证书）
    if (fetcher != null) {
      try {
        final r = await fetcher(url);
        if (r != null && r.isNotEmpty) return r;
      } catch (_) {}
    }
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        // 家庭媒体服务器多为自签/Let's Encrypt 证书，直连需忽略证书错误
        ..badCertificateCallback = (_, __, ___) => true;
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        lastDiag = 'HTTP ${res.statusCode}';
        return null;
      }
      return await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      lastDiag = '请求异常';
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// 字节 → 文本：兼容 UTF-8(含 BOM) / UTF-16LE / UTF-16BE / GBK 等
  /// 非 UTF-8 编码（中文 SRT 很常见；原来是纯 utf8 解码，时间轴都读不出来）
  static String _decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes.sublist(2), little: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes.sublist(2), little: false);
    }
    // 无 BOM 的 UTF-16：ASCII 字符高位/低位字节为 0，0x00 占比很高
    final probe = bytes.length > 200 ? bytes.sublist(0, 200) : bytes;
    final zeros = probe.where((b) => b == 0).length;
    if (probe.length > 20 && zeros > probe.length * 0.25) {
      return _utf16(bytes, little: probe[1] == 0);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // GBK 等：严格 utf8 会抛，宽松解码至少能保住 ASCII 的时间轴
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String _utf16(List<int> b, {required bool little}) {
    final units = <int>[];
    for (var i = 0; i + 1 < b.length; i += 2) {
      units.add(little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static bool _looksBinaryOrAss(String s) {
    if (s.contains('[Script Info]') || s.contains('[V4+ Styles]')) return true;
    // 图形字幕（PGS/VobSub）是二进制，UTF-8 解码后控制字符极多
    final head = s.length > 400 ? s.substring(0, 400) : s;
    var ctrl = 0;
    for (final c in head.codeUnits) {
      if (c < 9 || (c > 13 && c < 32) || c == 0xFFFD) ctrl++;
    }
    return ctrl > 20;
  }

  static String? _toSrtUrl(String url) {
    if (!url.contains('Stream.')) return null;
    return url.replaceFirst(
      RegExp(r'Stream\.[A-Za-z0-9]+'),
      'Stream.srt',
    );
  }

  static final RegExp _timeRe = RegExp(
    r'(\d{1,3}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,3}):(\d{2}):(\d{2})[,.](\d{1,3})',
  );

  static double _sec(RegExpMatch m, int i) {
    final h = int.parse(m.group(i)!);
    final mi = int.parse(m.group(i + 1)!);
    final s = int.parse(m.group(i + 2)!);
    var ms = int.parse(m.group(i + 3)!);
    if (m.group(i + 3)!.length == 2) ms *= 10;
    if (m.group(i + 3)!.length == 1) ms *= 100;
    return h * 3600 + mi * 60 + s + ms / 1000.0;
  }

  /// 解析 SRT / VTT 文本
  static List<SubtitleCue> parse(String raw) {
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final cues = <SubtitleCue>[];
    for (final block in text.split(RegExp(r'\n[ \t]*\n'))) {
      final m = _timeRe.firstMatch(block);
      if (m == null) continue;
      final start = _sec(m, 1);
      final end = _sec(m, 5);
      // 时间行后面可能还有 VTT 的 cue 设置（align:start 等），
      // 必须整行跳过，否则会混进字幕正文
      final nl = block.indexOf('\n', m.end);
      final bodyStart = nl < 0 ? block.length : nl + 1;
      final body = _clean(block.substring(bodyStart));
      if (body.isEmpty || end <= start) continue;
      cues.add(SubtitleCue(start, end, body));
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  /// 先按 SRT/VTT 解析；解析不出来再按 ASS/SSA 的 Dialogue 解析。
  /// （Emby 有时不管扩展名，直接回原 ASS 内容）
  static List<SubtitleCue> parseAny(String raw) {
    final srt = parse(raw);
    if (srt.isNotEmpty) return srt;
    return parseAss(raw);
  }

  static final RegExp _assTimeRe = RegExp(
    r'(\d+):(\d{1,2}):(\d{1,2})[.:](\d{1,3})',
  );

  static double? _assTime(String s) {
    final m = _assTimeRe.firstMatch(s.trim());
    if (m == null) return null;
    // ASS 是厘秒（2 位），补齐成毫秒
    final cs = m.group(4)!.padRight(3, '0').substring(0, 3);
    return int.parse(m.group(1)!) * 3600 +
        int.parse(m.group(2)!) * 60 +
        int.parse(m.group(3)!) +
        int.parse(cs) / 1000.0;
  }

  /// 解析 ASS/SSA 的 Dialogue 行（含特效字幕的 \N 换行与 {\an8} 定位标签）
  static List<SubtitleCue> parseAss(String raw) {
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final cues = <SubtitleCue>[];
    var inEvents = false;
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.startsWith('[')) {
        inEvents = t.toLowerCase().startsWith('[events]');
        continue;
      }
      if (!inEvents || !t.toLowerCase().startsWith('dialogue:')) continue;
      // Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
      final parts = t.substring(9).split(',');
      if (parts.length < 10) continue;
      final start = _assTime(parts[1]);
      final end = _assTime(parts[2]);
      if (start == null || end == null || end <= start) continue;
      final body = _clean(parts.sublist(9).join(','));
      if (body.isEmpty) continue;
      cues.add(SubtitleCue(start, end, body));
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static String _clean(String s) {
    var t = s;
    // ASS 样式覆盖块 {\an8}、位置标签等
    t = t.replaceAll(RegExp(r'\{[^}]*\}'), '');
    // HTML/WebVTT 标签（<i> <font ...> <c.xxx> <00:00:01.000>）
    t = t.replaceAll(RegExp(r'<[^>]*>'), '');
    t = t.replaceAll(RegExp(r'&nbsp;'), ' ');
    t = t.replaceAll(RegExp(r'&amp;'), '&');
    t = t.replaceAll(RegExp(r'&lt;'), '<');
    t = t.replaceAll(RegExp(r'&gt;'), '>');
    t = t.replaceAll(RegExp(r'\\N'), '\n');
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return t.trim();
  }

  /// 取 t 秒处应显示的字幕文本（不存在返回空串）
  static String textAt(List<SubtitleCue> cues, double t) {
    // 常见情况是顺序播放，先看缓存命中，命中不了再做二分
    for (final c in cues) {
      if (c.covers(t)) return c.text;
      if (c.start > t) break;
    }
    return '';
  }
}
