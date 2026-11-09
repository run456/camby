import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.65 影片版本选择器。
///
/// 覆盖三件事：
///  1. `MediaSources` → 含主版本的全量版本列表（排序 / isPrimary）；
///  2. 每个版本的视频 / 音频 / 字幕 / 体积展示文案（切换时联动的依据）；
///  3. 源码守卫：一次请求、播放链路带 MediaSourceId、两块大卡片无描边。
String src(String rel) => File(rel).readAsStringSync();

void main() {
  final raw = <dynamic>[
    // 故意让 Index 乱序：服务端不保证顺序，必须按 Index 排，第一条才是主版本
    {
      'Id': 'src-4k',
      'Index': 1,
      'Name': '4K',
      'Path': '/media/movie-2160p.mkv',
      'Container': 'mkv',
      'Size': 20 * 1073741824 + 107374182, // 20.10 GB
      'RunTimeTicks': 69600000000, // 116 分钟
      'MediaStreams': [
        {'Type': 'Video', 'Codec': 'hevc', 'Width': 3840, 'Height': 2160},
        {
          'Type': 'Audio',
          'Codec': 'aac',
          'Channels': 2,
          'Language': 'jpn',
          'IsDefault': true,
        },
        {'Type': 'Subtitle', 'Codec': 'srt', 'DisplayTitle': '(SRT)'},
      ],
    },
    {
      'Id': 'src-1080',
      'Index': 0,
      'Name': '1080p',
      'Path': '/media/movie-1080p.mp4',
      'Container': 'mp4',
      'Size': 3 * 1073741824,
      'RunTimeTicks': 69600000000,
      'MediaStreams': [
        {'Type': 'Video', 'Codec': 'h264', 'Width': 1920, 'Height': 1080},
        {'Type': 'Audio', 'Codec': 'aac', 'Channels': 6},
        {'Type': 'Subtitle', 'Codec': 'ass', 'DisplayTitle': 'ASS'},
      ],
    },
  ];

  group('MediaSources → 版本列表', () {
    test('按 Index 排序并把第一条标为主版本', () {
      final vs = EmbyServer.versionsFromSources(raw);
      expect(vs.length, 2);
      expect(vs[0].id, 'src-1080');
      expect(vs[0].name, '1080p');
      expect(vs[0].isPrimary, isTrue);
      expect(vs[1].id, 'src-4k');
      expect(vs[1].isPrimary, isFalse);
    });

    test('额外部分 = 全部非主版本，主版本不混进去', () {
      final extra = EmbyServer.versionsFromSources(
        raw,
      ).where((v) => !v.isPrimary).toList();
      expect(extra.length, 1);
      expect(extra.single.id, 'src-4k');
    });

    test('空 / 单条数据不抛，单版本也不该渲染选择器', () {
      expect(EmbyServer.versionsFromSources(null), isEmpty);
      expect(EmbyServer.versionsFromSources(<dynamic>[]), isEmpty);
      final one = EmbyServer.versionsFromSources([raw[1]]);
      expect(one.length, 1);
      expect(one.single.isPrimary, isTrue);
      final detail = src('lib/pages/detail_page.dart');
      expect(detail.contains('if (vs.length < 2) return const <Widget>[];'),
          isTrue,
          reason: '单版本必须整块隐藏版本板块');
    });
  });

  group('版本规格文案', () {
    final vs = EmbyServer.versionsFromSources(raw);
    final main = vs.first;
    final uhd = vs.last;

    test('视频 / 音频 / 字幕胶囊随版本变化', () {
      expect(main.videoLabel, '1080P H264');
      expect(main.audioLabel, 'AAC 5.1');
      expect(main.subtitleLabel, '(ASS)');
      expect(uhd.videoLabel, '4K HEVC');
      expect(uhd.audioLabel, 'AAC stereo (默认)');
      expect(uhd.subtitleLabel, '(SRT)');
    });

    test('体积 / 分辨率 / 下拉副标题 / 时长', () {
      expect(uhd.sizeLabel, '20.10 GB');
      expect(uhd.resolutionLabel, '4K');
      expect(uhd.versionSubtitle, '4K · MKV · 20.10 GB');
      expect(uhd.runtimeMin, 116);
      expect(main.sizeLabel, '3.00 GB');
    });

    test('缺 MediaStreams 时退回源级字段，不抛异常', () {
      final p = MediaExtraPart.fromJson({
        'Id': 'x',
        'Name': 'X',
        'Height': 720,
        'VideoCodec': 'h264',
      })!;
      expect(p.videoLabel, '720P H264');
      expect(p.audioLabel, isEmpty);
      expect(p.subtitleLabel, isEmpty);
      expect(p.sizeLabel, isEmpty);
      expect(p.isPrimary, isFalse);
      expect(p.copyWith(isPrimary: true).isPrimary, isTrue);
    });

    test('字幕轨去重、最多 4 条，避免长串撑破胶囊', () {
      final p = MediaExtraPart.fromJson({
        'Id': 'y',
        'Name': 'Y',
        'MediaStreams': [
          {'Type': 'Subtitle', 'Codec': 'srt', 'DisplayTitle': '(SRT)'},
          {'Type': 'Subtitle', 'Codec': 'srt', 'DisplayTitle': '(SRT)'},
          {'Type': 'Subtitle', 'Codec': 'ass', 'DisplayTitle': 'ASS'},
          {'Type': 'Subtitle', 'Codec': 'pgs', 'DisplayTitle': 'PGS'},
          {'Type': 'Subtitle', 'Codec': 'vtt', 'DisplayTitle': 'VTT'},
          {'Type': 'Subtitle', 'Codec': 'sub', 'DisplayTitle': 'SUB'},
        ],
      })!;
      expect(p.subtitleTracks.length, 4);
      expect(p.subtitleLabel, '(SRT / ASS / PGS / VTT)');
    });
  });

  group('源码守卫', () {
    test('简介 / 媒体信息两块大卡片统一无描边半透面', () {
      final detail = src('lib/pages/detail_page.dart');
      expect(
        RegExp(r'AppSurface\.soft\(\)').allMatches(detail).length,
        2,
        reason: '剧情简介与媒体信息各一次',
      );
      final theme = src('lib/theme.dart');
      final start = theme.indexOf('class AppSurface');
      final end = theme.indexOf('/// 字号 token', start);
      final seg = theme.substring(start, end);
      expect(seg.contains('BoxShadow'), isFalse);
      expect(seg.contains('boxShadow'), isFalse);
      expect(seg.contains('border:'), isFalse);
      expect(seg.contains('gradient:'), isFalse);
    });

    test('版本数据与播放链路接线完整', () {
      final detail = src('lib/pages/detail_page.dart');
      expect(detail.contains('_versionSection('), isTrue);
      expect(detail.contains('_VersionPicker('), isTrue);
      expect(detail.contains('_playWithVersion('), isTrue);
      expect(detail.contains('mediaVersions(_item.id)'), isTrue,
          reason: '版本与额外部分必须共用一次单条详情请求');
      expect(detail.contains('_mediaInfoCard(item, version: _selectedVersion)'),
          isTrue);
      expect(detail.contains('onPlayVersion'), isTrue);
      // 头图编码 / 4K 徽章也要跟着版本走，不能切到 4K 后顶部还写 H264
      expect(detail.contains('_shownVideoCodec(item)'), isTrue);
      expect(detail.contains('_shownIsTrue4K(item)'), isTrue);
      expect(detail.contains('_shownAudioChannels(item)'), isTrue);

      final client = src('lib/emby_client.dart');
      expect(client.contains('Future<List<MediaExtraPart>> mediaVersions('),
          isTrue);
      expect(client.contains('static List<MediaExtraPart> versionsFromSources('),
          isTrue);
      expect(client.contains("'Fields': 'MediaSources,MediaStreams,RunTimeTicks,Path'"),
          isTrue);

      final main = src('lib/main.dart');
      expect(main.contains('onPlayVersion:'), isTrue);
      expect(main.contains('mediaSourceId: mediaSourceId,'), isTrue);
      expect(main.contains('sourceLabel: sourceLabel,'), isTrue);
    });

    test('模型补齐版本展示所需字段', () {
      final models = src('lib/models.dart');
      for (final k in [
        'audioChannels',
        'audioLanguage',
        'audioDefault',
        'subtitleTracks',
        'String get videoLabel',
        'String get audioLabel',
        'String get subtitleLabel',
        'String get versionSubtitle',
        'String get sizeLabel',
      ]) {
        expect(models.contains(k), isTrue, reason: '缺 $k');
      }
    });
  });
}
