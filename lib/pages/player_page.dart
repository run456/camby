import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../layout.dart';
import '../app_state.dart';
import '../models.dart';
import '../player/boot_watch.dart';
import '../player/playback.dart';
import '../player/playback_plan.dart';
import '../player/display_caps.dart';
import '../player/subtitle_pick.dart';
import '../subtitles/subtitles.dart';
import '../subtitles/online_subtitle.dart';
import '../subtitles/subtitle_cache.dart';
import '../ugreen_resource.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/glass_sheet.dart';
import '../widgets/glass_toast.dart';
import '../widgets/liquid_press.dart';
import '../widgets/strm_boot_overlay.dart';
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

    /// 起播有结论时回调（首帧出来 / 明确失败）。
    /// 详情页的 STRM 加载弹窗靠它知道自己该关掉了。
    this.onBootSettled,

    /// 「额外部分」起播时指定的 MediaSource（-Cd1/-Cd2 等分段）。
    /// 非空时直接按该来源起播，不再走「主版本 → HLS 回退」的逻辑。
    this.mediaSourceId,

    /// 额外部分的显示名（用于播放页标题后缀，说明这是第几段）
    this.sourceLabel,
  });
  final MediaItem item;
  final AppState state;
  final SubtitleTrackInfo? subtitle;
  final double startSeconds;
  final VoidCallback? onBootSettled;
  final String? mediaSourceId;
  final String? sourceLabel;

  @override
  State<PlayerPage> createState() => PlayerPageState();
}

class PlayerPageState extends State<PlayerPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  PlaybackController? _player;

  /// 起播内核。设置页「默认播放内核」0=Exo / 1=MPV —— 之前在 initState 里
  /// 硬写 exo，导致设置项形同虚设（v1.7.29 bug1 的同类问题，本次一并根治）
  PlaybackEngine _engine = PlaybackEngine.exo;

  /// v2.0.83：本次播放的内核 / 色调映射 / 音频转码决策。
  late PlaybackPlan _plan;

  /// 实际起播地址（协商 / 转码 URL），切内核时必须复用它，
  /// 不能再用 item.videoUrl 把用户打回原片直连。
  String? _currentUrl;

  /// 协商结果，播放信息面板展示播放方式与诊断。
  PlaybackRoute? _route;

  /// 本轮起播试过的地址与内核真实报错（v2.0.90）。
  ///
  /// 绿联这类兼容实现取流失败时，Exo / libmpv 各自只会抛一句很含糊的异常，
  /// 页面上就退化成「无可用片源 · 模拟播放」。把每条候选的失败原因留下来，
  /// 播放信息面板和失败角标都能直接给出 403 / 404 / TLS 的区分。
  final List<String> _attempts = <String>[];

  /// 起播失败后是否已经自动换过 MPV 再试（每页只试一次，避免来回打转）
  bool _triedMpvOnFailure = false;

  /// 取流预检结果（v2.0.90），诊断面板与失败角标共用。
  final List<String> _probes = <String>[];

  /// 绿联取流能力探测结论（v2.0.91）。
  StreamCapability? _capability;

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

  /// ASS 特效渲染开关，默认开（仅 MPV 生效；设置行已按设计稿移除）
  bool _assSubtitle = true;

  /// 起播是否已经拿到结论（首帧出 或 明确失败）。
  /// 详情页的 STRM 加载弹窗通过 [PlayerPage.onBootSettled] 拿这个信号。
  final ValueNotifier<bool> _bootSettled = ValueNotifier<bool>(false);

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

  // 进出场黑幕：进出场时盖住整页，把横竖屏切换的系统旋转动画藏在黑幕后面
  bool _veiled = true;
  bool _revealed = false;
  bool _exiting = false;

  // 进度条按压（仅影响视觉粗细）
  bool _barPressed = false;

  // ---- 本次会话「真正看了多久」（v2.0.96）----
  // 以前用「结束位置 − 起播位置」当观看时长，从 12:00 续播、只看 1 分钟，
  // 就会被算成 12 分钟（观影日历里的「看了 12 分钟」）。这里在 300ms ticker
  // 里累加**位置的正向小步进**，拖动/续播定位造成的大跳变一律不计。
  double _watchedSec = 0;
  double _lastWatchPos = -1;
  bool _watchSessionOpen = false;

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

  // ---- 1.7.38 新增：字幕样式 / 硬解 / 播放上报 ----
  /// 叠加字幕的显示样式（持久化，见 SubtitleStyleStore）
  SubtitleStyle _subStyle = const SubtitleStyle();

  /// 设置页「记录观看历史」开关：关掉后既不上报，也不进「继续观看」
  bool _recordHistory = true;

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

  bool _bootOverlayDismissed = false;

  /// 起播加载弹窗是否可见（唯一一套：`StrmBootOverlay`）。
  ///
  /// 条件：还没出过首帧、不是演示/失败兜底、用户没点「继续等待」收起。
  /// 切内核时同样要显示 —— 否则点「切换 Exo」后画面会黑着没反应，
  /// 用户会以为没生效。
  bool get _bootOverlayVisible =>
      !_firstFrame && !_demo && !_fallback && !_bootOverlayDismissed;

  void _dismissBootOverlay() {
    setState(() => _bootOverlayDismissed = true);
    _resetHideTimer();
  }

  bool _demoPlaying = true;

  /// v1.7.64：屏幕常亮当前状态（避免每帧重复打平台通道）
  bool _wakelockOn = false;
  double _demoPosition = 0;

  // 字幕 / 分集 / 画面信息
  SubtitleTrackInfo? _subtitle;

  /// 当前挂载的在线字幕（非 Emby 服务端轨道）。底栏 / 信息面板靠它区分
  /// 「字幕关闭」与「用的是在线字幕」——只看 _subtitle == null 会误显示关闭。
  OnlineSubtitle? _onlineSubtitle;

  /// 当前在线字幕是**本机缓存**恢复的（而不是本次现搜的）。信息面板 / 底栏
  /// 据此显示「本机 · 迅雷」而不是「在线 · 迅雷」，避免用户以为又联网搜了一次。
  bool _subtitleFromCache = false;
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
    // 先用默认值占位，_applySavedPreferences() 读完设置后按真实内核重算。
    // 这样即使 SharedPreferences 异常，后续访问 _plan 也不会崩。
    _plan = resolvePlaybackPlan(item: widget.item, preferMpv: false);
    // v2.0.2：监听前后台切换 —— 用户直接上滑杀掉 App（或切到后台很久）
    // 时不会走 dispose，服务端就永远收不到 Stopped，活动日志里只剩
    // 「开始播放」，观看时长对不上。退到后台时补发一次 Stopped。
    WidgetsBinding.instance.addObserver(this);
    _subtitle = widget.subtitle;
    // 屏蔽系统自带音量条，只保留 App 内的玻璃音量指示
    VolumeController.instance.showSystemUI = false;
    // 横屏切换延后到路由淡入完成之后：此时页面已被黑幕盖住，
    // 系统的旋转动画只会转一块纯黑，不会再出现详情页歪斜旋转
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 280), () {
        if (!mounted) return;
        // 方向策略（已定）：**手机与平板一律强制横屏**。
        // 这样播放器只有一套布局与一套控件尺寸，不会因为竖屏平板/折叠屏
        // 再分叉出第二套控件树（按钮间距、字幕基准、手势区全都要另算一遍）。
        // 代价：平板竖持时用户需把机器转过来——取舍理由是「代码规整 +
        // 控件行为两端一致」优先。若日后要支持平板竖屏播放，只需在此处
        // 按 breakpoint 分支（平板放行 portraitUp 并额外做一版竖屏控件布局），
        // 其余页面/播放器逻辑都不受影响。
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
    // 注意：设置必须全部读完再开播。
    // 之前这里是 _applySavedPreferences(); _open(); 两句并发 —— 前者要 await
    // SharedPreferences.getInstance()（首次有磁盘 IO），后者是同步往下跑的，
    // 等 _start() 用 _engine 的时候设置根本还没读进来，于是「设置里选 MPV，
    // 实际永远开 Exo」。这是截图里顶栏恒显示 Exo 的真实原因。
    unawaited(_boot());
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
      _accrueWatched();
      _checkAutoNext();
      // v1.7.64：播放中保持屏幕常亮，暂停/退出时解除。
      // 放在 300ms ticker 里按「状态翻转」触发，避免每帧都打平台通道。
      final shouldStayOn = _isPlaying;
      if (shouldStayOn != _wakelockOn) {
        _wakelockOn = shouldStayOn;
        unawaited(WakelockPlus.toggle(enable: shouldStayOn));
      }
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
    // 起播彻底失败（地址不通 / 演示兜底）：这里立刻给结论，
    // 别让外部弹窗一直等到 25 秒超时
    if (_fallback || _demo) _markBootSettled();
    // 画面已挂上（黑幕下完成旋转），稍作停顿揭开，形成"黑 → 画面"的入画感
    if (mounted) {
      await Future.delayed(const Duration(milliseconds: 160));
      _reveal();
    }
    await _seekToStart();
    if (mounted) setState(() => _initializing = false);
    // v2.0.1：先发会话开始事件（带续播位置），再写 UserData。
    // 顺序很重要——若先写进度、后发一条 PositionTicks=0 的 Playing，
    // 服务端的续播位置会被重置，其它设备就看不到「继续观看」。
    if (!_demo && _recordHistory) {
      _openWatchSession();
      // 起播位置用**用户选择的续播点**，而不是「此刻播放器报的位置」：
      // 内核刚 open 时位置常常还是 0，服务端据此算时长就会把 12:00 续播
      // 记成「本次看了 12 分钟」。
      final startSec = widget.startSeconds > 0
          ? widget.startSeconds
          : _positionSeconds;
      unawaited(
        widget.state.reportServerPlaybackStart(
          widget.item.id,
          positionTicks: (startSec * 10000000).round(),
          playMethod: _route?.playMethod ?? 'DirectPlay',
          mediaSourceId: widget.mediaSourceId ?? widget.item.mediaSourceId,
          audioStreamIndex: widget.item.audioStreamIndex,
        ),
      );
    }
    // 进入播放即向服务端上报一次进度：Emby 的会话列表出现本设备，
    // 首页「继续观看」位置随后由 _reportProgressNow() 持续同步
    unawaited(_reportProgressNow());
    _startReportTimer();
    _startBootWatch();
  }

  // ---------------- 起播看护 ----------------

  /// 起播有结论了（首帧出来 / 明确失败），通知外部收起加载 UI
  void _markBootSettled() {
    if (_bootSettled.value) return;
    _bootSettled.value = true;
    widget.onBootSettled?.call();
  }

  /// 切到 Exo 内核（加载弹窗上的唯一出口）
  ///
  /// v1.7.55 修的两个真问题：
  ///  · 旧实现调 `_switchEngine()` 是**取反**的 —— 当前已经是 Exo 时会切回
  ///    MPV，点一次等于没切；
  ///  · 旧实现里 `_switchEngine` 末尾会把 `_autoFellBack` 复位成 false，
  ///    把「用户手动切了，别再自动回退」的清空，于是 10 秒后又被回退一次。
  /// 现在这里按目标内核显式切、切完把回退标记锁死，并重新开始计等待时间。
  Future<void> switchToExo() async {
    if (!mounted) return;
    if (_engine == PlaybackEngine.exo) {
      // 已经是 Exo：只可能从弹窗点到，给个明确反馈，别让用户以为按钮坏了
      showToast(context, '当前已是 Exo 内核');
      return;
    }
    _autoFellBack = true;
    // 失败提示由 _switchTo 统一给出（它知道 ok 与否），这里只补成功那条
    await _switchTo(PlaybackEngine.exo, silent: true);
    if (mounted && _engine == PlaybackEngine.exo) {
      showToast(
        context,
        '已切换到 Exo 内核',
        icon: Icons.check_circle_outline_rounded,
      );
    }
  }

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
        _markBootSettled();
        return;
      }
      final secs = DateTime.now().difference(_bootAt!).inMilliseconds / 1000.0;
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
  ///
  /// v1.7.55：这条自动回退原来还挂在「详情页那个弹窗路由」的计时上，改成
  /// 由播放页自身看护计时驱动，弹窗只是被动显示 —— 所以无论用户有没有看到
  /// 弹窗、有没有点过按钮，超时都一定会切。
  Future<void> _autoFallbackToExo() async {
    if (!mounted || _engine == PlaybackEngine.exo) return;
    showToast(
      context,
      'MPV 10 秒未出画面，已自动切到 Exo',
      icon: Icons.swap_horiz_rounded,
    );
    await _switchTo(PlaybackEngine.exo, silent: true);
  }

  // ---------------- 字幕样式 / 码率 / 硬解 / 上报 ----------------

  /// 读取持久化的字幕样式（首次进入为默认值）
  /// 读取设置页里对播放器有实际作用的项：内核、码率上限、MPV 缓存档位。
  /// 全部在 `_open()` 之前完成，避免开了没效果。
  /// 起播前把该读的设置全部读完，再开播（v1.7.49 修「设置选 MPV 却总是 Exo」）
  ///
  /// 顺序强制串行：读设置 → 定字幕轨 → 开播。任一步失败都继续往下，
  /// 不能让一个 SharedPreferences 异常把整个播放页卡在黑幕里。
  Future<void> _boot() async {
    await _applySavedPreferences();
    // 设备 HDR 能力只读一次，供播放信息面板解释「为什么是 SDR 输出」。
    unawaited(DisplayCaps.load());
    if (!mounted) return;
    // 外部显式传了 subtitle（详情页点某条字幕进入）就不覆盖用户意图
    if (widget.subtitle == null && !_userPickedSub) {
      await _autoPickSubtitle();
      if (!mounted) return;
    }
    // 本机缓存字幕：没有服务端字幕轨时优先复用，省掉再次联网搜索
    await _restoreCachedSubtitle();
    if (!mounted) return;
    await _open();
  }

  /// 起播时恢复本机缓存的在线字幕。
  ///
  /// 三个不覆盖条件：外部显式指定了字幕轨、用户已手动选过轨、影片本身有
  /// Emby 服务端字幕轨。最后一条尤其重要 —— 服务端字幕是用户精心配好的，
  /// 不能被一条缓存的在线搜索结果顶掉。
  ///
  /// 缓存里存的是解码后的字幕原文，一律走 App 叠加层渲染；ASS 特效字幕在
  /// 这里会退化为纯文本（首次在线加载时若用 MPV 仍走内核原生轨）。
  Future<void> _restoreCachedSubtitle() async {
    if (widget.subtitle != null || _userPickedSub) return;
    if (widget.item.subtitles.isNotEmpty) return;
    final cached = await OnlineSubtitleCache.load(widget.item.id);
    if (cached == null || !mounted) return;
    final cues = Subtitles.parseAny(cached.text);
    if (cues.isEmpty) return;
    setState(() {
      _subtitle = null;
      _onlineSubtitle = cached.toOnlineSubtitle();
      _subtitleFromCache = true;
      _cues = cues;
      _cueText = '';
    });
    _userPickedSub = true;
  }

  Future<void> _applySavedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final eng = prefs.getInt('set_play_engine') ?? 0;
      final cache = prefs.getInt('set_cache_size') ?? 0;
      // v1.7.50：尊重用户选的内核。之前 strm 条目会无视设置强制 Exo，
      // 表现为「设置选了 MPV，播放页却显示 Exo」，用户当成 bug 上报。
      _engine = eng == 1 ? PlaybackEngine.mpv : PlaybackEngine.exo;
      _cacheBytes = _cacheSizes[cache.clamp(0, _cacheSizes.length - 1)];
      // v2.0.83：DV 保底转码开关。设备的 libmpv 不带 gpu-next 时，
      // 让服务端把视频重编码成 SDR，牺牲画质换取绝不偏色。
      final dvTranscode = prefs.getBool('set_dv_transcode') ?? false;
      _plan = resolvePlaybackPlan(
        item: widget.item,
        preferMpv: _engine == PlaybackEngine.mpv,
        forceVideoTranscode:
            dvTranscode && widget.item.effectiveRange.isDolbyVision,
      );
      // Exo 侧没有任何色调映射 / DV 参数入口，HDR 与 DV 一律切 MPV。
      // 用户仍可在本页手动切回 Exo（尊重选择），但播放信息会给出提示。
      if (_plan.forceMpv) _engine = PlaybackEngine.mpv;
      // v2.0.93：这台服务器已经证实 Exo 拉不动流（见 AppState 里那条注释），
      // 就别再让用户每次陪 Exo 黑屏十几秒 —— 直接上 MPV。用户仍可在播放页
      // 顶栏手动切回 Exo，那属于「我就是要试一次」的主动选择，不拦。
      if (_engine == PlaybackEngine.exo &&
          widget.state.exoStreamUnavailable &&
          (widget.state.server?.isUgreen ?? false)) {
        _engine = PlaybackEngine.mpv;
      }
      // v1.7.50：自动连播 / strm 优先 Exo / ASS 特效的设置行已按设计稿移除，
      // 行为固定取默认值（开 / 开 / 开），字段保留供播放流程引用。
    } catch (_) {}
  }

  Future<void> _loadRecordHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool('set_record_history') ?? true;
      if (mounted) _recordHistory = v;
    } catch (_) {}
  }

  /// 自动选轨（v1.7.47 接通）。
  ///
  /// 「字幕默认语言」设置行已按设计稿移除，固定按 auto 规则挑一条，
  /// 交给 [_start] 在建立内核时挂上。
  ///
  /// 只影响「进入播放页时的初选」：用户一旦在字幕菜单里手动选过，本页
  /// 后续切集也不会被自动选轨覆盖（[_userPickedSub]）。
  Future<void> _autoPickSubtitle() async {
    // 用户已手动定过轨（含「关闭字幕」）→ 尊重他，自动选轨不插手
    if (_userPickedSub) return;
    final pick = SubtitlePicker.pick(widget.item.subtitles, SubtitlePref.auto);
    if (!mounted) return;
    setState(() => _subtitle = pick.track);
    // 已经建好内核（切集等场景）：补挂一次
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
      GlassPanelRoute<void>(
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
    // v1.7.65：心跳改为 30 秒（用户确认）。服务端 UserData 里的播放位置据此
    // 始终接近当前位置；失败会进入 AppState 的待上报队列，下次成功时补发。
    _reportTimer = Timer.periodic(
      const Duration(seconds: 30),
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
    // v1.7.65：进度统一经 AppState 上报入口，带「已看完」标记与失败重试队列，
    // 保证另一台设备能读到续播位置与已看状态。
    final played = total > 0 && pos >= total * 0.95;
    unawaited(
      widget.state.reportServerProgress(
        widget.item.id,
        (pos * 10000000).round(),
        played: played,
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

  /// 顶栏标题：额外部分（-Cd1 / -Cd2 分段）后面标注来源名，避免误以为在播主版本
  String get _displayTitle {
    final label = widget.sourceLabel;
    if (label == null || label.isEmpty) return widget.item.name;
    return '${widget.item.name} · $label';
  }

  Future<void> _tryOpen() async {
    final srv = widget.state.server;
    // 额外部分（-Cd1 / -Cd2 等分段）优先用它自己的 MediaSourceId。
    final sourceId = widget.mediaSourceId ?? widget.item.mediaSourceId;

    // v2.0.83：按片源能力**先算出正确地址**，不再「先直连、等无声或
    // 黑屏十几秒再回退」。协商出的 URL 自带 MediaSourceId /
    // PlaySessionId / StartTimeTicks，转码流续播也不会被打回片头。
    PlaybackRoute? route;
    if (srv != null) {
      try {
        route = await srv.resolvePlayback(
          item: widget.item,
          plan: _plan,
          startSeconds: widget.startSeconds,
          mediaSourceId: sourceId,
        );
      } catch (_) {}
    }
    _route = route;

    // v2.0.90：取流请求头由 `headersFor` 按目标地址决定 —— 绿联兼容层只认
    // `X-Emby-Token`，而 Exo / libmpv 各有独立网络栈，之前完全没带，这是
    // 「图片出得来、视频放不了」的直接原因（兼容方案文档 6.4）。
    // 注意不能无脑全站注入：strm 指向的第三方 CDN 不该拿到访问令牌。

    final primary = route?.url ?? widget.item.videoUrl;
    final direct =
        route?.fallbackUrl ??
        (srv != null
            ? srv.streamUrl(widget.item.id, mediaSourceId: sourceId)
            : null);
    final hls = srv != null
        ? srv.streamUrl(widget.item.id, mediaSourceId: sourceId, direct: false)
        : null;

    // 绿联：**先问服务端声明了哪些取流协议**，按协议拼端点再试。
    // v2.0.90 是猜几条常见路径，真机全 404 —— 因为绿联只在
    // MediaSources[].SupportedStreamingProtocols 登记过的协议才暴露端点，
    // 没登记就 404（不是 403）。所以猜测这条路是死的，必须按声明走。
    final urls = <String>[];
    StreamCapability? cap;
    if (srv != null && srv.isUgreen) {
      try {
        final resolved = await srv.resolveStreamUrls(widget.item);
        urls.addAll(resolved);
      } catch (_) {}
      cap = srv.lastStreamCapability;
    } else {
      for (final u in <String?>[primary, direct, hls]) {
        if (u != null && u.isNotEmpty && !urls.contains(u)) urls.add(u);
      }
    }
    _capability = cap;

    _attempts.clear();
    _probes.clear();

    // 绿联：先并行预检（只读响应头），把能用的地址排前面。
    // 没有这一步，一个 403 的端点会让 Exo 和 MPV 各自空转到超时，
    // 用户面对的是几十秒到两分钟的黑屏，最后只得到一句「播放失败」。
    var ordered = urls;
    var allRejected = false;
    if (srv != null && srv.isUgreen && urls.length > 1) {
      final probes = await Future.wait(
        urls.map(
          (u) => srv.probeStream(
            u,
            label: _shortUrl(u),
            // 预检只是排序 / 快速失败用，不能拖慢正常起播：
            // 局域网里 `Range: bytes=0-0` 的响应头一般 <1s，3s 足够。
            timeout: const Duration(seconds: 3),
          ),
        ),
      );
      for (final p in probes) {
        _probes.add(p.summary);
      }
      final good = <String>[];
      final bad = <String>[];
      for (var i = 0; i < urls.length; i++) {
        (probes[i].ok ? good : bad).add(urls[i]);
      }
      if (good.isNotEmpty) {
        ordered = <String>[...good, ...bad];
      } else {
        // 全部被拒：只有拿到的都是**明确的鉴权 / 路径错误**才快速收尾。
        // 超时、416（服务器不接受 Range）这类不算，照旧把所有候选跑一遍，
        // 免得把本可以播的地址误判掉。
        allRejected = probes.every(
          (p) => !shouldTryNextStream(p.statusCode),
        );
        ordered = allRejected ? urls.take(1).toList() : urls;
      }
    }

    if (await _tryAll(_engine, ordered)) return;

    // 一路试到 Exo 全败：换 MPV 再走一遍。
    // 理由不是「MPV 更兼容」这么笼统 —— 而是两者的失败面不同：Exo 走
    // Android HttpURLConnection（受原生 trust-all 影响），libmpv 走自带
    // ffmpeg（受 `tls-verify=no` 影响，且能解 Exo 不认的容器），任一侧
    // 走通就能播，比原地报「无可用片源」有用得多。
    if (_engine == PlaybackEngine.exo && !_triedMpvOnFailure && !allRejected) {
      _triedMpvOnFailure = true;
      // v2.0.94：只有「已经拿到实测可用地址、Exo 仍拉不动」才算内核问题。
      // v2.0.93 把 404 的地址错误当成 Exo 不行，白白让用户下次直接走
      // MPV（MPV 拿同一条错地址同样 404）—— 判定收紧到地址正确之后。
      if (srv != null && srv.isUgreen && (_capability?.hasVerifiedUrl ?? false)) {
        widget.state.markExoStreamUnavailable();
      }
      if (await _tryAll(PlaybackEngine.mpv, ordered)) return;
    }

    _fallback = true;
  }

  /// 用指定内核依次尝试一组地址；任一成功即返回 true。
  Future<bool> _tryAll(PlaybackEngine engine, List<String> urls) async {
    for (var i = 0; i < urls.length; i++) {
      if (!mounted) return false;
      // gpu-next 只给首选地址保留：后续候选已经是「首选失败」之后的兜底，
      // 不该再被同一个起不来的 VideoController 卡住。
      final ok = await _start(
        engine,
        urls[i],
        useGpuNextOverride: (i > 0 && _plan.useGpuNext) ? false : null,
      );
      if (ok) return true;
    }
    return false;
  }

  /// [useGpuNextOverride] 只用于回退：DV 片优先试 gpu-next，
  /// 万一设备捆绑的 libmpv 不支持它，后续尝试用普通 vo 重建，
  /// 不让整条回退链都卡在同一个起不来的 VideoController 上。
  Future<bool> _start(
    PlaybackEngine engine,
    String url, {
    bool? useGpuNextOverride,
  }) async {
    // 鉴权头按目标主机过滤：只有落在服务器本机才注入（见 headersFor）
    final headers =
        widget.state.server?.headersFor(url) ?? const <String, String>{};
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
          useGpuNext: useGpuNextOverride ?? _plan.useGpuNext,
          // v2.0.90：libmpv 的 TLS 是 ffmpeg 自己做的，原生 trust-all
          // 管不到，必须显式关校验，否则绿联自签证书下切 MPV 也是黑屏。
          ignoreSsl: widget.state.ignoreSslErrors,
        );
      }
      p.fit = _fit;
      // v1.7.58：只有 ASS/SSA 才交给 MPV 内核渲染（保留特效）；SRT/VTT
      // 一律走 App 叠加层，两内核外观统一（白字 + 半透明背景块），
      // 样式面板也必然生效。
      await p.open(
        url,
        subtitleUrl: (p.nativeSubtitles && _isAssUrl(_subtitle?.url))
            ? _subtitle?.url
            : null,
        audioCodec: widget.item.audioCodec,
        plan: _plan,
        headers: headers,
      );
      await p.setSpeed(_playbackSpeed);
      // v2.0.93：libmpv 的 open 是异步的 —— 收下 loadfile 就返回，
      // 真正的 HTTP 失败要过一会儿才写进 `path` 属性。绿联这种端点
      // 「探测 206 但内核拉不动」的场景，如果不在这里等一下，就会出现
      // 「进度条在走、画面全黑、诊断里只有一条记录」的哑火。
      if (engine == PlaybackEngine.mpv &&
          (widget.state.server?.isUgreen ?? false)) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final mpvErr = p.lastError;
        // 不在这里 dispose：外层 catch 会统一收尾，重复 dispose 反而会
        // 让 media_kit 抛「already disposed」把真实错因盖掉。
        if (mpvErr.isNotEmpty) throw StateError('libmpv: $mpvErr');
      }
      if (!mounted) {
        await p.dispose();
        return false;
      }
      final sub = _subtitle;
      if (sub != null) {
        if (sub.isImage) {
          // 图像字幕走 MPV 内封轨（open 时 subtitleUrl 已为 null，不下载 .srt）。
          // Exo 不支持图像字幕，setEmbeddedSubtitle 返回 false 即忽略。
          unawaited(
            p.setEmbeddedSubtitle(
              language: sub.language,
              streamIndex: sub.index,
            ),
          );
        } else if (!(p.nativeSubtitles && _isAssUrl(sub.url))) {
          unawaited(_loadCuesFor(sub));
        }
      }
      _currentUrl = url;
      final prev = _player;
      // p 在 setState 闭包里不会被提升到非空，这里先取出来
      final hw = p.hardwareDecode;
      setState(() {
        _player = p;
        _engine = engine;
        _fallback = false;
        _hw = hw;
        _attempts.clear();
      });
      await prev?.dispose();
      await p.play();
      // 起播成功：本次打开播放页只记一次本机播放次数（切内核会再调 _start，
      // 由 _localCounted 兜底避免重复计数），用于「偏好影片」统计。
      if (!_localCounted) {
        _localCounted = true;
        widget.state.addLocalPlay(widget.item.id);
      }
      // 新建的内核（尤其是 MPV）需要重新下发一次字幕样式与 ASS 开关
      unawaited(p.applySubtitleStyle(_subStyle));
      unawaited(p.setAssRendering(_assSubtitle));
      return true;
    } catch (e) {
      final le = p?.lastError ?? '';
      // v2.0.93：标出是哪个内核失败 —— 两个内核的网络栈完全不同，
      // 混在一起看根本分不清是「Exo 的 Range 不被接受」还是「MPV 证书」。
      final tag = engine == PlaybackEngine.exo ? 'Exo' : 'MPV';
      _attempts.add(
        '$tag · ${_shortUrl(url)} → '
        '${le.isEmpty ? _shortErr('$e') : _shortErr(le)}'
        '${headers.isEmpty ? '（未带鉴权头）' : ''}',
      );
      await p?.dispose();
      return false;
    }
  }

  /// 诊断用：只保留路径 + 关键 query，避免把 api_key 整串印到界面上。
  String _shortUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    final q = u.queryParameters;
    final keep = <String>[
      if (q['Static'] != null) 'Static=${q['Static']}',
      if (q['MediaSourceId'] != null) 'ms',
    ];
    return '${u.path}${keep.isEmpty ? '' : '?${keep.join('&')}'}';
  }

  String _shortErr(String e) {
    final s = e.replaceAll(RegExp(r'\s+'), ' ').trim();
    // ExoPlayer 的报错里真实状态码埋在长串来源栈中间，单独拎出来更可读
    final m = RegExp(r'(?:Response code|responseCode|status code)[:=\s]*(\d{3})',
            caseSensitive: false)
        .firstMatch(s);
    if (m != null) return 'HTTP ${m.group(1)}';
    if (s.contains('Handshake') || s.contains('CERTIFICATE')) return 'TLS 证书被拒';
    if (s.contains('403') || s.contains('Forbidden')) return 'HTTP 403';
    if (s.contains('404')) return 'HTTP 404';
    // v2.0.93：416 是「Range 不被接受」的典型信号 —— 探测用闭合区间
    // （bytes=0-0）能过，播放器用开放区间（bytes=0-）就可能被拒。
    if (s.contains('416') || s.contains('Range Not Satisfiable')) {
      return 'HTTP 416（不支持 Range）';
    }
    if (RegExp(r'\b5\d\d\b').hasMatch(s)) {
      final m2 = RegExp(r'\b5\d\d\b').firstMatch(s);
      return 'HTTP ${m2?.group(0)}';
    }
    if (s.contains('timed out') || s.contains('Timeout')) return '连接超时';
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  /// 顶栏胶囊点击：在 MPV / Exo 之间来回切（v1.7.56 修）
  ///
  /// 之前这里写的是 `onTap: _switchEngine` —— 顶栏胶囊的 onTap 是
  /// `VoidCallback?`，而 `_switchEngine` 的签名是
  /// `Future<void> Function({bool silent})`。Dart 允许把「带可选命名参数的
  /// 函数」赋给无参回调，于是编译通过、点击也确实会调，但**返回值被静默丢弃**：
  /// 切换过程中的异常、以及 `silent` 的语义全部失控，表现出来就是
  /// 「点了没反应」。现在改成显式无参回调，并把 Future 显式交出去。
  void _toggleEngine() {
    unawaited(_switchEngine(silent: false));
  }

  Future<void> _switchEngine({bool silent = false}) async {
    final target = _engine == PlaybackEngine.exo
        ? PlaybackEngine.mpv
        : PlaybackEngine.exo;
    if (!mounted) return;
    // v2.0.83：Exo 没有色调映射入口，HDR/DV 片切过去大概率发灰或发绿发紫。
    // 只提示、不拦着 —— 用户可能有自己的理由。
    if (!silent && target == PlaybackEngine.exo && _plan.range.isHdr) {
      showToast(
        context,
        'HDR / DV 片源建议用 MPV，Exo 可能偏色',
        icon: Icons.info_outline_rounded,
      );
    }
    // 先给一条「正在切换」的即时反馈：换内核要重建播放器，冷启动可能 1–3 秒，
    // 期间画面还是旧内核的帧，没有提示用户会以为点空了
    if (!silent) {
      showToast(
        context,
        '正在切换到 ${target.label} 内核…',
        icon: Icons.swap_horiz_rounded,
      );
    }
    await _switchTo(target, silent: true);
    if (mounted && !silent) {
      showToast(
        context,
        '已切换到 ${target.label} 内核',
        icon: Icons.check_circle_outline_rounded,
      );
    }
  }

  /// 切到指定内核（保留进度与播放/暂停状态），切换期间保持加载弹窗可见
  Future<void> _switchTo(PlaybackEngine target, {bool silent = false}) async {
    if (!mounted) return;
    if (_engine == target) {
      if (!silent) showToast(context, '当前已是 ${target.label}');
      return;
    }
    final pos = _positionSeconds;
    final wasPlaying = _isPlaying;
    final url = _currentUrl ?? widget.item.videoUrl;
    if (url == null) {
      setState(() => _engine = target);
      return;
    }
    setState(() => _initializing = true);
    await _player?.dispose();
    _player = null;
    // 「继续等待」收起过弹窗的话，切内核要重新亮出来（要有反馈）
    _bootOverlayDismissed = false;
    final ok = await _start(target, url);
    if (ok && pos > 1) {
      await _player?.seek(pos);
      if (!wasPlaying) await _player?.pause();
    }
    // v1.7.58：字幕挂载由 _start 统一按类型分发（ASS 走内核、文本走
    // 叠加层），这里不再无条件清叠加层——否则 MPV 下 SRT 会被清成空白。
    if (!mounted) return;
    setState(() => _initializing = false);
    // 切换失败（地址不通 / 内核建不起来）必须明说，否则用户只会看到
    // 「提示了正在切换，然后顶栏内核没变」，比不提示更让人困惑
    if (!ok) {
      showToast(
        context,
        '切换到 ${target.label} 失败，请检查片源或稍后重试',
        icon: Icons.error_outline_rounded,
      );
    }
    _resetHideTimer();
    // 新内核重新计时。注意不要复位 _autoFellBack：两个方向的意义不同 ——
    //  · 用户/自动已经退到 Exo → 不该再自动回退（回退只对 MPV 生效）
    //  · 用户手动切回 MPV → 由调用方显式放行一次
    // v1.7.54 之前这里无条件复位，导致在弹窗里切完 Exo 又被回退一次。
    if (target == PlaybackEngine.mpv) _autoFellBack = false;
    _startBootWatch();
  }

  @override
  /// 退到后台 / 被系统回收前补发一次 Stopped（v2.0.2）。
  ///
  /// 直接上滑杀 App 不会走 dispose，服务端只能看到 Start 看不到 Stop，
  /// 统计页的观看时长永远配不上对；这里在后台切换时兜一次。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _sessionEnded) {
      _sessionEnded = false;
      if (!_demo && _recordHistory) {
        _openWatchSession();
        unawaited(
          widget.state.reportServerPlaybackStart(
            widget.item.id,
            positionTicks: (_positionSeconds * 10000000).round(),
            playMethod: _route?.playMethod ?? 'DirectPlay',
            mediaSourceId: widget.mediaSourceId ?? widget.item.mediaSourceId,
            audioStreamIndex: widget.item.audioStreamIndex,
          ),
        );
      }
      return;
    }
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    if (_demo || !_recordHistory) return;
    final pos = _positionSeconds;
    final total = _totalSeconds;
    unawaited(
      widget.state.reportServerPlaybackStop(
        widget.item.id,
        (pos * 10000000).round(),
        played: total > 0 && pos >= total * 0.95,
        watchedSeconds: _watchedSec,
      ),
    );
    // 会话已结束，回到前台要重新起一段（否则后续心跳都成了孤立事件）
    _sessionEnded = true;
    _watchSessionOpen = false;
  }

  /// 后台补发过 Stopped：回到前台时重新发一次 Playing 续上会话
  bool _sessionEnded = false;

  /// 本次打开播放页是否已记过本机播放次数（切内核会再调 _start，靠它去重）
  bool _localCounted = false;

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 退出播放页恢复系统音量条
    VolumeController.instance.showSystemUI = true;
    // 退出播放页解除播放常亮（v1.7.64）
    unawaited(WakelockPlus.disable());
    _hideTimer?.cancel();
    _ticker?.cancel();
    _bufTimer?.cancel();
    _doubleTimer?.cancel();
    _scrubWatch?.cancel();
    _revealTimer?.cancel();
    // 退出前最后一次同步播放位置：其它设备上的「继续观看」立刻跟上
    _reportTimer?.cancel();
    _reportTimer = null;
    // v1.7.73：会话型播放停止事件（/Sessions/Stopped）—— 与起播时的 Start
    // 配对，服务端活动日志才能推算出观看时长（统计页「每日观看时长」）
    if (!_demo && _recordHistory) {
      final total = _totalSeconds;
      final pos = _positionSeconds;
      unawaited(
        widget.state.reportServerPlaybackStop(
          widget.item.id,
          (pos * 10000000).round(),
          played: total > 0 && pos >= total * 0.95,
          watchedSeconds: _watchedSec,
        ),
      );
    }
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

  /// 跳转后的「粘滞」显示（v1.7.60）。
  ///
  /// seek 发出后 libmpv / Exo 的 position 回调还会滞后几百毫秒地报旧值，
  /// 若立刻把显示交还给真实位置，圆点会先弹回起点再跳到目标（观感像卡顿）。
  /// 这里在跳转完成后把显示位置粘在目标一小段时间，等真实位置追上再交还。
  double? _settlePos;
  DateTime? _settleUntil;

  bool get _settleActive =>
      _settlePos != null &&
      _settleUntil != null &&
      DateTime.now().isBefore(_settleUntil!);

  /// 把当前应显示的进度推给 [_posNv]（拖动中取预览位置，避免回弹）
  void _syncPos() {
    final p = (_scrubbing || _seeking)
        ? _scrubPos
        : (_settleActive ? _settlePos! : _positionSeconds);
    if ((_posNv.value - p).abs() > 0.01) _posNv.value = p;
  }

  /// 累加「本次真正看了多久」（v2.0.96）。
  ///
  /// 判定规则：只有**播放中**、且位置是**小步向前**（300ms ticker 下 ≤1.5s）
  /// 时才算观看；拖动进度条、续播定位、跳集都会产生大跳变，直接跳过。
  /// 暂停时位置不动，自然也不累加。
  void _accrueWatched() {
    if (_demo || !_recordHistory) return;
    final pos = _positionSeconds;
    final last = _lastWatchPos;
    _lastWatchPos = pos;
    if (last < 0) return;
    if (!_isPlaying || _scrubbing || _seeking) return;
    final d = pos - last;
    if (d > 0 && d <= 1.5) _watchedSec += d;
  }

  /// 开一段「本机观看会话」（v2.0.96）。
  ///
  /// 切内核会重走 `_start`，但那是**同一场观看**，不能把已累计的时长清零，
  /// 所以用 [_watchSessionOpen] 做一次性闸门；退后台再回来时由
  /// `didChangeAppLifecycleState` 显式关掉，回到前台重新开一段。
  void _openWatchSession() {
    if (_watchSessionOpen) return;
    _watchSessionOpen = true;
    _watchedSec = 0;
    _lastWatchPos = -1;
  }

  /// 粘滞到期交还：等到真实位置追上目标（差 ≤1s）或窗口结束。
  Future<void> _waitSettleOut(int seq, double t) async {
    for (var i = 0; i < 12; i++) {
      await Future.delayed(const Duration(milliseconds: 90));
      if (!mounted || seq != _seekSeq) return; // 已被更新的操作取代
      if ((_positionSeconds - t).abs() <= 1.0) break;
    }
    if (!mounted || seq != _seekSeq) return;
    setState(() {
      _settlePos = null;
      _settleUntil = null;
    });
    _syncPos();
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
    _scrubWatch?.cancel();
    // v1.7.60：_scrubbing 与 _seeking 必须在**同一次** setState 里切换。
    // 分开写会露出「既不拖动、也还没开始跳转」的一帧，那一帧 _syncPos()
    // 会拿真实位置（还是拖动前那个点）推出去 —— 就是用户看到的
    // 「圆点先弹回 1:00，再跳到 2:00」。
    if (mounted) {
      setState(() {
        _scrubbing = false;
        _seeking = true;
        _scrubPos = target;
      });
    } else {
      _scrubbing = false;
      _seeking = true;
      _scrubPos = target;
    }
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
          _settlePos = t;
          _settleUntil = DateTime.now().add(const Duration(milliseconds: 900));
          _seeking = false;
        });
        unawaited(_waitSettleOut(seq, t));
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
    setState(() {
      // 先接管显示，再收 _seeking —— 顺序反了会露出回弹的一帧
      _settlePos = t;
      _settleUntil = DateTime.now().add(const Duration(milliseconds: 900));
      _seeking = false;
    });
    _syncPos();
    unawaited(_waitSettleOut(seq, t));
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
      GlassPanelRoute<double>(
        builder: (ctx) => AppSheet(
          title: '播放速度',
          blur: true,
          children: speeds.map((s) {
            final label = s
                .toStringAsFixed(2)
                .replaceAll(RegExp(r'0+$'), '')
                .replaceAll(RegExp(r'\.$'), '');
            return SheetRow(
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
  String _subInfoText() {
    if (_subtitle != null) {
      return '${_subtitle!.languageLabel} · ${_subtitle!.codecLabel}';
    }
    final online = _onlineSubtitle;
    if (online == null) return '关闭';
    return '${_subtitleFromCache ? '本机' : '在线'} · ${online.source.label}';
  }

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

  // ---------------- 字幕 / 信息 弹层 ----------------
  Future<void> _pickSubtitle() async {
    final tracks = widget.item.subtitles;
    // v1.7.49：即便这个片子一条字幕都没有，也要让用户能进字幕样式。
    // 之前是直接 toast 返回，用户压根找不到「字幕样式」在哪 ——
    // 它被藏在「长按字幕按钮」这个没人会猜到的隐藏手势里。
    final picked = await Navigator.of(context).push<_SubPick>(
      GlassPanelRoute<_SubPick>(
        builder: (ctx) => AppSheet(
          title: '选择字幕',
          blur: true,
          children: [
            if (tracks.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 14),
                child: Text(
                  '该影片没有可用字幕。可在 Emby 装字幕插件后重新扫描，'
                  '或手动放置外挂字幕文件。',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: Color(0xFF9FB0CC),
                  ),
                ),
              )
            else ...[
              SheetRow(
                label: '关闭字幕',
                selected: _subtitle == null && _onlineSubtitle == null,
                onTap: () => Navigator.pop(ctx, const _SubPick(null)),
              ),
              ...tracks.map(
                (t) => SheetRow(
                  label: t.menuLabel,
                  hint: t.displayTitle.isEmpty
                      ? _shortSubUrl(t.url)
                      : t.displayTitle,
                  selected: _subtitle?.url == t.url,
                  onTap: () => Navigator.pop(ctx, _SubPick(t)),
                ),
              ),
            ],
            // 已挂载的在线字幕：显示为当前项，点它可重新搜索
            if (_onlineSubtitle != null)
              SheetRow(
                label: _onlineSubtitle!.title,
                hint: '在线字幕 · 点击重新搜索',
                selected: true,
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_pickOnlineSubtitle());
                },
              ),
            // 在线字幕搜索入口：不占 Emby 字幕轨，选完直接写进叠加层 _cues
            SheetRow(
              label: '在线搜索字幕…',
              hint: '按文件名搜索迅雷 / SubtitleCat',
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickOnlineSubtitle());
              },
            ),
            // 本机已保存的字幕：导出成 .srt 到手机 / 删除（下次不再自动加载）。
            // _onlineSubtitle 非空即代表已保存成功（现搜或缓存恢复都会写缓存）。
            if (_onlineSubtitle != null) ...[
              SheetRow(
                label: '导出字幕…',
                hint: '保存到手机，可再拷到影片目录',
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_exportCachedSubtitle());
                },
              ),
              SheetRow(
                label: '删除本机字幕',
                hint: '下次播放不再自动加载',
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_removeCachedSubtitle());
                },
              ),
            ],
            // 字幕样式入口：明确一行，不再依赖长按
            SheetRow(
              label: '字幕样式…',
              hint: '大小 / 位置 / 描边 / 偏移',
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_showSubtitleStyle());
              },
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

  /// 在线字幕：搜索 → 下载 → 解码(UTF-8/GBK) → 解析 → 叠加层渲染。
  ///  · SRT/VTT 一律走 App 叠加层（两内核外观一致，且不重建播放器、不丢进度）
  ///  · ASS/SSA 在 MPV 下交给内核原生渲染，保住特效
  ///  · 不占用 SubtitleTrackInfo（那是 Emby 服务端轨道），故 _subtitle 置 null，
  ///    用 [_onlineSubtitle] 单独记录，避免底栏误显示「字幕关闭」
  Future<void> _pickOnlineSubtitle() async {
    final picked = await showOnlineSubtitleSheet(
      context,
      fileName: widget.item.filePath.isNotEmpty
          ? widget.item.filePath
          : widget.item.name,
      season: widget.item.seasonNumber,
      episode: widget.item.episodeNumber,
    );
    if (picked == null || !context.mounted) return;

    // 与手动选轨同等对待：后续切集 / 切内核不再被自动选轨覆盖
    _userPickedSub = true;
    try {
      showToast(context, '正在下载字幕…');
      // 拿解码后的原文，而不是只拿 cues：既要写本机缓存，也要能导出 .srt
      final text = await OnlineSubtitleService.downloadText(picked);
      if (!context.mounted) return;
      try {
        await OnlineSubtitleCache.save(widget.item.id, picked, text);
      } catch (_) {
        // 缓存写失败不影响本次播放，最多下次要重新搜
      }
      if (picked.isAss && (_player?.nativeSubtitles ?? false)) {
        await _player?.setSubtitle(picked.url);
        if (!context.mounted) return;
        setState(() {
          _subtitle = null;
          _onlineSubtitle = picked;
          _subtitleFromCache = false;
          _cues = const [];
          _cueText = '';
        });
        showToast(context, '字幕：${picked.title}');
      } else {
        final cues = Subtitles.parseAny(text);
        // MPV 文本字幕要先摘掉内核轨，否则会出现两份字幕重叠；
        // Exo 的 setSubtitle 返回 false、无副作用，调用它是安全的
        await _player?.setSubtitle(null);
        // 第二个 await 之后必须再查一次：下载期间用户可能已经退出播放页
        if (!context.mounted) return;
        setState(() {
          _subtitle = null;
          _onlineSubtitle = picked;
          _subtitleFromCache = false;
          _cues = cues;
          _cueText = '';
        });
        showToast(
          context,
          cues.isEmpty ? '字幕解析失败，换一条试试' : '已加载：${picked.title}',
        );
      }
    } catch (e) {
      if (context.mounted) showToast(context, '字幕下载失败：$e');
    }
    _resetHideTimer();
  }

  /// 导出文件名用的「影片名」：优先用**视频文件原名**（去扩展名），这样字幕
  /// 落到影片旁时 Emby 能按同名自动关联；拿不到服务器路径时回退到影片展示名。
  String _exportMovieName() {
    final fp = widget.item.filePath;
    if (fp.isNotEmpty) {
      final raw = fp.split(RegExp(r'[/\\]')).last;
      final dot = raw.lastIndexOf('.');
      final name = dot > 0 ? raw.substring(0, dot) : raw;
      if (name.trim().isNotEmpty) return name.trim();
    }
    return widget.item.name;
  }

  /// 导出本机字幕：先写成用户可见的文件，再给一个「复制路径 / 系统分享」面板。
  Future<void> _exportCachedSubtitle() async {
    try {
      final path = await OnlineSubtitleCache.export(
        widget.item.id,
        movieName: _exportMovieName(),
      );
      final cached = await OnlineSubtitleCache.load(widget.item.id);
      if (!context.mounted || cached == null) return;
      showToast(context, '字幕已保存到手机');
      await _showExportSheet(path, cached);
    } catch (e) {
      if (context.mounted) showToast(context, '导出失败：$e');
    } finally {
      _resetHideTimer();
    }
  }

  Future<void> _showExportSheet(String path, CachedSubtitle cached) async {
    final fileName = path.split(Platform.pathSeparator).last;
    await Navigator.of(context).push<void>(
      GlassPanelRoute<void>(
        builder: (ctx) => AppSheet(
          title: '字幕已保存到手机',
          blur: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Text(
                path,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: Color(0xFF9FB0CC),
                ),
              ),
            ),
            SheetRow(
              label: '系统分享…',
              hint: '发给 NAS / 文件管理器',
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await SharePlus.instance.share(
                    ShareParams(
                      files: [
                        XFile.fromData(
                          utf8.encode(cached.text),
                          name: fileName,
                          mimeType: 'text/plain',
                        ),
                      ],
                      subject: fileName,
                    ),
                  );
                } catch (e) {
                  if (context.mounted) showToast(context, '分享失败：$e');
                }
              },
            ),
            SheetRow(
              label: '复制文件路径',
              hint: '可在文件管理器里粘贴定位',
              onTap: () async {
                Navigator.pop(ctx);
                await Clipboard.setData(ClipboardData(text: path));
                if (context.mounted) showToast(context, '路径已复制');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 删除本机缓存并立即撤下当前字幕，避免「删了却还在显示」。
  Future<void> _removeCachedSubtitle() async {
    await OnlineSubtitleCache.remove(widget.item.id);
    if (!mounted) return;
    setState(() {
      _onlineSubtitle = null;
      _subtitleFromCache = false;
      _cues = const [];
      _cueText = '';
    });
    // 本页不再自动选轨，否则删掉后又被服务端轨顶上来，用户会觉得没删干净
    _userPickedSub = true;
    showToast(context, '已删除本机字幕');
    _resetHideTimer();
  }

  /// 切换字幕：**不重建播放器**，因此不会丢进度。
  ///  · MPV + ASS/SSA：内核原生挂载，ASS 特效也能显示
  ///  · 其余（Exo 全部、MPV 的 SRT/VTT）：用 App 叠加层自己渲染，
  ///    外观与样式面板完全可控（v1.7.58）
  ///
  /// [silent] = true 时不弹 toast（自动选轨用，避免起播就糊用户一脸提示）。
  Future<void> _applySubtitle(
    SubtitleTrackInfo? track, {
    bool silent = false,
  }) async {
    setState(() {
      _subtitle = track;
      // 选回服务端轨道（或关闭字幕）就不再处于「在线字幕」状态
      _onlineSubtitle = null;
      _subtitleFromCache = false;
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

    // v2.0.95：图像字幕（PGS / DVDSUB）必须走 MPV 内封轨原生渲染。
    // ExoPlayer 不支持图像字幕，选到这类轨时直接切到 MPV；切内核会重建播放器
    // 并按当前 _subtitle 重新开播（内封轨在 _start 里挂载），已开 MPV 则直接挂。
    if (track.isImage) {
      if (_engine != PlaybackEngine.mpv) {
        await _switchTo(PlaybackEngine.mpv, silent: true);
        if (!silent) {
          showToast(context, '已切 MPV 渲染内封字幕：${track.menuLabel}');
        }
      } else {
        final ok = await _player?.setEmbeddedSubtitle(
                  language: track.language,
                  streamIndex: track.index,
                ) ??
                false;
        if (!silent) {
          showToast(
            context,
            ok
                ? '字幕：${track.menuLabel}（MPV 内封轨）'
                : '该图像字幕无法渲染（仅 MPV 支持）',
          );
        }
      }
      _resetHideTimer();
      return;
    }

    // MPV 只接管 ASS/SSA；换到文本字幕时要先摘掉内核字幕，
    // 否则会出现「内核渲染 + 叠加层渲染」两份字幕重叠
    final useNative = _player?.nativeSubtitles == true && _isAssUrl(track.url);
    if (!useNative && _player?.nativeSubtitles == true) {
      await _player?.setSubtitle(null);
    }
    final native = useNative
        ? (await _player?.setSubtitle(track.url) ?? false)
        : false;
    if (!native) {
      final cues = await _loadCues(track);
      if (!mounted) return;
      if (!silent) {
        showToast(
          context,
          cues.isEmpty ? _subFailText() : '字幕：${track.menuLabel}',
        );
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

  /// 字幕是否 ASS/SSA（v1.7.58）。
  ///
  /// 只有这类字幕才交给 MPV 内核原生渲染：它们自带样式与特效，交给
  /// libass 还原最省事。SRT/VTT 走 App 叠加层——mpv 对文本字幕既不能
  /// 指定 BorderStyle（0.36/0.37 都没有 `sub-border-style`），也无法保证
  /// 样式面板的每一项都生效，而叠加层是完全可控的 White-on-半透明块。
  static bool _isAssUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final u = url.toLowerCase().split('?').first.split('#').first;
    return u.endsWith('.ass') || u.endsWith('.ssa');
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
      ignoreSsl: widget.state.ignoreSslErrors,
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
      ignoreSsl: widget.state.ignoreSslErrors,
    );
    if (!mounted || _subtitle?.url != track.url) return;
    setState(() => _cues = cues);
    if (cues.isEmpty) showToast(context, _subFailText());
  }

  /// 起播失败明细（v2.0.90）：逐条列出试过的地址与内核真实报错。
  ///
  /// 绿联最常见的两种失败在界面上必须能区分开：
  ///  · 全部 403 → NAS 后台没给媒体库账号开「允许直链播放」；
  ///  · 全部 404 → 固件把 stream 挂在别的路径下。
  void _showAttempts() {
    if (_attempts.isEmpty && _probes.isEmpty && _capability == null) return;
    final all = <String>[..._probes, ..._attempts];
    final buf = <String>[];
    // v2.0.91：能力探测结论放最前面 —— 「全 404」的真正原因在这里，
    // 不在下面那串 URL 里。
    final cap = _capability;
    if (cap != null) {
      buf.add('服务端取流能力：');
      buf.add('  ${cap.summary}');
      // v2.0.94：把实测 2xx 的地址也列出来。此前诊断只说「206」，却
      // 起播用另一条 URL 全 404，用户和开发者都看不出两条地址不同。
      // 显示脱敏路径后，一眼就能核对起播列表里有没有它。
      if (cap.hasVerifiedUrl) {
        buf.add('  实测可用地址：${cap.verifiedUrlLabel}');
        buf.add('  起播列表首条应为此地址');
      }
      buf.add('  → ${cap.verdict}');
      buf.add('');
    }
    if (_probes.isNotEmpty) {
      buf.add('取流预检（只读响应头，不下载画面）：');
      buf.addAll(_probes);
      buf.add('');
    }
    if (_attempts.isNotEmpty) {
      buf.add('内核起播记录：');
      for (var i = 0; i < _attempts.length; i++) {
        buf.add('${i + 1}. ${_attempts[i]}');
      }
      buf.add('');
    }
    final codes = RegExp('HTTP (\\d{3})')
        .allMatches(all.join(' '))
        .map((m) => m.group(1))
        .toSet();
    if (codes.isNotEmpty && codes.every((c) => c == '403')) {
      buf.add('全部 403 —— 去 NAS 后台检查：影视中心 → 设置 → 媒体服务器，');
      buf.add('给当前账号打开「允许第三方软件访问 / 直链播放」，再重连服务器。');
    } else if (codes.isNotEmpty && codes.every((c) => c == '404')) {
      // v2.0.91：404 的正确解读不是「路径写错」而是「服务端没为这个条目
      // 登记这种取流协议」。上面能力结论已经给出声明了哪些协议，这里补
      // 可执行的下一步，而不是让用户对着 URL 发呆。
      buf.add('全部 404 —— 服务端没为这个条目开放这种取流协议。');
      if (cap != null && !cap.hasAnyProtocol) {
        buf.add('建议：用影视中心的**管理员**账号重连（普通媒体库账号可能读不到');
        buf.add('MediaSources）；或该条目本身在影视中心里也没法播放。');
      } else {
        buf.add('说明声明与实现不一致，把上面「服务端取流能力」整段发我。');
      }
      buf.add('');
      if (ResourcePolicy.instance.localNetworkNote.isNotEmpty) {
        buf.add(ResourcePolicy.instance.localNetworkNote);
      }
    } else if (all.any((e) => e.contains('TLS'))) {
      buf.add('出现 TLS 证书错误 —— 回「我的服务器」确认该条目已勾选');
      buf.add('「忽略 SSL 证书校验」（绿联入口默认已勾）。');
    } else if (all.any((e) => e.contains('超时') || e.contains('timed out'))) {
      buf.add('出现连接超时 —— 确认手机与 NAS 在同一局域网、9443 端口可达。');
    }
    showAppDialog<void>(
      context: context,
      title: '播放诊断',
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 340),
        child: SingleChildScrollView(
          child: SelectableText(
            buf.join('\n'),
            style: TextStyle(
              // 注意：播放页被 UI 度量守卫禁止出现 10.5（那是缓冲速率字号），
              // 这里用 11 保持同一视觉档位。
              fontSize: 11,
              height: 1.55,
              color: AppColors.ink,
            ),
          ),
        ),
      ),
      actions: const [AppDialogAction(label: '知道了', value: null)],
    );
  }

  /// 失败角标上那一小段原因（不展开面板也能看出是 403 还是证书问题）。
  String get _failBrief {
    final all = <String>[..._probes, ..._attempts];
    for (final s in all) {
      final m = RegExp(r'HTTP \d{3}').firstMatch(s);
      if (m != null) return m.group(0)!;
    }
    if (all.any((e) => e.contains('TLS'))) return 'TLS 证书被拒';
    if (all.any((e) => e.contains('超时') || e.contains('timed out'))) {
      return '连接超时';
    }
    return all.isEmpty ? '' : '取流失败';
  }

  void _showInfo() {
    final item = widget.item;
    Navigator.of(context).push<void>(
      GlassPanelRoute<void>(
        builder: (ctx) => AppSheet(
          title: '播放信息',
          blur: true,
          // v2.0.66：真机反馈这块面板太大，收成按内容高度的紧凑信息卡
          compact: true,
          maxWidth: 400,
          maxHeightFactor: 0.9,
          children: [
            _InfoRow(k: '片名', v: item.name, maxLines: 2),
            const _InfoSection('媒体信息'),
            _InfoRow(
              k: '分辨率',
              v: item.resolutionKnown ? '${item.videoHeight}p' : '未知',
            ),
            _InfoRow(k: '视频编码', v: item.videoCodec.toUpperCase()),
            _InfoRow(k: '动态范围', v: item.effectiveRange.label),
            if (item.effectiveRange.isHdr) ...[
              _InfoRow(
                k: '画面处理',
                v: _engine == PlaybackEngine.mpv
                    ? _plan.displayNote
                    : 'Exo 无色调映射（可能偏色）',
              ),
              _InfoRow(k: '设备能力', v: DisplayCaps.label),
            ],
            if (_route != null)
              _InfoRow(
                k: '播放方式',
                v:
                    '${_route!.playMethod}'
                    '${_route!.negotiated ? ' · 能力协商' : ''}',
              ),
            // v2.0.90：让「取流到底带没带鉴权」一眼可见 —— 绿联取流 403
            // 十有八九就是这里空着。
            _InfoRow(
              k: '取流鉴权',
              v: (widget.state.server?.streamHeaders.isNotEmpty ?? false)
                  ? 'X-Emby-Token 已注入'
                  : '未注入（连接服务器后自动带上）',
            ),
            if (_attempts.isNotEmpty)
              _InfoRow(k: '起播重试', v: '${_attempts.length} 次（点角标看明细）'),
            _InfoRow(
              k: '音频',
              v: '${item.audioCodec} · ${item.audioChannels}ch',
            ),
            _InfoRow(k: '封装', v: item.container),
            _InfoRow(k: '大小', v: _fmtSize(item.fileSizeBytes)),
            _InfoRow(k: '字幕', v: _subInfoText()),
            _InfoRow(
              k: '进度',
              v: '${_fmt(_positionSeconds)} / ${_fmt(_totalSeconds)}',
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
    // 播放器 UI 度量：手机一套、平板一套（按钮尺寸/间距/字号随分辨率放大）
    final ui = PlayerUi.of(context);
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
              if (_initializing && !_bootOverlayVisible)
                Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              // v1.7.55：起播 / 切内核等待期**唯一**的加载弹窗。
              // 之前上面还盖着一个独立路由的 STRM 弹窗，两套并存；现在只在
              // 播放页内部渲染这一层，切内核与超时回退都由本页直接执行，
              // 不会出现「弹窗关了但没人去切」。
              if (_bootOverlayVisible)
                StrmBootOverlay(
                  item: widget.item,
                  engine: _engine,
                  waitedSeconds: _bootVN.value,
                  onSwitchEngine: () => unawaited(switchToExo()),
                  onCancel: _dismissBootOverlay,
                )
              else if (_demo)
                Positioned(
                  top: 52,
                  left: 16,
                  child: GestureDetector(
                    // v2.0.90：失败角标可点，直接看每一条候选的真实报错。
                    // 之前只有一句「无可用片源 · 模拟播放」，403（NAS 没开直链
                    // 播放）和 404（路径不对）在界面上长得一模一样。
                    onTap: (_attempts.isEmpty && _probes.isEmpty)
                        ? null
                        : _showAttempts,
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
                          Icon(
                            (_attempts.isEmpty && _probes.isEmpty)
                                ? Icons.info_outline_rounded
                                : Icons.error_outline_rounded,
                            size: 14,
                            color: AppColors.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            widget.item.videoUrl == null
                                ? '演示片源 · 模拟播放'
                                : ((_attempts.isEmpty && _probes.isEmpty)
                                      ? '无可用片源 · 模拟播放'
                                      : '播放失败 · ${_failBrief}'),
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.accent,
                            ),
                          ),
                          if (_attempts.isNotEmpty || _probes.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 13,
                              color: AppColors.accent,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

              // 双击 ±10 秒提示（v2.0.3）：
              // 紧贴对应按钮的**同一水平线**上，而不是堆在按钮组正上方 ——
              //   · +10 秒 → 快进按钮**右侧**，与其水平对齐，间距 = 快进↔播放 的 clusterGap
              //   · -10 秒 → 快退按钮**左侧**，与其水平对齐，间距 = 快退↔播放 的 clusterGap
              // 几何（相对屏幕水平中心 x=0，与 _centerControls 严格一致）：
              //   播放钮半宽 33、按钮间隔 26、快进退钮整宽 50、气泡半宽 46
              //   → 快进钮右缘 = 33+26+50 = 109；快退钮左缘 = -109
              //   +10 秒：气泡左缘 = 109+26 = 135 → 中心 135+46 = 181
              //   -10 秒：气泡右缘 = -109-26 = -135 → 中心 -135-46 = -181
              // 故不论左右，translate 的水平位移都是 ±181，纵向为 0（同屏心）。
              // v2.0.8：以上数字改为 PlayerUi 度量驱动，平板 242（见 layout.dart）。
              if (_doubleTip != null)
                Align(
                  alignment: Alignment.center,
                  child: Builder(
                    builder: (ctx) {
                      // 控件尺寸按分辨率取：手机 92/17、平板 112/21（设计稿）
                      final ui = PlayerUi.of(ctx);
                      return Transform.translate(
                        // _doubleTipLeft = true 是「-10秒」(快退，在左)；false 是「+10秒」(快进，在右)
                        offset: Offset(
                          _doubleTipLeft ? -ui.tipOffset : ui.tipOffset,
                          0,
                        ),
                        child: Glass(
                          // 固定宽高便于上面的位移精确对应 clusterGap 间距；内容居中不换行
                          width: ui.tipW,
                          padding: EdgeInsets.symmetric(
                            horizontal: ui.tipPadH,
                            vertical: ui.tipPadV,
                          ),
                          radius: ui.tablet ? 20 : 16,
                          blur: 20,
                          blurEnabled: false,
                          child: Text(
                            _doubleTip!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: ui.tipFont,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

              // 亮度 / 音量指示：距屏幕边缘 22dp，不再贴边
              // v1.7.62：指示条显示在手势的**对侧** —— 左半屏上滑调亮度时
              // 指示条在右边、右半屏上滑调音量时指示条在左边，避免被手指挡住
              // v1.7.64：整体加高（进度条 88→150、宽 62→68），离屏幕边缘
              // 22dp → 48dp，更醒目也不顶到曲面/挖孔区
              if (_adjustSide != null)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: _adjustSide == 'volume' ? ui.adjustEdge : null,
                  right: _adjustSide == 'brightness' ? ui.adjustEdge : null,
                  width: ui.adjustW,
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
                            size: ui.adjustIcon,
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
                            height: ui.adjustBarH,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: LinearProgressIndicator(
                                value: _adjustValue,
                                minHeight: 5,
                                backgroundColor: Colors.white.withOpacity(0.2),
                                valueColor: AlwaysStoppedAnimation(
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
              // v1.7.62：订阅 _posNv —— 拖动中 _updateScrub 每帧都会把
              // _scrubPos 推进 _posNv，气泡才能跟着手指实时走。以前直接读
              // _scrubPos 且只靠整页 setState 重建，拖动期间整页不重建，
              // 气泡就冻结在起拖附近的旧时间（底部小字却是活的）。
              if (_scrubbing)
                Align(
                  alignment: const Alignment(0, -0.18),
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _posNv,
                      builder: (_, pos, __) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _fmt(pos),
                            style: TextStyle(
                              fontSize: ui.scrubFont,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              shadows: [
                                Shadow(
                                  color: Color(0xAA000000),
                                  blurRadius: 14,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${pos - _scrubStartPos >= 0 ? '+' : '-'}${_fmt((pos - _scrubStartPos).abs())} · ${_fmt(total)}',
                            style: TextStyle(
                              fontSize: ui.scrubSubFont,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFFD2DEFA),
                              shadows: [
                                Shadow(
                                  color: Color(0x99000000),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
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
                  // 平板屏幕物理尺寸更大，同样的 dp 字号相对画面偏小，
                  // 按 PlayerUi 的倍率整体放大（用户自定义字号仍生效）
                  final subScale = PlayerUi.of(context).subtitleScale;
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
                      // v1.7.61：取消背景块，字幕回到纯文字（描边/阴影由
                      // 样式面板的「描边」控制）。Align 保留，让文字居中
                      // 且不被 Positioned 的紧约束撑满整行。
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: ConstrainedBox(
                          // 只保留限宽，长句自动换行、居中
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.85,
                          ),
                          child: Text(
                            cue,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: _subStyle.textStyle.copyWith(
                              fontSize: _subStyle.size * subScale,
                            ),
                          ),
                        ),
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
                      if (!_scrubbing && !_bootOverlayVisible)
                        _centerControls(),
                      _bottomBar(context, total),
                    ],
                  ),
                ),
              ),

              if (_locked)
                // 锁定后顶栏整体隐去，只剩这一枚锁；位置必须与未锁定时
                // 顶栏里那颗「解锁」钮**完全重合**（同 SafeArea + 同 14/8
                // 内边距 + 同 42 尺寸），否则一点锁就视觉跳一下。
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      // 与顶栏同 ui.topPadH/topPadV/topIcon，保证锁定前后不跳位
                      padding: EdgeInsets.fromLTRB(
                        PlayerUi.of(context).topPadH,
                        PlayerUi.of(context).topPadV,
                        PlayerUi.of(context).topPadH,
                        0,
                      ),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          // 长按解锁：锁定多半是为了防止小朋友误触，
                          // 轻点解锁等于没锁，这里要求按住 600ms
                          onLongPress: _unlockScreen,
                          child: GlassIconButton(
                            icon: Icons.lock_rounded,
                            iconSize: PlayerUi.of(context).topIcon,
                            blurEnabled: false,
                            onTap: null,
                          ),
                        ),
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
  Widget _topBar(BuildContext context, MediaItem item) {
    // 起播加载弹窗显示期间不画控制层：一来画面还没有，控件只会显得杂乱，
    // 二来顶栏/底栏会盖住弹窗上的「切换 Exo / 继续等待」按钮（v1.7.55）
    if (_bootOverlayVisible) return const SizedBox.shrink();
    final ui = PlayerUi.of(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(ui.topPadH, ui.topPadV, ui.topPadH, 0),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.arrow_back_ios_new_rounded,
                iconSize: ui.topIcon,
                blurEnabled: false,
                onTap: () => unawaited(_exitPlayer()),
              ),
              SizedBox(width: ui.topTitleGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // 额外部分（-Cd1/-Cd2 分段）在标题后标出，避免误以为在播主版本
                      _displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: ui.topTitle,
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
                      style: TextStyle(
                        fontSize: ui.topMeta,
                        color: const Color(0xFFA9BCD8),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: ui.topIconGap),
              Glass(
                height: ui.topChipH,
                padding: EdgeInsets.symmetric(horizontal: ui.topChipPadH),
                radius: ui.topChipH / 2,
                blur: 18,
                blurEnabled: false,
                // 显式无参回调：直接传 _switchEngine 会把 Future 静默丢掉
                onTap: _toggleEngine,
                child: Center(
                  child: Text(
                    _engine.short,
                    style: TextStyle(
                      fontSize: ui.topChipFont,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              SizedBox(width: ui.topIconGap),
              GlassIconButton(
                icon: Icons.lock_open_rounded,
                iconSize: ui.topIcon,
                blurEnabled: false,
                onTap: _lockScreen,
              ),
              SizedBox(width: ui.topIconGap),
              GlassIconButton(
                icon: Icons.info_outline_rounded,
                iconSize: ui.topIcon,
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
    final ui = PlayerUi.of(context);
    return Positioned.fill(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _GlassPlayBtn(icon: Icons.replay_rounded, onTap: () => _skip(-10)),
          SizedBox(width: ui.clusterGap),
          LiquidPress(
            onTap: _togglePlay,
            radius: ui.playBtn / 2,
            scale: 0.92,
            shadows: const [
              BoxShadow(
                color: Color(0x804F8CFF),
                blurRadius: 26,
                offset: Offset(0, 10),
              ),
            ],
            child: Container(
              width: ui.playBtn,
              height: ui.playBtn,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xF24F8CFF), Color(0xF27B5CFF)],
                ),
              ),
              child: Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: ui.playIcon,
                color: Colors.white,
              ),
            ),
          ),
          SizedBox(width: ui.clusterGap),
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
    // 同 _topBar：加载弹窗期间不画底栏（会压住弹窗的按钮）
    if (_bootOverlayVisible) return const SizedBox.shrink();
    final ui = PlayerUi.of(context);
    return Positioned(
      left: ui.barInset,
      right: ui.barInset,
      bottom: ui.barBottom,
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
            SizedBox(height: ui.barGap),
            // 单行：左边当前时间 → 中间胶囊（弹性）→ 右边缓冲速率 + 总时长
            // v1.7.33/1.7.40：时长与缓冲固定贴最右，不再和按钮挤在一行里
            Row(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _posNv,
                  builder: (_, pos, __) => Text(
                    _fmt(pos),
                    style: TextStyle(
                      fontSize: ui.timeFont,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFC6D5EF),
                    ),
                  ),
                ),
                SizedBox(width: ui.barInnerGap),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // 字幕：点选字幕，长按进入字幕样式面板
                        GestureDetector(
                          onLongPress: _showSubtitleStyle,
                          child: _Chip(
                            label: _subtitle != null
                                ? '字幕 · ${_subtitle!.languageLabel}'
                                : (_onlineSubtitle == null
                                      ? '字幕'
                                      : '字幕 · ${_subtitleFromCache ? '本机' : '在线'}'),
                            icon: Icons.subtitles_outlined,
                            onTap: _pickSubtitle,
                          ),
                        ),
                        SizedBox(width: ui.chipGap),
                        _Chip(
                          label: _fit == PlaybackFit.fill ? '满屏' : '自适配',
                          icon: Icons.aspect_ratio_rounded,
                          onTap: _toggleFit,
                        ),
                        SizedBox(width: ui.chipGap),
                        _SpeedChip(label: _speedLabel, onTap: _pickSpeed),
                        SizedBox(width: ui.chipGap),
                        _Chip(
                          label: _engine == PlaybackEngine.mpv
                              ? (_hw ? '硬解' : '软解')
                              : '硬解',
                          icon: Icons.memory_rounded,
                          onTap: () => unawaited(_toggleHardware()),
                        ),
                        SizedBox(width: ui.chipGap),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: ui.barInnerGap),
                // 缓冲速率常显（v1.7.40）：没数据时给占位，避免这一格忽隐忽现
                ValueListenableBuilder<String>(
                  valueListenable: _bufNv,
                  builder: (_, buf, __) => Text(
                    buf.isEmpty ? '-- MB/s' : buf,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: ui.timeFont - 0.5,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF8B94A7),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _fmt(total),
                  style: TextStyle(
                    fontSize: ui.timeFont,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFC6D5EF),
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
    final ui = PlayerUi.of(context);
    return Glass(
      width: ui.sideBtn,
      height: ui.sideBtn,
      padding: EdgeInsets.zero,
      radius: ui.sideBtn / 2,
      blur: 20,
      blurEnabled: false,
      onTap: onTap,
      child: Transform.flip(
        flipX: flipX,
        child: Icon(icon, size: ui.sideIcon, color: AppColors.ink),
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
    final ui = PlayerUi.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 168),
      child: Glass(
        height: ui.chipH,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        radius: ui.chipH / 2,
        blur: 16,
        blurEnabled: false,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: ui.chipIcon, color: Colors.white),
            const SizedBox(width: 5),
            // 字幕语言名可能很长：允许省略，避免把底栏挤爆
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: ui.chipFont,
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
        height: PlayerUi.of(context).barHitH,
        child: LayoutBuilder(
          builder: (context, c) {
            final ui = PlayerUi.of(context);
            final w = c.maxWidth;
            final x = w * pct;
            final r = pressed ? 9.0 : 6.0;
            // v2.0.13：轨道/圆点统一以热区中线（barHitH/2）垂直居中。
            // 旧实现轨道 top 按按下态高度算、圆点 top 是硬编码 8/10，
            // 平板档位下圆点中心与轨道中心最大偏差 6px（用户实测反馈）。
            final trackH = pressed ? ui.barActiveH : ui.barTrackH;
            final top = ui.barHitH / 2 - trackH / 2;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // 底轨
                Positioned(
                  left: 0,
                  right: 0,
                  top: top,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    height: pressed ? ui.barActiveH : ui.barTrackH,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        pressed ? ui.barActiveH : ui.barTrackH,
                      ),
                      color: Colors.white.withOpacity(0.22),
                    ),
                  ),
                ),
                // 已播放
                Positioned(
                  left: 0,
                  width: x,
                  top: top,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    height: pressed ? ui.barActiveH : ui.barTrackH,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        pressed ? ui.barActiveH : ui.barTrackH,
                      ),
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
                // 圆点：中心 = barHitH/2，与轨道同一中线
                Positioned(
                  left: (x - r).clamp(0.0, math.max(0.0, w - r * 2)),
                  top: ui.barHitH / 2 - r,
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

/// 玻璃面板 / 居中路由 / 通用行组件已抽到 `widgets/glass_sheet.dart`，
/// 在线字幕搜索面板复用同一套外观（手机 470 / 平板 620 的最大宽度）。

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

/// 通用行组件 `_SheetRow` 已抽到 `widgets/glass_sheet.dart`（`SheetRow`），
/// 字幕轨道行与在线字幕结果行共用。

/// 蓝竖条分节标题（设计稿「媒体信息」样式）
class _InfoSection extends StatelessWidget {
  const _InfoSection(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFFB9C8E2),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.k, required this.v, this.maxLines = 2});
  final String k;
  final String v;

  /// v2.0.66：片名这类长值最多两行，避免把紧凑面板重新撑高。
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              k,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9FB0CC)),
            ),
          ),
          Expanded(
            child: Text(
              v,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
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
