import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets/glass_sheet.dart';
import '../widgets/glass_toast.dart';
import 'lara_client.dart';
import 'translate_cache.dart';

/// 打开「翻译」玻璃弹层。
///
/// [itemId] / [field] 用于缓存定位（title / overview）；[original] 是要翻译的
/// 原文；[existing] 是已缓存的译文，非空时打开即直接展示（满足「下次点开直接查看」）。
/// 返回 push 的 future，调用方可在弹层关闭后刷新「已译」标记。
Future<T?> showTranslateSheet<T>(
  BuildContext context, {
  required String itemId,
  required String field,
  required String original,
  CachedTranslation? existing,
}) {
  if (!context.mounted) return Future<T?>.value(null);
  return Navigator.of(context).push<T>(
    GlassPanelRoute<T>(
      builder: (_) => _TranslateSheet(
        itemId: itemId,
        field: field,
        original: original,
        existing: existing,
      ),
    ),
  );
}

class _TranslateSheet extends StatefulWidget {
  const _TranslateSheet({
    required this.itemId,
    required this.field,
    required this.original,
    this.existing,
  });

  final String itemId;
  final String field;
  final String original;
  final CachedTranslation? existing;

  @override
  State<_TranslateSheet> createState() => _TranslateSheetState();
}

class _TranslateSheetState extends State<_TranslateSheet> {
  late LaraStyle _style;
  String? _translation;
  String _detectedSource = '';
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final cached = widget.existing;
    _style = cached != null ? _styleFromParam(cached.style) : LaraStyle.faithful;
    if (cached != null) {
      _translation = cached.text;
      _detectedSource = cached.detectedSource;
    }
  }

  LaraStyle _styleFromParam(String s) {
    for (final e in LaraStyle.values) {
      if (LaraClient.styleParam[e] == s) return e;
    }
    return LaraStyle.faithful;
  }

  Future<void> _doTranslate() async {
    if (_loading) return;
    final creds = await LaraCredentials.load();
    if (!mounted) return;
    if (creds == null || !creds.isValid) {
      showToast(
        context,
        '请先在设置页配置 Lara Access Key',
        icon: Icons.key_off_outlined,
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = LaraClient(creds);
      final res = await client.translate(
        widget.original,
        style: _style,
        noTrace: true,
      );
      if (!mounted) return;
      setState(() {
        _translation = res.translation;
        _detectedSource = res.sourceLanguage;
      });
    } on LaraAuthError catch (e) {
      if (!mounted) return;
      setState(() => _error = '鉴权失败：${e.message}');
    } on LaraApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = '翻译失败（${e.statusCode}）：${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '翻译失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmCache() async {
    if (_translation == null || _translation!.trim().isEmpty) return;
    await LaraTranslateCache.save(
      widget.itemId,
      widget.field,
      _translation!,
      LaraTranslateCache.metaOf(
        target: 'zh-CN',
        style: LaraClient.styleParam[_style]!,
        detectedSource: _detectedSource,
      ),
    );
    if (!mounted) return;
    showToast(context, '已缓存译文', icon: Icons.check_circle_outline_rounded);
  }

  Future<void> _copy() async {
    if (_translation == null || _translation!.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _translation!));
    if (!mounted) return;
    showToast(context, '译文已复制', icon: Icons.copy_outlined);
  }

  @override
  Widget build(BuildContext context) {
    final hasResult = _translation != null && _translation!.isNotEmpty;
    return Column(
      children: [
        _Header(onClose: () => Navigator.pop(context)),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BlockLabel('原文'),
                _TextCard(
                  child: SelectableText(
                    widget.original,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: Color(0xFFD3DEF0),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _BlockLabel('翻译风格'),
                _StylePicker(
                  value: _style,
                  onChanged: (s) => setState(() => _style = s),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _doTranslate,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            widget.existing != null ? '重新翻译' : '翻译',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 14),
                _BlockLabel('译文（中文）'),
                _TextCard(
                  minHeight: 64,
                  child: hasResult
                      ? SelectableText(
                          _translation!,
                          style: const TextStyle(
                            fontSize: 13.5,
                            height: 1.65,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _loading ? '翻译中…' : '点击上方「翻译」生成译文',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF9FB0CC),
                          ),
                        ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: AppColors.danger,
                    ),
                  ),
                ],
                if (hasResult) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _confirmCache,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            side: BorderSide(
                              color: AppColors.accent.withValues(alpha: 0.5),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('确认并缓存'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _copy,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFC6D3E6),
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('复制'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          const Text(
            'Lara 翻译',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, color: Color(0xFF9FB0CC)),
            iconSize: 20,
            splashRadius: 18,
          ),
        ],
      ),
    );
  }
}

class _BlockLabel extends StatelessWidget {
  const _BlockLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF9FB0CC),
          ),
        ),
      );
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.child, this.minHeight = 0});
  final Widget child;
  final double minHeight;
  @override
  Widget build(BuildContext context) => Container(
        constraints: BoxConstraints(minHeight: minHeight),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: child,
      );
}

class _StylePicker extends StatelessWidget {
  const _StylePicker({required this.value, required this.onChanged});
  final LaraStyle value;
  final ValueChanged<LaraStyle> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final s in LaraStyle.values)
            ChoiceChip(
              label: Text(LaraClient.styleLabel[s]!),
              selected: value == s,
              onSelected: (_) => onChanged(s),
              selectedColor: AppColors.accent.withValues(alpha: 0.22),
              checkmarkColor: AppColors.accent,
              labelStyle: TextStyle(
                fontSize: 12.5,
                color: value == s ? AppColors.accent : const Color(0xFFC6D3E6),
                fontWeight: value == s ? FontWeight.w700 : FontWeight.normal,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: value == s
                      ? AppColors.accent.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.12),
                ),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.04),
            ),
        ],
      );
}
