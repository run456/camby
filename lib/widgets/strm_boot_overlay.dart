import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models.dart';
import '../player/boot_watch.dart';
import '../player/playback.dart';

/// STRM 起播的**唯一**加载弹窗（v1.7.55）
///
/// 之前有两套并存的加载 UI：
///  1. `strm_loading_dialog.dart`：进播放页后盖上的大卡片（片名 / 三阶段 /
///     已等待 / 切换 Exo / 插件提示）；
///  2. 播放页 `_bootOverlay()`：黑屏期居中的小胶囊（「正在获取媒体信息…」）。
/// 两套同时在屏上，用户看到的就是「两种弹窗」。
///
/// 现在只保留这一套（设计稿 1661104d 的版式）：**由播放页托管** ——
/// 播放页就在底下跑，弹窗只是它上面一层玻璃卡片，所以：
///  · 点「切换到 Exo 内核」= 直接让底下那个播放器换内核，不存在「弹窗关掉了
///    但没人去切」的情况（v1.7.54 的真 bug：旧实现 pop 掉弹窗后，
///    真正切内核的播放页 State 还卡在 MPV 上）；
///  · 超时自动回退也在这里计时，用的是真实已等待时长，而不再依赖
///    「等首帧信号才关窗」—— 等不到首帧正是需要它的时候。
class StrmBootOverlay extends StatefulWidget {
  const StrmBootOverlay({
    super.key,
    required this.item,
    required this.engine,
    required this.waitedSeconds,
    required this.onSwitchEngine,
    required this.onCancel,
  });

  final MediaItem item;

  /// 当前内核（决定是否给「切 Exo」出口）
  final PlaybackEngine engine;

  /// 真实已等待秒数（播放页自己的看护计时）
  final double waitedSeconds;

  /// 切内核：交给播放页执行（保留进度）
  final VoidCallback onSwitchEngine;

  /// 「继续等待」：收起卡片，露出控制层（画面可能还没出来）
  final VoidCallback onCancel;

  @override
  State<StrmBootOverlay> createState() => _StrmBootOverlayState();
}

class _StrmBootOverlayState extends State<StrmBootOverlay> {
  /// 面板内部再记一份时间：重建时不会让「已等待」往回跳
  late double _base = widget.waitedSeconds;
  DateTime _at = DateTime.now();
  Timer? _tick;
  double _secs = 0;

  double get _waited {
    // 播放页的计时更权威（切内核会归零），取两者较大值避免倒退
    final outer = widget.waitedSeconds;
    final mine = _base + _secs;
    return math.max(outer, mine);
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(
        () => _secs = DateTime.now().difference(_at).inMilliseconds / 1000,
      );
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final waited = _waited;
    final showSwitch = BootWatchPolicy.showSwitchButton(
      engine: widget.engine,
      waitedSecs: waited,
    );
    final showPlugin = BootWatchPolicy.showPluginHint(waited);
    final stage = BootWatchPolicy.stageIndex(waited);
    final fileName = _fileName(widget.item);

    return Stack(
      children: [
        // 轻微压暗画面，让卡片浮起来（不挡触摸：下面没有可点的东西）
        const Positioned.fill(
          child: IgnorePointer(child: ColoredBox(color: Color(0x66000000))),
        ),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              child: _card(stage, waited, showSwitch, showPlugin, fileName),
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(
    int stage,
    double waited,
    bool showSwitch,
    bool showPlugin,
    String fileName,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.10),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 片名：两行截断，超长也不撑破卡片
              Text(
                widget.item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.92),
                  fontSize: 13.5,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 18),
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
                      BootWatchPolicy.titleFor(waited),
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
                  color: Colors.white.withOpacity(0.55),
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              _stages(stage),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    '已等待 ${waited.toStringAsFixed(0)} 秒',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    widget.engine.label,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.35),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (showSwitch) ...[
                const SizedBox(height: 16),
                _divider(),
                const SizedBox(height: 14),
                // 不再自己 pop：切内核由播放页执行，弹窗跟着画面状态走
                _button(
                  label: '切换到 Exo 内核',
                  primary: true,
                  onTap: widget.onSwitchEngine,
                ),
              ],
              const SizedBox(height: 10),
              Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onCancel,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      '继续等待',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
              ),
              if (showPlugin) ...[
                const SizedBox(height: 12),
                _divider(),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: Colors.white.withOpacity(0.45),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '建议在 Emby 服务端安装 STRM 媒体信息插件（MediaInfoKeeper / '
                        'StrmAssistant）预先生成媒体信息，装好后可秒开',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.45),
                          fontSize: 12,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              // 文件名作为最后一行小字：排查「加载的是哪个文件」时有用
              if (fileName.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.28),
                    fontSize: 10.5,
                  ),
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
                color: Colors.white.withOpacity(i <= stage ? 0.45 : 0.12),
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
                      : Colors.white.withOpacity(0.18),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                BootWatchPolicy.stageLabels[i],
                style: TextStyle(
                  fontSize: 11.5,
                  color: Colors.white.withOpacity(i <= stage ? 0.8 : 0.3),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _divider() =>
      Container(height: 1, color: Colors.white.withOpacity(0.08));

  Widget _button({
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    // 用 InkWell/ButtonStyle 而不是自绘的 LiquidPress：这里是压在最上层的
    // 弹窗，命中测试要绝对可靠（v1.7.54「切 Exo 胶囊点了没反应」就是
    // 被自绘按下态的手势吃掉了一次）
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: primary
              ? const Color(0xFF4C6FFF).withOpacity(0.85)
              : Colors.white.withOpacity(0.10),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: Colors.white.withOpacity(primary ? 0.18 : 0.10),
            ),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  static String _fileName(MediaItem item) {
    final raw = item.filePath;
    if (raw.isEmpty) return '';
    final parts = raw.split('/');
    return parts.last;
  }
}
