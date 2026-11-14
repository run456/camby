import 'dart:io';

import 'package:camby/models.dart';
import 'package:camby/player/playback_plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.83：HDR / DV 显示与音频转码链路的回归守卫。
///
/// 两个真实 bug 的根因都在这里钉死：
///  ① `hasDolbyVision` 曾经由音轨里的 TrueHD/ATMOS 推断（视频动态范围
///     怎么可能来自音轨），导致 SDR 片误报 DV、真 HDR10 片显示 SDR；
///  ② 客户端从不向 Emby 声明设备能力，服务端无法做音频转码决策，
///     HLS 回退是黑盒，且 PlayMethod 恒报 DirectPlay。
String src(String path) => File(path).readAsStringSync();

MediaItem mk({
  VideoRange range = VideoRange.sdr,
  String audioCodec = 'AAC',
  int audioChannels = 2,
}) => MediaItem(
  id: 'm1',
  name: '测试片',
  overview: '',
  colors: const [Color(0xFF101820)],
  type: MediaType.movie,
  videoRange: range,
  audioCodec: audioCodec,
  audioChannels: audioChannels,
);

void main() {
  group('视频动态范围解析', () {
    test('Emby VideoRangeType 常见取值全部认得', () {
      expect(parseVideoRange('SDR'), VideoRange.sdr);
      expect(parseVideoRange('HDR10'), VideoRange.hdr10);
      expect(parseVideoRange('HDR10Plus'), VideoRange.hdr10Plus);
      expect(parseVideoRange('hdr10_plus'), VideoRange.hdr10Plus);
      expect(parseVideoRange('HLG'), VideoRange.hlg);
      expect(parseVideoRange('DOVI'), VideoRange.dovi);
      expect(parseVideoRange('DOVIWithHDR10'), VideoRange.dovi);
      expect(parseVideoRange('DOVIWithHLG'), VideoRange.dovi);
      expect(parseVideoRange('HDR'), VideoRange.hdr10); // 旧 VideoRange 字段
      expect(parseVideoRange('Unknown'), VideoRange.unknown);
      expect(parseVideoRange(null), VideoRange.unknown);
      expect(parseVideoRange('随便什么'), VideoRange.unknown);
    });

    test('isHdr / isDolbyVision / needsGpuNext / label', () {
      expect(VideoRange.sdr.isHdr, isFalse);
      expect(VideoRange.unknown.isHdr, isFalse);
      for (final r in [
        VideoRange.hdr10,
        VideoRange.hdr10Plus,
        VideoRange.hlg,
        VideoRange.dovi,
      ]) {
        expect(r.isHdr, isTrue, reason: '$r 应算 HDR');
      }
      expect(VideoRange.dovi.isDolbyVision, isTrue);
      expect(VideoRange.hdr10.isDolbyVision, isFalse);
      // 只有 DV P5 的 IPTPQc2 必须靠 gpu-next 读 RPU 才不发绿发紫
      expect(VideoRange.dovi.needsGpuNext, isTrue);
      expect(VideoRange.hdr10.needsGpuNext, isFalse);
      expect(VideoRange.dovi.label, 'Dolby Vision');
      expect(VideoRange.hdr10Plus.label, 'HDR10+');
    });
  });

  group('MediaItem 序列化与老缓存降级', () {
    test('videoRange / audioStreamIndex / mediaSourceId 往返不丢', () {
      final m = MediaItem(
        id: 'm2',
        name: '片',
        overview: '',
        colors: const [Color(0xFF101820)],
        type: MediaType.movie,
        videoRange: VideoRange.dovi,
        audioStreamIndex: 2,
        mediaSourceId: 'src-9',
      );
      final back = MediaItem.fromJson(m.toJson());
      expect(back.videoRange, VideoRange.dovi);
      expect(back.audioStreamIndex, 2);
      expect(back.mediaSourceId, 'src-9');
      expect(back.effectiveRange, VideoRange.dovi);
    });

    test('没有 videoRange 的旧缓存由 isHdr / hasDolbyVision 反推', () {
      final legacy = <String, dynamic>{'isHdr': true, 'hasDolbyVision': false};
      expect(_legacyRange(legacy), VideoRange.hdr10);
      legacy['hasDolbyVision'] = true;
      expect(_legacyRange(legacy), VideoRange.dovi);
      legacy['isHdr'] = false;
      legacy['hasDolbyVision'] = false;
      expect(_legacyRange(legacy), VideoRange.sdr);
    });

    test('规格角标不再把 DV 与 ATMOS 混成一个标签', () {
      final m = mk(range: VideoRange.dovi);
      expect(m.specBadges, contains('Dolby Vision'));
      expect(m.specBadges.any((e) => e.contains('ATMOS')), isFalse);
    });
  });

  group('音频投递决策', () {
    test('无损 / DTS / 多声道编码与 ≥8 声道都要转码', () {
      for (final c in [
        'TrueHD',
        'DTS-HD MA',
        'DTSHDMA',
        'DTS:X',
        'DTS',
        'FLAC',
        'PCM',
        'LPCM',
      ]) {
        expect(isProblematicAudio(c, 2), isTrue, reason: c);
      }
      expect(isProblematicAudio('AAC', 8), isTrue);
      for (final c in ['AAC', 'AC3', 'EAC3', 'MP3', 'OPUS']) {
        expect(isProblematicAudio(c, 6), isFalse, reason: c);
      }
    });

    test('SDR + AAC：直连、不强制 MPV、PlayMethod=DirectPlay', () {
      final p = resolvePlaybackPlan(item: mk(), preferMpv: false);
      expect(p.audioDelivery, AudioDelivery.direct);
      expect(p.forceMpv, isFalse);
      expect(p.useGpuNext, isFalse);
      expect(p.toneMapToSdr, isFalse);
      expect(p.playMethod, 'DirectPlay');
    });

    test('HDR10 + TrueHD：强制 MPV、色调映射、音频单独转码', () {
      final p = resolvePlaybackPlan(
        item: mk(range: VideoRange.hdr10, audioCodec: 'TrueHD'),
        preferMpv: false,
      );
      expect(p.forceMpv, isTrue);
      expect(p.toneMapToSdr, isTrue);
      expect(p.useGpuNext, isFalse);
      expect(p.stereoDownmix, isTrue);
      expect(p.audioDelivery, AudioDelivery.audioOnly);
      expect(p.playMethod, 'DirectStream');
    });

    test('DV 片源：强制 MPV + gpu-next，与音轨无关', () {
      // 以前 DV 是靠音轨猜的：这里音轨是普通 AAC，必须照样识别成 DV。
      final p = resolvePlaybackPlan(
        item: mk(range: VideoRange.dovi, audioCodec: 'AAC'),
        preferMpv: false,
      );
      expect(p.range.isDolbyVision, isTrue);
      expect(p.forceMpv, isTrue);
      expect(p.useGpuNext, isTrue);
      expect(p.toneMapToSdr, isTrue);
      expect(p.audioDelivery, AudioDelivery.direct);
    });

    test('DV 保底转码：视频也重编码，PlayMethod=Transcode', () {
      final p = resolvePlaybackPlan(
        item: mk(range: VideoRange.dovi),
        preferMpv: false,
        forceVideoTranscode: true,
      );
      expect(p.audioDelivery, AudioDelivery.fullTranscode);
      expect(p.playMethod, 'Transcode');
    });
  });

  group('转码 URL 参数与能力协商', () {
    test('显式转码参数带齐必需项，且不强制视频重编码', () {
      final q = audioTranscodeParams(
        playSessionId: 'sid-1',
        startTimeTicks: ticksFromSeconds(123.5),
        mediaSourceId: 'src-9',
        audioStreamIndex: 2,
      );
      expect(q['PlaySessionId'], 'sid-1');
      expect(q['MediaSourceId'], 'src-9');
      expect(q['AudioStreamIndex'], '2');
      expect(q['AudioCodec'], 'aac');
      expect(q['MaxAudioChannels'], '2');
      expect(q['StartTimeTicks'], '1235000000');
      // 硬塞 VideoCodec 会把 4K HDR 压成 H264，默认不下发
      expect(q.containsKey('VideoCodec'), isFalse);
    });

    test('fullTranscode 才下发 VideoCodec', () {
      final q = audioTranscodeParams(
        playSessionId: 'sid',
        startTimeTicks: 0,
        videoTranscode: true,
      );
      expect(q['VideoCodec'], 'h264');
    });

    test('直连参数补齐 MediaSourceId / PlaySessionId', () {
      final q = directPlayParams(playSessionId: 'sid', mediaSourceId: 'src');
      expect(q['Static'], 'true');
      expect(q['MediaSourceId'], 'src');
      expect(q['PlaySessionId'], 'sid');
      expect(q.containsKey('AudioStreamIndex'), isFalse);
    });

    test('DeviceProfile 不声明无损音轨能力，字幕全部外挂', () {
      final dp = cambyDeviceProfile();
      final direct = (dp['DirectPlayProfiles'] as List).first as Map;
      final audio = direct['AudioCodec'] as String;
      expect(audio.contains('aac'), isTrue);
      expect(audio.toLowerCase().contains('truehd'), isFalse);
      expect(audio.toLowerCase().contains('dts'), isFalse);
      final subs = (dp['SubtitleProfiles'] as List).cast<Map>();
      expect(subs.every((e) => e['Method'] == 'External'), isTrue);
    });

    test('PlaybackInfo body 带 DeviceProfile / 续播位置 / 音轨', () {
      final body = playbackInfoBody(
        userId: 'u1',
        startTimeTicks: 10000000,
        mediaSourceId: 'src',
        audioStreamIndex: 2,
      );
      expect(body['UserId'], 'u1');
      expect(body['StartTimeTicks'], 10000000);
      expect(body['AudioStreamIndex'], 2);
      expect(body['MediaSourceId'], 'src');
      expect(body['AllowVideoStreamCopy'], isTrue);
      expect((body['DeviceProfile'] as Map)['Name'], 'Camby Android');
    });

    test('PlaybackRoute 可区分协商成功与显式兜底', () {
      const r = PlaybackRoute(
        url: 'https://x/master.m3u8',
        fallbackUrl: 'https://x/stream',
        playMethod: 'DirectStream',
        playSessionId: 'sid',
        negotiated: true,
        diagnostic: 'PlaybackInfo 协商',
      );
      expect(r.negotiated, isTrue);
      expect(r.playMethod, 'DirectStream');
    });
  });

  group('源码守卫：旧实现不许回来', () {
    test('emby_client 不再用音轨推断 Dolby Vision', () {
      final s = src('lib/emby_client.dart');
      expect(
        s.contains(
          "audioCodec.contains('TrueHD') || audioCodec.contains('ATMOS')",
        ),
        isFalse,
      );
      expect(s.contains('hasDolbyVision: range.isDolbyVision'), isTrue);
      expect(s.contains('parseVideoRange('), isTrue);
      expect(s.contains('videoRange: range'), isTrue);
    });

    test('播放能力协商链路齐全', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains('/Items/'), isTrue);
      expect(
        s.contains("'/PlaybackInfo'") || s.contains('/PlaybackInfo'),
        isTrue,
      );
      expect(s.contains('playbackInfoBody('), isTrue);
      expect(s.contains('audioTranscodeParams('), isTrue);
      expect(s.contains('ensurePlaySessionId()'), isTrue);
      expect(s.contains('_sessionPlayMethod'), isTrue);
      expect(s.contains("'PlayMethod': 'DirectPlay'"), isFalse);
    });

    test('播放页用真实动态范围，且按决策结果起播', () {
      final s = src('lib/pages/player_page.dart');
      expect(
        s.contains("item.hasDolbyVision ? 'Dolby Vision' : 'SDR'"),
        isFalse,
      );
      expect(s.contains('item.effectiveRange.label'), isTrue);
      expect(s.contains('resolvePlayback('), isTrue);
      expect(
        s.contains('useGpuNext: useGpuNextOverride ?? _plan.useGpuNext'),
        isTrue,
      );
      expect(
        s.contains('useGpuNextOverride: _plan.useGpuNext ? false : null'),
        isTrue,
      );
      expect(s.contains('_currentUrl'), isTrue);
      expect(s.contains('playMethod: _route?.playMethod'), isTrue);
    });

    test('MPV 有色调映射与 gpu-next，SDR 片不受影响', () {
      final s = src('lib/player/playback.dart');
      expect(s.contains("vo: 'gpu-next'"), isTrue);
      expect(s.contains("'target-prim', 'bt.709'"), isTrue);
      expect(s.contains("'target-trc', 'bt.1886'"), isTrue);
      expect(s.contains("'tone-mapping', 'spline'"), isTrue);
      expect(s.contains("'tone-mapping', 'hable'"), isTrue);
      expect(s.contains('plan?.toneMapToSdr ?? false'), isTrue);
      expect(s.contains("'audio-channels', 'stereo'"), isTrue);
    });

    test('设置页有 DV 保底转码开关，原生层有 HDR 能力诊断', () {
      expect(
        src('lib/pages/settings_page.dart').contains("'dv_transcode'"),
        isTrue,
      );
      expect(
        src('lib/player/display_caps.dart').contains('hdrCapabilities'),
        isTrue,
      );
      expect(
        src('android/app/src/main/kotlin/cn/camby/camby/MainActivity.kt')
            .contains('supportedHdrTypes'),
        isTrue,
      );
    });
  });
}

/// 只构造最小 JSON，验证 fromJson 的老缓存降级路径
VideoRange _legacyRange(Map<String, dynamic> extra) {
  final base = mk().toJson()
    ..remove('videoRange')
    ..addAll(extra);
  return MediaItem.fromJson(base).effectiveRange;
}
