import 'dart:ui' show Color;

import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.7.23 / v1.7.25 / v1.7.27 / v1.7.28 补齐项的行为回归
void main() {
  group('中文字幕判定链', () {
    test('语言代码优先', () {
      expect(
        const SubtitleTrackInfo(index: 0, language: 'zh').isChinese,
        isTrue,
      );
      expect(
        const SubtitleTrackInfo(index: 0, language: 'chi').isChinese,
        isTrue,
      );
      expect(
        const SubtitleTrackInfo(index: 0, language: 'zho').isChinese,
        isTrue,
      );
    });

    test('明确外语不翻转', () {
      for (final lang in ['eng', 'jpn', 'fre', 'ger', 'kor']) {
        expect(
          SubtitleTrackInfo(index: 0, language: lang).isChinese,
          isFalse,
          reason: '$lang 不该被判成中文',
        );
      }
    });

    test('显示名里的中文标记也算', () {
      expect(
        const SubtitleTrackInfo(index: 0, displayTitle: '简体中文').isChinese,
        isTrue,
      );
      expect(
        const SubtitleTrackInfo(index: 0, displayTitle: 'Chinese (CHS)')
            .isChinese,
        isTrue,
      );
    });

    test('外挂字幕文件名兜底：.chs / .zh-cn', () {
      expect(
        const SubtitleTrackInfo(
          index: 0,
          sourcePath: '/media/Movies/Film.2024.chs.srt',
        ).isChinese,
        isTrue,
      );
      expect(
        const SubtitleTrackInfo(
          index: 0,
          sourcePath: '/media/Movies/Film.2024.zh-cn.ass',
        ).isChinese,
        isTrue,
      );
    });

    test('分段匹配：scene 里的 en 不误判为外语，仍走文本兜底', () {
      // 关键要求 —— 不能因为文件名含 scene 就判成英文
      const t = SubtitleTrackInfo(
        index: 0,
        sourcePath: '/media/Movies/the.scene.2004.srt',
      );
      // 没有明确外语标记 → 文本字幕走默认中文兜底
      expect(t.isChinese, isTrue);
      expect(t.language, isEmpty);
    });

    test('无语言标记的文本字幕默认中文（v1.7.27）', () {
      for (final codec in ['srt', 'subrip', 'ass', 'ssa', 'vtt']) {
        expect(
          SubtitleTrackInfo(index: 0, codec: codec).isChinese,
          isTrue,
          reason: '$codec 无语言标记应默认中文',
        );
      }
    });

    test('图片字幕不参与兜底', () {
      for (final codec in ['pgssub', 'pgs', 'sup']) {
        expect(
          SubtitleTrackInfo(index: 0, codec: codec).isChinese,
          isFalse,
          reason: '$codec 是图片字幕，不该被当中文',
        );
      }
    });

    test('详情页标签用的是同一套判断', () {
      const item = MediaItem(
        id: 'x',
        name: '测试影片',
        overview: '',
        colors: [Color(0xFF101820), Color(0xFF203040)],
        type: MediaType.movie,
        subtitles: [SubtitleTrackInfo(index: 0, codec: 'srt')],
      );
      expect(itemHasChineseSubtitle(item), isTrue);

      const item2 = MediaItem(
        id: 'y',
        name: '测试影片2',
        overview: '',
        colors: [Color(0xFF101820), Color(0xFF203040)],
        type: MediaType.movie,
        subtitles: [SubtitleTrackInfo(index: 0, language: 'eng', codec: 'srt')],
      );
      expect(itemHasChineseSubtitle(item2), isFalse);
    });
  });

  group('字幕候选地址（v1.7.25 五级）', () {
    test('candidates 保持优先级并去重', () {
      const t = SubtitleTrackInfo(
        index: 1,
        url: 'https://a/1',
        altUrls: ['https://a/2', 'https://a/1', 'https://a/3'],
        sourcePath: '/media/sub.chs.srt',
      );
      expect(t.candidates, ['https://a/1', 'https://a/2', 'https://a/3']);
    });

    test('文本候选把 Stream.ass 统一转成 Stream.srt，且保留 /Items/File 直取', () {
      const t = SubtitleTrackInfo(
        index: 3,
        url: 'https://a/Videos/1/2/Subtitles/3/0/Stream.ass?api_key=t',
        altUrls: ['https://a/Items/1/File?Path=%2Fmedia%2Fsub.chs.srt&api_key=t'],
      );
      final texts = t.textCandidates;
      expect(texts.first, contains('Stream.srt'));
      expect(texts.last, contains('/Items/1/File'));
      // 文件直取地址里没有 Stream.xxx，不能被改写
      expect(texts.last, contains('Path='));
    });

    test('序列化保留 sourcePath', () {
      const t = SubtitleTrackInfo(
        index: 0,
        url: 'u',
        sourcePath: '/media/x.srt',
      );
      final back = SubtitleTrackInfo.fromJson(t.toJson());
      expect(back.sourcePath, '/media/x.srt');
      expect(back.url, 'u');
    });
  });
}
