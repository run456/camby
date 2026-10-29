import 'package:camby/emby_client.dart';
import 'package:camby/widgets/subtitle_style_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.7.38 新增逻辑的回归测试：
/// 字幕样式持久化 / 叠加层落位、Emby 码率上限参数、文件名分辨率兜底。
void main() {
  group('SubtitleStyle', () {
    test('默认值与 copyWith', () {
      const s = SubtitleStyle();
      expect(s.size, 17);
      expect(s.pos, 0.12);
      expect(s.stroke, 1.8);
      expect(s.color, Colors.white);

      final t = s.copyWith(size: 22, color: Colors.amber);
      expect(t.size, 22);
      expect(t.color, Colors.amber);
      // 未指定的字段必须保持原值
      expect(t.pos, s.pos);
      expect(t.opa, s.opa);
      expect(s.size, 17, reason: 'copyWith 不能改动原对象');
    });

    test('JSON 往返无损', () {
      const s = SubtitleStyle(
        size: 21.5,
        pos: 0.3,
        opa: 0.75,
        stroke: 0,
        offset: -0.08,
        color: Color(0xFFA6FFB2),
      );
      final t = SubtitleStyle.fromJson(s.toJson());
      expect(t.size, 21.5);
      expect(t.pos, 0.3);
      expect(t.opa, 0.75);
      expect(t.stroke, 0);
      expect(t.offset, -0.08);
      expect(t.color.toARGB32(), 0xFFA6FFB2);
    });

    test('残缺 JSON 回落到默认值', () {
      final t = SubtitleStyle.fromJson(<String, dynamic>{'size': 20});
      expect(t.size, 20);
      expect(t.pos, 0.12);
      expect(t.stroke, 1.8);
      expect(t.color, Colors.white);
    });

    test('bottomRatio = 位置 + 偏移，且被夹在 0~0.6', () {
      expect(const SubtitleStyle().bottomRatio, closeTo(0.12, 1e-9));
      expect(
        const SubtitleStyle(pos: 0.4, offset: 0.35).bottomRatio,
        0.6,
        reason: '正偏移过大时不能把字幕推出屏幕',
      );
      expect(
        const SubtitleStyle(pos: 0.05, offset: -0.2).bottomRatio,
        0.0,
        reason: '负偏移过大时不能穿到屏幕下方',
      );
    });

    test('textStyle：关描边只有一层阴影，开描边是四向描边', () {
      expect(const SubtitleStyle(stroke: 0).textStyle.shadows?.length, 1);
      const s = SubtitleStyle(size: 24, opa: 0.5);
      final ts = s.textStyle;
      expect(ts.shadows?.length, 4);
      expect(ts.fontSize, 24);
      // 半透明 => alpha 127（255*0.5 取整）
      expect(ts.color?.alpha, 128);
    });
  });

  group('Emby streamUrl 码率上限', () {
    EmbyServer server() => EmbyServer(
          host: 'example.com',
          port: 8096,
          secure: true,
          username: 'u',
        );

    test('不带码率时不追加 MaxStreamingBitrate', () {
      final url = server().streamUrl('42');
      expect(url, contains('Static=true'));
      expect(url, isNot(contains('MaxStreamingBitrate')));
    });

    test('带码率时追加参数（转码地址同理）', () {
      final direct = server().streamUrl('42', maxBitrate: 20000000);
      expect(direct, contains('&MaxStreamingBitrate=20000000'));
      final hls = server().streamUrl('42', direct: false, maxBitrate: 1);
      expect(hls, contains('master.m3u8'));
      expect(hls, contains('&MaxStreamingBitrate=1'));
    });

    test('0 / 负数视为「不限」，不追加参数', () {
      expect(server().streamUrl('42', maxBitrate: 0),
          isNot(contains('MaxStreamingBitrate')));
      expect(server().streamUrl('42', maxBitrate: -1),
          isNot(contains('MaxStreamingBitrate')));
    });
  });

  group('文件名分辨率兜底', () {
    int? h(String n) => EmbyServer.heightFromNameForTest(n);

    test('显式 Np 标记', () {
      expect(h('Movie.2160p.WEB-DL.x265.mkv'), 2160);
      expect(h('Some Show S01E02 1080p HEVC'), 1080);
      expect(h('老片.720p.HDTV'), 720);
      expect(h('dvd rip 480p'), 480);
    });

    test('隐含标记：4K / UHD / HDRip', () {
      expect(h('The.Matrix.4K.Remaster'), 2160);
      expect(h('Planet Earth II UHD'), 2160);
      expect(h('Movie.HDRip.AC3'), 720);
    });

    test('认不出时不猜，返回 null 交给 MediaStreams', () {
      expect(h(''), isNull);
      expect(h('童年回忆录 Home Video'), isNull);
      // 2170p 这类非标准写法不能误判成别的分辨率
      expect(h('weird 2170p source'), isNull);
    });
  });
}
