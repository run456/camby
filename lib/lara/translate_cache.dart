import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一条已缓存的 Lara 翻译结果。
///
/// [text] 是翻译后的中文原文（UTF-8），[meta] 记录来源信息，供再次打开详情页时
/// 直接回显、以及「重新翻译」时复用参数。缓存按 `MediaItem.id` + 字段（title /
/// overview）隔离，避免同一影片的标题译文与简介译文互相覆盖。
class CachedTranslation {
  const CachedTranslation({required this.text, required this.meta});

  final String text;
  final Map<String, dynamic> meta;

  String get target => (meta['target'] as String?) ?? 'zh-CN';
  String get style => (meta['style'] as String?) ?? 'faithful';
  String get detectedSource => (meta['detectedSource'] as String?) ?? '';
  DateTime? get savedAt =>
      DateTime.tryParse((meta['savedAt'] as String?) ?? '');
}

/// 翻译结果的本机缓存（按影片 id + 字段）。
///
/// 为什么是本机私有目录而不是在线保存：翻译是**个人偏好**（同一片有人要忠实、
/// 有人要流畅），且 Lara 账户侧并无「按影片存译文」的概念。所以落盘到 App 私有
/// 文档目录 `lara_translate_cache/<id>_<field>.json`，下次进详情页即可免调用直接
/// 查看，符合需求「确认后缓存翻译后的文本，下次点开可以直接查看」。
abstract final class LaraTranslateCache {
  static const String cacheDirName = 'lara_translate_cache';

  /// 字段名做文件名后缀：title / overview。
  static String fileName(String itemId, String field) =>
      '${safeId(itemId)}_$field.json';

  /// 影片 ID 做文件名：Emby 的 id 一般是数字，但自定义源可能带特殊字符。
  static String safeId(String id) {
    final t = id.trim();
    if (t.isEmpty) return '_empty';
    return t.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  static Map<String, dynamic> metaOf({
    required String target,
    required String style,
    required String detectedSource,
  }) =>
      <String, dynamic>{
        'target': target,
        'style': style,
        'detectedSource': detectedSource,
        'savedAt': DateTime.now().toIso8601String(),
      };

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$cacheDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> save(
    String itemId,
    String field,
    String text,
    Map<String, dynamic> meta,
  ) async {
    final dir = await _cacheDir();
    final file = File('${dir.path}/${fileName(itemId, field)}');
    await file.writeAsString(
      jsonEncode({'text': text, 'meta': meta}),
      encoding: utf8,
      flush: true,
    );
  }

  /// 读不到 / 文件损坏一律返回 null，绝不因为缓存问题把详情页卡住。
  static Future<CachedTranslation?> load(String itemId, String field) async {
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}/${fileName(itemId, field)}');
      if (!await file.exists()) return null;
      final decoded =
          jsonDecode(await file.readAsString(encoding: utf8)) as Map;
      final text = decoded['text'];
      final meta = decoded['meta'];
      if (text is! String || text.isEmpty) return null;
      return CachedTranslation(
        text: text,
        meta: meta is Map ? Map<String, dynamic>.from(meta) : <String, dynamic>{},
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> remove(String itemId, String field) async {
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}/${fileName(itemId, field)}');
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 一次读某影片的全部缓存字段（title / overview），供进页时预读。
  static Future<Map<String, CachedTranslation>> loadAll(String itemId) async {
    final out = <String, CachedTranslation>{};
    for (final f in const ['title', 'overview']) {
      final c = await load(itemId, f);
      if (c != null) out[f] = c;
    }
    return out;
  }
}
