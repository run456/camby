import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/liquid_press.dart';
import 'dlna_controller.dart';
import 'dlna_protocol.dart';

/// 打开投屏面板（底部玻璃抽屉）。
///
/// 外观与「选择字幕 / 选择影片版本」一致：`Glass` + 透明背景的
/// `showModalBottomSheet`、圆角 24、白 12% 细边、拖拽把手；v2.0.82 定的
/// 规范也照旧 —— 正文蓝灰 `#9FB0CC`，**所有动作文字统一 [AppColors.accent]**。
///
/// [buildUrl] 由详情页提供：兼容模式切换后要重新拼一次带 MediaSourceId 的
/// Emby 流地址，控制器不缓存 URL。
Future<void> showCastingSheet({
  required BuildContext context,
  required DlnaController controller,
  required String title,
  required String itemId,
  required String Function(bool compatible) buildUrl,
  Duration startAt = Duration.zero,
  Duration? duration,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _CastingSheet(
      controller: controller,
      title: title,
      itemId: itemId,
      buildUrl: buildUrl,
      startAt: startAt,
      duration: duration,
    ),
  );
}

class _CastingSheet extends StatefulWidget {
  const _CastingSheet({
    required this.controller,
    required this.title,
    required this.itemId,
    required this.buildUrl,
    required this.startAt,
    required this.duration,
  });

  final DlnaController controller;
  final String title;
  final String itemId;
  final String Function(bool compatible) buildUrl;
  final Duration startAt;
  final Duration? duration;

  @override
  State<_CastingSheet> createState() => _CastingSheetState();
}

class _CastingSheetState extends State<_CastingSheet> {
  @override
  void initState() {
    super.initState();
    // 首帧之后再触发发现，避免在 build 阶段通知监听器。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = widget.controller;
      if (c.phase == DlnaPhase.idle && c.devices.isEmpty) c.discover();
    });
  }

  CastRequest _request(DlnaController c, {Duration? startAt}) => CastRequest(
    url: widget.buildUrl(c.compatibleMode),
    title: widget.title,
    id: widget.itemId,
    startAt: startAt ?? widget.startAt,
    duration: widget.duration,
    mimeType: c.compatibleMode ? 'application/vnd.apple.mpegurl' : 'video/mp4',
  );

  void _onCompatibleChanged(bool value) {
    final c = widget.controller;
    c.setCompatibleMode(value);
    final d = c.current;
    if (d == null) return;
    // 已在投屏时立刻用新地址重投，不让用户先断开再手动点一次。
    c.cast(d, _request(c, startAt: c.position));
  }

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 24,
      blur: 24,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      padding: EdgeInsets.zero,
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (ctx, _) => _body(ctx),
        ),
      ),
    );
  }

  Widget _body(BuildContext ctx) {
    final c = widget.controller;
    final url = widget.buildUrl(c.compatibleMode);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 8),
        _header(ctx),
        const SizedBox(height: 4),
        _stateBody(ctx, c),
        _compatibleRow(c),
        _hintRow(url),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _header(BuildContext ctx) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 14, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '投屏到电视',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.of(ctx).maybePop(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stateBody(BuildContext ctx, DlnaController c) {
    switch (c.phase) {
      case DlnaPhase.discovering:
      case DlnaPhase.connecting:
        return _busy(c.message);
      case DlnaPhase.error:
        return _error(c);
      case DlnaPhase.playing:
      case DlnaPhase.paused:
      case DlnaPhase.stopped:
        return _controls(c);
      case DlnaPhase.idle:
      case DlnaPhase.ready:
        return c.devices.isEmpty ? _empty(c) : _deviceList(ctx, c);
    }
  }

  Widget _busy(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            message.isEmpty ? '请稍候…' : message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF9FB0CC)),
          ),
        ],
      ),
    );
  }

  Widget _error(DlnaController c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 32,
            color: AppColors.warn,
          ),
          const SizedBox(height: 10),
          Text(
            c.message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF9FB0CC)),
          ),
          const SizedBox(height: 6),
          _textButton('重新搜索', () => c.discover()),
        ],
      ),
    );
  }

  Widget _empty(DlnaController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cast_rounded,
            size: 36,
            color: Colors.white.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          const Text(
            '没有找到投屏设备',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '请确认电视 / 盒子与手机连接同一 Wi-Fi，并已开启 DLNA、'
            '「多屏互动」或「投屏」功能。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: Color(0xFF9FB0CC),
            ),
          ),
          const SizedBox(height: 6),
          _textButton('重新搜索', () => c.discover()),
        ],
      ),
    );
  }

  Widget _deviceList(BuildContext ctx, DlnaController c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.36,
          ),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            itemCount: c.devices.length,
            itemBuilder: (_, i) =>
                _deviceTile(c, c.devices[i], c.current?.id == c.devices[i].id),
          ),
        ),
        const SizedBox(height: 2),
        _textButton('重新搜索', () => c.discover()),
      ],
    );
  }

  Widget _deviceTile(DlnaController c, DlnaDevice d, bool selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: LiquidPress(
        radius: 14,
        semanticLabel: '投屏到 ${d.title}',
        onTap: () => c.cast(d, _request(c)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected
                ? AppColors.accent.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.tv_rounded,
                size: 20,
                color: selected ? AppColors.accent : const Color(0xFFDFE7F5),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      d.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    if (d.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        d.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9FB0CC),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Color(0xFF9FB0CC),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(DlnaController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _currentCard(c),
          const SizedBox(height: 12),
          _progress(c),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              _round(
                Icons.fast_rewind_rounded,
                '后退 10 秒',
                () => c.seek(c.position - const Duration(seconds: 10)),
              ),
              _round(
                c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                c.isPlaying ? '暂停' : '播放',
                () => c.isPlaying ? c.pause() : c.play(),
              ),
              _round(
                Icons.fast_forward_rounded,
                '快进 10 秒',
                () => c.seek(c.position + const Duration(seconds: 10)),
              ),
              if (c.current?.hasVolume == true) ...[
                _round(
                  Icons.volume_down_rounded,
                  '音量减',
                  () => c.setVolume(c.volume - 5),
                ),
                _round(
                  Icons.volume_up_rounded,
                  '音量加',
                  () => c.setVolume(c.volume + 5),
                ),
              ],
              _round(Icons.stop_rounded, '停止', () => c.stop()),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (c.devices.length > 1)
                _textButton('切换设备', () async {
                  await c.disconnect();
                  await c.discover();
                }),
              _textButton('断开投屏', () => c.disconnect()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _currentCard(DlnaController c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.accent.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cast_rounded, size: 22, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  c.current?.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _statusLabel(c.phase),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9FB0CC),
                  ),
                ),
              ],
            ),
          ),
          if (c.current?.hasVolume == true)
            Text(
              '音量 ${c.volume}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF9FB0CC)),
            ),
        ],
      ),
    );
  }

  String _statusLabel(DlnaPhase phase) => switch (phase) {
    DlnaPhase.playing => '正在播放',
    DlnaPhase.paused => '已暂停',
    DlnaPhase.stopped => '已停止',
    DlnaPhase.connecting => '连接中…',
    DlnaPhase.error => '连接失败',
    _ => '已连接',
  };

  Widget _progress(DlnaController c) {
    final total = c.duration.inSeconds;
    final cur = c.position.inSeconds.clamp(0, total > 0 ? total : 1 << 30);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (total > 0 ? cur / total : 0.0).clamp(0.0, 1.0).toDouble(),
            minHeight: 4,
            backgroundColor: Colors.white.withValues(alpha: 0.10),
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              formatUpnpDuration(c.position),
              style: const TextStyle(fontSize: 11, color: Color(0xFF9FB0CC)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                c.castTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9FB0CC)),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatUpnpDuration(c.duration),
              style: const TextStyle(fontSize: 11, color: Color(0xFF9FB0CC)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _round(IconData icon, String tip, VoidCallback onTap) => LiquidPress(
    radius: 22,
    semanticLabel: tip,
    onTap: onTap,
    child: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.07),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Icon(icon, size: 20, color: AppColors.accent),
    ),
  );

  Widget _compatibleRow(DlnaController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 10, 0),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '兼容模式（服务端转码）',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '原片无法播放时打开，画质会有损失',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFF9FB0CC)),
                ),
              ],
            ),
          ),
          Switch(value: c.compatibleMode, onChanged: _onCompatibleChanged),
        ],
      ),
    );
  }

  Widget _hintRow(String url) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '投屏由电视直接播放 Emby 流，手机只作遥控；请确认手机与电视在同一 Wi-Fi。',
            style: TextStyle(
              fontSize: 10.5,
              height: 1.5,
              color: Color(0xFF9FB0CC),
            ),
          ),
          if (!isLanReachableUrl(url)) ...[
            const SizedBox(height: 6),
            const Text(
              '当前服务器地址电视可能无法访问，请在服务器设置里改用局域网 IP。',
              style: TextStyle(
                fontSize: 10.5,
                height: 1.5,
                color: AppColors.warn,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _textButton(String label, VoidCallback onTap) => LiquidPress(
    radius: 10,
    semanticLabel: label,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.accent,
        ),
      ),
    ),
  );
}
