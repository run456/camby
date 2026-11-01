import 'package:camby/emby_client.dart';
import 'package:camby/widgets/subtitle_style_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.7.38 新增逻辑的回归测试：
/// 字幕样式持久化 / 叠加层落位、文件名分辨率兜底。
void main() {
  group('SubtitleStyle', () {
    test('默认值与 copyWith（大小/位置/偏移/加粗/字体可调）', () {
      const s = SubtitleStyle();
      expect(s.size, 17);
      expect(s.pos, 0.12);
      expect(s.bold, isTrue, reason: '默认加粗（影院风格）');
      expect(s.font, SubtitleFont.system);

      final t = s.copyWith(size: 22, pos: 0.2, bold: false, font: SubtitleFont.fangsong);
      expect(t.size, 22);
      expect(t.pos, 0.2);
      expect(t.bold, isFalse);
      expect(t.font, SubtitleFont.fangsong);
      // 未指定的字段必须保持原值
      expect(t.offset, s.offset);
      expect(s.size, 17, reason: 'copyWith 不能改动原对象');
    });

    test('JSON 往返只保留 size/pos/offset/bold/font', () {
      const s = SubtitleStyle(
        size: 21.5,
        pos: 0.3,
        offset: -0.08,
        bold: false,
        font: SubtitleFont.fangsong,
      );
      final t = SubtitleStyle.fromJson(s.toJson());
      expect(t.size, 21.5);
      expect(t.pos, 0.3);
      expect(t.offset, -0.08);
      expect(t.bold, isFalse);
      expect(t.font, SubtitleFont.fangsong);
    });

    test('残缺 JSON 回落到默认值（加粗默认开、字体默认系统）', () {
      final t = SubtitleStyle.fromJson(<String, dynamic>{'size': 20});
      expect(t.size, 20);
      expect(t.pos, 0.12);
      expect(t.bold, isTrue);
      expect(t.font, SubtitleFont.system);
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

    test('textStyle：加粗开=w800、关=w500；仿宋套 fontFamily', () {
      final boldOn = const SubtitleStyle(size: 24).textStyle;
      expect(boldOn.shadows?.length, 8);
      expect(boldOn.fontWeight, FontWeight.w800);
      expect(boldOn.color, const Color(0xFFFFFFFF));
      expect(boldOn.fontFamily, isNull);

      final boldOff = const SubtitleStyle(size: 24, bold: false).textStyle;
      expect(boldOff.fontWeight, FontWeight.w500);

      final fang = const SubtitleStyle(font: SubtitleFont.fangsong).textStyle;
      expect(fang.fontFamily, 'FangSong');
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
