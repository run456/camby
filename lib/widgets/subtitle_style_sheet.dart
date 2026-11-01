import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// 叠加层字幕的显示样式（1.7.38 新增）
///
/// Exo 内核无法原生渲染外挂字幕，由播放页叠加 Text 自己画；旧版本这套文字是
/// 硬编码的「17 号白字 + 四向描边」。v1.7.38 把它开放为可调项，v2.0.17 起
/// 把样式固定为「影院风格」（白色加粗 + 黑色硬描边），仅保留大小 / 位置两项
/// 可调，避免用户把字幕调得看不清。
class SubtitleStyle {
  const SubtitleStyle({
    this.size = 17,
    this.pos = 0.12,
    this.offset = 0.0,
  });

  /// 字号（dp）
  final double size;

  /// 距屏幕底部的相对位置（0 = 贴底，0.5 = 居中偏下）
  final double pos;

  /// 相对标准位置的微调（可为负），用于躲开画面下方的硬字幕
  final double offset;

  SubtitleStyle copyWith({
    double? size,
    double? pos,
    double? offset,
  }) => SubtitleStyle(
    size: size ?? this.size,
    pos: pos ?? this.pos,
    offset: offset ?? this.offset,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'size': size,
    'pos': pos,
    'offset': offset,
  };

  factory SubtitleStyle.fromJson(Map<String, dynamic> j) => SubtitleStyle(
    size: (j['size'] as num?)?.toDouble() ?? 17,
    pos: (j['pos'] as num?)?.toDouble() ?? 0.12,
    offset: (j['offset'] as num?)?.toDouble() ?? 0.0,
  );

  /// 字号基准（dp）：libmpv 的 `sub-scale = 1.0` 按这个字号对齐，
  /// 保证 Exo 叠加层与 MPV 原生渲染的观感一致。
  static const double baseSize = 17;

  /// 影院风格固定样式（v2.0.17 起固定，不再可调）：
  /// 白色加粗 + 黑色硬描边，任何画面上都清晰可读，与目标截图一致。
  static const Color _textColor = Color(0xFFFFFFFF);
  static const Color _strokeColor = Color(0xFF000000);

  /// 叠加层文字的最终样式（播放页直接拿去给 Text 用）
  TextStyle get textStyle => TextStyle(
    fontSize: size,
    height: 1.32,
    fontWeight: FontWeight.w800,
    color: _textColor,
    shadows: <Shadow>[
      for (final o in <Offset>[
        Offset(1, 1), Offset(-1, 1), Offset(1, -1), Offset(-1, -1),
        Offset(0, 1), Offset(0, -1), Offset(1, 0), Offset(-1, 0),
      ])
        Shadow(color: _strokeColor, blurRadius: 0.5, offset: o),
    ],
  );

  /// 距底部的实际位置比例（标准位置 + 微调）
  double get bottomRatio => (pos + offset).clamp(0.0, 0.6);
}

/// 字幕样式的持久化读写
abstract final class SubtitleStyleStore {
  // 键名与 APK libapp.so 中提取到的字符串保持一致
  static const String kSize = 'camby_sub_size';
  static const String kPos = 'camby_sub_pos';
  static const String kOffset = 'camby_sub_offset';

  /// 读取历史样式；没有记录时返回默认值
  static Future<SubtitleStyle> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasAny = prefs.containsKey(kSize) || prefs.containsKey(kPos);
      if (!hasAny) return const SubtitleStyle();
      return SubtitleStyle(
        size: prefs.getDouble(kSize) ?? 17,
        pos: prefs.getDouble(kPos) ?? 0.12,
        offset: prefs.getDouble(kOffset) ?? 0.0,
      );
    } catch (_) {
      return const SubtitleStyle();
    }
  }

  static Future<void> save(SubtitleStyle s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(kSize, s.size);
      await prefs.setDouble(kPos, s.pos);
      await prefs.setDouble(kOffset, s.offset);
    } catch (_) {
      /* 样式存不下不影响播放 */
    }
  }
}

/// 字幕样式面板：播放页「字幕样式」入口拉起。
///
/// 版式严格按设计稿：标题 + 右上关闭圆钮；两行滑杆（大小 / 位置），
/// 右侧蓝色语义化数值。字幕样式（白字加粗 + 黑描边）现已固定为影院风格，
/// 仅开放大小与位置两项可调。
/// 拖动即时预览（_emit），松手落盘（_commit）。
class SubtitleStyleSheet extends StatefulWidget {
  const SubtitleStyleSheet({
    super.key,
    required this.style,
    required this.onChanged,
  });

  final SubtitleStyle style;

  /// [commit] = true 表示本次变更要落盘（拖动结束 / 点色板）
  final void Function(SubtitleStyle next, bool commit) onChanged;

  @override
  State<SubtitleStyleSheet> createState() => _SubtitleStyleSheetState();
}

class _SubtitleStyleSheetState extends State<SubtitleStyleSheet> {
  late SubtitleStyle _style;

  @override
  void initState() {
    super.initState();
    _style = widget.style;
  }

  /// 拖动过程中：只向上抛样式变化做即时预览，不写盘
  void _emit(SubtitleStyle next) {
    _style = next;
    widget.onChanged(next, false);
    if (mounted) setState(() {});
  }

  /// 松手 / 点选：正式提交 + 持久化
  Future<void> _commit(SubtitleStyle next) async {
    _style = next;
    widget.onChanged(next, true);
    await SubtitleStyleStore.save(next);
    if (mounted) setState(() {});
  }

  /// 确认：落盘并关闭面板
  Future<void> _confirm() async {
    widget.onChanged(_style, true);
    await SubtitleStyleStore.save(_style);
    if (mounted) Navigator.of(context).maybePop();
  }

  /// 关闭 = 取消：把拖动过程中的即时预览回滚到打开面板时的样式
  Future<void> _cancel() async {
    final orig = widget.style;
    widget.onChanged(orig, true);
    await SubtitleStyleStore.save(orig);
    if (mounted) Navigator.of(context).maybePop();
  }

  /// 恢复默认：直接套回出厂样式（并即时下发，方便当场看效果）
  Future<void> _resetDefaults() => _commit(const SubtitleStyle());

  // ---- 数值 → 设计稿语义文案 ----

  String get _sizeLabel =>
      '${(_style.size / SubtitleStyle.baseSize * 100).round()}%';

  String get _posLabel {
    final v = _style.pos;
    if (v < 0.10) return '很低';
    if (v < 0.16) return '偏低';
    if (v < 0.24) return '适中';
    if (v < 0.32) return '偏高';
    return '很高';
  }

  @override
  Widget build(BuildContext context) {
    // 与播放页 _GlassPanel 保持同一套尺寸规则：横屏下尽量吃满可用高度
    final media = MediaQuery.of(context);
    final avail = media.size.height - media.padding.vertical;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 470, maxHeight: avail - 24),
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
          // Material(transparency)：弹层路由没有 Material 祖先，
          // 缺它时 Text 落回 fallback 样式（debug 下出现黄色下划线）
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 12, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '字幕样式',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      // 恢复默认 / 确认 放在关闭旁边（面板高度吃紧时不用
                      // 再往下滚去找按钮）
                      _HeaderBtn(label: '恢复默认', onTap: _resetDefaults),
                      const SizedBox(width: 8),
                      _HeaderBtn(label: '确认', primary: true, onTap: _confirm),
                      const SizedBox(width: 8),
                      _CloseButton(onTap: _cancel),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(top: 6, bottom: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _styleRow(
                          label: '大小',
                          value: _style.size,
                          min: 12,
                          max: 30,
                          step: 1,
                          display: _sizeLabel,
                          onLive: (v) => _emit(_style.copyWith(size: v)),
                          onCommit: (v) => _commit(_style.copyWith(size: v)),
                        ),
                        _styleRow(
                          label: '位置',
                          value: _style.pos,
                          min: 0.04,
                          max: 0.45,
                          step: 0.01,
                          display: _posLabel,
                          onLive: (v) => _emit(_style.copyWith(pos: v)),
                          onCommit: (v) => _commit(_style.copyWith(pos: v)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 设计稿的一行：左侧标签 + 中间滑杆 + 右侧蓝色语义值
  Widget _styleRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required double step,
    required String display,
    required ValueChanged<double> onLive,
    required ValueChanged<double> onCommit,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 2, 22, 2),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: Colors.white.withOpacity(0.16),
                thumbColor: Colors.white,
                overlayColor: AppColors.accent.withOpacity(0.2),
                trackHeight: 3.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: ((max - min) / step).round(),
                onChanged: onLive,
                onChangeEnd: onCommit,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF7FA8EE),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹层右上角的圆形关闭钮（＝取消，回滚本次调整）
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.10),
          border: Border.all(color: Colors.white.withOpacity(0.14)),
        ),
        child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
      ),
    );
  }
}

/// 标题行右侧的小胶囊按钮（恢复默认 / 确认）
class _HeaderBtn extends StatelessWidget {
  const _HeaderBtn({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          gradient: primary
              ? const LinearGradient(
                  colors: [Color(0xFF2F7FE8), Color(0xFF4F9CFF)],
                )
              : null,
          color: primary ? null : Colors.white.withOpacity(0.10),
          border: Border.all(
            color: primary
                ? const Color(0x66FFFFFF)
                : Colors.white.withOpacity(0.14),
          ),
          boxShadow: primary
              ? const [
                  BoxShadow(
                    color: Color(0x592F7FE8),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: primary ? Colors.white : const Color(0xFFC9D6EA),
            ),
          ),
        ),
      ),
    );
  }
}
