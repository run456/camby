import '../models.dart';

/// 播放决策层（v2.0.83）。
///
/// 把「这条片源该用什么内核、要不要色调映射、音频要不要转码」从播放页里
/// 抽成纯函数，方便单测，也避免决策散落在 `_tryOpen` / `_start` 各处。
///
/// 这里的产物只是**决策**；真正拼 URL、发 PlaybackInfo 请求在
/// [EmbyServer] 里做（那边才有 baseUrl / token / userId）。

/// 音频投递方式
enum AudioDelivery {
  /// 原片直连：客户端能解码，服务端不参与
  direct,

  /// 只重编码音频、视频 copy（Emby 的 Direct Stream）
  audioOnly,

  /// 视频也要重编码（兜底：DV 偏色且设备无法正确色调映射时用）
  fullTranscode,
}

/// Android AudioTrack 常见「解码出来但不出声」的音轨。
///
/// TrueHD / DTS-HD MA 经 ffmpeg 解成 7.1 PCM 后，声道掩码常不被接受；
/// DTS / 多声道 FLAC / LPCM 同理。命中后优先让服务端转成 AAC 立体声，
/// 客户端下混只作直连时的兜底。
const kProblematicAudioCodecs = <String>[
  'TRUEHD',
  'DTSHD',
  'DTSHDMA',
  'DTSX',
  'DTS',
  'MLP',
  'FLAC',
  'PCM',
  'LPCM',
];

bool isProblematicAudio(String codec, int channels) {
  final c = codec.toUpperCase().replaceAll(RegExp(r'[\s_\-]'), '');
  if (kProblematicAudioCodecs.any((e) => c.contains(e))) return true;
  return channels >= 8;
}

/// 秒 → Emby 的 100ns tick
int ticksFromSeconds(double seconds) =>
    (seconds <= 0 ? 0 : seconds * 10000000).round();

class PlaybackPlan {
  const PlaybackPlan({
    required this.range,
    required this.audioDelivery,
    required this.forceMpv,
    required this.useGpuNext,
    required this.toneMapToSdr,
    required this.stereoDownmix,
    required this.problematicAudio,
  });

  final VideoRange range;
  final AudioDelivery audioDelivery;

  /// HDR / DV 一律走 MPV：Exo 侧没有任何色调映射 / DV 参数入口。
  final bool forceMpv;

  /// DV Profile 5 的 IPTPQc2 → BT.2020 转换依赖 vo=gpu-next + libplacebo。
  final bool useGpuNext;

  /// Flutter texture 不支持 HDR 直通，统一 tone-map 到 SDR。
  final bool toneMapToSdr;

  /// 直连时给 libmpv 的 audio-channels=stereo 兜底
  final bool stereoDownmix;
  final bool problematicAudio;

  /// 上报给 /Sessions/Playing 的 PlayMethod，必须是实际播放方式
  String get playMethod => switch (audioDelivery) {
    AudioDelivery.direct => 'DirectPlay',
    AudioDelivery.audioOnly => 'DirectStream',
    AudioDelivery.fullTranscode => 'Transcode',
  };

  /// 播放信息面板里的「画面处理」说明
  String get displayNote {
    if (range.isDolbyVision) return 'Dolby Vision → SDR（gpu-next 色调映射）';
    if (range.isHdr) return '${range.label} → SDR 色调映射';
    return 'SDR 直通';
  }
}

PlaybackPlan resolvePlaybackPlan({
  required MediaItem item,
  required bool preferMpv,
  bool forceVideoTranscode = false,
}) {
  final range = item.effectiveRange;
  final problematic = isProblematicAudio(item.audioCodec, item.audioChannels);
  final delivery = forceVideoTranscode
      ? AudioDelivery.fullTranscode
      : (problematic ? AudioDelivery.audioOnly : AudioDelivery.direct);
  return PlaybackPlan(
    range: range,
    audioDelivery: delivery,
    forceMpv: preferMpv || range.isHdr,
    useGpuNext: range.needsGpuNext,
    toneMapToSdr: range.isHdr,
    stereoDownmix: problematic,
    problematicAudio: problematic,
  );
}

/// 显式转码流 URL 的查询参数（PlaybackInfo 协商失败时的回退）。
///
/// 刻意**不写** `VideoCodec`：视频是否 copy 由服务端的 DeviceProfile 决定；
/// 硬塞一个服务端不认的值反而会强制视频重编码，把 4K HDR 压成 H264。
/// `StartTimeTicks` 必须带 —— 转码流不支持客户端 seek，不带就会回到片头。
Map<String, String> audioTranscodeParams({
  required String playSessionId,
  required int startTimeTicks,
  String? mediaSourceId,
  int? audioStreamIndex,
  String audioCodec = 'aac',
  int audioBitrate = 192000,
  int maxAudioChannels = 2,
  bool videoTranscode = false,
  String videoCodec = 'h264',
  int maxStreamingBitrate = 120000000,
}) => {
  if (mediaSourceId != null && mediaSourceId.isNotEmpty)
    'MediaSourceId': mediaSourceId,
  'PlaySessionId': playSessionId,
  if (audioStreamIndex != null) 'AudioStreamIndex': '$audioStreamIndex',
  'AudioCodec': audioCodec,
  'AudioBitrate': '$audioBitrate',
  'MaxAudioChannels': '$maxAudioChannels',
  'MaxStreamingBitrate': '$maxStreamingBitrate',
  if (videoTranscode) 'VideoCodec': videoCodec,
  'StartTimeTicks': '$startTimeTicks',
};

/// 直接播放 URL 的查询参数：补齐 Emby 文档列为必需的 MediaSourceId /
/// PlaySessionId（旧实现只有 api_key，某些服务端版本会 400 或选错源）。
Map<String, String> directPlayParams({
  required String playSessionId,
  String? mediaSourceId,
  int? audioStreamIndex,
}) => {
  'Static': 'true',
  if (mediaSourceId != null && mediaSourceId.isNotEmpty)
    'MediaSourceId': mediaSourceId,
  'PlaySessionId': playSessionId,
  if (audioStreamIndex != null) 'AudioStreamIndex': '$audioStreamIndex',
};

/// 交给 `POST /Items/{Id}/PlaybackInfo` 的设备能力声明。
///
/// 关键设计：DirectPlayProfiles 的 AudioCodec **刻意不列** TrueHD /
/// DTS-HD / 多声道 PCM。服务端比对后发现音轨不在能力表里，就会返回
/// 「视频 copy + 音频转 AAC」的 DirectStream URL —— 这正是我们要的：
/// 出声、不重编码视频、不破坏 HDR/DV 元数据。
Map<String, dynamic> cambyDeviceProfile() => {
  'Name': 'Camby Android',
  'Id': 'camby-android-83',
  'MaxStreamingBitrate': 120000000,
  'MaxStaticBitrate': 120000000,
  'MusicStreamingTranscodingBitrate': 192000,
  'DirectPlayProfiles': [
    {
      'Container': 'mkv,mov,mp4,ts,webm,avi',
      'Type': 'Video',
      'VideoCodec': 'h264,hevc,h265,av1,vp9,mpeg4,mpeg2video,vc1',
      'AudioCodec': 'aac,ac3,eac3,mp3,opus,vorbis',
    },
  ],
  'TranscodingProfiles': [
    {
      'Container': 'ts',
      'Type': 'Video',
      'VideoCodec': 'h264',
      'AudioCodec': 'aac,ac3,eac3,mp3',
      'Protocol': 'hls',
      'Context': 'Streaming',
      'MaxAudioChannels': '2',
      'BreakOnNonKeyFrames': true,
    },
    {
      'Container': 'mp4',
      'Type': 'Video',
      'VideoCodec': 'h264',
      'AudioCodec': 'aac',
      'Protocol': 'http',
      'Context': 'Streaming',
      'MaxAudioChannels': '2',
    },
    {
      'Container': 'mp3',
      'Type': 'Audio',
      'AudioCodec': 'mp3',
      'Protocol': 'http',
      'Context': 'Streaming',
    },
  ],
  'CodecProfiles': [
    {
      'Type': 'Audio',
      'Codec': 'aac',
      'Conditions': [
        {
          'Condition': 'LessThanEqual',
          'Property': 'AudioChannels',
          'Value': '2',
          'IsRequired': false,
        },
      ],
    },
  ],
  // 字幕一律外挂：App 自己渲染（MPV 原生 / Exo 叠加层），
  // 不烧进画面，避免服务端为字幕触发视频转码。
  'SubtitleProfiles': [
    {'Format': 'srt', 'Method': 'External'},
    {'Format': 'sub', 'Method': 'External'},
    {'Format': 'subrip', 'Method': 'External'},
    {'Format': 'ass', 'Method': 'External'},
    {'Format': 'ssa', 'Method': 'External'},
    {'Format': 'vtt', 'Method': 'External'},
  ],
};

Map<String, dynamic> playbackInfoBody({
  required String userId,
  required int startTimeTicks,
  String? mediaSourceId,
  int? audioStreamIndex,
  int maxStreamingBitrate = 120000000,
}) => {
  'UserId': userId,
  'StartTimeTicks': startTimeTicks,
  'IsPlayback': true,
  'AutoOpenLiveStream': true,
  'EnableDirectPlay': true,
  'EnableDirectStream': true,
  'EnableTranscoding': true,
  'AllowVideoStreamCopy': true,
  'AllowAudioStreamCopy': true,
  'MaxStreamingBitrate': maxStreamingBitrate,
  if (mediaSourceId != null && mediaSourceId.isNotEmpty)
    'MediaSourceId': mediaSourceId,
  if (audioStreamIndex != null) 'AudioStreamIndex': audioStreamIndex,
  'DeviceProfile': cambyDeviceProfile(),
};

/// [EmbyServer.resolvePlayback] 的产物：主地址 + 直连兜底 + 上报方式。
class PlaybackRoute {
  const PlaybackRoute({
    required this.url,
    required this.fallbackUrl,
    required this.playMethod,
    required this.playSessionId,
    required this.negotiated,
    this.diagnostic = '',
  });

  final String url;
  final String fallbackUrl;
  final String playMethod;
  final String playSessionId;

  /// 是否走通了 PlaybackInfo 协商（false = 显式参数或直连）
  final bool negotiated;
  final String diagnostic;
}
