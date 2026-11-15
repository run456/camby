import 'package:flutter_test/flutter_test.dart';
import 'package:camby/models.dart';

/// A1（v2.0.98）：绿联影视中心内置的 PGS / DVDSUB 图像字幕之前会被当成 SRT
/// 去请求 `/Subtitles/{idx}/Stream.srt` 端点，绿联无法把图像字幕转文本 → HTTP 404
/// 「字幕加载失败」。修复后：图像字幕用 [SubtitleTrackInfo.isImage] 标记，
/// [textUrl]/[textCandidates] 返回空，由播放器改走 MPV 内封轨原生渲染。
void main() {
  group('SubtitleTrackInfo.isImage：图像字幕判定', () {
    test('PGS 各写法都算图像字幕（大小写/前后缀）', () {
      for (final c in const [
        'pgs',
        'pgssub',
        'hdmv_pgs_subtitle',
        'PGS',
        'Hdmv_Pgs_Subtitle',
      ]) {
        expect(SubtitleTrackInfo(index: 0, codec: c).isImage, isTrue,
            reason: 'codec=$c 应判为图像字幕');
      }
    });

    test('DVDSUB / VobSub 是图像字幕', () {
      expect(SubtitleTrackInfo(index: 0, codec: 'dvd_subtitle').isImage, isTrue);
      expect(SubtitleTrackInfo(index: 0, codec: 'DVD_SUB').isImage, isTrue);
      expect(SubtitleTrackInfo(index: 0, codec: 'vobsub').isImage, isTrue);
    });

    test('纯文本字幕不算图像字幕（含 sub 兜底的误判防护）', () {
      // 这几类早期会被 `sub` 子串误命中，必须显式排除。
      for (final c in const ['srt', 'subrip', 'subtitles', 'ass', 'ssa', 'vtt']) {
        expect(SubtitleTrackInfo(index: 0, codec: c).isImage, isFalse,
            reason: 'codec=$c 是文本字幕，不应判为图像');
      }
    });
  });

  group('图像字幕不生成 .srt 候选（避免撞 404）', () {
    test('textUrl 对图像字幕返回空', () {
      const t = SubtitleTrackInfo(
        index: 1,
        codec: 'pgssub',
        language: 'chi',
        url: 'https://ug/Videos/9/Subtitles/1/Stream.pgs?api_key=k',
      );
      expect(t.isImage, isTrue);
      expect(t.textUrl, isEmpty);
    });

    test('textCandidates 对图像字幕返回空列表（含 altUrls）', () {
      const t = SubtitleTrackInfo(
        index: 2,
        codec: 'dvd_subtitle',
        url: 'https://ug/Videos/9/Subtitles/2/Stream.dvb?api_key=k',
        altUrls: [
          'https://ug/Videos/9/Subtitles/2/Stream.srt?api_key=k',
        ],
      );
      expect(t.isImage, isTrue);
      expect(t.textCandidates, isEmpty);
    });

    test('文本字幕仍正常产出 .srt 文本地址', () {
      const t = SubtitleTrackInfo(
        index: 0,
        codec: 'ass',
        url: 'https://ug/Videos/1/2/Subtitles/0/Stream.ass?api_key=k',
      );
      expect(t.isImage, isFalse);
      expect(t.textUrl,
          'https://ug/Videos/1/2/Subtitles/0/Stream.srt?api_key=k');
    });
  });
}
