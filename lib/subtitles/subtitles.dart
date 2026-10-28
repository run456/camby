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

  /// 抓取并解析。失败返回空列表（调用方据此提示）。
  static Future<List<SubtitleCue>> load(String url) async {
    if (url.isEmpty) return const [];
    var raw = await _fetch(url);
    if (raw == null) return const [];
    // ASS/SSA 直接解析不了文本：让 Emby 转成 SRT 再取一次
    if (_looksBinaryOrAss(raw)) {
      final alt = _toSrtUrl(url);
      if (alt != null && alt != url) {
        final raw2 = await _fetch(alt);
        if (raw2 != null && !_looksBinaryOrAss(raw2)) raw = raw2;
      }
    }
    return parse(raw);
  }

  static Future<String?> _fetch(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final bytes = await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 15));
      // 先按 UTF-8 严格解；失败退回宽松解（GBK 会显示为替换符，但至少不崩）
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
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
