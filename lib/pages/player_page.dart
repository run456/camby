import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:volume_controller/volume_controller.dart';

import '../app_state.dart';
import '../models.dart';
import '../player/playback.dart';
import '../subtitles/subtitles.dart';
import '../theme.dart';
import '../widgets/glass_toast.dart';
import '../widgets/liquid_press.dart';

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
  PlaybackEngine _engine = PlaybackEngine.exo;
  bool _initializing = true;
  bool _fallback = false;
  bool _controlsVisible = true;
  bool _locked = false;

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
  String _bufText = '';
  Timer? _bufTimer;
  bool _demoPlaying = true;
  double _demoPosition = 0;

  // 字幕 / 分集 / 画面信息
  SubtitleTrackInfo? _subtitle;
  List<SubtitleCue> _cues = const [];
  String _cueText = '';
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
    _open();
    _loadEpisodes();
    _resetHideTimer();
    _ticker = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      _tickCue();
      setState(() {});
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

  /// 缓冲状态：MPV 读 cache-speed（字节/秒）；Exo 用已缓冲位置兜底。
  /// 字段赋值即可，300ms ticker 会带上渲染。
  Future<void> _pollBuffer() async {
    final p = _player;
    if (p == null || !p.ready || !_isPlaying || _demo) {
      if (_bufText.isNotEmpty) _bufText = '';
      return;
    }
    if (p.engine == PlaybackEngine.mpv) {
      final bps = await p.cacheSpeedBytes();
      if (!mounted) return;
      if (bps != null && bps > 0) {
        _bufText = '缓冲 ${(bps / 1048576).toStringAsFixed(1)} MB/s';
        return;
      }
    }
    final buf = p.bufferedSeconds;
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

  bool get _hasPrev => _episodeIndex > 0;
  bool get _hasNext =>
      _episodeIndex >= 0 && _episodeIndex < _episodes.length - 1;

  void _goEpisode(int delta) {
    final next = _episodes[_episodeIndex + delta];
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
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
      setState(() {
        _player = p;
        _engine = engine;
        _fallback = false;
      });
      await prev?.dispose();
      await p.play();
      return true;
    } catch (_) {
      await p?.dispose();
      return false;
    }
  }

  Future<void> _switchEngine() async {
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
    showToast(context, '已切换至 ${target.label}');
    _resetHideTimer();
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
    _player?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  bool get _demo => _fallback || _player == null || !_player!.ready;

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
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    setState(() {});
  }

  void _updateScrub(double v) {
    _scrubPos = v.clamp(0.0, _totalSeconds);
    _previewSeek(_scrubPos);
    _armScrubWatch();
    if (mounted) setState(() {});
  }

  Future<void> _endScrub() async {
    final target = _scrubPos.clamp(0.0, _totalSeconds);
    _scrubbing = false;
    _scrubWatch?.cancel();
    if (mounted) setState(() {});
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
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _Sheet(
        title: '播放速度',
        children: speeds.map((s) {
          final label = s.toStringAsFixed(2)
              .replaceAll(RegExp(r'0+$'), '')
              .replaceAll(RegExp(r'\.$'), '');
          return _SheetRow(
            label: '$label×',
            selected: _playbackSpeed == s,
            onTap: () => Navigator.pop(ctx, s),
          );
        }).toList(),
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

  // ---------------- 字幕 / 信息 弹层 ----------------
  Future<void> _pickSubtitle() async {
    final tracks = widget.item.subtitles;
    if (tracks.isEmpty) {
      showToast(context, '该影片没有可用的外挂字幕');
      return;
    }
    final picked = await showModalBottomSheet<_SubPick>(
      context: context,
      backgroundColor: Colors.transparent,
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
              hint: t.displayTitle.isEmpty ? null : t.displayTitle,
              selected: _subtitle?.url == t.url,
              onTap: () => Navigator.pop(ctx, _SubPick(t)),
            ),
          ),
        ],
      ),
    );
    // 点弹窗外部关闭 → picked 为 null：什么都不做。
    // 以前这里把 null 当成「关闭字幕」，所以一碰画面字幕就没了。
    if (picked == null) return;
    if (picked.track?.url == _subtitle?.url) return;
    await _applySubtitle(picked.track);
  }

  /// 切换字幕：**不重建播放器**，因此不会丢进度。
  ///  · MPV：内核原生挂载，ASS 特效也能显示
  ///  · Exo：video_player 没有运行时挂字幕接口 → 用叠加层自己渲染
  Future<void> _applySubtitle(SubtitleTrackInfo? track) async {
    setState(() {
      _subtitle = track;
      if (track == null) {
        _cues = const [];
        _cueText = '';
      }
    });
    if (track == null) {
      await _player?.setSubtitle(null);
      showToast(context, '已关闭字幕');
      _resetHideTimer();
      return;
    }

    final native = await _player?.setSubtitle(track.url) ?? false;
    if (!native) {
      final cues = await _loadCues(track);
      if (!mounted) return;
      if (cues.isEmpty) {
        showToast(context, '该字幕无法作为文本显示（可能为图形字幕 PGS），可切 MPV 内核');
      } else {
        showToast(context, '字幕：${track.menuLabel}');
      }
    } else {
      setState(() {
        _cues = const [];
        _cueText = '';
      });
      showToast(context, '字幕：${track.menuLabel}');
    }
    _resetHideTimer();
  }

  /// 字幕下载通道：复用 App 的 Emby 鉴权（Token 头 + 忽略自签证书），
  /// 与视频同源，避免 Exo 字幕叠加层在 LAN 服务器上 401 / 证书失败。
  Future<String?> _subFetcher(String url) =>
      widget.state.server?.fetchText(url) ?? Future<String?>.value(null);

  /// 拉取文本字幕（Exo 叠加层用）。期间又换了字幕就丢弃本次结果。
  Future<List<SubtitleCue>> _loadCues(SubtitleTrackInfo track) async {
    final cues = await Subtitles.load(track.textUrl, fetcher: _subFetcher);
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
    final cues = await Subtitles.load(track.textUrl, fetcher: _subFetcher);
    if (!mounted || _subtitle?.url != track.url) return;
    setState(() => _cues = cues);
    if (cues.isEmpty) {
      showToast(context, '该字幕无法作为文本显示（可能为图形字幕 PGS），可切 MPV 内核');
    }
  }

  void _showInfo() {
    final item = widget.item;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
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
          _InfoRow(k: '音频', v: '${item.audioCodec} · ${item.audioChannels}ch'),
          _InfoRow(k: '封装', v: item.container),
          _InfoRow(
            k: '字幕',
            v: _subtitle == null
                ? '关闭'
                : '${_subtitle!.languageLabel} · ${_subtitle!.codecLabel}',
          ),
          _InfoRow(k: '倍速', v: _speedLabel),
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
            label: '切换内核（当前 ${_engine.short}）',
            onTap: () {
              Navigator.pop(ctx);
              _switchEngine();
            },
          ),
        ],
      ),
    );
  }

  // ---------------- 构建 ----------------
  @override
  Widget build(BuildContext context) {
    if (_demo && _demoPlaying && !_scrubbing && !_seeking) {
      _demoPosition = math.min(_demoPosition + 0.3, _totalSeconds);
      if (_demoPosition >= _totalSeconds) _demoPosition = 0;
    }
    final item = widget.item;
    final total = _totalSeconds;
    // 拖动中、以及松手后等待跳转确认期间，都显示预览位置，杜绝回弹
    final pos = (_scrubbing || _seeking) ? _scrubPos : _positionSeconds;
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
          onHorizontalDragCancel: () => unawaited(_endScrub()),
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

              // 双击快进提示：显示在对应半屏的上方，避开正中央的播放按钮，
              // 不再和播放/暂停圆钮重叠。
              if (_doubleTip != null)
                Align(
                  alignment: _doubleTipLeft
                      ? const Alignment(-0.55, -0.22)
                      : const Alignment(0.55, -0.22),
                  child: Glass(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    radius: 16,
                    blur: 20,
                    child: Text(
                      _doubleTip!,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
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
              // 位置随控制层显隐让位，避免压住进度条
              if (_cueText.isNotEmpty)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: _controlsVisible ? 128 : 56,
                  child: IgnorePointer(
                    child: Text(
                      _cueText,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        height: 1.32,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        // 四向描边：任何画面上都能读清
                        shadows: [
                          Shadow(
                            color: Color(0xE6000000),
                            blurRadius: 2,
                            offset: Offset(1, 1),
                          ),
                          Shadow(
                            color: Color(0xE6000000),
                            blurRadius: 2,
                            offset: Offset(-1, 1),
                          ),
                          Shadow(
                            color: Color(0xE6000000),
                            blurRadius: 2,
                            offset: Offset(1, -1),
                          ),
                          Shadow(
                            color: Color(0xE6000000),
                            blurRadius: 2,
                            offset: Offset(-1, -1),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                      _bottomBar(context, pos, total),
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
                    child: GlassIconButton(
                      icon: Icons.lock_rounded,
                      size: 44,
                      onTap: () => setState(() => _locked = false),
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
              GlassIconButton(
                icon: Icons.lock_open_rounded,
                iconSize: 15,
                onTap: () => setState(() => _locked = true),
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: Icons.info_outline_rounded,
                iconSize: 15,
                onTap: _showInfo,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _centerControls() {
    return Positioned.fill(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _GlassPlayBtn(
            icon: Icons.skip_previous_rounded,
            enabled: _hasPrev,
            onTap: () => _goEpisode(-1),
          ),
          const SizedBox(width: 26),
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
          const SizedBox(width: 26),
          _GlassPlayBtn(
            icon: Icons.skip_next_rounded,
            enabled: _hasNext,
            onTap: () => _goEpisode(1),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context, double pos, double total) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 10,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ProgressBar(
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
            const SizedBox(height: 2),
            // 时间单独一行：不再和两个胶囊挤在一行（挤爆会画出溢出条纹）
            Row(
              children: [
                Text(
                  _fmt(pos),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFC6D5EF),
                  ),
                ),
                const Spacer(),
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
            const SizedBox(height: 8),
            Row(
              children: [
                _Chip(
                  label: _subtitle == null
                      ? '字幕'
                      : '字幕 · ${_subtitle!.languageLabel}',
                  icon: Icons.subtitles_outlined,
                  onTap: _pickSubtitle,
                ),
                const SizedBox(width: 8),
                // 画面比例：自适配 / 满屏
                _Chip(
                  label: _fit == PlaybackFit.fill ? '满屏' : '自适配',
                  icon: Icons.aspect_ratio_rounded,
                  onTap: _toggleFit,
                ),
                const SizedBox(width: 8),
                // 倍速：紧挨画面比例，不再占用右侧竖排调节杆
                _Chip(
                  label: _speedLabel,
                  icon: Icons.speed_rounded,
                  onTap: _pickSpeed,
                ),
                const SizedBox(width: 10),
                // 缓冲速度替代原来的标题（标题顶栏已有，重复且占位）
                Expanded(
                  child: Text(
                    _bufText,
                    maxLines: 1,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8B94A7),
                    ),
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

/// 中央玻璃圆钮；enabled=false 时置灰且不可点
class _GlassPlayBtn extends StatelessWidget {
  const _GlassPlayBtn({
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.flipX = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

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
      onTap: enabled ? onTap : null,
      child: Transform.flip(
        flipX: flipX,
        child: Icon(
          icon,
          size: 23,
          color: enabled ? AppColors.ink : AppColors.ink.withOpacity(0.3),
        ),
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

/// 字幕选择结果包装：区分「点关闭字幕」和「点外部关掉弹窗」。
/// 直接返回 SubtitleTrackInfo? 的话，二者都是 null，会把字幕误关。
class _SubPick {
  const _SubPick(this.track);
  final SubtitleTrackInfo? track;
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF2141A28),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: Colors.white.withOpacity(0.25),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
              child: Row(
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            ...children,
            const SizedBox(height: 12),
          ],
        ),
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
