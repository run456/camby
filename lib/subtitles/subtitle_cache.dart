import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'online_subtitle.dart';

/// 一条保存在本机的在线字幕。
///
/// [text] 是**解码并去掉内联标签后的 UTF-8 字幕原文**（不是 bytes、不是
/// `SubtitleCue` 列表），这样既能直接导出成 .srt，也能重新 parseAny 挂回叠加层。
/// [meta] 记录它是哪一条搜索结果，供底栏 / 信息面板显示来源与标题。
class CachedSubtitle {
  const CachedSubtitle({required this.text, required this.meta});

  final String text;
  final Map<String, dynamic> meta;

  String get title => (meta['title'] as String?) ?? '本机字幕';
  String get url => (meta['url'] as String?) ?? '';
  String get language => (meta['language'] as String?) ?? 'und';
  String get format => (meta['format'] as String?) ?? 'srt';
  String get fileName => (meta['fileName'] as String?) ?? '';
  String get source => (meta['source'] as String?) ?? 'xunlei';

  DateTime? get savedAt => DateTime.tryParse((meta['savedAt'] as String?) ?? '');

  OnlineSubtitle toOnlineSubtitle() => OnlineSubtitle(
        id: 'cache:$url',
        title: title,
        source: source == 'subtitleCat'
            ? OnlineSubtitleSource.subtitleCat
            : OnlineSubtitleSource.xunlei,
        url: url,
        format: format,
        language: language,
        fileName: fileName,
      );
}

/// 在线字幕的本机缓存 / 导出。
///
/// 为什么是「本机」而不是「影片所在文件夹」：`MediaItem.filePath` 是 Emby
/// **服务器上**的路径（`/volume1/video/...`、`D:\Movies\...`），手机 App 对它
/// 没有写权限；Emby 也没有字幕上传 API。所以缓存放在 App 私有目录用于自动
/// 复用，导出文件放在 App 外部私有目录（文件管理器可见）供用户自行拷到 NAS。
///
/// 目录结构（应用私有文档目录 / subtitle_cache/）：
/// ```
///   <itemId>.sub   解码后的字幕原文（UTF-8）
///   <itemId>.json  来源元信息（title / url / language / format / savedAt）
/// ```
/// 分两个文件而不是塞进一个 JSON，避免几百 KB 的字幕文本被 JSON 转义放大。
abstract final class OnlineSubtitleCache {
  static const String cacheDirName = 'subtitle_cache';
  static const String exportDirName = 'subtitles';

  /// 影片 ID 做文件名：Emby 的 id 一般是数字，但剧集 / 自定义源可能带特殊字符。
  static String safeId(String id) {
    final t = id.trim();
    if (t.isEmpty) return '_empty';
    return t.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  /// 导出文件名：`<影片名>.<语言>.<格式>`，与 Emby 外挂字幕命名习惯一致，
  /// 拷到影片目录后改不改后缀都能被识别。
  ///
  /// [movieName] 由调用方决定——优先用**视频文件原名**（去扩展名），这样字幕
  /// 落到影片旁时 Emby 能按同名自动关联；否则用影片展示名。这里只负责清洗
  /// 成合法文件名并拼上语言 / 格式后缀，不再额外去掉画质标签（避免破坏与原
  /// 视频文件的同名匹配）。
  static String exportFileName(String movieName, String language, String format) {
    var base = movieName.trim();
    if (base.isEmpty) base = 'subtitle';
    final lang = language.isEmpty ? 'und' : language;
    final ext = format.isEmpty ? 'srt' : format;
    return '${OnlineSubtitleService.safeFileName(base)}.$lang.$ext';
  }

  static Map<String, dynamic> metaOf(OnlineSubtitle s) => <String, dynamic>{
        'title': s.title,
        'url': s.url,
        'language': s.language,
        'format': s.format,
        'fileName': s.fileName,
        'source': s.source.name,
        'savedAt': DateTime.now().toIso8601String(),
      };

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$cacheDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> save(String itemId, OnlineSubtitle s, String text) async {
    final dir = await _cacheDir();
    final id = safeId(itemId);
    await File('${dir.path}/$id.sub')
        .writeAsString(text, encoding: utf8, flush: true);
    await File('${dir.path}/$id.json')
        .writeAsString(jsonEncode(metaOf(s)), encoding: utf8, flush: true);
  }

  /// 读不到 / 文件损坏一律返回 null，绝不因为缓存问题把播放页卡住。
  static Future<CachedSubtitle?> load(String itemId) async {
    try {
      final dir = await _cacheDir();
      final id = safeId(itemId);
      final textFile = File('${dir.path}/$id.sub');
      final metaFile = File('${dir.path}/$id.json');
      if (!await textFile.exists() || !await metaFile.exists()) return null;
      final text = await textFile.readAsString(encoding: utf8);
      if (text.isEmpty) return null;
      final decoded = jsonDecode(await metaFile.readAsString(encoding: utf8));
      if (decoded is! Map) return null;
      return CachedSubtitle(text: text, meta: Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> remove(String itemId) async {
    try {
      final dir = await _cacheDir();
      final id = safeId(itemId);
      var removed = false;
      for (final suffix in const ['.sub', '.json']) {
        final f = File('${dir.path}/$id$suffix');
        if (await f.exists()) {
          await f.delete();
          removed = true;
        }
      }
      return removed;
    } catch (_) {
      return false;
    }
  }

  /// 把字幕写成用户可见的 .srt/.ass 文件，返回绝对路径。
  ///
  /// Android 上 `getExternalStorageDirectory()` 是 `/storage/emulated/0/Android/
  /// data/<包名>/files`，属于 App 私有外部目录，**不需要申请存储权限**，
  /// 文件管理器也能看到。拿不到时回退到应用文档目录。
  static Future<String> export(String itemId, {required String movieName}) async {
    final cached = await load(itemId);
    if (cached == null) throw StateError('没有可导出的本机字幕');
    // 影片名兜底链：调用方传入的影片名 → 缓存里记录的字幕来源标题 → 占位。
    // 优先信任调用方（通常是视频文件原名 / 影片展示名），缺了再用字幕标题补，
    // 绝不让导出文件落到无意义的 `subtitle.*`。
    final name = movieName.trim().isNotEmpty
        ? movieName
        : (cached.title.trim().isNotEmpty ? cached.title : 'subtitle');
    // 非 Android 平台 getExternalStorageDirectory() 会直接抛异常（而非返回
    // null），用 try/catch 兜住并回退到应用文档目录，保证导出在所有平台都能跑。
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ??
          (await getApplicationDocumentsDirectory());
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/$exportDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(
      '${dir.path}/${exportFileName(name, cached.language, cached.format)}',
    );
    await file.writeAsString(cached.text, encoding: utf8, flush: true);
    return file.path;
  }
}
