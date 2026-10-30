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
}
