import 'package:flutter_test/flutter_test.dart';
import 'package:camby/models.dart';
import 'package:camby/subtitles/subtitles.dart';

void main() {
  test('SRT 解析：时间轴 + 多行文本', () {
    const srt = '''
1
00:00:01,000 --> 00:00:04,500
第一行
第二行

2
00:00:05,000 --> 00:00:07,000
<i>斜体标签</i>会被去掉

3
00:00:08,000 --> 00:00:08,000
结束时间等于开始时间的无效条
''';
    final cues = Subtitles.parse(srt);
    expect(cues.length, 2);
    expect(cues[0].start, 1.0);
    expect(cues[0].end, 4.5);
    expect(cues[0].text, '第一行\n第二行');
    expect(cues[1].text, '斜体标签会被去掉');
  });

  test('VTT 解析：点号毫秒 + 样式标签', () {
    const vtt = '''
WEBVTT

00:00:02.000 --> 00:00:04.000 align:start
<c.yellow>带样式</c>字幕

00:00:04.200 --> 00:00:06.000
<00:00:05.000>时间戳标签
''';
    final cues = Subtitles.parse(vtt);
    expect(cues.length, 2);
    expect(cues[0].start, 2.0);
    expect(cues[0].text, '带样式字幕');
    expect(cues[1].text, '时间戳标签');
  });

  test('textAt：命中区间内返回文本，区间外为空', () {
    final cues = Subtitles.parse('''
1
00:00:01,000 --> 00:00:03,000
AAA

2
00:00:04,000 --> 00:00:06,000
BBB
''');
    expect(Subtitles.textAt(cues, 2.0), 'AAA');
    expect(Subtitles.textAt(cues, 3.5), '');
    expect(Subtitles.textAt(cues, 5.0), 'BBB');
    expect(Subtitles.textAt(cues, 99), '');
  });

  test('ASS 文本不会被误判为 SRT 条目', () {
    const ass = '''
[Script Info]
Title: test

[Events]
Format: Layer, Start, End
Dialogue: 0,0:00:01.00,0:00:02.00,test
''';
    final cues = Subtitles.parse(ass);
    expect(cues, isEmpty);
  });

  test('textUrl：统一转成 Stream.srt', () {
    const t = SubtitleTrackInfo(
      index: 0,
      codec: 'ass',
      url: 'https://x/Videos/1/2/Subtitles/0/Stream.ass?api_key=k',
    );
    expect(
      t.textUrl,
      'https://x/Videos/1/2/Subtitles/0/Stream.srt?api_key=k',
    );
  });
}
