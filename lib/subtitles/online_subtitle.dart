// lib/subtitles/online_subtitle.dart
//
// 在线字幕搜索（移植自 PotplayerJavChineseSubs_subtitlecat 3.0 的思路，
// 用 Dart 重写，不依赖 PotPlayer 宿主 API）。
//
// 上游插件为 MIT（Copyright (c) 2024 Exhen & Contributors）。若你分发本文件，
// 请连同原 LICENSE 一起保留。注意：MIT 只覆盖代码，不覆盖 SubtitleCat 网站、
// 迅雷字幕接口的服务条款，商用分发前请自行评估。
//
// 集成方式见文件末尾 [集成到 player_page.dart] 注释。
//
// 依赖：项目已有 http: ^1.4.0 即可运行。
// 可选（强烈建议，否则 GBK 中文字幕会乱码）：
//   pubspec.yaml 加  gbk_codec: ^0.4.0
//   main.dart 里：
//     import 'package:gbk_codec/gbk_codec.dart';
//     OnlineSubtitleConfig.gbkDecoder = (bytes) => gbk_bytes.decode(bytes);

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'subtitles.dart'; // Subtitles.parseAny / SubtitleCue
import '../widgets/glass_sheet.dart'; // 与播放页共用玻璃面板 / 行组件

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

class OnlineSubtitleConfig {
  OnlineSubtitleConfig._();

  static const String subtitleCatBase = 'www.subtitlecat.com';
  static const String xunleiHost = 'api-shoulei-ssl.xunlei.com';
  static const String xunleiPath = '/oracle/subtitle';

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  /// 单个 HTTP 请求的超时。两个源并行且各自隔离，一个挂掉不拖累另一个。
  static const Duration timeout = Duration(seconds: 8);

  /// 单个源的总超时（搜索页 + 若干详情页，每个请求各自 8s）
  static const Duration sourceTimeout = Duration(seconds: 25);

  /// 每个源最多返回多少条
  static const int maxPerSource = 20;

  /// SubtitleCat 最多抓多少个详情页（原插件会串行抓几十个，这里限并发 + 限量）
  static const int maxDetailPages = 8;
  static const int detailConcurrency = 4;

  /// GBK 解码器，由 App 注入（见文件头）。不注入时 UTF-8 失败会退到 latin1，
  /// 时间轴能读但中文会乱码。
  static String Function(List<int>)? gbkDecoder;
}

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

enum OnlineSubtitleSource { xunlei, subtitleCat }

extension OnlineSubtitleSourceX on OnlineSubtitleSource {
  String get label =>
      this == OnlineSubtitleSource.xunlei ? '迅雷' : 'SubtitleCat';

  Color get color => this == OnlineSubtitleSource.xunlei
      ? const Color(0xFFFFB74D)
      : const Color(0xFF64B5F6);
}

class OnlineSubtitle {
  const OnlineSubtitle({
    required this.id,
    required this.title,
    required this.source,
    required this.url,
    required this.format,
    this.language = 'und',
    this.fileName = '',
  });

  final String id;
  final String title;
  final OnlineSubtitleSource source;
  final String url;

  /// srt / ass / ssa ...
  final String format;

  /// zh-CN / zh-TW / en / und
  final String language;
  final String fileName;

  bool get isChinese =>
      language == 'zh-CN' ||
      language == 'zh-TW' ||
      language == 'zh' ||
      language == 'chs' ||
      language == 'cht';

  bool get isAss =>
      format == 'ass' || format == 'ssa' || url.toLowerCase().contains('.ass');
}

// ---------------------------------------------------------------------------
// 核心服务
// ---------------------------------------------------------------------------

class OnlineSubtitleService {
  OnlineSubtitleService._();

  static const String _site = 'https://${OnlineSubtitleConfig.subtitleCatBase}';

  // -------------------------------------------------------------------------
  // 对外主入口
  // -------------------------------------------------------------------------

  /// 按文件名（或手动标题）搜索。两个源并行、各自超时/异常隔离。
  ///
  /// [season]/[episode] 传入后会拼 `S01E02`；[manualTitle] 非空时跳过文件名清理。
  static Future<List<OnlineSubtitle>> search(
    String fileName, {
    String? manualTitle,
    int? season,
    int? episode,
    bool enableXunlei = true,
    bool enableSubtitleCat = true,
  }) async {
    final manual = manualTitle?.trim() ?? '';
    final cleaned = manual.isNotEmpty
        ? manual
        : cleanTitle(fileName, season: season, episode: episode);
    if (cleaned.isEmpty) return const <OnlineSubtitle>[];

    // 番号比长标题更容易命中字幕库（与上游插件思路一致，但只用于迅雷源，
    // SubtitleCat 仍用完整标题，避免剧集名被误判）。
    final code = extractCode(cleaned);
    final xunleiQuery = code.isNotEmpty ? code : cleaned;

    final jobs = <Future<List<OnlineSubtitle>>>[
      if (enableXunlei) _guarded(() => _searchXunlei(xunleiQuery)),
      if (enableSubtitleCat) _guarded(() => _searchSubtitleCat(cleaned)),
    ];
    if (jobs.isEmpty) return const <OnlineSubtitle>[];

    final groups = await Future.wait(jobs);
    final merged = <OnlineSubtitle>[];
    final seen = <String>{};
    for (final group in groups) {
      for (final item in group) {
        if (item.url.isEmpty || !seen.add(item.url)) continue;
        merged.add(item);
      }
    }
    // 中文字幕 → 迅雷源 → 其余，中文优先展示
    merged.sort((a, b) => _rank(b).compareTo(_rank(a)));
    return merged;
  }

  static int _rank(OnlineSubtitle s) =>
      (s.isChinese ? 100 : 0) +
      (s.source == OnlineSubtitleSource.xunlei ? 10 : 0);

  /// 单个源失败只返回空列表，绝不抛到 UI。
  static Future<List<OnlineSubtitle>> _guarded(
    Future<List<OnlineSubtitle>> Function() job,
  ) async {
    try {
      return await job().timeout(
        OnlineSubtitleConfig.sourceTimeout,
        onTimeout: () => const <OnlineSubtitle>[],
      );
    } catch (_) {
      return const <OnlineSubtitle>[];
    }
  }

  // -------------------------------------------------------------------------
  // 文件名清理（移植 CleanTitle，修正大小写与边界问题）
  // -------------------------------------------------------------------------

  static const Set<String> _videoExt = {
    'mp4',
    'mkv',
    'avi',
    'wmv',
    'flv',
    'webm',
    'mov',
    'ts',
    'm2ts',
    'rmvb',
    'mpg',
    'mpeg',
    'divx',
    '3gp',
    'vob',
    'asf',
    'm4v',
    'rm',
    'ogm',
    'ogv',
    'mpls',
    'iso',
  };

  static const Set<String> _qualityTags = {
    '4k',
    '2k',
    '8k',
    '720p',
    '1080p',
    '2160p',
    '480p',
    '360p',
    'hd',
    'fhd',
    'uhd',
    'sd',
    'hdr',
    'bluray',
    'web-dl',
    'x264',
    'x265',
  };

  static String cleanTitle(String raw, {int? season, int? episode}) {
    var t = htmlUnescape(raw).trim();

    // 1. 去 [xxx.com] / [4K] 等方括号内容
    t = t.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    // 2. 去 xxx.com@ 之类的站点前缀
    final at = t.indexOf('@');
    if (at >= 0) t = t.substring(at + 1);
    // 3. 去扩展名（大小写不敏感）
    final dot = t.lastIndexOf('.');
    if (dot > 0 && _videoExt.contains(t.substring(dot + 1).toLowerCase())) {
      t = t.substring(0, dot);
    }
    // 4. 循环剥离末尾画质标签，形如 -1080p / _FHD
    var changed = true;
    while (changed) {
      changed = false;
      final m = RegExp(r'[-_]([A-Za-z0-9\-]+)$').firstMatch(t);
      if (m != null && _qualityTags.contains(m.group(1)!.toLowerCase())) {
        t = t.substring(0, m.start);
        changed = true;
      }
    }
    // 5. 常见的点/下划线分词换成空格，去掉尾部残留分隔符
    t = t.replaceAll(RegExp(r'[._]+'), ' ').replaceAll(RegExp(r'\s+'), ' ');
    t = t.replaceAll(RegExp(r'^[\s\-_]+|[\s\-_]+$'), '');

    // 5b. 点号分词后再从尾部连续剔除画质/编码词。
    // 例：Inception.2010.1080p.BluRay.x264 → Inception 2010，
    // 否则整串标签会当关键词，命中率明显下降。保留至少 1 个词。
    final words = t.split(' ');
    while (
        words.length > 1 && _qualityTags.contains(words.last.toLowerCase())) {
      words.removeLast();
    }
    t = words.join(' ').trim();

    // 6. 季/集号。剧集文件名常自带 S01E02，此时再拼一次会变成
    //    "Show S01E02 S01E02"，反而搜不到，所以已带完整季集号就跳过。
    final hasSeasonEpisode =
        RegExp(r'\bS\d{1,2}E\d{1,2}\b', caseSensitive: false).hasMatch(t);
    if (season != null && !hasSeasonEpisode) {
      final s = season.toString().padLeft(2, '0');
      final e = episode == null ? '' : 'E${episode.toString().padLeft(2, '0')}';
      t = '$t S$s$e';
    }
    return t.trim();
  }

  /// 提取番号：2–5 个大写字母 + 可选连字符 + 2–5 位数字 → `ABCD-123`。
  /// 用正则替代上游的手写字符扫描，语义相同且不会跳过字符。
  static String extractCode(String s) {
    final m = RegExp(r'\b([A-Z]{2,5})-?([0-9]{2,5})\b').firstMatch(s);
    if (m == null) return '';
    return '${m.group(1)}-${m.group(2)}';
  }

  static String htmlUnescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&rsquo;', "'");

  // -------------------------------------------------------------------------
  // 源 ①：迅雷（JSON 接口，中文字幕主力）
  // -------------------------------------------------------------------------

  static Future<List<OnlineSubtitle>> _searchXunlei(String query) async {
    final uri = Uri.https(
      OnlineSubtitleConfig.xunleiHost,
      OnlineSubtitleConfig.xunleiPath,
      {'gcid': '', 'cid': '', 'name': query},
    );
    final bytes = await _getBytes(uri);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map || decoded['data'] is! List) {
      return const <OnlineSubtitle>[];
    }
    final data = decoded['data'] as List;
    final out = <OnlineSubtitle>[];
    for (final raw in data) {
      if (out.length >= OnlineSubtitleConfig.maxPerSource) break;
      if (raw is! Map) continue;
      final url = raw['url']?.toString() ?? '';
      final ext = (raw['ext'] ?? 'srt').toString().toLowerCase();
      if (url.isEmpty || !url.startsWith('http')) continue;

      var name = (raw['name'] ?? '').toString();
      if (name.isEmpty) name = (raw['simple_name'] ?? '').toString();
      if (name.isEmpty) name = query;
      final suffix = '.$ext';
      if (name.toLowerCase().endsWith(suffix)) {
        name = name.substring(0, name.length - suffix.length);
      }
      name = safeFileName(name);
      final display = '$name（迅雷）';

      out.add(OnlineSubtitle(
        id: 'xunlei:$url',
        title: display,
        source: OnlineSubtitleSource.xunlei,
        url: url,
        format: ext,
        language: _langFromXunlei(raw['languages']),
        fileName: '$display.$ext',
      ));
    }
    return out;
  }

  /// 上游插件把 lang 硬编码成 zh-CN，这里读接口真实返回的 languages。
  static String _langFromXunlei(dynamic languages) {
    if (languages is List) {
      final joined = languages.join(' ').toLowerCase();
      if (joined.contains('简') ||
          joined.contains('chs') ||
          joined.contains('simplified')) {
        return 'zh-CN';
      }
      if (joined.contains('繁') ||
          joined.contains('cht') ||
          joined.contains('traditional')) {
        return 'zh-TW';
      }
      if (joined.contains('英') || joined.contains('en')) return 'en';
      if (joined.contains('日') || joined.contains('ja')) return 'ja';
    }
    // 该接口的字幕绝大多数是中文，未知时按中文处理（与原插件一致）
    return 'zh-CN';
  }

  // -------------------------------------------------------------------------
  // 源 ②：SubtitleCat（HTML 解析）
  //
  // 重要事实：该站的「中文」不是现成文件，而是页面 JS 调
  // translate.googleapis.com 把 -orig.srt 分批机翻出来的（见 /js/translate.js），
  // 详情页里 -zh-CN.srt 直链通常 404。所以这里解析的是**静态 .srt 链接**
  // （各语言原始字幕，通常英文）+ -orig.srt 兜底；想要中文字幕请用迅雷源。
  // 上游 3.0 插件硬找 "-zh-CN.srt"，实测对绝大多数条目返回 0 结果。
  // -------------------------------------------------------------------------

  static Future<List<OnlineSubtitle>> _searchSubtitleCat(String query) async {
    final searchUri = Uri.https(
      OnlineSubtitleConfig.subtitleCatBase,
      '/index.php',
      {'search': query},
    );
    final html = utf8.decode(
      await _getBytes(searchUri),
      allowMalformed: true,
    );

    // <a href="subs/1655/Inception.2010.1080p.BrRip.x264.html">Title</a>
    final linkRe = RegExp(
      r'href="(subs/[^"]+\.html)"[^>]*>([^<]+)</a>',
      caseSensitive: false,
    );
    final matches = linkRe
        .allMatches(html)
        .take(OnlineSubtitleConfig.maxDetailPages)
        .toList();
    if (matches.isEmpty) return const <OnlineSubtitle>[];

    final items = await _mapPool<RegExpMatch, OnlineSubtitle>(
      matches,
      OnlineSubtitleConfig.detailConcurrency,
      (m) => _parseDetailPage(m.group(1)!, m.group(2)!),
    );

    items.sort((a, b) => _rank(b).compareTo(_rank(a)));
    return items.take(OnlineSubtitleConfig.maxPerSource).toList();
  }

  static Future<List<OnlineSubtitle>> _parseDetailPage(
    String relativePath,
    String pageTitle,
  ) async {
    final pageUrl = '$_site/$relativePath';
    final html = utf8.decode(
      await _getBytes(Uri.parse(pageUrl)),
      allowMalformed: true,
    );
    final title = safeFileName(htmlUnescape(pageTitle).trim());
    final out = <OnlineSubtitle>[];

    // 静态下载链接：href="/subs/1610/Inception.2010-en.srt"
    final srtRe = RegExp(r'href="(/subs/[^"]+\.srt)"', caseSensitive: false);
    final seenPaths = <String>{};
    for (final m in srtRe.allMatches(html)) {
      final path = m.group(1)!;
      if (!seenPaths.add(path)) continue;
      final fileName = path.split('/').last;
      final langMatch =
          RegExp(r'-([A-Za-z][A-Za-z0-9\-]*)\.srt$').firstMatch(fileName);
      final lang = langMatch?.group(1)?.toLowerCase() ?? 'und';
      out.add(OnlineSubtitle(
        id: 'sc:$path',
        title: '$title · ${langLabel(lang)}',
        source: OnlineSubtitleSource.subtitleCat,
        url: '$_site$path',
        format: 'srt',
        language: lang,
        fileName: fileName,
      ));
    }

    // -orig.srt 兜底：从 onclick 参数里取文件名与目录
    // translate_from_server_folder('af', 'Inception.2010-orig.srt', '/subs/1604/')
    final origRe = RegExp(
      r"translate_from_server_folder\('[^']*',\s*'([^']+\.srt)',\s*'(/subs/[^']*/)'\)",
    );
    final orig = origRe.firstMatch(html);
    if (orig != null) {
      final path = '${orig.group(2)}${orig.group(1)}';
      if (seenPaths.add(path)) {
        out.add(OnlineSubtitle(
          id: 'sc:$path',
          title: '$title · 原文',
          source: OnlineSubtitleSource.subtitleCat,
          url: '$_site$path',
          format: 'srt',
          language: 'en',
          fileName: orig.group(1)!,
        ));
      }
    }
    return out;
  }

  static String langLabel(String code) {
    const map = {
      'en': 'English',
      'zh-cn': '简体中文',
      'zh-tw': '繁體中文',
      'zh': '中文',
      'ja': '日本語',
      'ko': '한국어',
      'fr': 'Français',
      'de': 'Deutsch',
      'es': 'Español',
      'pt': 'Português',
      'ru': 'Русский',
      'ar': 'العربية',
      'th': 'ไทย',
      'vi': 'Tiếng Việt',
      'und': '未知',
    };
    return map[code.toLowerCase()] ?? code.toUpperCase();
  }

  // -------------------------------------------------------------------------
  // 下载 + 解码
  // -------------------------------------------------------------------------

  /// 下载字幕并解码成 UTF-8 文本（自动处理 UTF-8 BOM / GBK / latin1）。
  ///
  /// 迅雷字幕实测是 GBK 且带 `<font color=...>` 标签，项目原有的
  /// Subtitles._decode() 不认 GBK，所以必须在这里解码后再交给 parseAny。
  static Future<String> downloadText(OnlineSubtitle item) async {
    final bytes = await _getBytes(Uri.parse(item.url));
    return stripInlineTags(decodeBytes(bytes));
  }

  /// 一步到位：下载 → 解码 → 解析成项目现有的 SubtitleCue 列表。
  static Future<List<SubtitleCue>> fetchCues(OnlineSubtitle item) async =>
      Subtitles.parseAny(await downloadText(item));

  static String decodeBytes(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    // UTF-8 严格解码成功 → 保持原样；GBK 中文字节几乎不可能通过严格校验
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // fall through
    }
    final gbk = OnlineSubtitleConfig.gbkDecoder;
    if (gbk != null) {
      try {
        return gbk(bytes);
      } catch (_) {
        // 解码器异常时继续兜底
      }
    }
    // 没注入 GBK 解码器：时间轴（ASCII）仍可解析，中文会是乱码
    return latin1.decode(bytes, allowInvalid: true);
  }

  /// SRT 里常见的内联标签，叠加层是纯 Text，不去掉会显示成字面量。
  static String stripInlineTags(String s) => s
      .replaceAll(
          RegExp(r'</?(?:font|b|i|u|s)[^>]*>', caseSensitive: false), '')
      .replaceAll('&nbsp;', ' ');

  static String safeFileName(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();

  // -------------------------------------------------------------------------
  // HTTP 与并发工具
  // -------------------------------------------------------------------------

  static Future<List<int>> _getBytes(Uri uri) async {
    final res = await http.get(uri, headers: {
      'User-Agent': OnlineSubtitleConfig.userAgent,
      'Accept': '*/*',
    }).timeout(OnlineSubtitleConfig.timeout);
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode} @ $uri');
    }
    const cap = 8 * 1024 * 1024;
    if (res.bodyBytes.length > cap) {
      throw Exception('响应过大，判定不是字幕');
    }
    return res.bodyBytes;
  }

  /// 限并发 map；单个任务失败被吞掉，不影响其他任务。
  static Future<List<T>> _mapPool<I, T>(
    List<I> items,
    int concurrency,
    Future<List<T>> Function(I) fn,
  ) async {
    final out = <T>[];
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++; // 单线程事件循环，无 await，安全
        if (i >= items.length) return;
        try {
          out.addAll(await fn(items[i]));
        } catch (_) {
          // 某个详情页 404/超时，忽略
        }
      }
    }

    final n = math.min(concurrency, items.length);
    if (n == 0) return out;
    await Future.wait(List.generate(n, (_) => worker()));
    return out;
  }
}

// ---------------------------------------------------------------------------
// UI：搜索结果面板
//
// 与播放页的变速 / 字幕 / 信息 / 样式面板共用 [GlassPanelRoute] + [GlassPanel]：
// 居中卡片、手机 470 / 平板 620 的最大宽度、同样的底色与边框、同样的入场动画。
// 不用底部抽屉：横屏播放时会压住进度条，平板上也会拉成一条横贯屏幕的色块。
// ---------------------------------------------------------------------------

/// 弹出在线字幕搜索面板，返回用户选中的条目（取消返回 null）。
Future<OnlineSubtitle?> showOnlineSubtitleSheet(
  BuildContext context, {
  required String fileName,
  String? manualTitle,
  int? season,
  int? episode,
}) {
  return Navigator.of(context).push<OnlineSubtitle>(
    GlassPanelRoute<OnlineSubtitle>(
      builder: (_) => _OnlineSubtitleSheet(
        fileName: fileName,
        manualTitle: manualTitle,
        season: season,
        episode: episode,
      ),
    ),
  );
}

class _OnlineSubtitleSheet extends StatefulWidget {
  const _OnlineSubtitleSheet({
    required this.fileName,
    this.manualTitle,
    this.season,
    this.episode,
  });

  final String fileName;
  final String? manualTitle;
  final int? season;
  final int? episode;

  @override
  State<_OnlineSubtitleSheet> createState() => _OnlineSubtitleSheetState();
}

class _OnlineSubtitleSheetState extends State<_OnlineSubtitleSheet> {
  late final TextEditingController _ctrl;
  late Future<List<OnlineSubtitle>> _future;

  @override
  void initState() {
    super.initState();
    final initial = widget.manualTitle?.trim().isNotEmpty == true
        ? widget.manualTitle!.trim()
        : OnlineSubtitleService.cleanTitle(
            widget.fileName,
            season: widget.season,
            episode: widget.episode,
          );
    _ctrl = TextEditingController(text: initial);
    _future = _search(initial);
  }

  Future<List<OnlineSubtitle>> _search(String q) =>
      OnlineSubtitleService.search(widget.fileName, manualTitle: q);

  void _reload() {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _future = _search(q));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // 键盘弹起时把面板整体顶上去，同时压缩面板高度，避免输入框被遮住。
    // 高度上交给 GlassPanel 的 maxWidth（手机 470 / 平板 620）+ 这里的固定高度，
    // 因此横屏、平板都不会出现拉满整屏的色块。
    final inset = media.viewInsets.bottom;
    final avail = media.size.height - media.padding.vertical - inset - 24;
    final panelH = math.max(240.0, math.min(avail, 620.0));

    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: GlassPanel(
        child: SizedBox(
          height: panelH,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                // 标题栏固定，不随结果列表滚动
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '在线字幕搜索',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.of(context).maybePop(),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.10),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _ctrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '影片标题 / 番号',
                      hintStyle: const TextStyle(color: Color(0xFF9FB0CC)),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.search_rounded,
                            color: Color(0xFF9FB0CC)),
                        onPressed: _reload,
                      ),
                    ),
                    onSubmitted: (_) => _reload(),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<OnlineSubtitle>>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              SizedBox(height: 14),
                              Text(
                                '正在搜索迅雷 / SubtitleCat…',
                                style: TextStyle(
                                    color: Color(0xFF9FB0CC), fontSize: 12),
                              ),
                            ],
                          ),
                        );
                      }
                      final list = snap.hasError
                          ? const <OnlineSubtitle>[]
                          : (snap.data ?? const <OnlineSubtitle>[]);
                      if (list.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              '没有找到字幕。可换个标题或番号重试；\n'
                              '两个字幕源都不可用时会显示为空。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0xFF9FB0CC),
                                fontSize: 12.5,
                                height: 1.6,
                              ),
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.only(bottom: 14),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final s = list[i];
                          return SheetRow(
                            label: s.title,
                            hint: '${OnlineSubtitleService.langLabel(s.language)}'
                                ' · .${s.format}'
                                '${s.isChinese ? ' · 中文' : ''}',
                            leading: _SourceBadge(source: s.source),
                            onTap: () => Navigator.of(context).pop(s),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 来源角标：迅雷（中文主力）/ SubtitleCat（补充源）。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final OnlineSubtitleSource source;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: source.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: source.color.withValues(alpha: 0.35)),
      ),
      child: Text(
        source.label,
        style: TextStyle(color: source.color, fontSize: 10),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 集成关系（v2.0.45）
// ---------------------------------------------------------------------------
//
// 上游思路来自 MIT 项目 PotplayerJavChineseSubs_subtitlecat 3.0 的双源字幕，
// 用 Dart 重写；许可全文见仓库 licenses/LICENSE-UPSTREAM.txt，
// 版权人 Exhen & Contributors，分发时须原样保留。
//
//  · 播放页：字幕弹窗的「在线搜索字幕…」→ _pickOnlineSubtitle() 调用本文件的
//    showOnlineSubtitleSheet()，拿到结果后 fetchCues() 写入叠加层 _cues。
//  · 弹层外观：复用 widgets/glass_sheet.dart 的 GlassPanelRoute / GlassPanel /
//    SheetRow，与播放页其它面板一致，并按屏宽限制最大宽度（手机 470 / 平板 620）。
//  · 编码：迅雷返回 GBK，main.dart 在启动时注入
//    OnlineSubtitleConfig.gbkDecoder = gbk_bytes.decode（gbk_codec 依赖）。
//    漏掉这一步不报错，但中文字幕会乱码。
//  · AndroidManifest.xml 已有 INTERNET 权限，无需改动。
//
// 两个数据源均为第三方未文档化端点 / HTML 结构，单源失败会静默降级为空列表，
// 不影响另一源；改版导致失效时优先调整本文件内的解析规则。
