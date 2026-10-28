import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

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

  Future<void> setSpeed(double speed);

  /// 网络缓冲速度（字节/秒），拿不到返回 null（Exo 用 bufferedSeconds 兜底）
  Future<double?> cacheSpeedBytes();

  /// 内核是否自己渲染字幕（MPV=true）。返回 false 时由播放页叠加渲染，
  /// 这样 Exo 也能挂外挂字幕，且切字幕不需要重建播放器。
  bool get nativeSubtitles;

  /// 运行时切换外挂字幕（null = 关闭）。返回 true 表示内核已接管显示。
  Future<bool> setSubtitle(String? url);

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
      // 满屏：按视频比例给定内在尺寸，FittedBox cover 裁切铺满
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: 1024,
            height: 1024 / aspect,
            child: VideoPlayer(c),
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

  @override
  Future<void> dispose() async => _c?.dispose();
}

/// MPV / libmpv（media_kit）
class MpvController implements PlaybackController {
  MpvController({bool hardwareDecode = true}) : _hwdec = hardwareDecode {
    _player = Player();
    _vc = VideoController(_player);
  }

  late final Player _player;
  late final VideoController _vc;
  final bool _hwdec;
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
      }
    } catch (_) {}
    await _player.open(Media(url), play: true);
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
