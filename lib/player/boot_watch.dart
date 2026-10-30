import 'playback.dart';

/// 起播看护策略（v1.7.44）
///
/// 把「等多久该给用户什么」从播放页 UI 里抽出来，一是方便单测覆盖阈值，
/// 二是这几个数字以后要调时只改一处。
class BootWatchPolicy {
  const BootWatchPolicy._();

  /// 超过这么久还没首帧 → 露出「切换到 Exo 内核」按钮
  ///
  /// 定 8 秒的依据：正常网络下 strm 直链 ffprobe 一般 2~5 秒出画，
  /// 超过 8 秒基本可以判定「这个内核搞不定」，而不是「再等等就好」。
  static const double showSwitchSecs = 8.0;

  /// 超过这么久还没首帧 → 自动换 Exo 重开
  ///
  /// 比手动按钮晚 2 秒：先给用户看见按钮（知道发生了什么），再自动动手。
  /// 如果一上来就自动切，用户只会觉得「闪了一下，还是不知道刚才是怎么回事」。
  static const double autoFallbackSecs = 10.0;

  /// 超过这么久还没首帧 → 提示可能需要服务端插件预热
  static const double pluginHintSecs = 25.0;

  /// 现在是否该自动回退到 Exo
  ///
  /// 三个条件缺一不可：① 当前是 MPV（Exo 已经是兜底，没有更兜的）；
  /// ② 本轮还没回退过（避免 mpv→exo→mpv 来回跳）；
  /// ③ 已等待超过 [autoFallbackSecs]。
  static bool shouldFallback({
    required PlaybackEngine engine,
    required bool alreadyFellBack,
    required double waitedSecs,
  }) {
    if (engine != PlaybackEngine.mpv) return false;
    if (alreadyFellBack) return false;
    return waitedSecs >= autoFallbackSecs;
  }

  /// 加载胶囊上是否显示「切换 Exo」按钮
  ///
  /// 只有 MPV 才显示：Exo 已经是兜底内核，再给一个「切到 Exo」的按钮是废话。
  static bool showSwitchButton({
    required PlaybackEngine engine,
    required double waitedSecs,
  }) => engine == PlaybackEngine.mpv && waitedSecs >= showSwitchSecs;

  /// 是否显示「可能需要服务端插件预热」
  static bool showPluginHint(double waitedSecs) =>
      waitedSecs >= pluginHintSecs;

  /// 三段进度点（连接 → 探测 → 缓冲）当前走到第几段（0 起）
  ///
  /// 没有真实的分阶段回调可依赖 —— libmpv / ExoPlayer 都不告诉我们
  /// 「现在在解析 moov 还是在校验 302」。所以按等待时长推断：
  /// 这是给用户「正在推进」的体感，不是精确进度，不该被当成真话读。
  ///
  ///  · 0–4s  ：连接（DNS / 302 跳转 / 建 TLS）
  ///  · 4–12s ：探测（服务端 ffprobe 远端文件，strm 的主要耗时就在这里）
  ///  · 12s+  ：缓冲（拿到元信息，开始灌数据）
  static int stageIndex(double waitedSecs) {
    if (waitedSecs >= 12) return 2;
    if (waitedSecs >= 4) return 1;
    return 0;
  }

  /// 阶段文案
  static const List<String> stageLabels = ['连接', '探测', '缓冲'];

  /// 加载弹窗的主标题：随阶段变化，让用户知道「不是卡死了，是在往后走」
  static String titleFor(double waitedSecs) {
    switch (stageIndex(waitedSecs)) {
      case 0:
        return '正在连接服务器…';
      case 1:
        return '正在获取媒体信息…';
      default:
        return '正在缓冲画面…';
    }
  }

  /// 弹窗最短显示时长。
  ///
  /// 网络快的时候 300ms 就出画面了，弹窗一闪而过反而像闪屏；垫到 1.2 秒
  /// 让它有一个完整的「出现 → 淡出」过程，看起来才是设计过的动效。
  static const double minVisibleSecs = 1.2;
}
