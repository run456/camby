import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/subtitles/online_subtitle.dart';
import 'package:camby/subtitles/subtitle_cache.dart';
import 'package:camby/subtitles/subtitles.dart';

/// flutter test 跑在桌面宿主上，path_provider 的原生通道没有实现，
/// 这里把两个用到的通道方法 mock 成系统临时目录（getExternalStorageDirectory
/// 返回 null，模拟非 Android 走文档目录回退）。
const _ppChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late final Directory docsDir;
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = Directory.systemTemp.createTempSync('camby_docs');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ppChannel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          return docsDir.path;
        case 'getExternalStorageDirectory':
          return null; // 模拟非 Android，走文档目录回退
        default:
          return null;
      }
    });
  });

  group('OnlineSubtitleCache.safeId', () {
    test('数字 id 原样保留', () {
      expect(OnlineSubtitleCache.safeId('15512'), '15512');
    });
    test('特殊字符替换为下划线', () {
      expect(OnlineSubtitleCache.safeId('a/b:c*d?e'), 'a_b_c_d_e');
    });
    test('空白回落到占位', () {
      expect(OnlineSubtitleCache.safeId('   '), '_empty');
    });
  });

  group('OnlineSubtitleCache.exportFileName', () {
    test('影片名直接拼出 语言.格式（保留原文件名便于 Emby 匹配）', () {
      final name = OnlineSubtitleCache.exportFileName(
        'Movie.Name-1080p',
        'zh-CN',
        'srt',
      );
      // 调用方已去掉扩展名，这里只清洗非法字符并拼上 语言.格式
      expect(name, 'Movie.Name-1080p.zh-CN.srt');
    });
    test('空片名用 subtitle 兜底', () {
      expect(
        OnlineSubtitleCache.exportFileName('', '', 'srt'),
        'subtitle.und.srt',
      );
    });
  });

  group('OnlineSubtitleCache 存取', () {
    late OnlineSubtitle item;
    const text = '''1
00:00:01,000 --> 00:00:03,000
你好，世界

2
00:00:04,000 --> 00:00:06,000
字幕测试
''';

    setUp(() {
      item = OnlineSubtitle(
        id: 'u1',
        title: '示例字幕',
        source: OnlineSubtitleSource.xunlei,
        url: 'https://example.com/a.srt',
        format: 'srt',
        language: 'zh-CN',
        fileName: 'a.srt',
      );
    });

    test('save 后能 load 回来，且能够解析出字幕', () async {
      await OnlineSubtitleCache.save('999', item, text);
      final c = await OnlineSubtitleCache.load('999');
      expect(c, isNotNull);
      expect(c!.title, '示例字幕');
      expect(c.url, 'https://example.com/a.srt');
      expect(c.language, 'zh-CN');
      expect(c.source, 'xunlei');
      // 缓存文本能重新解析成叠加层 cues
      final cues = Subtitles.parseAny(c.text);
      expect(cues.length, 2);
      expect(cues.first.text, contains('你好'));
      // toOnlineSubtitle 能重建来源标识
      expect(c.toOnlineSubtitle().source, OnlineSubtitleSource.xunlei);
      await OnlineSubtitleCache.remove('999');
    });

    test('不存在的 id 返回 null，不抛异常', () async {
      expect(await OnlineSubtitleCache.load('no-such-id'), isNull);
    });

    test('remove 后 load 返回 null', () async {
      await OnlineSubtitleCache.save('1000', item, text);
      expect(await OnlineSubtitleCache.remove('1000'), isTrue);
      expect(await OnlineSubtitleCache.load('1000'), isNull);
    });

    test('export 写出 .srt 并返回绝对路径', () async {
      await OnlineSubtitleCache.save('1001', item, text);
      final path = await OnlineSubtitleCache.export(
        '1001',
        movieName: '示例影片',
      );
      expect(path, endsWith('.srt'));
      final f = File(path);
      expect(await f.exists(), isTrue);
      expect(await f.readAsString(), text);
      await OnlineSubtitleCache.remove('1001');
    });
  });
}
