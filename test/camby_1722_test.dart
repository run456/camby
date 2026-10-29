import 'dart:convert';

import 'package:camby/models.dart';
import 'package:camby/subtitles/subtitles.dart';
import 'package:camby/widgets/subtitle_style_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.7.22 对齐项的回归测试：
///  · 字幕多候选地址（DeliveryUrl 优先 + 新旧路由回退）
///  · SubtitleTrackInfo 序列化带上 altUrls
///  · 字幕样式与 libmpv 属性的换算关系（sub-pos / sub-scale 的方向）
void main() {
  group('SubtitleTrackInfo 多候选地址', () {
    test('candidates 按优先级排列且去重', () {
      const t = SubtitleTrackInfo(
        index: 3,
        url: 'https://a/primary',
        altUrls: <String>[
          'https://a/alt1',
          'https://a/primary', // 与主地址重复，应被剔除
          '', // 空串应被跳过
          'https://a/alt2',
        ],
      );
      expect(t.candidates, <String>[
        'https://a/primary',
        'https://a/alt1',
        'https://a/alt2',
      ]);
    });

    test('只有备用地址时主地址为空不影响', () {
      const t = SubtitleTrackInfo(
        index: 0,
        altUrls: <String>['https://a/only'],
      );
      expect(t.candidates, <String>['https://a/only']);
      // textUrl 会去取 url（这里是 null）→ 空串
      expect(t.textUrl, '');
    });

    test('textUrl 把 Stream.ass 改写成 Stream.srt', () {
      const t = SubtitleTrackInfo(
        index: 1,
        url: 'https://h/emby/Videos/x/Subtitles/1/Stream.ass?api_key=k',
      );
      expect(t.textUrl, contains('Stream.srt'));
      expect(t.textUrl, contains('api_key=k'));
    });

    test('textCandidates 逐个改写且保持数量', () {
      const t = SubtitleTrackInfo(
        index: 1,
        url: 'https://h/a/Stream.ass?x=1',
        altUrls: <String>['https://h/b/Stream.vtt?x=1'],
      );
      final texts = t.textCandidates;
      expect(texts.length, 2);
      expect(texts[0], 'https://h/a/Stream.srt?x=1');
      expect(texts[1], 'https://h/b/Stream.srt?x=1');
    });

    test('toJson / fromJson 保留 altUrls', () {
      const t = SubtitleTrackInfo(
        index: 2,
        language: 'chi',
        url: 'https://h/p',
        altUrls: <String>['https://h/a1', 'https://h/a2'],
      );
      final back = SubtitleTrackInfo.fromJson(t.toJson());
      expect(back.altUrls, t.altUrls);
      expect(back.url, t.url);
      expect(back.index, 2);
      expect(back.language, 'chi');
    });

    test('旧缓存 JSON（无 altUrls 字段）不炸', () {
      final back = SubtitleTrackInfo.fromJson(<String, dynamic>{
        'index': 0,
        'url': 'https://h/old',
      });
      expect(back.altUrls, isEmpty);
      expect(back.candidates, <String>['https://h/old']);
    });
  });

  group('Subtitles.load 多候选回退', () {
    /// 模拟服务器：只有第二个地址能给出字幕内容
    Future<List<int>?> fetcher(String url) async {
      if (url.contains('second')) {
        // 必须是 UTF-8 字节，不能用 codeUnits（那是 UTF-16 码元）
        return utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n你好\n');
      }
      return null; // 第一个地址 404
    }

    test('主地址失败后自动试备用地址', () async {
      final cues = await Subtitles.load(
        'https://h/first/Stream.srt',
        altUrls: const <String>['https://h/second/Stream.srt'],
        fetcher: fetcher,
      );
      expect(cues.length, 1);
      expect(cues.first.text, '你好');
    });

    test('全部失败返回空且 lastDiag 有原因', () async {
      final cues = await Subtitles.load(
        'https://h/first/Stream.srt',
        altUrls: const <String>['https://h/third/Stream.srt'],
        fetcher: (u) async => null,
      );
      expect(cues, isEmpty);
      expect(Subtitles.lastDiag, isNotEmpty);
    });

    test('altUrls 与 fallbackUrl 同时给出时都能轮到', () async {
      final seen = <String>[];
      final cues = await Subtitles.load(
        'https://h/first/Stream.srt',
        altUrls: const <String>['https://h/second/Stream.srt'],
        fallbackUrl: 'https://h/first/Stream.ass',
        fetcher: (u) async {
          seen.add(u);
          return null;
        },
      );
      expect(cues, isEmpty);
      // 三个地址都要试过
      expect(seen.length, 3);
    });
  });

  group('字幕样式 → libmpv 属性换算', () {
    test('bottomRatio 越大越靠下，sub-pos 越小', () {
      const near = SubtitleStyle(pos: 0.05); // 贴底
      const far = SubtitleStyle(pos: 0.4); // 更靠上
      // 播放页把 bottomRatio 换算成 sub-pos = (1 - bottomRatio) * 100
      final posNear = (1 - near.bottomRatio) * 100;
      final posFar = (1 - far.bottomRatio) * 100;
      expect(posNear, greaterThan(posFar),
          reason: '贴底应得到更大的 sub-pos（libmpv 值越大越靠下）');
    });

    test('baseSize 作为 sub-scale 的 1.0 基准', () {
      const def = SubtitleStyle();
      expect(def.size, SubtitleStyle.baseSize,
          reason: '默认字号应与 baseSize 相同，保证默认 sub-scale = 1.0');
      expect(def.size / SubtitleStyle.baseSize, 1.0);
    });

    test('bottomRatio 会被夹到 0~0.6，避免算出负的 sub-pos', () {
      const s = SubtitleStyle(pos: 0.5, offset: 0.5);
      expect(s.bottomRatio, 0.6);
      final subPos = (1 - s.bottomRatio) * 100;
      expect(subPos, greaterThanOrEqualTo(0));
    });
  });
}
