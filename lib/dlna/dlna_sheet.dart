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
/// [buildUrl] 由详情页提供：兼容模式 / 字幕烧录切换后要重新拼一次带
/// MediaSourceId 的 Emby 流地址，控制器不缓存 URL（鉴权 token 可能会变）。
/// v2.0.85 起多带 [burn] 与 [subtitleIndex] 两个维度。
typedef CastUrlBuilder =
    String Function({
      required bool compatible,
      required bool burn,
      required int? subtitleIndex,
    });

Future<void> showCastingSheet({
  required BuildContext context,
  required DlnaController controller,
  required String title,
  required String itemId,
  required CastUrlBuilder buildUrl,
  List<CastSubtitle> subtitles = const <CastSubtitle>[],
  int? preferredSubtitleIndex,
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
      subtitles: subtitles,
      preferredSubtitleIndex: preferredSubtitleIndex,
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
    this.subtitles = const <CastSubtitle>[],
    this.preferredSubtitleIndex,
  });

  final DlnaController controller;
  final String title;
  final String itemId;
  final CastUrlBuilder buildUrl;
  final Duration startAt;
  final Duration? duration;
  final List<CastSubtitle> subtitles;
  final int? preferredSubtitleIndex;

  @override
  State<_CastingSheet> createState() => _CastingSheetState();
}

class _CastingSheetState extends State<_CastingSheet> {
  @override
  void initState() {
    super.initState();
    // 首帧之后再触发发现 / 注入字幕，避免在 build 阶段通知监听器。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = widget.controller;
      c.configureSubtitles(
        available: widget.subtitles,
        preferredIndex: widget.preferredSubtitleIndex,
        scope: widget.itemId,
      );
      if (c.phase == DlnaPhase.idle && c.devices.isEmpty) c.discover();
    });
  }

  /// 一条投屏请求：把「兼容模式 / 烧录 / 选中的字幕」三个开关折算成
  /// 实际 URL + 是否外挂字幕。
  ///
  /// 烧录模式下字幕已被服务端编进画面，**必须**把 subtitleUrl 置空，
  /// 否则电视会同时显示画面里的和外挂的两份字幕。
  CastRequest _request(DlnaController c, {Duration? startAt}) {
    final sub = c.effectiveSubtitle;
    final burn = c.burnSubtitle && sub != null;
    return CastRequest(
      url: widget.buildUrl(
        compatible: c.compatibleMode,
        burn: burn,
        subtitleIndex: sub?.streamIndex,
      ),
      title: widget.title,
      id: widget.itemId,
      startAt: startAt ?? widget.startAt,
      duration: widget.duration,
      mimeType: (c.compatibleMode || burn)
          ? 'application/vnd.apple.mpegurl'
          : 'video/mp4',
      subtitleUrl: burn ? null : sub?.url,
      subtitleLabel: sub == null
          ? ''
          : (burn ? '${sub.label} · 已烧录' : sub.label),
    );
  }

  /// 改字幕 / 烧录 / 兼容模式后，若正在投屏就用新地址重投一次，
  /// 不让用户「先断开、再改、再点一次」。connecting 中不重投，避免和
  /// 正在进行的 SetAVTransportURI 打架。
  void _recastIfActive(DlnaController c) {
    final d = c.current;
    if (d == null) return;
    final active =
        c.phase == DlnaPhase.playing ||
        c.phase == DlnaPhase.paused ||
        c.phase == DlnaPhase.stopped;
    if (!active) return;
    c.cast(d, _request(c, startAt: c.position));
  }

  void _onCompatibleChanged(bool value) {
    final c = widget.controller;
    c.setCompatibleMode(value);
    _recastIfActive(c);
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.w.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 8),
        _header(ctx),
        const SizedBox(height: 4),
        // 字幕要先于设备列表选好：DLNA 没有标准的「选字幕」动作，
        // 只能在起播那次 SetAVTransportURI 的 metadata 里带过去。
        _subtitleSection(c),
        _stateBody(ctx, c),
        _compatibleRow(c),
        _hintRow(_request(c).url),
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
                color: AppColors.w.withValues(alpha: 0.10),
                border: Border.all(color: AppColors.w.withValues(alpha: 0.14)),
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
          SizedBox(
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
          Icon(
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
            color: AppColors.w.withValues(alpha: 0.35),
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
          // v2.0.85：字幕区占了约 100dp，设备列表上限收一点，避免整张
          // 抽屉在 720p / 小屏机型上顶到状态栏。
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.26,
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
                : AppColors.w.withValues(alpha: 0.04),
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
          Icon(Icons.cast_rounded, size: 22, color: AppColors.accent),
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
                if (c.castSubtitleLabel.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    '字幕：${c.castSubtitleLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppColors.accent,
                    ),
                  ),
                ],
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
            backgroundColor: AppColors.w.withValues(alpha: 0.10),
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
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
        color: AppColors.w.withValues(alpha: 0.07),
        border: Border.all(color: AppColors.w.withValues(alpha: 0.14)),
      ),
      child: Icon(icon, size: 20, color: AppColors.accent),
    ),
  );

  // ── v2.0.85 · 投屏字幕 ─────────────────────────────────────────────────

  /// 选字幕 + 烧录开关。默认走 DIDL-Lite 外挂（无损、不转码）；电视不吃
  /// 外挂字幕时打开烧录，让 Emby 把字幕编进画面（有损、但任何电视都认）。
  Widget _subtitleSection(DlnaController c) {
    if (c.subtitles.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(18, 0, 18, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '本片没有可随投屏发送的字幕轨',
            style: TextStyle(fontSize: 10.5, color: Color(0xFF9FB0CC)),
          ),
        ),
      );
    }
    final sub = c.effectiveSubtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '投屏字幕',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                _subtitleChip(c, label: '不带字幕', value: null),
                for (final s in c.subtitles)
                  _subtitleChip(c, label: s.label, value: s),
              ],
            ),
          ),
          if (sub != null && !sub.isTextFriendly) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '这是图形字幕，电视多半不认；建议打开下面的「字幕烧录」。',
              style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: AppColors.warn,
              ),
            ),
          ],
          const SizedBox(height: 2),
          _burnRow(c, sub),
        ],
      ),
    );
  }

  Widget _subtitleChip(
    DlnaController c, {
    required String label,
    required CastSubtitle? value,
  }) {
    final selected = c.isSubtitleSelected(value);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: LiquidPress(
        radius: 9,
        semanticLabel: '投屏字幕 $label',
        onTap: () {
          c.selectSubtitle(value);
          _recastIfActive(c);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: selected
                ? AppColors.accent.withValues(alpha: 0.20)
                : AppColors.w.withValues(alpha: 0.05),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.6)
                  : AppColors.w.withValues(alpha: 0.12),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.accent : const Color(0xFFDFE7F5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _burnRow(DlnaController c, CastSubtitle? sub) {
    final enabled = sub != null;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '字幕烧录（服务端转码）',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: enabled ? Colors.white : const Color(0xFF9FB0CC),
                ),
              ),
              const Text(
                '电视不显示外挂字幕时打开，画质会有损失',
                style: TextStyle(fontSize: 10, color: Color(0xFF9FB0CC)),
              ),
            ],
          ),
        ),
        Switch(
          value: enabled && c.burnSubtitle,
          onChanged: enabled
              ? (v) {
                  c.setBurnSubtitle(v);
                  _recastIfActive(c);
                }
              : null,
        ),
      ],
    );
  }

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
          const SizedBox(height: 3),
          const Text(
            '字幕以 DIDL-Lite 外挂字段发送，各厂商电视支持不一；不显示时请打开「字幕烧录」。',
            style: TextStyle(
              fontSize: 10.5,
              height: 1.5,
              color: Color(0xFF9FB0CC),
            ),
          ),
          if (!isLanReachableUrl(url)) ...[
            const SizedBox(height: 6),
            Text(
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
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.accent,
        ),
      ),
    ),
  );
}
