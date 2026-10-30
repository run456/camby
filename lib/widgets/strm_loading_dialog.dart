import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models.dart';
import '../player/boot_watch.dart';
import '../player/playback.dart';

import 'liquid_press.dart';

/// STRM / 慢速片源的**起播加载弹窗**（v1.7.49）
///
/// 为什么不是播放页里的覆盖层：设计稿要求「加载 strm 前先有弹窗」——
/// 也就是**在进入播放页之前**就把这件事告诉用户。之前的实现是进了播放页
/// 再盖一层胶囊，用户看到的顺序不对，所以「没看到弹窗」。
///
/// 展示时机：详情页点「播放」→ 先弹这个 → 用户在弹窗里就已经能看到
/// 「正在获取媒体信息 / 已等待 N 秒」→ 首帧出来才进播放页。
///
/// 分阶段（连接 → 探测 → 缓冲）由 [BootWatchPolicy.stageIndex] 按时间推断，
/// 不是真实进度 —— libmpv / ExoPlayer 都不暴露这些回调。
class StrmLoadingDialog extends StatefulWidget {
  const StrmLoadingDialog({
    super.key,
    required this.item,
    required this.engine,
    required this.onSwitchEngine,
    required this.onDone,
    required this.start,
    required this.probe,
    this.alreadyFellBack = false,
  });

  final MediaItem item;
  final PlaybackEngine engine;

  /// 用户点「切换 Exo 内核」时回调
  final VoidCallback onSwitchEngine;

  /// 首帧真正出来了 → 关掉弹窗进播放页
  final VoidCallback onDone;

  /// 真正去开播放器（弹窗出现后再调，让用户先看到「在等」）
  final Future<bool> Function() start;

  /// 探针：首帧出来了吗？起播已经失败了吗？
  final bool Function() probe;

  /// 已经自动回退过一次，不再重复提示
  final bool alreadyFellBack;

  @override
  State<StrmLoadingDialog> createState() => _StrmLoadingDialogState();
}

class _StrmLoadingDialogState extends State<StrmLoadingDialog> {
  DateTime _at = DateTime.now();
  Timer? _tick;
  double _secs = 0;

  /// 已经弹过「起播失败」（避免每 200ms 弹一次）
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    // 弹窗先出现，再开播放器：用户先看到「正在获取媒体信息」，
    // 而不是对着黑屏等几百毫秒才冒出弹窗。
    unawaited(() async {
      final ok = await widget.start();
      if (!mounted || _reported) return;
      if (!ok) {
        _reported = true;
        // 起播直接失败（地址 404 / 鉴权失败）：不再傻等，
        // 关窗让详情页去提示，比在这里等到 25 秒强
        widget.onDone();
      }
    }());

    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _reported) return;
      final s = DateTime.now().difference(_at).inMilliseconds / 1000.0;
      setState(() => _secs = s);
      // 首帧判据交给调用方：MPV 看 videoParams，Exo 看 isInitialized
      if (s >= BootWatchPolicy.minVisibleSecs && widget.probe()) {
        _reported = true;
        widget.onDone();
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMpv = widget.engine == PlaybackEngine.mpv;
    final showSwitch = _secs >= BootWatchPolicy.showSwitchSecs && isMpv;
    final showPlugin = _secs >= BootWatchPolicy.pluginHintSecs;
    final stage = BootWatchPolicy.stageIndex(_secs);

    // 外层不透明黑：设计稿是「黑底 + 中央玻璃卡片」，不是半透明蒙版。
    // 用不透明黑是因为此刻播放器还没出画面，透出底下也没东西可看，
    // 反而会让上一页（详情页）的残影闪一下。
    return PopScope(
      // 等待中不许返回：返回了播放器还在后台起，状态会错乱
      canPop: false,
      child: Material(
        color: Colors.black,
        child: Stack(
          children: [
            // 极淡的径向光，避免纯黑显得像死机
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.15),
                    radius: 0.9,
                    colors: [
                      const Color(0xFF2A3550).withValues(alpha: 0.55),
                      Colors.black,
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: _card(showSwitch, showPlugin, stage),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(bool showSwitch, bool showPlugin, int stage) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 片名（两行截断，标题过长也不撑破卡片）
              Text(
                widget.item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontSize: 13.5,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFF6E8BFF),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      BootWatchPolicy.titleFor(_secs),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'STRM 首次播放需要服务器探测远端视频，可能需要较长时间',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              _stages(stage),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '已等待 ${_secs.toStringAsFixed(0)} 秒',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    widget.engine.label,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (showSwitch) ...[
                const SizedBox(height: 18),
                _divider(),
                const SizedBox(height: 14),
                _action(
                  label: '切换 Exo 内核',
                  desc: 'Exo 对 302 直链兼容性更好，保留进度',
                  primary: true,
                  onTap: () {
                    // 计时归零：换了内核就是新的一轮等待
                    _at = DateTime.now();
                    widget.onSwitchEngine();
                  },
                ),
              ],
              const SizedBox(height: 10),
              _action(
                label: '继续等待',
                onTap: () {},
                // 「继续等待」不是按钮而是一句安慰：它不做事，只是让用户
                // 有事可做。做成按钮按下去没反应反而更糟，所以表现为纯文字。
                ghost: true,
              ),
              if (showPlugin) ...[
                const SizedBox(height: 16),
                _divider(),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '建议在 Emby 服务端安装 STRM 媒体信息插件（MediaInfoKeeper / '
                        'StrmAssistant）预先生成媒体信息，装好后可秒开',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 三段进度点：连接 → 探测 → 缓冲
  Widget _stages(int stage) {
    return Row(
      children: [
        for (var i = 0; i < BootWatchPolicy.stageLabels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 1.4,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: Colors.white.withValues(
                  alpha: i <= stage ? 0.45 : 0.12,
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i <= stage
                      ? const Color(0xFF6E8BFF)
                      : Colors.white.withValues(alpha: 0.18),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                BootWatchPolicy.stageLabels[i],
                style: TextStyle(
                  fontSize: 11.5,
                  color: Colors.white.withValues(
                    alpha: i <= stage ? 0.8 : 0.3,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _divider() => Container(
        height: 1,
        color: Colors.white.withValues(alpha: 0.08),
      );

  Widget _action({
    required String label,
    required VoidCallback onTap,
    String? desc,
    bool primary = false,
    bool ghost = false,
  }) {
    if (ghost) {
      return Center(
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12.5,
          ),
        ),
      );
    }
    return LiquidPress(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
        decoration: BoxDecoration(
          color: primary
              ? const Color(0xFF4C6FFF).withValues(alpha: 0.85)
              : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: primary ? 0.18 : 0.10),
          ),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (desc != null) ...[
              const Spacer(),
              Flexible(
                child: Text(
                  desc,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 用弹窗包装一次起播。
///
/// 调用方（详情页）只需要给两件事：
///  · [start]：真正去开播放器，返回是否成功；
///  · [ready]：探针，问「首帧出来了吗 / 是不是已经失败了」。
///
/// 弹窗每 200ms 问一次 [ready]，出结果就关自己。这样编排逻辑留在弹窗里，
/// 调用方不需要知道「至少显示多久」这类细节。
///
/// 返回 [StrmLoadingResult]：
///  · [StrmLoadingResult.ready]  —— 首帧出来了，正常进播放页
///  · [StrmLoadingResult.switched] —— 用户点了「切换 Exo」，调用方换内核重开
///  · [StrmLoadingResult.failed] —— 起播失败或超时（此时也已关窗，别再硬等）
Future<StrmLoadingResult> showStrmLoading({
  required BuildContext context,
  required MediaItem item,
  required PlaybackEngine engine,
  required Future<bool> Function() start,
  required bool Function() ready,

  /// 用户点「切换 Exo 内核」时调用（真正的切内核动作在播放页里）
  VoidCallback? onSwitchEngine,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var switched = false;

  final route = PageRouteBuilder<StrmLoadingResult>(
    opaque: true,
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => StrmLoadingDialog(
      item: item,
      engine: engine,
      onSwitchEngine: () {
        switched = true;
        onSwitchEngine?.call();
        if (navigator.canPop()) {
          navigator.pop(StrmLoadingResult.switched);
        }
      },
      onDone: () {
        if (navigator.canPop()) navigator.pop(StrmLoadingResult.ready);
      },
      probe: ready,
      start: start,
    ),
    transitionsBuilder: (_, anim, __, child) =>
        FadeTransition(opacity: anim, child: child),
  );

  final result = await navigator.push<StrmLoadingResult>(route);
  if (switched) return StrmLoadingResult.switched;
  return result ?? StrmLoadingResult.failed;
}

/// 起播包装的结果
enum StrmLoadingResult {
  /// 首帧已出，可以进播放页
  ready,

  /// 用户要求换成 Exo 内核
  switched,

  /// 起播失败 / 用户放弃
  failed,
}
