import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.65 影片版本选择器。
///
/// 覆盖三件事：
///  1. `MediaSources` → 含主版本的全量版本列表（排序 / isPrimary）；
///  2. 每个版本的视频 / 音频 / 字幕 / 体积展示文案（切换时联动的依据）；
///  3. 源码守卫：一次请求、播放链路带 MediaSourceId、两块大卡片的胶囊描边；
///  4. v2.0.66：版本规格覆盖到播放页（4K 不再显示 1080p）+ 信息弹窗紧凑化。
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
    test('简介 / 媒体信息两块大卡片恢复胶囊同款描边', () {
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
      expect(seg.contains('gradient:'), isFalse);
      expect(seg.contains('border:'), isTrue);
      expect(seg.contains('alpha: 0.16'), isTrue,
          reason: '描边与 ChipLabel 的 bd 一致');
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

  group('v2.0.66 播放页规格联动', () {
    const base = MediaItem(
      id: 'm',
      name: '影片',
      type: MediaType.movie,
      overview: '',
      colors: [],
      videoHeight: 1080,
      videoCodec: 'H264',
      audioCodec: 'AAC',
      audioChannels: 6,
      container: 'MKV',
      fileSizeBytes: 3221225472,
    );
    final uhd = MediaExtraPart.fromJson({
      'Id': 'src-4k',
      'Name': '4K',
      'Path': '/media/2160p.mkv',
      'Container': 'mkv',
      'Size': 20 * 1073741824,
      'MediaStreams': [
        {'Type': 'Video', 'Codec': 'hevc', 'Width': 3840, 'Height': 2160},
        {'Type': 'Audio', 'Codec': 'eac3', 'Channels': 6, 'IsDefault': true},
      ],
    })!;

    test('withMediaSource 把 4K 规格覆盖到展示用 item', () {
      final out = base.withMediaSource(uhd);
      expect(out.videoHeight, 2160, reason: '播放页顶栏不能再写 1080p');
      expect(out.videoCodec.toUpperCase(), 'HEVC');
      expect(out.audioCodec.toUpperCase(), 'EAC3');
      expect(out.audioChannels, 6);
      expect(out.container, 'MKV');
      expect(out.fileSizeBytes, 20 * 1073741824);
      expect(out.filePath, '/media/2160p.mkv');
      expect(out.resolutionKnown, isTrue);
      // Item 级字段不受影响
      expect(out.id, 'm');
      expect(out.name, '影片');
      expect(out.resumeSeconds, base.resumeSeconds);
    });

    test('服务端缺字段时逐项保留 item 原值，不出现 0p / 空编码', () {
      const empty = MediaExtraPart(id: 'y', name: 'Y');
      final out = base.withMediaSource(empty);
      expect(out.videoHeight, 1080);
      expect(out.videoCodec, 'H264');
      expect(out.audioCodec, 'AAC');
      expect(out.audioChannels, 6);
      expect(out.container, 'MKV');
      expect(out.fileSizeBytes, 3221225472);
    });

    test('源码守卫：版本规格进播放页 + 信息面板紧凑化', () {
      final models = src('lib/models.dart');
      expect(models.contains('MediaItem withMediaSource('), isTrue);
      final main = src('lib/main.dart');
      expect(main.contains('item.withMediaSource(version)'), isTrue);
      expect(main.contains('item.withMediaSource(part)'), isTrue,
          reason: '额外部分也要带对该分段的规格');
      expect(main.contains('required MediaExtraPart version'), isTrue);
      final player = src('lib/pages/player_page.dart');
      expect(player.contains('compact: true'), isTrue);
      expect(player.contains('maxWidth: 400'), isTrue);
      expect(player.contains('if (compact)'), isTrue,
          reason: '紧凑面板按内容收拢，不再被 Flexible 拉成近满屏');
      final glass = src('lib/widgets/glass_sheet.dart');
      expect(glass.contains('maxHeightFactor'), isTrue);
      expect(glass.contains('maxWidth ?? PlayerUi.of(context).panelMaxW'),
          isTrue);
    });
  });

  group('v2.0.69 版本名推断分辨率', () {
    // 复现真机 bug：服务端不回版本源的 Width/Height（某些 Emby 兼容实现只给
    // 文件名），旧逻辑 height 恒为 0，详情页与播放页把 4K 源误显示成主版本 1080p。
    test('MediaSource 缺宽高但名称含 4K → 推断 2160', () {
      final v = MediaExtraPart.fromJson({
        'Id': 'src-4k',
        'Name': '4K Remux',
        'Path': '/media/movie-uhd.mkv',
        'Container': 'mkv',
        'MediaStreams': [
          {'Type': 'Video', 'Codec': 'hevc'}, // 故意不给 Width / Height
        ],
      })!;
      expect(v.height, 2160, reason: '名称里的 4K 必须被采信');
      expect(v.resolutionLabel, '4K');
      expect(v.videoLabel, '4K HEVC');
    });

    test('名称认不出时退回文件路径里的 2160p 标记', () {
      final v = MediaExtraPart.fromJson({
        'Id': 'src-4k',
        'Name': '终极收藏版',
        'Path': '/media/Movie.2160p.WEB-DL.x265.mkv',
        'MediaStreams': [
          {'Type': 'Video', 'Codec': 'hevc'},
        ],
      })!;
      expect(v.height, 2160);
      expect(v.resolutionLabel, '4K');
    });

    test('名字与路径都认不出分辨率 → 不误判，height 保持 0', () {
      final v = MediaExtraPart.fromJson({
        'Id': 'src-x',
        'Name': '正片',
        'Path': '/media/Movie.mkv',
        'MediaStreams': [
          {'Type': 'Video', 'Codec': 'hevc'},
        ],
      })!;
      expect(v.height, 0);
      expect(v.resolutionLabel, isEmpty);
    });

    test('推断出的 4K 规格联动到播放页（顶栏不再写 1080p）', () {
      const base = MediaItem(
        id: 'm',
        name: '影片',
        type: MediaType.movie,
        overview: '',
        colors: [],
        videoHeight: 1080,
        videoCodec: 'H264',
        audioCodec: 'AAC',
        audioChannels: 6,
        container: 'MKV',
      );
      final inferred4k = MediaExtraPart.fromJson({
        'Id': 'src-4k',
        'Name': '4K',
        'Path': '/media/movie-2160p.mkv',
        'MediaStreams': [
          {'Type': 'Video', 'Codec': 'hevc'},
        ],
      })!;
      final out = base.withMediaSource(inferred4k);
      expect(out.videoHeight, 2160, reason: '播放页顶栏必须显示 4K');
      expect(out.resolutionKnown, isTrue);
    });
  });
}
