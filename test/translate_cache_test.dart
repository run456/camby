import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/lara/translate_cache.dart';

/// flutter test 跑在桌面宿主上，path_provider 的原生通道没有实现，
/// 这里把用到的 `getApplicationDocumentsDirectory` 通道方法 mock 成系统临时目录。
const _ppChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late final Directory docsDir;
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = Directory.systemTemp.createTempSync('camby_lara_docs');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ppChannel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          return docsDir.path;
        default:
          return null;
      }
    });
  });

  group('LaraTranslateCache.safeId', () {
    test('纯数字字母 id 原样保留', () {
      expect(LaraTranslateCache.safeId('15512'), '15512');
    });
    test('特殊字符替换为下划线', () {
      expect(LaraTranslateCache.safeId('a/b:c*d?e'), 'a_b_c_d_e');
    });
    test('空白回落到占位', () {
      expect(LaraTranslateCache.safeId('   '), '_empty');
    });
    test('文件名按 id + 字段拼出', () {
      expect(
        LaraTranslateCache.fileName('item9', 'title'),
        'item9_title.json',
      );
    });
  });

  group('LaraTranslateCache 存取（title / overview）', () {
    const meta = <String, dynamic>{
      'target': 'zh-CN',
      'style': 'faithful',
      'detectedSource': 'en',
      'savedAt': '2025-01-01T00:00:00.000Z',
    };

    test('save 后能 load 回来，且字段正确', () async {
      await LaraTranslateCache.save('m1', 'title', '你好世界', meta);
      final c = await LaraTranslateCache.load('m1', 'title');
      expect(c, isNotNull);
      expect(c!.text, '你好世界');
      expect(c.target, 'zh-CN');
      expect(c.style, 'faithful');
      expect(c.detectedSource, 'en');
      await LaraTranslateCache.remove('m1', 'title');
    });

    test('title 与 overview 互不覆盖（按 id+字段隔离）', () async {
      await LaraTranslateCache.save('m2', 'title', '标题译文', meta);
      await LaraTranslateCache.save('m2', 'overview', '简介译文', meta);
      final t = await LaraTranslateCache.load('m2', 'title');
      final o = await LaraTranslateCache.load('m2', 'overview');
      expect(t!.text, '标题译文');
      expect(o!.text, '简介译文');
      await LaraTranslateCache.remove('m2', 'title');
      await LaraTranslateCache.remove('m2', 'overview');
    });

    test('不存在的 id 返回 null，不抛异常', () async {
      expect(await LaraTranslateCache.load('no-such', 'title'), isNull);
    });

    test('remove 不存在返回 false，存在返回 true', () async {
      expect(await LaraTranslateCache.remove('x', 'title'), isFalse);
      await LaraTranslateCache.save('x', 'title', 't', meta);
      expect(await LaraTranslateCache.remove('x', 'title'), isTrue);
    });

    test('loadAll 一次读回该影片已缓存的全部字段', () async {
      await LaraTranslateCache.save('m3', 'title', 'T', meta);
      await LaraTranslateCache.save('m3', 'overview', 'O', meta);
      final all = await LaraTranslateCache.loadAll('m3');
      expect(all.length, 2);
      expect(all['title']!.text, 'T');
      expect(all['overview']!.text, 'O');
      await LaraTranslateCache.remove('m3', 'title');
      await LaraTranslateCache.remove('m3', 'overview');
    });

    test('loadAll 在无缓存时返回空 map', () async {
      final all = await LaraTranslateCache.loadAll('never_saved');
      expect(all, isEmpty);
    });

    test('中文 UTF-8 译文落盘后无损读回', () async {
      const zh = '在黑暗的森林里，一名少女遇见了会说话的狐狸。';
      await LaraTranslateCache.save('m4', 'overview', zh, meta);
      final c = await LaraTranslateCache.load('m4', 'overview');
      expect(c!.text, zh);
      await LaraTranslateCache.remove('m4', 'overview');
    });

    test('meta 缺失时回落到默认值，不抛异常', () async {
      // save 写入完整文件后，手工覆盖为空 meta 以验证 load 的稳健性
      await LaraTranslateCache.save('m5', 'title', 'x', meta);
      final dir = Directory('${docsDir.path}/lara_translate_cache');
      final f = File('${dir.path}/m5_title.json');
      await f.writeAsString('{"text":"x"}', flush: true);
      final c = await LaraTranslateCache.load('m5', 'title');
      expect(c, isNotNull);
      expect(c!.text, 'x');
      expect(c.target, 'zh-CN'); // 默认值
      await LaraTranslateCache.remove('m5', 'title');
    });

    test('文件损坏时 load 返回 null 而非抛异常', () async {
      final dir = Directory('${docsDir.path}/lara_translate_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}/broken_title.json');
      await f.writeAsString('not json at all', flush: true);
      expect(await LaraTranslateCache.load('broken', 'title'), isNull);
    });
  });
}
