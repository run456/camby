import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import '../widgets/subtitle_style_sheet.dart';

/// 播放器对外声明的 User-Agent。
///
/// strm 片源基本都指向第三方直链（alist / openlist / 网盘反代 / 各类 CDN），
/// 其中相当一部分对 UA 做白名单校验：libmpv 默认发 `Lavf/xx`，会被直接 403，
/// 表现就是「进度条不走、画面全黑、也没有任何报错」，而 ExoPlayer 用自己的 UA
/// 恰好能过 —— 这就是「MPV 一直黑屏、切 Exo 就能放」最常见的成因。
/// 伪装成 VLC 是最通用的一档（绝大多数直链白名单都放行它）。
const String kPlayerUserAgent = 'VLC/3.0.20 LibVLC/3.0.20';

/// 播放内核
enum PlaybackEngine { exo, mpv }

extension PlaybackEngineX on PlaybackEngine {
  String get label => this == PlaybackEngine.exo ? 'ExoPlayer' : 'MPV';
  String get short => this == PlaybackEngine.exo ? 'Exo' : 'MPV';
  String get desc =>
      this == PlaybackEngine.exo ? '兼容性最佳 · 通用渲染' : 'ASS 特效字幕 · 硬解更强';
}

/// 画面比例：自适配（完整显示）/ 满屏（裁切铺满）
enum PlaybackFit { fit, fill }

/// 内核统一抽象：播放页只依赖这个接口
abstract class PlaybackController {
  PlaybackEngine get engine;
  bool get ready;
  double get positionSeconds;
  double get durationSeconds;
  bool get isPlaying;
  bool get isBuffering;

  /// 首帧是否已经真正渲染出来。
  ///
  /// Exo 的 `initialize()` 天然等到可渲染才算完成，所以它等于 `ready`；
  /// MPV 的 `open()` 是**立即返回**的（libmpv 异步探测），必须靠视频参数
  /// 是否解析出来判断 —— 否则播放页会以为「已经开播了」，直接揭幕，
  /// 用户看到的是一块纯黑，App 自己却毫不知情。
  bool get firstFrameReady;

  /// 已缓冲到的位置（秒），用于底栏「缓冲至」展示
  double get bufferedSeconds;

  /// 上一次跳转是否成功（供播放信息面板诊断）
  bool get lastSeekOk;
  String get lastSeekError;

  /// 画面比例（自适配 / 满屏），set 后 buildView 即生效
  PlaybackFit get fit;
  set fit(PlaybackFit v);

  Widget buildView();
  Future<void> open(String url, {String? subtitleUrl});
  Future<void> play();
  Future<void> pause();

  /// 跳转。
  /// [preview] = true 表示拖动过程中的预览帧：
  ///  · MPV 在上一次 seek 未完成时直接丢弃，避免 lock 排队堆积
  ///  · Exo 仍走正常 seekTo，但由页面层做节流
  Future<void> seek(double seconds, {bool preview = false});

  /// 当前是否硬件解码（播放页顶栏硬解按钮的状态来源）
  bool get hardwareDecode;

  /// 运行时切换硬件解码（1.7.38 新增）：播放页顶栏「硬解」按钮直接开关，
  /// 不再需要回设置页改完重建播放器。MPV 走 hwdec 属性热切换；Exo 恒为
  /// 硬解，这里只能回报状态。
  Future<void> setHardwareDecode(bool on);

  Future<void> setSpeed(double speed);

  /// 网络缓冲速度（字节/秒），拿不到返回 null（Exo 用 bufferedSeconds 兜底）
  Future<double?> cacheSpeedBytes();

  /// 内核是否自己渲染字幕（MPV=true）。返回 false 时由播放页叠加渲染，
  /// 这样 Exo 也能挂外挂字幕，且切字幕不需要重建播放器。
  bool get nativeSubtitles;

  /// 运行时切换外挂字幕（null = 关闭）。返回 true 表示内核已接管显示。
  Future<bool> setSubtitle(String? url);

  /// 下发字幕样式（1.7.38 / v1.7.22）。
  ///
  /// 只有 MPV 内核真正接管字幕渲染，才需要把样式翻译成 libmpv 原生属性：
  /// `sub-scale` / `sub-pos` / `sub-delay` / `sub-color` / `sub-border-color` /
  /// `sub-opacity`。Exo 内核由播放页叠加层自绘，这里空实现即可 —— 两内核
  /// 观感保持一致，靠的是同一份 [SubtitleStyle] 数据源。
  Future<void> applySubtitleStyle(SubtitleStyle style);

  /// 运行时开关 ASS 特效渲染（设置页「ASS 特效字幕渲染」，v1.7.47 接通）。
  ///
  /// 关掉后 libmpv 走 `sub-ass=no`：ASS 只按纯文本 + App 样式渲染，
  /// 不再有字体特效、定位字幕、卡拉 OK 变色。好处是画面统一、不吃
  /// GPU；代价是丢失原盘特效。Exo 本来就没有 ASS 能力，恒为 false。
  Future<void> setAssRendering(bool on);

  Future<void> dispose();
}

/// ExoPlayer（Flutter video_player 插件底层）
class ExoController implements PlaybackController {
  ExoController();

  VideoPlayerController? _c;
  bool _seekOk = true;
  String _seekError = '';

  @override
  PlaybackFit fit = PlaybackFit.fit;

  @override
  PlaybackEngine get engine => PlaybackEngine.exo;

  @override
  bool get ready => _c?.value.isInitialized ?? false;

  @override
  bool get lastSeekOk => _seekOk;

  @override
  String get lastSeekError => _seekError;

  @override
  double get positionSeconds =>
      (_c?.value.position ?? Duration.zero).inMilliseconds / 1000.0;

  @override
  double get durationSeconds =>
      (_c?.value.duration ?? Duration.zero).inMilliseconds / 1000.0;

  @override
  bool get isPlaying => _c?.value.isPlaying ?? false;

  @override
  bool get isBuffering => _c?.value.isBuffering ?? false;

  @override
  bool get firstFrameReady => _c?.value.isInitialized ?? false;

  @override
  double get bufferedSeconds {
    final ranges = _c?.value.buffered;
    if (ranges == null || ranges.isEmpty) return 0;
    return ranges.last.end.inMilliseconds / 1000.0;
  }

  @override
  Widget buildView() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    final aspect = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;
    if (fit == PlaybackFit.fill) {
      // 满屏：先 SizedBox.expand 强制占满整屏，再 FittedBox cover 裁切铺满。
      // 若直接放在 Center 的松约束里，FittedBox 会缩到视频本征尺寸，
      // 结果只是把画面居中缩小，根本没有裁切铺满。
      return SizedBox.expand(
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 1024,
              height: 1024 / aspect,
              child: VideoPlayer(c),
            ),
          ),
        ),
      );
    }
    return AspectRatio(aspectRatio: aspect, child: VideoPlayer(c));
  }

  @override
  Future<void> open(String url, {String? subtitleUrl}) async {
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    _c = c;
    await c.initialize();
  }

  @override
  Future<void> play() async => _c?.play();

  @override
  Future<void> pause() async => _c?.pause();

  @override
  Future<void> seek(double seconds, {bool preview = false}) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      _seekOk = false;
      _seekError = 'Exo 未初始化';
      return;
    }
    // video_player 的 seekTo 里有 `if (position > value.duration) position = value.duration`：
    // 片源时长未知（duration == 0，常见于转码流 / HLS / strm）时，
    // 任何跳转都会被静默打回 0 秒 —— 表现就是“拖了没反应/回到片头”。
    // 这里宁可不跳，也不要把播放位置重置掉。
    if (c.value.duration <= Duration.zero) {
      _seekOk = false;
      _seekError = '片源时长未知，ExoPlayer 会把位置打回开头（可切 MPV 内核）';
      return;
    }
    try {
      await c.seekTo(Duration(milliseconds: (seconds * 1000).round()));
      _seekOk = true;
      _seekError = '';
    } catch (e) {
      _seekOk = false;
      _seekError = '$e';
    }
  }

  // Exo（video_player/ExoPlayer）始终走 MediaCodec 硬解，没有软解开关
  @override
  bool get hardwareDecode => true;

  @override
  Future<void> setHardwareDecode(bool on) async {}

  @override
  Future<void> setSpeed(double speed) async => _c?.setPlaybackSpeed(speed);

  @override
  Future<double?> cacheSpeedBytes() async => null; // Exo 无字节速率，用缓冲位置兜底

  // ExoPlayer（video_player 插件）没有运行时挂外挂字幕的接口，
  // 只能由播放页用叠加层渲染 → nativeSubtitles = false
  @override
  bool get nativeSubtitles => false;

  @override
  Future<bool> setSubtitle(String? url) async => false;

  // Exo 内核的字幕是播放页叠加层画的，样式由页面直接作用于 Text，
  // 内核侧没有可调项（这里保持空实现，避免误以为没生效）
  @override
  Future<void> applySubtitleStyle(SubtitleStyle style) async {}

  // Exo 无 ASS 能力：叠加层只画纯文本。设置页那一项对 Exo 无意义，
  // 页面会据 [nativeSubtitles] 提示用户切 MPV。
  @override
  Future<void> setAssRendering(bool on) async {}

  @override
  Future<void> dispose() async => _c?.dispose();
}

/// MPV / libmpv（media_kit）
class MpvController implements PlaybackController {
  MpvController({bool hardwareDecode = true, int cacheMb = 512})
    : _hwdec = hardwareDecode,
      _cacheMb = cacheMb {
    _player = Player();
    _vc = VideoController(_player);
  }

  /// 网络缓冲上限（MB），对应 libmpv 的 `demuxer-max-bytes`。
  /// 设置页「缓存大小」四个档位就是改这个值：越大越抗卡顿，常驻内存越多。
  final int _cacheMb;

  late final Player _player;
  late final VideoController _vc;
  bool _hwdec;
  bool _opened = false;
  bool _seekOk = true;
  String _seekError = '';
  bool _seekBusy = false;

  @override
  PlaybackFit fit = PlaybackFit.fit;

  @override
  PlaybackEngine get engine => PlaybackEngine.mpv;

  /// 注意：这里不能要求 duration > 0。
  /// 部分片源（strm、直播流、未解析完的流）duration 恒为 0，
  /// 之前会被判成“未就绪”，导致所有 seek 走演示分支、画面纹丝不动。
  @override
  bool get ready => _opened;

  @override
  bool get lastSeekOk => _seekOk;

  @override
  String get lastSeekError => _seekError;

  @override
  double get positionSeconds => _player.state.position.inMilliseconds / 1000.0;

  @override
  double get durationSeconds => _player.state.duration.inMilliseconds / 1000.0;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  bool get isBuffering => _player.state.buffering;

  @override
  bool get firstFrameReady {
    final v = _player.state.videoParams;
    return (v.w ?? 0) > 0 && (v.h ?? 0) > 0;
  }

  @override
  bool get nativeSubtitles => true;

  @override
  Future<bool> setSubtitle(String? url) async {
    if (!_opened) return false;
    try {
      if (url == null || url.isEmpty) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        await _player.setSubtitleTrack(SubtitleTrack.uri(url));
        // 有些片源 open 时 sub-visibility 被自动关掉，明确打开
        final platform = _player.platform;
        if (platform is NativePlayer) {
          try {
            await platform.setProperty('sub-visibility', 'yes');
          } catch (_) {}
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 把 [SubtitleStyle] 翻译成 libmpv 原生字幕属性（v1.7.22 修复项，
  /// v1.7.57 重写：透明度烤进颜色 alpha + 写后回读校验 + 旧属性名回退）。
  ///
  /// 设计稿要求的映射关系：
  ///   大小      → `sub-scale`        （1.0 = libmpv 默认字号）
  ///   垂直位置  → `sub-pos`          （0–100，**值越大越靠下**，与 App 的
  ///                                   bottomRatio 语义相反，需换算）
  ///   时间偏移  → `sub-delay`        （秒，正值 = 字幕延后）
  ///   颜色      → `sub-color`        （不透明度烤进 #AARRGGBB 的 alpha）
  ///   描边色    → `sub-border-color`
  ///
  /// v1.7.57 实测两个事实（此前「面板调了没反应」的根因）：
  /// 1. mpv **没有** `sub-opacity` 属性（0.36/0.37 均报 option not found），
  ///    而旧实现把不透明度下发到它上面；media_kit 的 setProperty 走
  ///    mpv_set_property_string 且**吞掉错误码、从不抛异常**，导致失败被
  ///    try/catch 静默掩盖。现在不透明度直接合成进颜色的 alpha 通道。
  /// 2. `sub-border-size` 是较新 mpv 的名字（旧版叫 `sub-outline-size`），
  ///    Android 捆绑库版本不定 → 先写新名并回读校验，读不到再写旧名。
  @override
  Future<void> applySubtitleStyle(SubtitleStyle style) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;

    /// sub-pos：App 的 pos 是「距底部比例」，libmpv 是「距顶部百分比」。
    /// bottomRatio 0.12 ≈ 贴底 → sub-pos ≈ 88。
    final subPos = ((1.0 - style.bottomRatio) * 100).clamp(0.0, 100.0);

    /// sub-scale：以 [SubtitleStyle.baseSize] 为 1.0 基准
    final subScale = (style.size / SubtitleStyle.baseSize).clamp(0.3, 3.0);

    /// 描边宽度（0 时连同边框色一起关掉）。
    final borderSize = style.stroke <= 0 ? 0.0 : style.stroke;

    /// 不透明度 → 颜色 alpha（0–255，FF = 不透明）
    final alpha = (style.opa.clamp(0.0, 1.0) * 255).round();
    final textColor = _mpvColorWithAlpha(style.color, alpha);
    final borderColor = _mpvColorWithAlpha(const Color(0xFF000000), alpha);

    Future<void> set(String name, String value) async {
      try {
        await platform.setProperty(name, value);
      } catch (_) {}
    }

    /// 写入后回读校验；读不到（属性不存在 / 旧命名）则回退旧属性名。
    /// media_kit 的 setProperty 对无效属性不报错，只能靠回读发现。
    Future<void> setWithFallback(
      String name,
      String legacyName,
      String value,
    ) async {
      await set(name, value);
      var ok = false;
      try {
        final cur = await platform.getProperty(name);
        ok = cur.isNotEmpty;
      } catch (_) {}
      if (!ok) await set(legacyName, value);
    }

    await set('sub-scale', subScale.toStringAsFixed(3));
    await set('sub-pos', subPos.toStringAsFixed(2));
    await set('sub-color', textColor);
    // 字幕恒用黑描边，任何画面上都读得清（与叠加层 Shadow 同策略）
    await setWithFallback('sub-border-color', 'sub-outline-color', borderColor);
    await setWithFallback(
      'sub-border-size',
      'sub-outline-size',
      borderSize.toStringAsFixed(2),
    );
    // 关键：ASS 字幕默认由 libass 按文件自带样式渲染，App 里的字号 /
    // 颜色 / 描边全被忽略。force 让 libass 采用上面的样式覆盖，但保留
    // ASS 的定位信息。
    await set('sub-ass-override', 'force');
  }

  /// 运行时开关 ASS 特效渲染（v1.7.47）。
  ///
  /// libmpv 的 `sub-ass`：yes → 走 libass，完整还原 ASS/SSA 特效；
  /// no → ASS 被当纯文本，按 [applySubtitleStyle] 下发的样式渲染。
  ///
  /// 注意顺序：必须在字幕已挂载之后设置才稳，部分版本在无字幕时设置
  /// 会被忽略，所以这里设完再补一次 `sub-visibility`。
  @override
  Future<void> setAssRendering(bool on) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('sub-ass', on ? 'yes' : 'no');
      if (on) {
        // 重新挂一次，让 libmpv 用新开关重解析当前轨道
        await platform.setProperty('sub-visibility', 'yes');
      }
    } catch (_) {
      // 老版本 libmpv 无此属性，忽略
    }
  }

  /// Flutter [Color] + 0–255 alpha → libmpv 颜色串 `#AARRGGBB`。
  ///
  /// mpv 没有独立的 `sub-opacity` 属性（v1.7.57 实测），不透明度只能
  /// 合成进颜色的 alpha 通道（00 = 全透明，FF = 不透明）。
  static String _mpvColorWithAlpha(Color c, int alpha) {
    final a = alpha.clamp(0, 255);
    final v = (a << 24) | (c.toARGB32() & 0xFFFFFF);
    return '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  @override
  double get bufferedSeconds => _player.state.buffer.inMilliseconds / 1000.0;

  @override
  Widget buildView() {
    if (!_opened) return const SizedBox.shrink();
    return Video(
      controller: _vc,
      fit: fit == PlaybackFit.fill ? BoxFit.cover : BoxFit.contain,
      controls: null, // 控制层由 Camby 自己绘制
      pauseUponEnteringBackgroundMode: false,
    );
  }

  @override
  Future<void> open(String url, {String? subtitleUrl}) async {
    // libmpv 默认 hwdec=no（纯软解）。设置页「硬件解码优先」打开时走
    // MediaCodec 硬解，解码失败 mpv 会自动回退软解（auto-safe 语义）。
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('hwdec', _hwdec ? 'auto-safe' : 'no');
        // 硬解 + 低延迟缓冲调优：MediaCodec 直接输出，减少一次拷贝
        if (_hwdec) {
          await platform.setProperty('vd-lavc-threads', '0');
        }
        // 设置页「缓存大小」：必须显式给 back-buffer，否则 libmpv 默认
        // forward 只有 64MiB，调大 demuxer-max-bytes 也会被后续缓冲卡住
        final mb = _cacheMb.clamp(64, 8192);
        final bytes = mb * 1024 * 1024;
        await platform.setProperty('demuxer-max-bytes', '$bytes');
        await platform.setProperty('demuxer-max-back-bytes', '$bytes');
        await platform.setProperty('cache-secs', '${(mb / 8).clamp(10, 600)}');
        // strm 直链常见问题：默认 UA 被 CDN 拒绝 → 一直黑屏无报错。
        // 两处都设（属性 + 请求头）是因为不同 libmpv 版本读的位置不一样。
        await platform.setProperty('user-agent', kPlayerUserAgent);
        // 默认 60s 太久：黑屏要等一分钟才暴露问题。30s 足够慢速源，也能
        // 让「10 秒无首帧自动回退 Exo」先一步生效。
        await platform.setProperty('network-timeout', '30');
      }
    } catch (_) {}
    await _player.open(
      Media(url, httpHeaders: const {'User-Agent': kPlayerUserAgent}),
      play: true,
    );
    _opened = true;
    if (subtitleUrl != null && subtitleUrl.isNotEmpty) {
      try {
        await _player.setSubtitleTrack(SubtitleTrack.uri(subtitleUrl));
      } catch (_) {}
    }
  }

  @override
  Future<void> play() async => _player.play();

  @override
  Future<void> pause() async => _player.pause();

  @override
  Future<void> seek(double seconds, {bool preview = false}) async {
    if (!_opened) {
      _seekOk = false;
      _seekError = 'MPV 未打开';
      return;
    }
    // media_kit 的 seek 在 lock 里串行执行（synchronized 默认 true）。
    // 拖动时若把每一帧的预览跳转都塞进去，mpv 会排队“补播”历史位置，
    // 松手后落点完全不对。所以预览跳转在上一次未完成时直接丢弃。
    if (preview && _seekBusy) return;
    _seekBusy = true;
    try {
      await _player.seek(Duration(milliseconds: (seconds * 1000).round()));
      _seekOk = true;
      _seekError = '';
    } catch (e) {
      _seekOk = false;
      _seekError = '$e';
    } finally {
      _seekBusy = false;
    }
  }

  @override
  bool get hardwareDecode => _hwdec;

  /// 运行时热切换硬解：直接改 hwdec 属性，mpv 会重建解码链路。
  /// 失败时保持原状态并静默返回（解码器和片源组合众多，不做兜底）。
  @override
  Future<void> setHardwareDecode(bool on) async {
    if (!_opened) return;
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('hwdec', on ? 'auto-safe' : 'no');
        _hwdec = on;
      }
    } catch (_) {}
  }

  @override
  Future<void> setSpeed(double speed) async => _player.setRate(speed);

  @override
  Future<double?> cacheSpeedBytes() async {
    if (!_opened) return null;
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        final v = await platform.getProperty('cache-speed');
        return double.tryParse(v);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> dispose() async => _player.dispose();
}
