import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// 叠加层字幕的显示样式（1.7.38 新增）
///
/// Exo 内核无法原生渲染外挂字幕，由播放页叠加 Text 自己画；旧版本这套文字是
/// 硬编码的「17 号白字 + 四向描边」，在明亮的动画画面 / 大屏横屏上偏小、偏淡。
/// v1.7.38 把它开放成可调项，并持久化到 SharedPreferences（键名与 APK
/// libapp.so 中提取到的保持一致）。
class SubtitleStyle {
  const SubtitleStyle({
    this.size = 17,
    this.pos = 0.12,
    this.opa = 1.0,
    this.stroke = 1.8,
    this.offset = 0.0,
    this.color = Colors.white,
  });

  /// 字号（dp）
  final double size;

  /// 距屏幕底部的相对位置（0 = 贴底，0.5 = 居中偏下）
  final double pos;

  /// 文字不透明度
  final double opa;

  /// 描边宽度（0 = 关闭描边）
  final double stroke;

  /// 相对标准位置的微调（可为负），用于躲开画面下方的硬字幕
  final double offset;

  /// 文字颜色（描边恒为黑，保证任何画面上都读得清）
  final Color color;

  SubtitleStyle copyWith({
    double? size,
    double? pos,
    double? opa,
    double? stroke,
    double? offset,
    Color? color,
  }) =>
      SubtitleStyle(
        size: size ?? this.size,
        pos: pos ?? this.pos,
        opa: opa ?? this.opa,
        stroke: stroke ?? this.stroke,
        offset: offset ?? this.offset,
        color: color ?? this.color,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'size': size,
        'pos': pos,
        'opa': opa,
        'stroke': stroke,
        'offset': offset,
        'color': color.toARGB32(),
      };

  factory SubtitleStyle.fromJson(Map<String, dynamic> j) => SubtitleStyle(
        size: (j['size'] as num?)?.toDouble() ?? 17,
        pos: (j['pos'] as num?)?.toDouble() ?? 0.12,
        opa: (j['opa'] as num?)?.toDouble() ?? 1.0,
        stroke: (j['stroke'] as num?)?.toDouble() ?? 1.8,
        offset: (j['offset'] as num?)?.toDouble() ?? 0.0,
        color: Color((j['color'] as num?)?.toInt() ?? 0xFFFFFFFF),
      );

  /// 字号基准（dp）：libmpv 的 `sub-scale = 1.0` 按这个字号对齐，
  /// 保证 Exo 叠加层与 MPV 原生渲染的观感一致。
  static const double baseSize = 17;

  /// 叠加层文字的最终样式（播放页直接拿去给 Text 用）
  TextStyle get textStyle => TextStyle(
        fontSize: size,
        height: 1.32,
        fontWeight: FontWeight.w600,
        color: color.withAlpha((255 * opa.clamp(0.0, 1.0)).round()),
        shadows: stroke <= 0
            ? const <Shadow>[
                Shadow(color: Color(0xCC000000), blurRadius: 8),
              ]
            : <Shadow>[
                for (final o in const [
                  Offset(1, 1),
                  Offset(-1, 1),
                  Offset(1, -1),
                  Offset(-1, -1),
                ])
                  Shadow(
                    color: const Color(0xE6000000),
                    blurRadius: stroke,
                    offset: o,
                  ),
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
  static const String kOpa = 'camby_sub_opa';
  static const String kStroke = 'camby_sub_stroke';
  static const String kOffset = 'camby_sub_offset';
  static const String kColor = 'camby_sub_color';

  /// 读取历史样式；没有记录时返回默认值
  static Future<SubtitleStyle> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasAny = prefs.containsKey(kSize) ||
          prefs.containsKey(kPos) ||
          prefs.containsKey(kColor);
      if (!hasAny) return const SubtitleStyle();
      return SubtitleStyle(
        size: prefs.getDouble(kSize) ?? 17,
        pos: prefs.getDouble(kPos) ?? 0.12,
        opa: prefs.getDouble(kOpa) ?? 1.0,
        stroke: prefs.getDouble(kStroke) ?? 1.8,
        offset: prefs.getDouble(kOffset) ?? 0.0,
        color: Color(prefs.getInt(kColor) ?? 0xFFFFFFFF),
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
      await prefs.setDouble(kOpa, s.opa);
      await prefs.setDouble(kStroke, s.stroke);
      await prefs.setDouble(kOffset, s.offset);
      await prefs.setInt(kColor, s.color.toARGB32());
    } catch (_) {
      /* 样式存不下不影响播放 */
    }
  }
}

/// 字幕样式面板：播放页底栏「字幕」长按 / 「字幕样式」入口拉起。
///
/// 拖动即时预览（_emit），松手后落盘（_commit）。
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

  static const List<Color> _palette = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFFFFF3B0),
    Color(0xFFA6FFB2),
    Color(0xFFFFC7F0),
    Color(0xFF9FD8FF),
    Color(0xFFD3C4FF),
  ];

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

  /// 数值微调：±step 后立刻提交（滑块在横屏大屏上很难拖准，补一组 ± 按钮）
  Future<void> _nudge(
    double current,
    double step,
    double min,
    double max,
    SubtitleStyle Function(double v) apply,
  ) async {
    final v = (current + step).clamp(min, max);
    await _commit(apply(v.toDouble()));
  }

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
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 12, 18, 6),
              child: Row(
                children: [
                  Text(
                    '字幕样式',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            // 实时预览
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0.5),
                      AppColors.bg.withOpacity(0.35),
                    ],
                  ),
                ),
                child: SizedBox(
                  height: 84,
                  child: Center(
                    child: Text(
                      '字幕预览 Subtitle Preview',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: _style.textStyle,
                    ),
                  ),
                ),
              ),
            ),
            _colorRow(),
            _slider(
              label: '字号',
              value: _style.size,
              min: 12,
              max: 30,
              step: 1,
              display: '${_style.size.round()}',
              onLive: (v) => _emit(_style.copyWith(size: v)),
              onCommit: (v) => _commit(_style.copyWith(size: v)),
            ),
            _slider(
              label: '位置',
              value: _style.pos,
              min: 0.04,
              max: 0.45,
              step: 0.01,
              display: '${(_style.pos * 100).round()}%',
              onLive: (v) => _emit(_style.copyWith(pos: v)),
              onCommit: (v) => _commit(_style.copyWith(pos: v)),
            ),
            _slider(
              label: '偏移',
              value: _style.offset,
              min: -0.2,
              max: 0.2,
              step: 0.01,
              display: _style.offset.toStringAsFixed(2),
              onLive: (v) => _emit(_style.copyWith(offset: v)),
              onCommit: (v) => _commit(_style.copyWith(offset: v)),
            ),
            _slider(
              label: '不透明度',
              value: _style.opa,
              min: 0.3,
              max: 1.0,
              step: 0.05,
              display: '${(_style.opa * 100).round()}%',
              onLive: (v) => _emit(_style.copyWith(opa: v)),
              onCommit: (v) => _commit(_style.copyWith(opa: v)),
            ),
            _slider(
              label: '描边',
              value: _style.stroke,
              min: 0,
              max: 4,
              step: 0.2,
              display: _style.stroke.toStringAsFixed(1),
              onLive: (v) => _emit(_style.copyWith(stroke: v)),
              onCommit: (v) => _commit(_style.copyWith(stroke: v)),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _colorRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 62,
            child: Text(
              '颜色',
              style: TextStyle(fontSize: 12, color: Color(0xFF9FB0CC)),
            ),
          ),
          ..._palette.map(
            (c) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _ColorSwatch(
                color: c,
                selected: _style.color.toARGB32() == c.toARGB32(),
                onTap: () => _commit(_style.copyWith(color: c)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider({
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
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9FB0CC),
                ),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: Colors.white,
            icon: const Icon(Icons.remove_rounded),
            onPressed: value > min
                ? () => _nudge(
                      value,
                      -step,
                      min,
                      max,
                      (v) => _copyBy(label, v),
                    )
                : null,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: Colors.white.withOpacity(0.16),
                thumbColor: Colors.white,
                overlayColor: AppColors.accent.withOpacity(0.2),
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 8),
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
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: Colors.white,
            icon: const Icon(Icons.add_rounded),
            onPressed: value < max
                ? () => _nudge(
                      value,
                      step,
                      min,
                      max,
                      (v) => _copyBy(label, v),
                    )
                : null,
          ),
          SizedBox(
            width: 42,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  SubtitleStyle _copyBy(String label, double v) {
    switch (label) {
      case '字号':
        return _style.copyWith(size: v);
      case '位置':
        return _style.copyWith(pos: v);
      case '偏移':
        return _style.copyWith(offset: v);
      case '不透明度':
        return _style.copyWith(opa: v);
      case '描边':
        return _style.copyWith(stroke: v);
      default:
        return _style;
    }
  }
}

/// 色板上的一颗颜色
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected ? Colors.white : Colors.white.withOpacity(0.25),
            width: selected ? 2.4 : 1,
          ),
          boxShadow: [
            if (selected)
              BoxShadow(
                color: color.withOpacity(0.7),
                blurRadius: 10,
                spreadRadius: 1,
              ),
          ],
        ),
      ),
    );
  }
}

/// 兼容旧 Widget 的小工具：把样式序列化成字符串调试用
String debugStyleJson(SubtitleStyle s) => jsonEncode(s.toJson());
