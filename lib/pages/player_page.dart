import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:volume_controller/volume_controller.dart';

import '../app_state.dart';
import '../models.dart';
import '../player/boot_watch.dart';
import '../player/playback.dart';
import '../player/subtitle_pick.dart';
import '../subtitles/subtitles.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/glass_toast.dart';
import '../widgets/liquid_press.dart';
import '../widgets/subtitle_style_sheet.dart';

/// 全屏播放页：Infuse 式布局 + 全局液态玻璃
///  · 单击空白：显隐控制层
///  · 双击左/右半屏：快退/快进 10 秒
///  · 左右滑动：快进/快退；拖动底部进度条：精确定位
///  · 左侧上下滑动：亮度；右侧上下滑动：音量（不弹系统音量条）
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.item,
    required this.state,
    this.subtitle,

    /// 起播位置（秒）：「继续播放」传入上次位置，「重新播放」传 0
    this.startSeconds = 0,
  });
  final MediaItem item;
  final AppState state;
  final SubtitleTrackInfo? subtitle;
  final double startSeconds;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with TickerProviderStateMixin {
  PlaybackController? _player;
  /// 起播内核。设置页「默认播放内核」0=Exo / 1=MPV —— 之前在 initState 里
  /// 硬写 exo，导致设置项形同虚设（v1.7.29 bug1 的同类问题，本次一并根治）
  PlaybackEngine _engine = PlaybackEngine.exo;
  bool _initializing = true;
  bool _fallback = false;
  bool _controlsVisible = true;
  bool _locked = false;

  // ---------------- 起播看护（v1.7.44：A 加载态 + B 自动回退 + D 智能内核）--------
  /// 首帧是否真的渲染出来了。MPV 的 `open()` 立即返回，不能拿它当「已开播」——
  /// 之前就是这么误判的，于是黑幕一揭、画面全黑而 App 毫不知情。
  bool _firstFrame = false;
  /// 起播已等待秒数（用 Notifier 是为了不每 500ms 重建整页）
  final ValueNotifier<double> _bootVN = ValueNotifier<double>(0);
  DateTime? _bootAt;
  Timer? _bootTimer;
  /// MPV 无首帧已经自动回退过 Exo（每轮起播只回退一次）
  bool _autoFellBack = false;
  /// 设置页「STRM 优先 Exo」（D 方案），默认开
  bool _strmPreferExo = true;

  /// 设置页「ASS 特效字幕渲染」，默认开（v1.7.47 接通，仅 MPV 生效）
  bool _assSubtitle = true;

  Timer? _hideTimer;
  Timer? _ticker;
  DateTime? _lastTapAt;
  Offset? _lastTapPos;
  DateTime? _lastDoubleTapAt;
  Timer? _revealTimer;
  Offset? _tapPos;

  // 拖动状态（进度条与屏幕手势共用一套状态机）
  bool _scrubbing = false;
  double _scrubPos = 0;
  double _scrubStartPos = 0;
  double _scrubStartX = 0;

  // 跳转提交：松手后等播放器真正跳过去，避免 UI 先弹回旧位置
  bool _seeking = false;
  int _seekSeq = 0;
  DateTime? _lastPreviewAt;
  double _lastPreviewTarget = -1;
  String _seekDiag = '未跳转';

  // 进出场黑幕：进出场时盖住整页，把横竖屏切换的系统旋转动画藏在黑幕后面
  bool _veiled = true;
  bool _revealed = false;
  bool _exiting = false;

  // 进度条按压（仅影响视觉粗细）
  bool _barPressed = false;

  // 亮度/音量
  String? _adjustSide; // 'brightness' | 'volume'
  double _adjustBase = 0;
  double _adjustValue = 0;
  double _adjustStartDy = 0;

  double _playbackSpeed = 1.0;
  PlaybackFit _fit = PlaybackFit.fit;

  // ---- 高频刷新解耦（v1.7.38）----
  // 以前 _ticker 每 300ms 就 setState 一次，整页（含一堆 Glass 毛玻璃控件）
  // 跟着重建，拖进度、切倍速时肉眼可见掉帧。现在三个高频量各自走
  // ValueNotifier，只有订阅它们的那一小块子树重建。
  final ValueNotifier<double> _posNv = ValueNotifier<double>(0);
  final ValueNotifier<String> _bufNv = ValueNotifier<String>('');
  final ValueNotifier<String> _cueNv = ValueNotifier<String>('');
  // 字幕样式变更信号：拖动滑杆时只递增它，让叠加层重画，
  // 不再 setState 整页（v1.7.28 的卡顿根因）
  final ValueNotifier<int> _styleRev = ValueNotifier<int>(0);

  String get _bufText => _bufNv.value;
  set _bufText(String v) {
    if (_bufNv.value != v) _bufNv.value = v;
  }

  Timer? _bufTimer;
  // Exo 没有字节速率接口：用「缓冲时长增速 × 平均码率」估算下载速度
  double _lastBufSec = 0;
  int _lastBufMs = 0;
  double _emaBps = 0;
  int _emaAtMs = 0;

  // ---- 1.7.38 新增：字幕样式 / 码率 / 硬解 / 播放上报 ----
  /// 叠加字幕的显示样式（持久化，见 SubtitleStyleStore）
  SubtitleStyle _subStyle = const SubtitleStyle();

  /// 设置页「记录观看历史」开关：关掉后既不上报，也不进「继续观看」
  bool _recordHistory = true;

  /// 最大码率（bps）。null = 原片直连；有值时服务端按该码率转码。
  int? _maxBitrate;

  /// 设置页最大码率档位的映射（0=自动，其余为上限 bps）
  static const List<int?> _bitrates = [null, 40000000, 20000000, 10000000];

  /// 设置页缓存档位 → MPV `demuxer-max-bytes`（字节）。档位越高越抗卡顿，内存占用越大。
  static const List<int> _cacheSizes = [512, 1024, 2048, 4096];

  /// MPV 网络缓冲上限（MB），在 `_start` 里传给内核
  int _cacheBytes = 512;

  /// 设置页「自动连播下一集」：播完跳到本剧第下一集（没有则不动）
  bool _autoNext = true;

  /// 本集已经触发过自动续播，防止 ticker 反复跳
  bool _autoNextFired = false;

  /// 当前是否硬件解码（由播放页直接热切换，不再回设置页）
  bool _hw = true;

  /// 进度上报节流
  Timer? _reportTimer;
  DateTime? _lastReportAt;

  bool _demoPlaying = true;
  double _demoPosition = 0;

  // 字幕 / 分集 / 画面信息
  SubtitleTrackInfo? _subtitle;
  List<SubtitleCue> _cues = const [];

  /// 用户在本页字幕菜单里手动选过轨（关掉字幕也算）。
  /// 一旦为 true，自动选轨就不再插手 —— 用户意图高于设置项。
  bool _userPickedSub = false;

  /// 当前应显示的字幕文本（v1.7.38 改由 ValueNotifier 驱动，见 [_cueNv]）
  String get _cueText => _cueNv.value;
  set _cueText(String v) {
    if (_cueNv.value != v) _cueNv.value = v;
  }

  List<MediaItem> _episodes = const [];
  int _episodeIndex = -1;

  @override
  void initState() {
    super.initState();
    _subtitle = widget.subtitle;
    // 屏蔽系统自带音量条，只保留 App 内的玻璃音量指示
    VolumeController.instance.showSystemUI = false;
    // 横屏切换延后到路由淡入完成之后：此时页面已被黑幕盖住，
    // 系统的旋转动画只会转一块纯黑，不会再出现详情页歪斜旋转
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 280), () {
        if (!mounted) return;
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      });
    });
    // 兜底：即使视频迟迟打不开（演示/失败），黑幕也要按时揭开
    _revealTimer = Timer(const Duration(milliseconds: 900), _reveal);
    unawaited(_loadSubStyle());
    _loadRecordHistory();
    _applySavedPreferences();
    // 字幕自动选轨必须在 _open() 之前定下来：_start() 会拿 _subtitle 去挂载。
    // 外部显式传了 subtitle（详情页点某条字幕进入）就不覆盖用户意图。
    if (widget.subtitle == null) unawaited(_autoPickSubtitle());
    _open();
    _loadEpisodes();
    _resetHideTimer();
    _ticker = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      // 演示模式没有真实内核，进度靠这里推进（原来写在 build 里）
      if (_demo && _demoPlaying && !_scrubbing && !_seeking) {
        _demoPosition = math.min(_demoPosition + 0.3, _totalSeconds);
        if (_demoPosition >= _totalSeconds) _demoPosition = 0;
      }
      _tickCue();
      _syncPos();
      _checkAutoNext();
    });
    _bufTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollBuffer(),
    );
  }

  /// 揭开进出场黑幕（只执行一次）
  void _reveal() {
    if (_revealed || !mounted) return;
    _revealed = true;
    _revealTimer?.cancel();
    _bootTimer?.cancel();
    _revealTimer = null;
    setState(() => _veiled = false);
  }

  /// 退出播放页：先盖黑幕 → 切回竖屏（旋转被黑幕遮住）→ 再淡出回详情页
  Future<void> _exitPlayer() async {
    if (_exiting) return;
    _exiting = true;
    _hideTimer?.cancel();
    setState(() => _veiled = true);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    // 等系统旋转动画走完（约 300ms），黑幕下完成
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// 缓冲状态：MPV 读 cache-speed（字节/秒）；Exo 用「缓冲时长增速 × 平均码率」
  /// 估算下载速度（video_player 只暴露已缓冲时长，不暴露字节数）。
  /// 字段赋值即可，300ms ticker 会带上渲染。
  Future<void> _pollBuffer() async {
    final p = _player;
    if (p == null || !p.ready || !_isPlaying || _demo) {
      if (_bufText.isNotEmpty) _bufText = '';
      return;
    }
    final buf = p.bufferedSeconds;
    final now = DateTime.now().millisecondsSinceEpoch;
    double? bps;

    if (p.engine == PlaybackEngine.mpv) {
      bps = await p.cacheSpeedBytes();
      if (!mounted) return;
      if (bps != null && bps > 0) {
        _bufText = '缓冲 ${(bps / 1048576).toStringAsFixed(1)} MB/s';
        return;
      }
    } else {
      // Exo：已缓冲时长增加多少秒 → 乘以平均码率 → 换算成字节/秒
      final dur = p.durationSeconds;
      final fileSize = widget.item.fileSizeBytes;
      if (_lastBufMs > 0 && dur > 0 && fileSize > 0) {
        final dt = (now - _lastBufMs) / 1000.0;
        final dbuf = buf - _lastBufSec;
        if (dt > 0.2 && dbuf > 0.05) {
          final inst = (dbuf / dt) * (fileSize / dur);
          // 平滑：Exo 的缓冲是一次一大段跳变的，直接显示会剧烈跳动
          _emaBps = _emaBps <= 0 ? inst : (_emaBps * 0.55 + inst * 0.45);
          _emaAtMs = now;
        }
      }
      _lastBufSec = buf;
      _lastBufMs = now;
      // 只保留最近 6 秒内测到的速度，避免缓冲满后一直显示旧值
      if (_emaBps > 0 && now - _emaAtMs < 6000) bps = _emaBps;
    }

    if (bps != null && bps > 0) {
      _bufText = '缓冲 ${(bps / 1048576).toStringAsFixed(1)} MB/s';
      return;
    }
    _bufText = buf > p.positionSeconds + 1 ? '缓冲至 ${_fmt(buf)}' : '';
  }

  Future<void> _open() async {
    setState(() => _initializing = true);
    await _tryOpen();
    // 画面已挂上（黑幕下完成旋转），稍作停顿揭开，形成"黑 → 画面"的入画感
    if (mounted) {
      await Future.delayed(const Duration(milliseconds: 160));
      _reveal();
    }
    await _seekToStart();
    if (mounted) setState(() => _initializing = false);
    // 进入播放即向服务端上报一次 start：Emby 的会话列表出现本设备，
    // 首页「继续观看」位置随后由 _reportProgressNow() 持续同步
    unawaited(_reportProgressNow());
    _startReportTimer();
    _startBootWatch();
  }

  // ---------------- 起播看护 ----------------

  /// 每 500ms 检查一次首帧：
  /// · 没出来 → 更新「已等待 N 秒」，8 秒后露出「切换 Exo」按钮，25 秒提示插件；
  /// · 出来了 → 收起胶囊；
  /// · MPV 超过 10 秒还没出来 → 自动换 Exo 重开（B 方案），用户全程无感。
  void _startBootWatch() {
    _bootTimer?.cancel();
    _bootTimer = null;
    _bootAt = DateTime.now();
    _bootVN.value = 0;
    _firstFrame = _player?.firstFrameReady ?? false;
    if (_demo || _fallback) return;
    _bootTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final p = _player;
      if (p == null) return;
      if (p.firstFrameReady) {
        t.cancel();
        _bootTimer = null;
        if (!_firstFrame) setState(() => _firstFrame = true);
        return;
      }
      final secs =
          DateTime.now().difference(_bootAt!).inMilliseconds / 1000.0;
      _bootVN.value = secs;
      if (BootWatchPolicy.shouldFallback(
        engine: p.engine,
        alreadyFellBack: _autoFellBack,
        waitedSecs: secs,
      )) {
        _autoFellBack = true;
        t.cancel();
        _bootTimer = null;
        unawaited(_autoFallbackToExo());
      }
    });
  }

  /// MPV 10 秒无首帧 → 自动切 Exo 重开（保留进度）
  Future<void> _autoFallbackToExo() async {
    if (!mounted || _engine == PlaybackEngine.exo) return;
    showToast(
      context,
      'MPV 10 秒未出画面，已自动切到 Exo',
      icon: Icons.swap_horiz_rounded,
    );
    await _switchEngine(silent: true);
  }

  // ---------------- 字幕样式 / 码率 / 硬解 / 上报 ----------------

  /// 读取持久化的字幕样式（首次进入为默认值）
  /// 读取设置页里对播放器有实际作用的项：内核、码率上限、MPV 缓存档位。
  /// 全部在 `_open()` 之前完成，避免开了没效果。
  Future<void> _applySavedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final eng = prefs.getInt('set_play_engine') ?? 0;
      final br = prefs.getInt('set_max_bitrate') ?? 0;
      final cache = prefs.getInt('set_cache_size') ?? 0;
      _engine = eng == 1 ? PlaybackEngine.mpv : PlaybackEngine.exo;
      // D 方案：strm 条目默认走 Exo。它对「无 Content-Length / 无 moov」的
      // 伪流式直链兼容性更好，经常是 Exo 能出画面、MPV 一直黑屏。
      if (_strmPreferExo && widget.item.isStrm) {
        _engine = PlaybackEngine.exo;
      }
      _maxBitrate = _bitrates[br.clamp(0, _bitrates.length - 1)];
      _cacheBytes = _cacheSizes[cache.clamp(0, _cacheSizes.length - 1)];
      _autoNext = prefs.getBool('set_auto_next') ?? true;
      _strmPreferExo = prefs.getBool('set_strm_exo') ?? true;
      _assSubtitle = prefs.getBool('set_ass_subtitle') ?? true;
    } catch (_) {}
  }

  Future<void> _loadRecordHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool('set_record_history') ?? true;
      if (mounted) _recordHistory = v;
    } catch (_) {}
  }

  /// 设置页「字幕默认语言」→ 自动选轨（v1.7.47 接通）。
  ///
  /// 这个设置项从 1.7.36 起就只有 UI、没有读取点，点了等于没点。
  /// 现在按 [SubtitlePicker] 的规则挑一条，交给 [_start] 在建立内核时挂上。
  ///
  /// 只影响「进入播放页时的初选」：用户一旦在字幕菜单里手动选过，本页
  /// 后续切集也不会被自动选轨覆盖（[_userPickedSub]）。
  Future<void> _autoPickSubtitle() async {
    // 用户已手动定过轨（含「关闭字幕」）→ 尊重他，自动选轨不插手
    if (_userPickedSub) return;
    SubtitlePref pref;
    try {
      final prefs = await SharedPreferences.getInstance();
      pref = SubtitlePrefX.fromCode(prefs.getInt('set_sub_lang'));
    } catch (_) {
      pref = SubtitlePref.auto;
    }
    final pick = SubtitlePicker.pick(widget.item.subtitles, pref);
    if (!mounted) return;
    setState(() => _subtitle = pick.track);
    // 已经建好内核（改成异步后才返回的极端情况）：补挂一次
    if (_player != null && pick.track != null) {
      unawaited(_applySubtitle(pick.track, silent: true));
    }
  }

  Future<void> _loadSubStyle() async {
    final s = await SubtitleStyleStore.load();
    if (!mounted) return;
    setState(() => _subStyle = s);
    // 冷启动进来时播放器可能还没建好，这里扑个空也没关系：
    // _start() 建完内核后会再下发一次
    unawaited(_player?.applySubtitleStyle(s) ?? Future<void>.value());
  }

  /// 打开字幕样式面板：拖动即时预览，松手落盘
  Future<void> _showSubtitleStyle() async {
    _hideTimer?.cancel();
    final base = _subStyle;
    await Navigator.of(context).push<void>(
      _GlassPanelRoute<void>(
        builder: (ctx) => SubtitleStyleSheet(
          style: base,
          onChanged: (next, commit) {
            if (!mounted) return;
            // 拖动中只更新样式（叠加层会跟着重建），不 setState 整页
            _subStyle = next;
            _styleRev.value++;
            // Exo 走叠加层（读 _subStyle 重建即可），MPV 需要下发原生属性
            unawaited(
              _player?.applySubtitleStyle(next) ?? Future<void>.value(),
            );
          },
        ),
      ),
    );
    _resetHideTimer();
  }

  /// 切换最大码率：原片（不限制）/ 40M / 20M / 10M / 5M / 2M。
  ///
  /// Emby 侧用 MaxStreamingBitrate 参数让服务端按该码率重新出流，因此必须
  /// **重建播放地址并保留当前进度**（与切内核同一套序列：记位置 → 重建 → seek 回原处）。
  Future<void> _changeBitrate() async {
    const presets = <(String, int?)>[
      ('原片（不限码率）', null),
      ('40 Mbps', 40000000),
      ('20 Mbps', 20000000),
      ('10 Mbps', 10000000),
      ('5 Mbps', 5000000),
      ('2 Mbps', 2000000),
    ];
    final picked = await _showGlassPanel<int>(
      title: '选择码率',
      subtitle: '外网播放可调低码率；服务端需开启转码权限',
      // -1 哨兵代表「不限码率」：直接 pop null 与「点外部关闭」无法区分
      options: presets
          .map(
            (e) => (
              e.$1,
              () => Navigator.pop(context, e.$2 ?? -1),
              e.$2 == _maxBitrate,
            ),
          )
          .toList(),
    );
    if (!mounted) return;
    // 点暗层/手势返回关闭 → null，等同于「不改」。
    // 以前直接往下走会把 null 当成「不限码率」，关个面板就把码率重置了。
    if (picked == null) {
      _resetHideTimer();
      return;
    }
    await _applyBitrate(picked == -1 ? null : picked);
  }

  /// 应用码率：重建播放并从原位置续播
  Future<void> _applyBitrate(int? bitrate) async {
    if (bitrate == _maxBitrate) return;
    final pos = _positionSeconds;
    final wasPlaying = _isPlaying;
    final url = widget.item.videoUrl;
    setState(() {
      _maxBitrate = bitrate;
      _initializing = true;
    });
    await _player?.dispose();
    _player = null;
    if (url != null) {
      var ok = false;
      final srv = widget.state.server;
      if (srv != null) {
        ok = await _start(
          _engine,
          srv.streamUrl(
            widget.item.id,
            direct: bitrate == null,
            maxBitrate: bitrate,
          ),
        );
      }
      if (!ok) ok = await _start(_engine, url);
      if (ok && pos > 1) {
        await _player?.seek(pos);
        if (!wasPlaying) await _player?.pause();
      }
    }
    if (!mounted) return;
    setState(() => _initializing = false);
    _resetHideTimer();
    if (_maxBitrate == null) {
      showToast(context, '已切到原片画质');
    } else {
      showToast(context, '码率上限 ${(_maxBitrate! ~/ 1000000)} Mbps');
    }
  }

  /// 运行时开关硬件解码（1.7.38 新增）。MPV 热切 hwdec 属性；Exo 提示不支持。
  Future<void> _toggleHardware() async {
    final p = _player;
    if (p == null) {
      showToast(context, '播放器尚未就绪');
      return;
    }
    if (p.engine == PlaybackEngine.exo) {
      showToast(context, 'ExoPlayer 恒为硬解，无需切换');
      return;
    }
    final next = !p.hardwareDecode;
    await p.setHardwareDecode(next);
    if (!mounted) return;
    setState(() => _hw = p.hardwareDecode);
    // 与设置页的开关联动写回，下次起播沿用
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('set_hw_decode', _hw);
    } catch (_) {}
    if (!mounted) return;
    final hw = _hw;
    showToast(context, hw ? '已开启硬件解码' : '已切换到软件解码');
    _resetHideTimer();
  }

  /// 锁定控制层：顶栏锁按钮 → 隐藏全部控件，只留一个解锁按钮
  void _lockScreen() {
    _hideTimer?.cancel();
    setState(() {
      _locked = true;
      _controlsVisible = false;
    });
    showToast(context, '已锁定 · 长按解锁', icon: Icons.lock_rounded);
  }

  /// 解锁：需要长按，避免误触后又马上被自动隐藏
  void _unlockScreen() {
    setState(() {
      _locked = false;
      _controlsVisible = true;
    });
    _resetHideTimer();
  }

  /// 起播后立刻同步一次进度，并挂上周期定时器
  void _startReportTimer() {
    _reportTimer?.cancel();
    // 每 10 秒补一次：服务端 UserData 里的播放位置因此始终接近当前位置
    _reportTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_reportProgress()),
    );
  }

  /// 节流后的进度上报入口：10s 定时器、暂停 / 播放切换都走这里
  Future<void> _reportProgress() async {
    final now = DateTime.now();
    if (_lastReportAt != null && now.difference(_lastReportAt!).inSeconds < 5) {
      return;
    }
    await _reportProgressNow();
  }

  /// 立即上报当前进度（Emby 的 Ticks：100ns 为一个单位）
  ///
  /// 两件事一起做：① 服务端写 PlaybackPositionTicks；② 本地 AppState 同步
  /// 进度 —— 少了 ② 的话，退出播放页回首页，「继续观看」要等下次拉库才更新。
  Future<void> _reportProgressNow() async {
    if (_demo || !_recordHistory) return;
    final pos = _positionSeconds;
    final total = _totalSeconds;
    if (total > 0) {
      widget.state.updateProgress(
        widget.item.id,
        seconds: pos,
        total: total,
        played: pos >= total * 0.95,
      );
    }
    final srv = widget.state.server;
    if (srv == null) return;
    _lastReportAt = DateTime.now();
    unawaited(srv.reportProgress(widget.item.id, (pos * 10000000).round()));
  }

  /// 通用玻璃面板：码率 / 倍速 / 字幕等单选列表共用一套外观。
  /// 与 _Sheet 的差异：多一行副标题（_InfoHeader），适合需要说明参数含义的场景。
  Future<T?> _showGlassPanel<T>({
    required String title,
    String? subtitle,
    required List<(String, VoidCallback, bool)> options,
  }) {
    _hideTimer?.cancel();
    return Navigator.of(context).push<T>(
      _GlassPanelRoute<T>(
        builder: (ctx) => _Sheet(
          title: title,
          subtitle: subtitle,
          children: [
            for (final e in options)
              _SheetRow(label: e.$1, selected: e.$3, onTap: e.$2),
          ],
        ),
      ),
    );
  }

  /// 字幕 URL 的精简显示形式：去掉 api_key 等查询串，只留资源路径
  String _shortSubUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    final i = url.indexOf('?');
    final raw = i < 0 ? url : url.substring(0, i);
    final seg = raw.split('/');
    if (seg.length > 2) {
      return '${seg[seg.length - 2]}/${seg[seg.length - 1]}';
    }
    return raw;
  }

  /// 续播定位：内核刚打开时可能还没拿到时长/时间轴，seek 会失效，
  /// 所以等就绪后重试最多 4 次；用户一旦自己拖动就立刻让位。
  Future<void> _seekToStart() async {
    final target = widget.startSeconds;
    if (target < 5) return;
    for (var i = 0; i < 4; i++) {
      if (!mounted || _player == null) return;
      if (_scrubbing || _seeking) return; // 用户已接管
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted || _scrubbing || _seeking) return;
      await _commitSeek(target);
      if (!mounted || _scrubbing) return;
      if ((_positionSeconds - target).abs() <= 5) break;
    }
    if (mounted && widget.item.resumeLabel.isNotEmpty) {
      showToast(
        context,
        '从 ${widget.item.resumeLabel} 继续播放',
        icon: Icons.play_arrow_rounded,
      );
    }
  }

  Future<void> _loadEpisodes() async {
    final sid = widget.item.seriesId;
    final srv = widget.state.server;
    if (sid == null || srv == null) return;
    try {
      final list = await srv.episodes(sid);
      if (!mounted) return;
      setState(() {
        _episodes = list;
        _episodeIndex = list.indexWhere((e) => e.id == widget.item.id);
      });
    } catch (_) {
      /* 分集拉不到就保持禁用态 */
    }
  }

  /// 自动连播：设置页开关打开时，本集播到 95% 以上自动跳下一集。
  ///
  /// 三个前置条件缺一不可，避免误跳：① 开关打开；② 有分集列表且不是最后一集；
  /// ③ 时长已知（时长未知的 strm 流无法判断「播完」）。
  void _checkAutoNext() {
    if (!_autoNext || _autoNextFired) return;
    if (_episodes.isEmpty) return;
    if (_episodeIndex < 0 || _episodeIndex >= _episodes.length - 1) return;
    final total = _player?.durationSeconds ?? 0;
    if (total <= 0) return;
    if (_positionSeconds < total * 0.95) return;
    _autoNextFired = true;
    unawaited(_reportProgressNow());
    _goEpisode(1);
  }

  /// 切上一集 / 下一集（自动连播的落地实现）
  ///
  /// 注意：pushReplacement 是 **新的 State**，用户手选的字幕状态会丢；
  /// 但如果新一集有字幕资源，仍按设置项的偏好重新选一次（各集轨道集合
  /// 常常不同，沿用上一集的 url 会挂错文件）。
  void _goEpisode(int delta) {
    final next = _episodes[_episodeIndex + delta];
    Navigator.of(context).pushReplacement(
      CambyRoutes.fade(
        builder: (_) => PlayerPage(
          item: next,
          state: widget.state,
          startSeconds: next.resumeSeconds ?? 0,
        ),
      ),
    );
  }

  Future<void> _tryOpen() async {
    final url = widget.item.videoUrl;
    if (url == null) {
      _fallback = true;
      return;
    }
    if (await _start(_engine, url)) return;
    final srv = widget.state.server;
    if (srv != null &&
        await _start(_engine, srv.streamUrl(widget.item.id, direct: false)))
      return;
    _fallback = true;
  }

  Future<bool> _start(PlaybackEngine engine, String url) async {
    PlaybackController? p;
    try {
      if (engine == PlaybackEngine.exo) {
        p = ExoController();
      } else {
        // 设置页「硬件解码优先」：MPV 走 MediaCodec 硬解（auto-safe，
        // 解码失败自动回退软解）；关闭则纯软解。Exo 恒为硬解。
        final prefs = await SharedPreferences.getInstance();
        p = MpvController(
          hardwareDecode: prefs.getBool('set_hw_decode') ?? true,
          cacheMb: _cacheBytes,
        );
      }
      p.fit = _fit;
      await p.open(url, subtitleUrl: _subtitle?.url);
      await p.setSpeed(_playbackSpeed);
      if (!mounted) {
        await p.dispose();
        return false;
      }
      // Exo 无法原生挂字幕：启动时就把已选字幕加载进叠加层
      final sub = _subtitle;
      if (!p.nativeSubtitles && sub?.url != null) {
        unawaited(_loadCuesFor(sub!));
      }
      final prev = _player;
      // p 在 setState 闭包里不会被提升到非空，这里先取出来
      final hw = p.hardwareDecode;
      setState(() {
        _player = p;
        _engine = engine;
        _fallback = false;
        _hw = hw;
      });
      await prev?.dispose();
      await p.play();
      // 新建的内核（尤其是 MPV）需要重新下发一次字幕样式与 ASS 开关
      unawaited(p.applySubtitleStyle(_subStyle));
      unawaited(p.setAssRendering(_assSubtitle));
      return true;
    } catch (_) {
      await p?.dispose();
      return false;
    }
  }

  Future<void> _switchEngine({bool silent = false}) async {
    final target = _engine == PlaybackEngine.exo
        ? PlaybackEngine.mpv
        : PlaybackEngine.exo;
    final pos = _positionSeconds;
    final wasPlaying = _isPlaying;
    final url = widget.item.videoUrl;
    if (url == null) {
      setState(() => _engine = target);
      return;
    }
    setState(() => _initializing = true);
    await _player?.dispose();
    _player = null;
    final ok = await _start(target, url);
    if (ok && pos > 1) {
      await _player?.seek(pos);
      if (!wasPlaying) await _player?.pause();
    }
    // MPV 由内核渲染字幕：清掉 Exo 时代的叠加层，避免两份字幕叠着
    if (ok && target == PlaybackEngine.mpv && mounted) {
      setState(() {
        _cues = const [];
        _cueText = '';
      });
    }
    if (!mounted) return;
    setState(() => _initializing = false);
    if (!silent) showToast(context, '已切换至 ${target.label}');
    _resetHideTimer();
    // 新内核重新计时：手动切回 MPV 时也允许再自动回退一次
    _autoFellBack = false;
    _startBootWatch();
  }

  @override
  void dispose() {
    // 退出播放页恢复系统音量条
    VolumeController.instance.showSystemUI = true;
    _hideTimer?.cancel();
    _ticker?.cancel();
    _bufTimer?.cancel();
    _doubleTimer?.cancel();
    _scrubWatch?.cancel();
    _revealTimer?.cancel();
    // 退出前最后一次同步播放位置：其它设备上的「继续观看」立刻跟上
    _reportTimer?.cancel();
    _reportTimer = null;
    unawaited(_reportProgressNow());
    _player?.dispose();
    _posNv.dispose();
    _bufNv.dispose();
    _cueNv.dispose();
    _styleRev.dispose();
    _bootVN.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  bool get _demo => _fallback || _player == null || !_player!.ready;

  /// 把当前应显示的进度推给 [_posNv]（拖动中取预览位置，避免回弹）
  void _syncPos() {
    final p = (_scrubbing || _seeking) ? _scrubPos : _positionSeconds;
    if ((_posNv.value - p).abs() > 0.01) _posNv.value = p;
  }

  double get _totalSeconds {
    final d = _player?.durationSeconds ?? 0;
    if (d > 0) return d;
    return (widget.item.runtimeMin * 60).toDouble();
  }

  double get _positionSeconds => _player?.positionSeconds ?? _demoPosition;

  bool get _isPlaying => _player?.isPlaying ?? _demoPlaying;

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          _isPlaying &&
          !_locked &&
          !_scrubbing &&
          !_seeking &&
          !_barPressed) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  String _fmt(double sec) {
    final d = Duration(seconds: sec.round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ---------------- 手势 ----------------
  void _onTap() {
    if (_locked) return;
    final now = DateTime.now();
    final pos = _tapPos ?? Offset.zero;
    // 双击判定：距上次点击 < 300ms 且两次点击位置接近（< 64dp）才算双击。
    // 加位置约束是为了避免“点屏幕唤出控件后，又在别处快速点一下”被误判成
    // 双击快进/退，进而触发 seek 打断播放。单击依旧立即切换控件显隐。
    if (_lastTapAt != null &&
        _lastTapPos != null &&
        now.difference(_lastTapAt!).inMilliseconds < 300 &&
        (pos - _lastTapPos!).distance <= 64) {
      _lastTapAt = null;
      _lastTapPos = null;
      _doDoubleTap();
      return;
    }
    _lastTapAt = now;
    _lastTapPos = pos;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      // 唤出控件时重新开始 4s 自动隐藏，避免被上一次的旧计时器“秒杀”
      _resetHideTimer();
    } else {
      // 手动隐藏时取消待触发的自动隐藏，避免刚收起又被旧计时器打断
      _hideTimer?.cancel();
    }
  }

  void _doDoubleTap() {
    if (_locked) return;
    final now = DateTime.now();
    // 防抖：一次双击跳转后 700ms 内忽略再次双击。视频 seek 到新位置
    // 会短暂缓冲，用户着急连点时，若不设防抖会反复 seek，形成“点一下
    // 又缓冲、再点又跳”的无限循环，视频始终放不出来。
    if (_lastDoubleTapAt != null &&
        now.difference(_lastDoubleTapAt!).inMilliseconds < 700) {
      return;
    }
    _lastDoubleTapAt = now;
    final w = MediaQuery.of(context).size.width;
    final left = (_tapPos?.dx ?? 0) < w / 2;
    unawaited(_quickSeek(_positionSeconds + (left ? -10 : 10)));
    _showDoubleTip(left ? '-10秒' : '+10秒', left);
    _resetHideTimer();
  }

  void _showDoubleTip(String label, bool left) {
    _doubleTip = label;
    _doubleTipLeft = left;
    if (mounted) setState(() {});
    _doubleTimer?.cancel();
    _doubleTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _doubleTip = null);
    });
  }

  Timer? _doubleTimer;
  String? _doubleTip;
  bool _doubleTipLeft = false;

  void _onHorizontalStart(DragStartDetails d) {
    if (_locked) return;
    _scrubStartPos = _positionSeconds;
    _scrubStartX = d.globalPosition.dx;
    _beginScrub(_scrubStartPos);
  }

  void _onHorizontalUpdate(DragUpdateDetails d) {
    if (!_scrubbing) return;
    final w = MediaQuery.of(context).size.width;
    final delta = (d.globalPosition.dx - _scrubStartX) / w * _totalSeconds;
    _updateScrub(_scrubStartPos + delta);
  }

  void _onHorizontalEnd(_) {
    if (!_scrubbing) return;
    unawaited(_endScrub());
  }

  // ---------------- 拖动状态机（进度条 / 屏幕手势共用）----------------
  /// 开始拖动：控制层必须同时显示出来，否则底部进度条处于
  /// IgnorePointer 状态，用户会看到“画面跳了、进度条不动”。
  void _beginScrub(double start) {
    _hideTimer?.cancel();
    _seeking = false;
    _scrubbing = true;
    // 基准位置：面板上显示「相对当前播放点跳了多少」
    _scrubStartPos = _positionSeconds;
    _scrubPos = start.clamp(0.0, _totalSeconds);
    _armScrubWatch();
    _syncPos();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
  }

  void _updateScrub(double v) {
    _scrubPos = v.clamp(0.0, _totalSeconds);
    _previewSeek(_scrubPos);
    _armScrubWatch();
    // 拖动中也要推给进度条，否则手指在动、条不动
    _syncPos();
  }

  Future<void> _endScrub() async {
    // 只有真的在拖动时才提交。onHorizontalDragCancel 在手势竞技场判负时
    // 也会触发（普通点按就可能走到），以前无条件提交，会把 _scrubPos
    // （初值 0 或上次拖动留下的旧位置）当成目标真跳一次 —— 表现就是
    // "点一下画面，视频顿 1 秒再回退几帧"。
    if (!_scrubbing) return;
    final target = _scrubPos.clamp(0.0, _totalSeconds);
    _scrubbing = false;
    _scrubWatch?.cancel();
    _syncPos();
    await _commitSeek(target);
    _resetHideTimer();
  }

  /// 看门狗：手势偶尔收不到 end/cancel（被系统手势/弹层抢走），
  /// 中央大时间提示会永久挂着。1.2s 没有更新就当作松手。
  Timer? _scrubWatch;
  void _armScrubWatch() {
    _scrubWatch?.cancel();
    _scrubWatch = Timer(const Duration(milliseconds: 1200), () {
      if (mounted && _scrubbing) unawaited(_endScrub());
    });
  }

  /// 拖动过程中的预览跳转：节流到 ~350ms 一次、位移 >1.5s 才发，
  /// 既保留画面跟随感，又不会把 seek 塞爆（MPV 尤其明显）。
  void _previewSeek(double v) {
    if (_demo || _player == null) return;
    final now = DateTime.now();
    final since = _lastPreviewAt == null
        ? 9999
        : now.difference(_lastPreviewAt!).inMilliseconds;
    if (since < 350 || (v - _lastPreviewTarget).abs() < 1.5) return;
    _lastPreviewAt = now;
    _lastPreviewTarget = v;
    unawaited(_player!.seek(v, preview: true));
  }

  /// 提交一次跳转：发出 seek 后轮询确认播放器真的到位，
  /// 未到位则补一次；期间 UI 保持预览位置，不会回弹。
  Future<void> _commitSeek(double target) async {
    final seq = ++_seekSeq;
    final t = target.clamp(0.0, _totalSeconds);
    _scrubPos = t;
    if (_demo) {
      // 演示模式也要复位 _seeking：否则一旦有真实跳转正在进行、
      // 又来了演示分支的跳转，_seeking 会被永远卡在 true，进度显示冻结。
      if (mounted) {
        setState(() {
          _seeking = false;
          _demoPosition = t;
        });
      }
      return;
    }
    // 目标与当前位置几乎一致：不发给播放器。ExoPlayer 即便 seek 到当前
    // 位置也会重新缓冲（停顿约 1 秒，并从稍早的帧继续）。
    final cur = _player?.positionSeconds ?? t;
    if ((t - cur).abs() <= 1.0) {
      if (mounted) {
        setState(() {
          _seeking = false;
          _seekDiag = '已在 ${_fmt(t)}';
        });
      }
      return;
    }
    if (mounted) setState(() => _seeking = true);
    var ok = false;
    try {
      await _player?.seek(t);
      for (var i = 0; i < 8; i++) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (!mounted || seq != _seekSeq) return; // 已被更新的操作取代
        final cur = _player?.positionSeconds ?? -1;
        if ((cur - t).abs() <= 2.5) {
          ok = true;
          break;
        }
        if (i == 3) await _player?.seek(t); // 中途补一次
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted || seq != _seekSeq) return;
    final err = _player?.lastSeekError ?? '';
    setState(() {
      _seeking = false;
      _seekDiag = ok
          ? '成功 ${_fmt(t)}'
          : '失败 ${_fmt(t)} · ${_engine.short}${err.isEmpty ? '' : ' · $err'}';
    });
    if (!ok) {
      final err = _player?.lastSeekError ?? '';
      showToast(
        context,
        err.isEmpty ? '跳转未生效（${_engine.short} 内核）' : '跳转未生效 · $err',
      );
    }
  }

  void _onVerticalStart(DragStartDetails d) async {
    if (_locked) return;
    final w = MediaQuery.of(context).size.width;
    final isBrightness = d.globalPosition.dx < w / 2;
    _adjustSide = isBrightness ? 'brightness' : 'volume';
    _adjustStartDy = d.globalPosition.dy;
    _adjustBase = isBrightness
        ? (await ScreenBrightness.instance.application)
        : (await VolumeController.instance.getVolume());
    _adjustValue = _adjustBase;
    setState(() {});
  }

  void _onVerticalUpdate(DragUpdateDetails d) {
    if (_adjustSide == null) return;
    final h = MediaQuery.of(context).size.height;
    final delta = (d.globalPosition.dy - _adjustStartDy) / h; // 向上拖动为正
    final next = (_adjustBase - delta).clamp(0.0, 1.0);
    _adjustValue = next;
    if (_adjustSide == 'brightness') {
      ScreenBrightness.instance.setApplicationScreenBrightness(next);
    } else {
      VolumeController.instance.setVolume(next);
    }
    setState(() {});
  }

  void _onVerticalEnd(_) {
    _adjustSide = null;
    _adjustStartDy = 0;
    setState(() {});
  }

  /// 轻量跳转：双击快进/退、快进退按钮用。只 seek 一次、不进入拖动那套
  /// 1.2s 轮询确认流程——±10 秒的小跳转无需精确对位，反而要尽快返回，
  /// 否则视频会被长时间的 _seeking 打断，表现为“暂停 2-3 秒才继续”。
  Future<void> _quickSeek(double seconds) async {
    final t = seconds.clamp(0.0, _totalSeconds);
    _scrubPos = t;
    if (_demo) {
      if (mounted) setState(() => _demoPosition = t);
      return;
    }
    try {
      await _player?.seek(t);
    } catch (_) {}
    if (mounted) setState(() {});
    _resetHideTimer();
  }

  void _togglePlay() {
    if (_demo) {
      setState(() => _demoPlaying = !_demoPlaying);
    } else {
      _isPlaying ? _player?.pause() : _player?.play();
    }
    // 播放↔暂停切换时补一次进度上报（节流 5s），服务端会话状态跟着走
    unawaited(_reportProgress());
    _resetHideTimer();
  }

  void _skip(int delta) {
    unawaited(_quickSeek(_positionSeconds + delta));
    showToast(context, delta < 0 ? '已快退 10 秒' : '已快进 10 秒');
  }

  Future<void> _setSpeed(double v) async {
    final next = v.clamp(0.25, 3.0);
    setState(() => _playbackSpeed = next);
    await _player?.setSpeed(next);
    _resetHideTimer();
  }

  /// 倍速选择弹层：底栏「倍速」胶囊点开后选档，替代右侧竖排调节杆
  Future<void> _pickSpeed() async {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
    final picked = await Navigator.of(context).push<double>(
      _GlassPanelRoute<double>(
        builder: (ctx) => _Sheet(
          title: '播放速度',
          children: speeds.map((s) {
            final label = s
                .toStringAsFixed(2)
                .replaceAll(RegExp(r'0+$'), '')
                .replaceAll(RegExp(r'\.$'), '');
            return _SheetRow(
              label: '$label×',
              selected: _playbackSpeed == s,
              onTap: () => Navigator.pop(ctx, s),
            );
          }).toList(),
        ),
      ),
    );
    if (picked != null) await _setSpeed(picked);
  }

  /// 画面比例：自适配（完整显示）↔ 满屏（裁切铺满）
  void _toggleFit() {
    setState(() {
      _fit = _fit == PlaybackFit.fit ? PlaybackFit.fill : PlaybackFit.fit;
      _player?.fit = _fit;
    });
    showToast(context, _fit == PlaybackFit.fill ? '画面：满屏' : '画面：自适配');
    _resetHideTimer();
  }

  String get _speedLabel =>
      '${_playbackSpeed.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}×';

  /// 播放信息面板：字幕一行（语言 · 格式）
  String _subInfoText() => _subtitle == null
      ? '关闭'
      : '${_subtitle!.languageLabel} · ${_subtitle!.codecLabel}';

  /// 播放信息面板：码率一行
  String _bitrateText() => _maxBitrate == null
      ? '原片（不限 · 直连播放）'
      : '≤ ${(_maxBitrate! ~/ 1000000)} Mbps（服务端转码）';

  /// 播放信息面板：码率按钮上的短标签
  String _bitrateShort() =>
      _maxBitrate == null ? '原片' : '${(_maxBitrate! ~/ 1000000)} Mbps';

  /// 文件大小：0 表示服务端没给（strm 常见），显示「未知」而不是 0 B
  String _fmtSize(int bytes) {
    if (bytes <= 0) return '未知';
    const kb = 1024.0;
    if (bytes < kb) return '$bytes B';
    if (bytes < kb * kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    if (bytes < kb * kb * kb) {
      return '${(bytes / kb / kb).toStringAsFixed(1)} MB';
    }
    return '${(bytes / kb / kb / kb).toStringAsFixed(2)} GB';
  }

  /// 入库时间：只有日期，避免信息面板被长串时间戳撑开
  String _fmtDate(int? ms) {
    if (ms == null || ms <= 0) return '未知';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  // ---------------- 字幕 / 信息 弹层 ----------------
  Future<void> _pickSubtitle() async {
    final tracks = widget.item.subtitles;
    if (tracks.isEmpty) {
      // 字幕轨全部来自服务端 MediaStreams。这里一条都没有，说明服务器上
      // 这部电影既没有内封字幕、也没有扫描到外挂字幕 —— App 侧没有远端
      // 字幕站可查（没接 OpenSubtitles 之类的源），只能引导用户去解决源头。
      showToast(
        context,
        '该影片没有可用字幕：可在 Emby 装字幕插件后重新扫描，或手动放置外挂字幕',
        icon: Icons.subtitles_off_rounded,
      );
      return;
    }
    final picked = await Navigator.of(context).push<_SubPick>(
      _GlassPanelRoute<_SubPick>(
        builder: (ctx) => _Sheet(
          title: '选择字幕',
          children: [
            _SheetRow(
              label: '关闭字幕',
              selected: _subtitle == null,
              onTap: () => Navigator.pop(ctx, const _SubPick(null)),
            ),
            ...tracks.map(
              (t) => _SheetRow(
                label: t.menuLabel,
                hint: t.displayTitle.isEmpty
                    ? _shortSubUrl(t.url)
                    : t.displayTitle,
                selected: _subtitle?.url == t.url,
                onTap: () => Navigator.pop(ctx, _SubPick(t)),
              ),
            ),
          ],
        ),
      ),
    );
    // 点弹窗外部关闭 → picked 为 null：什么都不做。
    // 以前这里把 null 当成「关闭字幕」，所以一碰画面字幕就没了。
    if (picked == null) return;
    if (picked.track?.url == _subtitle?.url) return;
    // 用户手动定过字幕：本页后续切集/切内核不再自动选轨覆盖他的选择
    _userPickedSub = true;
    await _applySubtitle(picked.track);
  }

  /// 切换字幕：**不重建播放器**，因此不会丢进度。
  ///  · MPV：内核原生挂载，ASS 特效也能显示
  ///  · Exo：video_player 没有运行时挂字幕接口 → 用叠加层自己渲染
  ///
  /// [silent] = true 时不弹 toast（自动选轨用，避免起播就糊用户一脸提示）。
  Future<void> _applySubtitle(
    SubtitleTrackInfo? track, {
    bool silent = false,
  }) async {
    setState(() {
      _subtitle = track;
      if (track == null) {
        _cues = const [];
        _cueText = '';
      }
    });
    if (track == null) {
      await _player?.setSubtitle(null);
      if (!silent) showToast(context, '已关闭字幕');
      _resetHideTimer();
      return;
    }

    final native = await _player?.setSubtitle(track.url) ?? false;
    if (!native) {
      final cues = await _loadCues(track);
      if (!mounted) return;
      if (!silent) {
        showToast(context, cues.isEmpty ? _subFailText() : '字幕：${track.menuLabel}');
      }
    } else {
      setState(() {
        _cues = const [];
        _cueText = '';
      });
      if (!silent) showToast(context, '字幕：${track.menuLabel}');
    }
    _resetHideTimer();
  }

  /// 字幕失败提示：带上具体原因（HTTP 状态 / 编码 / 无时间轴），
  /// 便于用户直接反馈是哪一步出的问题。
  String _subFailText() {
    final d = Subtitles.lastDiag;
    if (d.isEmpty) return '该字幕无法作为文本显示（可切 MPV 内核）';
    return '字幕加载失败 · $d（可切 MPV 内核）';
  }

  /// 字幕下载通道：复用 App 的 Emby 鉴权（Token 头 + 忽略自签证书），
  /// 与视频同源，避免 Exo 字幕叠加层在 LAN 服务器上 401 / 证书失败。
  Future<List<int>?> _subFetcher(String url) async {
    final srv = widget.state.server;
    if (srv == null) return null;
    return srv.fetchBytes(url);
  }

  /// 拉取文本字幕（Exo 叠加层用）。期间又换了字幕就丢弃本次结果。
  Future<List<SubtitleCue>> _loadCues(SubtitleTrackInfo track) async {
    final texts = track.textCandidates;
    final cues = await Subtitles.load(
      texts.isEmpty ? track.textUrl : texts.first,
      altUrls: texts.length > 1 ? texts.sublist(1) : const <String>[],
      fetcher: _subFetcher,
      fallbackUrl: track.url,
      diagOf: () => widget.state.server?.subtitleDiag ?? '',
    );
    if (!mounted || _subtitle?.url != track.url) return const [];
    setState(() {
      _cues = cues;
      _cueText = '';
    });
    return cues;
  }

  /// 每帧按当前播放位置刷新叠加字幕文本
  void _tickCue() {
    if (_cues.isEmpty) {
      if (_cueText.isNotEmpty) _cueText = '';
      return;
    }
    final t = (_scrubbing || _seeking) ? _scrubPos : _positionSeconds;
    final next = Subtitles.textAt(_cues, t);
    if (next != _cueText) _cueText = next;
  }

  /// 加载一条字幕到叠加层（仅非原生内核需要）
  Future<void> _loadCuesFor(SubtitleTrackInfo track) async {
    final texts = track.textCandidates;
    final cues = await Subtitles.load(
      texts.isEmpty ? track.textUrl : texts.first,
      altUrls: texts.length > 1 ? texts.sublist(1) : const <String>[],
      fetcher: _subFetcher,
      fallbackUrl: track.url,
      diagOf: () => widget.state.server?.subtitleDiag ?? '',
    );
    if (!mounted || _subtitle?.url != track.url) return;
    setState(() => _cues = cues);
    if (cues.isEmpty) showToast(context, _subFailText());
  }

  void _showInfo() {
    final item = widget.item;
    Navigator.of(context).push<void>(
      _GlassPanelRoute<void>(
        builder: (ctx) => _Sheet(
          title: '播放信息',
          children: [
            _InfoRow(k: '片名', v: item.name),
            _InfoRow(k: '内核', v: _engine.label),
            _InfoRow(
              k: '画质',
              v: item.resolutionKnown
                  ? '${item.videoHeight}p · ${item.videoCodec}'
                  : '未知 · ${item.videoCodec}',
            ),
            _InfoRow(
              k: '音频',
              v: '${item.audioCodec} · ${item.audioChannels}ch',
            ),
            _InfoRow(k: '封装', v: item.container),
            _InfoRow(k: '大小', v: _fmtSize(item.fileSizeBytes)),
            _InfoRow(k: '入库', v: _fmtDate(item.dateCreatedMs)),
            _InfoRow(k: '字幕', v: _subInfoText()),
            _InfoRow(k: '倍速', v: _speedLabel),
            _InfoRow(k: '码率', v: _bitrateText()),
            _InfoRow(
              k: '进度',
              v:
                  '${_fmt(_positionSeconds)} / ${_fmt(_totalSeconds)}'
                  '${_player?.durationSeconds != null && _player!.durationSeconds > 0 ? '' : '（时长未知，用片长兜底）'}',
            ),
            _InfoRow(k: '最近跳转', v: _seekDiag),
            _InfoRow(
              k: '内核状态',
              v:
                  '${_player?.ready == true ? '已就绪' : '未就绪'}'
                  '${_player?.lastSeekOk == true ? '' : ' · ${_player?.lastSeekError ?? ''}'}',
            ),
            _SheetRow(
              label: '码率上限（当前 ${_bitrateShort()}）',
              hint: '调低可适配外网',
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_changeBitrate());
              },
            ),
            _SheetRow(
              label: '切换内核（当前 ${_engine.short}）',
              onTap: () {
                Navigator.pop(ctx);
                _switchEngine();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 构建 ----------------
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final total = _totalSeconds;
    // 系统返回手势/返回键也走统一退出序列（黑幕遮旋转）
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exitPlayer());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _tapPos = d.globalPosition,
          onTap: _onTap,
          onHorizontalDragStart: _onHorizontalStart,
          onHorizontalDragUpdate: _onHorizontalUpdate,
          onHorizontalDragEnd: _onHorizontalEnd,
          // 手势被系统/弹层打断时也要收尾，否则大时间提示会一直挂着
          onHorizontalDragCancel: () {
            if (_scrubbing) unawaited(_endScrub());
          },
          onVerticalDragStart: _onVerticalStart,
          onVerticalDragUpdate: _onVerticalUpdate,
          onVerticalDragEnd: _onVerticalEnd,
          onVerticalDragCancel: () => _onVerticalEnd(null),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: _VideoSurface(
                  _player,
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          item.colors.first.withOpacity(0.9),
                          Colors.black,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_initializing)
                const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                )
              else if (!_demo && !_fallback && !_firstFrame)
                // A 方案：黑屏期的加载胶囊。原来这里什么都没有，用户只能
                // 对着纯黑猜「是不是卡了」，8 秒后才敢去试别的内核。
                _bootOverlay()
              else if (_demo)
                Positioned(
                  top: 52,
                  left: 16,
                  child: Glass(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    radius: 999,
                    blur: 16,
                    blurEnabled: false,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.info_outline_rounded,
                          size: 14,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.item.videoUrl == null
                              ? '演示片源 · 模拟播放'
                              : '无可用片源 · 模拟播放',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // 双击快进提示：v1.7.22 起中央的「上一部/下一部」已移除，
              // 提示直接占回它们腾出的位置 —— 距屏幕中心 148dp 处。
              // 窄屏按可用宽度内收，避免贴边。
              if (_doubleTip != null)
                Align(
                  alignment: Alignment.center,
                  child: Builder(
                    builder: (ctx) {
                      final w = MediaQuery.sizeOf(ctx).width;
                      // 148dp 是设计值；屏宽不够时留 76dp 边距（玻璃气泡半宽）
                      final dx = (w / 2 - 76).clamp(0.0, 148.0);
                      return Transform.translate(
                        offset: Offset(_doubleTipLeft ? -dx : dx, 0),
                        child: Glass(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 12,
                          ),
                          radius: 16,
                          blur: 20,
                          blurEnabled: false,
                          child: Text(
                            _doubleTip!,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

              // 亮度 / 音量指示：距屏幕边缘 22dp，不再贴边
              if (_adjustSide != null)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: _adjustSide == 'brightness' ? 22 : null,
                  right: _adjustSide == 'volume' ? 22 : null,
                  width: 62,
                  child: Center(
                    child: Glass(
                      padding: const EdgeInsets.symmetric(
                        vertical: 13,
                        horizontal: 8,
                      ),
                      radius: 18,
                      blur: 20,
                      blurEnabled: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _adjustSide == 'brightness'
                                ? Icons.brightness_6_rounded
                                : Icons.volume_up_rounded,
                            size: 17,
                            color: AppColors.ink,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _adjustSide == 'brightness' ? '亮度' : '音量',
                            style: const TextStyle(
                              fontSize: 9,
                              color: Color(0xFFA9BCD8),
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            '${(_adjustValue * 100).round()}%',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 7),
                          SizedBox(
                            height: 88,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: LinearProgressIndicator(
                                value: _adjustValue,
                                minHeight: 5,
                                backgroundColor: Colors.white.withOpacity(0.2),
                                valueColor: const AlwaysStoppedAnimation(
                                  AppColors.accent,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 拖动进度时的大时间提示：只显示目标时间 + 相对位移，
              // 不再重复「目标 / 总长」（会和控制层压在一起）
              if (_scrubbing)
                Align(
                  alignment: const Alignment(0, -0.18),
                  child: IgnorePointer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _fmt(_scrubPos),
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            shadows: [
                              Shadow(color: Color(0xAA000000), blurRadius: 14),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_scrubPos - _scrubStartPos >= 0 ? '+' : '-'}${_fmt((_scrubPos - _scrubStartPos).abs())} · ${_fmt(total)}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFD2DEFA),
                            shadows: [
                              Shadow(color: Color(0x99000000), blurRadius: 10),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // 外挂字幕叠加层（Exo 内核 / MPV 未接管时）：
              // 只订阅 _cueNv，字幕换行不会连带重建整页
              ListenableBuilder(
                listenable: Listenable.merge(<Listenable>[_cueNv, _styleRev]),
                builder: (context, _) {
                  final cue = _cueText;
                  if (cue.isEmpty) return const SizedBox.shrink();
                  return Positioned(
                    left: 24,
                    right: 24,
                    // v1.7.28：位置完全固定，不随控制层显隐跳动
                    // （代价是控件弹出时进度条可能短暂压住字幕，这是"固定"的必然结果）
                    bottom:
                        (MediaQuery.of(context).size.height *
                                _subStyle.bottomRatio)
                            .clamp(
                              12.0,
                              MediaQuery.of(context).size.height / 2,
                            ),
                    child: IgnorePointer(
                      child: Text(
                        cue,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: _subStyle.textStyle,
                      ),
                    ),
                  );
                },
              ),

              // 控制层
              IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withOpacity(0.55),
                                Colors.transparent,
                                Colors.transparent,
                                Colors.black.withOpacity(0.75),
                              ],
                              stops: const [0.0, 0.28, 0.62, 1.0],
                            ),
                          ),
                        ),
                      ),
                      _topBar(context, item),
                      // 拖动进度时隐藏中央按钮，把画面让给大时间提示
                      if (!_scrubbing) _centerControls(),
                      _bottomBar(context, total),
                    ],
                  ),
                ),
              ),

              if (_locked)
                Positioned(
                  right: 18,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    // 长按解锁：锁定多半是为了防止小朋友误触，
                    // 轻点解锁等于没锁，这里要求按住 600ms
                    child: GestureDetector(
                      onLongPress: _unlockScreen,
                      child: GlassIconButton(
                        icon: Icons.lock_rounded,
                        size: 44,
                        blurEnabled: false,
                        onTap: null,
                      ),
                    ),
                  ),
                ),

              // 进出场黑幕：盖住横竖屏切换时的系统旋转动画
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _veiled ? 1 : 0,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOut,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 起播加载胶囊：片名 + 已等待秒数 + 内核实名；8 秒后给「切 Exo」，
  /// 25 秒后补一句「可能需要服务端插件预热」。
  Widget _bootOverlay() {
    final raw = widget.item.filePath;
    final name = raw.isEmpty ? widget.item.name : raw.split('/').last;
    return Center(
      child: ValueListenableBuilder<double>(
        valueListenable: _bootVN,
        builder: (_, secs, __) {
          final slow = BootWatchPolicy.showSwitchButton(
            engine: _engine,
            waitedSecs: secs,
          );
          final verySlow = BootWatchPolicy.showPluginHint(secs);
          return Glass(
            radius: 20,
            blur: 16,
            blurEnabled: false,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 15),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '正在获取媒体信息…',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 245),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.muted,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '已等待 ${secs.toStringAsFixed(0)} 秒 · ${_engine.label}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppColors.muted.withOpacity(0.85),
                  ),
                ),
                if (slow) ...[
                  const SizedBox(height: 12),
                  LiquidPress(
                    radius: 14,
                    scale: 0.96,
                    onTap: () => unawaited(_switchEngine()),
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: AppColors.accent.withOpacity(0.20),
                        border: Border.all(
                          color: AppColors.accent.withOpacity(0.55),
                        ),
                      ),
                      child: const Text(
                        '切换到 Exo 内核',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFBFD4FF),
                        ),
                      ),
                    ),
                  ),
                ],
                if (verySlow) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '片源仍在探测，可能需要在服务端装预热插件',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.warn,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _topBar(BuildContext context, MediaItem item) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.arrow_back_ios_new_rounded,
                iconSize: 15,
                blurEnabled: false,
                onTap: () => unawaited(_exitPlayer()),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_engine.label} · ${item.videoHeight}p · ${item.videoCodec} · '
                      '${item.audioCodec} ${item.audioChannels}ch',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFFA9BCD8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Glass(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                radius: 17,
                blur: 18,
                blurEnabled: false,
                onTap: _switchEngine,
                child: Center(
                  child: Text(
                    _engine.short,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 硬件解码热开关：出现异常解码时可直接切回软解，
              // 不用回设置页改完再重建播放器（丢进度）
              GestureDetector(
                onLongPress: _toggleHardware,
                child: Glass(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  radius: 17,
                  blur: 18,
                  blurEnabled: false,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.bolt_rounded,
                        size: 13,
                        color: _hw ? AppColors.accent : AppColors.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _hw ? '硬解' : '软解',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _hw ? Colors.white : AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: Icons.lock_open_rounded,
                iconSize: 15,
                blurEnabled: false,
                onTap: _lockScreen,
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: Icons.info_outline_rounded,
                iconSize: 15,
                blurEnabled: false,
                onTap: _showInfo,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // v1.7.22：去掉中央的「上一部 / 下一部」两个按钮 —— 它们既挤压了
  // 播放键的呼吸空间，又和双击 ±10 秒的提示抢位置。中央只留
  // 「快退 / 播放 / 快进」三件套，切集走详情页的分集列表。
  // 顺带修掉旧注释里「底栏有下一段」的说法：底栏从来没有这个按钮。
  Widget _centerControls() {
    return Positioned.fill(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _GlassPlayBtn(icon: Icons.replay_rounded, onTap: () => _skip(-10)),
          const SizedBox(width: 26),
          LiquidPress(
            onTap: _togglePlay,
            radius: 33,
            scale: 0.92,
            shadows: const [
              BoxShadow(
                color: Color(0x804F8CFF),
                blurRadius: 26,
                offset: Offset(0, 10),
              ),
            ],
            child: Container(
              width: 66,
              height: 66,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xF24F8CFF), Color(0xF27B5CFF)],
                ),
              ),
              child: Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 30,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 26),
          _GlassPlayBtn(
            // 水平镜像 replay 图标，与快退严格对称（forward 图标不是镜像对）
            icon: Icons.replay_rounded,
            flipX: true,
            onTap: () => _skip(10),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context, double total) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 10,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条只订阅位置
            ValueListenableBuilder<double>(
              valueListenable: _posNv,
              builder: (_, pos, __) => _ProgressBar(
                value: pos,
                total: total,
                pressed: _barPressed,
                onDown: (v) {
                  _barPressed = true;
                  _beginScrub(v);
                },
                onUpdate: _updateScrub,
                onUp: (v) {
                  _barPressed = false;
                  _updateScrub(v);
                  unawaited(_endScrub());
                },
              ),
            ),
            const SizedBox(height: 8),
            // 单行：左边当前时间 → 中间胶囊（弹性）→ 右边缓冲速率 + 总时长
            // v1.7.33/1.7.40：时长与缓冲固定贴最右，不再和按钮挤在一行里
            Row(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _posNv,
                  builder: (_, pos, __) => Text(
                    _fmt(pos),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFC6D5EF),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // 字幕：点选字幕，长按进入字幕样式面板
                        GestureDetector(
                          onLongPress: _showSubtitleStyle,
                          child: _Chip(
                            label: _subtitle == null
                                ? '字幕'
                                : '字幕 · ${_subtitle!.languageLabel}',
                            icon: Icons.subtitles_outlined,
                            onTap: _pickSubtitle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _Chip(
                          label: _fit == PlaybackFit.fill ? '满屏' : '自适配',
                          icon: Icons.aspect_ratio_rounded,
                          onTap: _toggleFit,
                        ),
                        const SizedBox(width: 8),
                        _SpeedChip(label: _speedLabel, onTap: _pickSpeed),
                        const SizedBox(width: 8),
                        _Chip(
                          label: _engine == PlaybackEngine.mpv
                              ? (_hw ? '硬解' : '软解')
                              : '硬解',
                          icon: Icons.memory_rounded,
                          onTap: () => unawaited(_toggleHardware()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // 缓冲速率常显（v1.7.40）：没数据时给占位，避免这一格忽隐忽现
                ValueListenableBuilder<String>(
                  valueListenable: _bufNv,
                  builder: (_, buf, __) => Text(
                    buf.isEmpty ? '-- MB/s' : buf,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8B94A7),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _fmt(total),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFC6D5EF),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 中央玻璃圆钮（v1.7.22 起只剩快退 / 快进两个，不再需要禁用态）
class _GlassPlayBtn extends StatelessWidget {
  const _GlassPlayBtn({
    required this.icon,
    required this.onTap,
    this.flipX = false,
  });

  final IconData icon;
  final VoidCallback onTap;

  /// 水平镜像（快进 = 快退图标的镜像，保证严格对称）
  final bool flipX;

  @override
  Widget build(BuildContext context) {
    return Glass(
      width: 50,
      height: 50,
      padding: EdgeInsets.zero,
      radius: 25,
      blur: 20,
      blurEnabled: false,
      onTap: onTap,
      child: Transform.flip(
        flipX: flipX,
        child: Icon(icon, size: 23, color: AppColors.ink),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 168),
      child: Glass(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        radius: 15,
        blur: 16,
        blurEnabled: false,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 5),
            // 字幕语言名可能很长：允许省略，避免把底栏挤爆
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义进度条：按下时轨道变粗、圆点放大、浮出时间气泡
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.value,
    required this.total,
    required this.pressed,
    required this.onDown,
    required this.onUpdate,
    required this.onUp,
  });

  final double value;
  final double total;
  final bool pressed;
  final ValueChanged<double> onDown;
  final ValueChanged<double> onUpdate;
  final ValueChanged<double> onUp;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double _last = 0;

  double _valueAt(Offset local, double width) {
    final total = widget.total <= 0 ? 0.0 : widget.total;
    final v = (local.dx / (width <= 0 ? 1 : width)).clamp(0.0, 1.0) * total;
    _last = v;
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final pct = widget.total <= 0
        ? 0.0
        : (widget.value / widget.total).clamp(0.0, 1.0);
    final pressed = widget.pressed;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        widget.onDown(_valueAt(d.localPosition, box.size.width));
      },
      onPanUpdate: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        widget.onUpdate(_valueAt(d.localPosition, box.size.width));
      },
      onPanEnd: (_) => widget.onUp(_last),
      // 手势被上层抢走时也要收尾，否则进度条会一直停在“按下”态
      onPanCancel: () => widget.onUp(_last),
      // 单击（无拖动）直达：Pan 永远不会触发 onPanEnd，
      // 不注册 Tap 的话“点一下 10:00”永远不跳转。
      onTapUp: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        widget.onUp(_valueAt(d.localPosition, box.size.width));
      },
      child: SizedBox(
        height: 34,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final x = w * pct;
            final r = pressed ? 9.0 : 6.0;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // 底轨
                Positioned(
                  left: 0,
                  right: 0,
                  top: 13,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    height: pressed ? 8 : 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(pressed ? 8 : 4),
                      color: Colors.white.withOpacity(0.22),
                    ),
                  ),
                ),
                // 已播放
                Positioned(
                  left: 0,
                  width: x,
                  top: 13,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    height: pressed ? 8 : 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(pressed ? 8 : 4),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF2F7FE8), Color(0xFF4F9CFF)],
                      ),
                      boxShadow: pressed
                          ? const [
                              BoxShadow(
                                color: Color(0x664F9CFF),
                                blurRadius: 12,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
                // 圆点
                Positioned(
                  left: (x - r).clamp(0.0, math.max(0.0, w - r * 2)),
                  top: pressed ? 8 : 10,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    width: pressed ? 18 : 12,
                    height: pressed ? 18 : 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withOpacity(
                            pressed ? 0.26 : 0.16,
                          ),
                          blurRadius: pressed ? 14 : 0,
                          spreadRadius: pressed ? 6 : 3,
                        ),
                      ],
                    ),
                  ),
                ),
                // 时间气泡已移除：拖动时中央大时间提示已经显示目标时间，
                // 两者同时出现会互相压住（用户反馈的「跳转时间和控件重叠」）。
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------- 玻璃弹层 ----------------

/// 通用玻璃面板容器：底部弹层的统一外观（与播放信息/码率面板共用）。
/// 播放页一律关闭实时模糊（blurEnabled=false），避免每次唤出都把视频压停。
/// 居中玻璃面板的容器（v1.7.32）
///
/// 原来是 `showModalBottomSheet` 的底部抽屉，四类弹层（变速/字幕/信息/样式）
/// 全都从屏幕底边推上来，遮住进度条又不方便单手够。统一改成居中卡片：
/// 固定最大宽度、最大高度留 12% 余量、内容超出时面板内部滚动。
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 470, maxHeight: h * 0.88),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xF2141A28),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 40,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: SingleChildScrollView(child: child),
        ),
      ),
    );
  }
}

/// 居中面板的路由：自带可点暗层、淡入缩放入场，退场走反向动画。
///
/// 为什么不用 `showGeneralDialog`：它底层的 `RawDialogRoute` 不接受返回手势，
/// 系统侧滑返回时面板会「啪」地消失。`PageRouteBuilder` 是标准 `PageRoute`，
/// 参与返回手势并驱动 [transitionsBuilder] 的反向播放。
class _GlassPanelRoute<T> extends PageRouteBuilder<T> {
  _GlassPanelRoute({required WidgetBuilder builder, super.settings})
    : super(
        opaque: false,
        barrierDismissible: true,
        barrierColor: const Color(0x99000000),
        barrierLabel: '关闭面板',
        transitionDuration: Anim.base,
        reverseTransitionDuration: Anim.fast,
        pageBuilder: (ctx, _, _) => builder(ctx),
        transitionsBuilder: (ctx, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Anim.curve,
            reverseCurve: Anim.curveIn,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      );
}

/// 倍速胶囊：非 1.0 倍速时高亮，避免和「字幕 / 画面比例」混淆
class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final boosted = label != '1×';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 120),
      child: Glass(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        radius: 15,
        blur: 16,
        blurEnabled: false,
        // 非 1 倍速时整体偏冷色调，作为「已加速」的视觉标记
        gradient: boosted
            ? const LinearGradient(
                colors: [Color(0x384F8CFF), Color(0x1E4F8CFF)],
              )
            : null,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.speed_rounded,
              size: 13,
              color: boosted ? AppColors.accent : Colors.white,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: boosted ? AppColors.accent : Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 字幕选择结果包装：区分「点关闭字幕」和「点外部关掉弹窗」。
/// 直接返回 SubtitleTrackInfo? 的话，二者都是 null，会把字幕误关。
class _SubPick {
  const _SubPick(this.track);
  final SubtitleTrackInfo? track;
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                // 关闭：手势返回之外再给一个明确的出口
                GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Colors.white.withOpacity(0.55),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9FB0CC),
                  ),
                ),
              ),
            ),
          Divider(height: 1, color: Colors.white.withOpacity(0.07)),
          const SizedBox(height: 6),
          ...children,
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.label,
    this.hint,
    this.selected = false,
    required this.onTap,
  });
  final String label;
  final String? hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected
                ? AppColors.accent.withOpacity(0.18)
                : Colors.white.withOpacity(0.04),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withOpacity(0.5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              if (hint != null)
                Text(
                  hint!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9FB0CC),
                  ),
                ),
              if (selected) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: AppColors.accent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.k, required this.v});
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              k,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9FB0CC)),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 视频渲染层：把原生播放器表面与「控件 / 进度条 / 字幕」所在的频繁重建树隔离。
///
/// 播放页每 300ms 全量 setState + 每次点按都会重建整页。若视频视图直接写在
/// 这棵树里，media_kit 的 Video / ExoPlayer 的 VideoPlayer 底层 Surface 会被反复
/// 重同步，表现为「点一下画面卡顿、回退几帧、甚至短暂暂停」。这里缓存
/// buildView() 产出的 widget 实例，只有播放器对象、就绪态或画面比例真正变化时才
/// 重建，彻底避免重建牵连到视频表面（与 Yamby 把原生播放器渲染与 UI 解耦的思路一致）。
class _VideoSurface extends StatefulWidget {
  final PlaybackController? player;
  final Widget placeholder;
  const _VideoSurface(this.player, this.placeholder);

  @override
  State<_VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<_VideoSurface> {
  Widget? _child;
  PlaybackController? _lastPlayer;
  bool _lastReady = false;
  PlaybackFit _lastFit = PlaybackFit.fit;

  @override
  void didUpdateWidget(covariant _VideoSurface old) {
    if (widget.player != old.player) {
      _child = null;
      _lastPlayer = null;
      _lastReady = false;
    }
    super.didUpdateWidget(old);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final ready = p?.ready ?? false;
    final fit = p?.fit ?? PlaybackFit.fit;
    if (_child == null ||
        p != _lastPlayer ||
        ready != _lastReady ||
        fit != _lastFit) {
      _lastPlayer = p;
      _lastReady = ready;
      _lastFit = fit;
      _child = (p != null && ready) ? p.buildView() : widget.placeholder;
    }
    return _child!;
  }
}
