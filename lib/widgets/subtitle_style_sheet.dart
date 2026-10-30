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
  }) => SubtitleStyle(
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
        ? const <Shadow>[Shadow(color: Color(0xCC000000), blurRadius: 8)]
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
      final hasAny =
          prefs.containsKey(kSize) ||
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

/// 字幕样式面板：播放页「字幕样式」入口拉起。
///
/// 版式严格按设计稿：标题 + 右上关闭圆钮；四行滑杆（大小 / 位置 / 描边 /
/// 不透明度），右侧蓝色语义化数值；底部一行颜色圆点。
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

  /// 设计稿色板：白 / 黄 / 绿 / 蓝 / 红
  static const List<Color> _palette = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFFF7D354),
    Color(0xFF82D98C),
    Color(0xFF85B6F0),
    Color(0xFFF28D8D),
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

  String get _strokeLabel {
    final v = _style.stroke;
    if (v <= 0) return '关闭';
    if (v < 1.2) return '较细';
    if (v < 2.6) return '适中';
    return '较粗';
  }

  String get _opaLabel => '${(_style.opa * 100).round()}%';

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
                  padding: const EdgeInsets.fromLTRB(22, 14, 14, 4),
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
                      const _CloseButton(),
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
                        _styleRow(
                          label: '描边',
                          value: _style.stroke,
                          min: 0,
                          max: 4,
                          step: 0.2,
                          display: _strokeLabel,
                          onLive: (v) => _emit(_style.copyWith(stroke: v)),
                          onCommit: (v) => _commit(_style.copyWith(stroke: v)),
                        ),
                        _styleRow(
                          label: '不透明度',
                          value: _style.opa,
                          min: 0.3,
                          max: 1.0,
                          step: 0.05,
                          display: _opaLabel,
                          onLive: (v) => _emit(_style.copyWith(opa: v)),
                          onCommit: (v) => _commit(_style.copyWith(opa: v)),
                        ),
                        _colorRow(),
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

  Widget _colorRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 4),
      child: Row(
        children: [
          const SizedBox(
            width: 76,
            child: Text(
              '颜色',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          ..._palette.map(
            (c) => Padding(
              padding: const EdgeInsets.only(right: 12),
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
}

/// 弹层右上角的圆形关闭钮
class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).maybePop(),
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
