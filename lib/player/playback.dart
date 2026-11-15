import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../widgets/subtitle_style_sheet.dart';
import 'playback_plan.dart';

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

  /// 内核自己吐出来的最近一条错误（v2.0.90）。
  ///
  /// ExoPlayer 的 `errorDescription` 里通常带 `Response code: 403` 这类
  /// 真实 HTTP 状态；libmpv 走 `stream.error` 事件。播放页把它显示给用户，
  /// 否则绿联这类「401/403 取流被拒」的情况只会表现为「一直黑屏 / 回落到
  /// 模拟播放」，用户和开发者都无从判断。
  String get lastError;

  /// 最近一次起播时实际发出的请求头（诊断用，值为脱敏后的占位）。
  Map<String, String> get lastRequestHeaders;

  /// 画面比例（自适配 / 满屏），set 后 buildView 即生效
  PlaybackFit get fit;
  set fit(PlaybackFit v);

  Widget buildView();
  Future<void> open(
    String url, {
    String? subtitleUrl,
    String? audioCodec,
    PlaybackPlan? plan,
    Map<String, String>? headers,
  });
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
  String _lastError = '';
  Map<String, String> _lastHeaders = const <String, String>{};

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
  String get lastError {
    final e = _c?.value.errorDescription;
    if (e != null && e.isNotEmpty) return e;
    return _lastError;
  }

  @override
  Map<String, String> get lastRequestHeaders => _lastHeaders;

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
  Future<void> open(
    String url, {
    String? subtitleUrl,
    String? audioCodec,
    PlaybackPlan? plan,
    Map<String, String>? headers,
  }) async {
    // Exo/video_player 没有暴露色调映射或色彩空间参数，plan 对它无意义。
    // HDR/DV 片源由播放决策层强制切到 MPV（见 resolvePlaybackPlan）。
    //
    // v2.0.90：httpHeaders 必须带上。`video_player` 的 Android 侧会把它
    // 设成 ExoPlayer `DefaultHttpDataSource` 的 defaultRequestProperties；
    // 之前这里是空手起播，绿联那边只认 `X-Emby-Token` 请求头（query 里的
    // api_key 只是兜底），于是登录、拉库、海报全通，唯独取流 403 ——
    // 这正是「图片出来了但视频放不了」的根因。
    final h = Map<String, String>.from(headers ?? const <String, String>{});
    _lastHeaders = h;
    _lastError = '';
    final c = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: h,
    );
    _c = c;
    try {
      await c.initialize();
    } catch (e) {
      _lastError = '$e';
      rethrow;
    }
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
  MpvController({
    bool hardwareDecode = true,
    int cacheMb = 512,
    bool useGpuNext = false,
    bool ignoreSsl = false,
  }) : _hwdec = hardwareDecode,
       _cacheMb = cacheMb,
       _useGpuNext = useGpuNext,
       _ignoreSsl = ignoreSsl {
    _player = Player();
    // v2.0.90：libmpv 走自带的 ffmpeg 网络栈，Kotlin 侧给 HttpsURLConnection
    // 换 trust-all SSLSocketFactory 对它**完全无效**（v2.0.87 只覆盖了 Exo）。
    // 自签证书（绿联 9443）下 MPV 会直接 TLS 握手失败，表现为「切 MPV 也黑屏」。
    _errSub = _player.stream.error.listen((e) {
      if (e.isNotEmpty) _lastError = e;
    });
    // DV Profile 5 的 IPTPQc2 → BT.2020 转换只有 vo=gpu-next + libplacebo
    // 会读 RPU 做重塑；普通 vo=gpu 会把它当 YCbCr 解，画面发绿发紫。
    // 只对 DV 片源开，避免改变所有片源的渲染路径。
    _vc = useGpuNext
        ? VideoController(
            _player,
            configuration: const VideoControllerConfiguration(vo: 'gpu-next'),
          )
        : VideoController(_player);
  }

  final bool _useGpuNext;

  bool get gpuNextEnabled => _useGpuNext;

  /// 是否该对 libmpv 关掉 TLS 校验（绿联自签证书 / 用户勾了「忽略 SSL」）。
  final bool _ignoreSsl;

  /// libmpv 的错误事件订阅（`stream.error`），dispose 时必须取消。
  StreamSubscription<String>? _errSub;
  String _lastError = '';
  Map<String, String> _lastHeaders = const <String, String>{};

  /// 最近一次 HDR 处理说明，播放信息面板展示（尽力而为）。
  static String lastHdrDiagnostic = '';

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
  String get lastError => _lastError;

  @override
  Map<String, String> get lastRequestHeaders => _lastHeaders;

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
  ///   字重      → `sub-bold` = yes/no（随用户加粗开关，与 Flutter 叠加层同步）
  ///   字体      → `sub-font`         （仿宋走内置 FangSong，否则用默认；
  ///                                   内置字体需 pubspec 注册并向 mpv 暴露）
  ///   颜色      → `sub-color`        （v2.0.17 起固定白字 + 黑描边）
  ///   描边色    → `sub-border-color`
  ///
  /// v2.0.17 起字幕样式固定为「影院风格」（白字加粗 + 黑描边），仅在 App 内
  /// 开放大小 / 位置两项；颜色与描边不再下发用户可调值。
  ///
  /// `sub-border-size` 是较新 mpv 的名字（旧版叫 `sub-outline-size`），
  /// Android 捆绑库版本不定 → 先写新名并回读校验，读不到再写旧名。
  @override
  Future<void> applySubtitleStyle(SubtitleStyle style) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;

    /// sub-pos：App 的 pos 是「距底部比例」，libmpv 是「距顶部百分比」。
    /// bottomRatio 0.12 ≈ 贴底 → sub-pos ≈ 88。
    final subPos = ((1.0 - style.bottomRatio) * 100).clamp(0.0, 100.0);

    /// sub-scale：以 [SubtitleStyle.baseSize] 为 1.0 基准
    final subScale = (style.size / SubtitleStyle.baseSize).clamp(0.3, 3.0);

    /// 描边宽度：影院风格固定黑描边 3.0
    const borderSize = 3.0;

    /// 文字/描边颜色固定（v2.0.17 起样式固定为白字+黑描边，不再读用户调色）
    const textColor = '#FFFFFFFF';
    const borderColor = '#FF000000';

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
    // 影院风格固定：白字 + 黑描边；加粗随用户开关（与 Flutter 叠加层同步）
    await set('sub-bold', style.bold ? 'yes' : 'no');
    // 字体：仿宋走内置字体文件（pubspec 注册 family 名 FangSong），否则用默认
    if (style.font == SubtitleFont.fangsong) {
      await set('sub-font', 'FangSong');
      // mpv 按内部 family 名匹配字体，需把内置 ttf 暴露给它的字体目录
      final dir = await _ensureFangSongFont();
      if (dir != null) await set('sub-fonts-dir', dir);
    } else {
      await set('sub-font', '');
    }
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
  /// 把内置的 `FangSong.ttf` 抽到应用私有目录，返回该目录路径（供 mpv
  /// `sub-fonts-dir` 使用）。仅抽一次（[__fontReady] 守卫），后续直接复用。
  ///
  /// mpv 在 Android 上不读 fontconfig，而是扫描 `sub-fonts-dir` 里的 ttf/otf
  /// 按内部 family 名匹配；Flutter 已把字体打进 asset，这里取出交给 mpv。
  static bool __fontReady = false;
  static Future<String?> _ensureFangSongFont() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/subfonts');
      await dir.create(recursive: true);
      final file = File('${dir.path}/FangSong.ttf');
      if (__fontReady && await file.exists()) return dir.path;
      // 用 asset 字节数当版本指纹：v2.0.46 起内置字体换成简繁并集子集，
      // 体积从 2.6MB 变成 4.4MB。老用户覆盖安装后，应用私有目录里还是旧
      // 字体文件，只判断 exists() 会一直沿用旧的繁体缺字版本。
      final bytes = await rootBundle.load('assets/fonts/FangSong.ttf');
      if (await file.exists() && await file.length() == bytes.lengthInBytes) {
        __fontReady = true;
        return dir.path;
      }
      await file.writeAsBytes(bytes.buffer.asUint8List());
      __fontReady = true;
      return dir.path;
    } catch (_) {
      return null;
    }
  }

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

  /// v2.0.83：把 HDR / DV 正确 tone-map 到 SDR。
  ///
  /// Flutter texture 不具备 HDR 直通能力（media-kit 官方结论），所以目标
  /// 色彩空间必须显式钉死为 bt.709 / bt.1886，让 mpv 自己完成转换；否则
  /// 它会按 BT.2020 输出，DV Profile 5 的 IPTPQc2 一旦没被 RPU 重塑就是
  /// 整屏发绿发紫。所有属性都「写后回读 / 失败静默」——老版 libmpv 不认
  /// 时不影响起播，只是退化成默认处理。
  Future<void> _applyHdrToneMapping(NativePlayer platform) async {
    Future<void> set(String name, String value) async {
      try {
        await platform.setProperty(name, value);
      } catch (_) {}
    }

    await set('target-prim', 'bt.709');
    await set('target-trc', 'bt.1886');
    // spline 依赖 libplacebo（gpu-next）；老 vo=gpu 不认时回退 hable。
    await set('tone-mapping', 'spline');
    try {
      final cur = await platform.getProperty('tone-mapping');
      if (cur.isEmpty || !cur.toLowerCase().contains('spline')) {
        await set('tone-mapping', 'hable');
      }
    } catch (_) {
      await set('tone-mapping', 'hable');
    }
    await set('tone-mapping-mode', 'auto');
    await set('hdr-compute-peak', 'yes');
    await set('hdr10-opt', 'yes');
    await set('gamut-mapping-mode', 'relative');
  }

  @override
  Future<void> open(
    String url, {
    String? subtitleUrl,
    String? audioCodec,
    PlaybackPlan? plan,
    Map<String, String>? headers,
  }) async {
    _lastError = '';
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
        // v2.0.90：自签证书。libmpv 的 TLS 由 ffmpeg 自己做，不走 Android
        // 的 HttpsURLConnection，原生 trust-all 对它无效。仅在服务器配置
        // 勾了「忽略 SSL」时关闭校验；普通 HTTP/受信证书服务器不碰这一项。
        if (_ignoreSsl) {
          try {
            await platform.setProperty('tls-verify', 'no');
          } catch (_) {}
        }
        // 默认 60s 太久：黑屏要等一分钟才暴露问题。30s 足够慢速源，也能
        // 让「10 秒无首帧自动回退 Exo」先一步生效。
        await platform.setProperty('network-timeout', '30');
        // v2.0.25：杜比视界 Profile 5 用 IPT 色彩空间，需播放器做 IPT→BT.2020
        // 转换，否则画面整体发绿。让 libmpv 处理 DV 的 RPU 元数据；当地
        // 播放器不支持 DV 时自动转为 SDR/标准色域。无 DV 的片源此属性为
        // no-op，不影响普通 HDR/SDR 画面。
        await platform.setProperty('dovi', 'yes');
        // v2.0.83：HDR / DV 显式色调映射到 SDR。SDR 片一个参数都不碰，
        // 避免为了修偏色把普通片子的观感也改了。
        if (plan?.toneMapToSdr ?? false) {
          await _applyHdrToneMapping(platform);
          try {
            final vo = await platform.getProperty('current-vo');
            lastHdrDiagnostic = vo.isEmpty
                ? 'MPV 色调映射 → SDR'
                : 'MPV $vo · 色调映射 → SDR';
          } catch (_) {
            lastHdrDiagnostic = 'MPV 色调映射 → SDR';
          }
        } else {
          lastHdrDiagnostic = 'SDR 直通';
        }
        // v2.0.25：TrueHD / DTS-HD MA 等无损多声道经 ffmpeg 解码后是 7.1 PCM，
        // Android 的 AudioTrack 常因声道掩码不支持而直接不出声（表现即「无声」）。
        // v2.0.83：判据换成决策层的完整编码集合（补了 DTS / DTS:X / 多声道
        // FLAC / LPCM / ≥8 声道），旧判断只留作 plan 缺席时的兜底。
        final needStereo =
            plan?.stereoDownmix ??
            (audioCodec != null &&
                (audioCodec.contains('TrueHD') ||
                    audioCodec.contains('DTS-HD') ||
                    audioCodec.contains('DTS-HDMA')));
        if (needStereo) {
          await platform.setProperty('audio-channels', 'stereo');
        }
      }
    } catch (_) {}
    // v2.0.90：把 Emby 鉴权头一起交给 libmpv。
    // media_kit 会把 httpHeaders 转成 `http-header-fields` 的 mpv_node 数组，
    // 任意 header 名都能透传（已核对 media_kit 1.2.6 源码）。绿联兼容层
    // 只认 `X-Emby-Token` 请求头，缺了它就是 403。
    final h = <String, String>{
      'User-Agent': kPlayerUserAgent,
      ...?headers,
    };
    _lastHeaders = h;
    await _player.open(Media(url, httpHeaders: h), play: true);
    _opened = true;
    // v2.0.91：libmpv 收到 404 时 stream.error 常常是空的，只在日志里留一句。
    // 起播后回读 `path` 属性，`#` 后面那截是 ffmpeg 的错误描述
    // （例如 `EDemuxerNo` / `HTTP error 404 Not Found`），补进诊断。
    unawaited(_captureMpvError());
    if (subtitleUrl != null && subtitleUrl.isNotEmpty) {
      try {
        await _player.setSubtitleTrack(SubtitleTrack.uri(subtitleUrl));
      } catch (_) {}
    }
  }

  @override
  Future<void> play() async => _player.play();

  /// 回读 `path` 属性里的失败原因（v2.0.91）。
  ///
  /// libmpv 的 `path` 在打开失败后形如
  /// `https://… # HTTP error 404 Not Found`，`#` 之后就是 ffmpeg 的
  /// 结论。成功时它不含 `#`，这里不覆盖任何东西。
  Future<void> _captureMpvError() async {
    // 给 libmpv 一点时间把失败写进属性；成功场景下这段等待不产生副作用
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    for (final prop in <String>['path', 'media-title']) {
      try {
        final v = await platform.getProperty(prop);
        final i = v.indexOf('#');
        if (i > 0 && i < v.length - 1) {
          final tail = v.substring(i + 1).trim();
          if (tail.isNotEmpty) {
            _lastError = tail;
            return;
          }
        }
      } catch (_) {}
    }
  }

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
  Future<void> dispose() async {
    await _errSub?.cancel();
    _errSub = null;
    await _player.dispose();
  }
}
