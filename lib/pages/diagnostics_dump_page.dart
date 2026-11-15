import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_sheet.dart';
import '../widgets/glass_toast.dart';
import '../widgets/liquid_press.dart';

/// 诊断导出页（v2.0.95）：把服务端下发的**原始条目 JSON**完整摊开，供定位
/// 绿联影视中心（UGOS Pro）兼容层字段差异。
///
/// 为什么需要：问题 2/4 的精确根因（首页图片字段、傲骨贤妻第 1 季是否被登记成
/// `Type=Season`）依赖真机原始 JSON，沙箱连不上用户局域网。本页把 `Movie /
/// Series / Season` 全部拉下来（含 `_fromJson` 解析前的中间态），用户可复制
/// 指定条目（如「傲骨贤妻」相关季）或一次性复制全部，贴回对话后由下一回合修。
class DiagnosticsDumpPage extends StatefulWidget {
  const DiagnosticsDumpPage({super.key, required this.state});

  final AppState state;

  @override
  State<DiagnosticsDumpPage> createState() => _DiagnosticsDumpPageState();
}

class _DiagnosticsDumpPageState extends State<DiagnosticsDumpPage> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final server = widget.state.server;
    if (server == null) {
      setState(() {
        _loading = false;
        _error = '请先连接服务器';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await server.rawItemJsons();
      setState(() {
        _items = data;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where((e) {
          final name = (e['Name'] as String? ?? '').toLowerCase();
          final id = (e['Id'] as String? ?? '').toLowerCase();
          return name.contains(q) || id.contains(q);
        })
        .toList();
  }

  String _pretty(Map<String, dynamic> m) =>
      const JsonEncoder.withIndent('  ').convert(m);

  Future<void> _copy(String text, {String? label}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showToast(context, label ?? '已复制 JSON', icon: Icons.copy_all_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = context.isTablet;
    final hPad = wide ? 24.0 : 16.0;
    final top = MediaQuery.of(context).padding.top;
    final list = _filtered;

    return Container(
      color: AppColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, top + 12, hPad, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    size: 22,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '导出原始条目 JSON',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      Text(
                        '原始字段（未解析）· 共 ${_items.length} 条'
                        '${_query.isNotEmpty ? ' · 命中 ${list.length}' : ''}',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_loading && _error == null)
                  LiquidPress(
                    radius: 12,
                    onTap: () => _copy(
                      _pretty(<String, dynamic>{
                        'TotalRecordCount': _items.length,
                        'Items': _items,
                      }),
                      label: '已复制全部原始 JSON',
                    ),
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: AppColors.primary.withOpacity(0.16),
                        border: Border.all(
                          color: AppColors.primary.withOpacity(0.45),
                        ),
                      ),
                      child: const Center(
                        child: Text(
                          '复制全部',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 8),
            child: _searchBox(),
          ),
          Expanded(
            child: _body(list, hPad),
          ),
        ],
      ),
    );
  }

  Widget _searchBox() => SizedBox(
        height: 36,
        child: TextField(
          controller: _controller,
          onChanged: (v) => setState(() => _query = v),
          style: const TextStyle(fontSize: 12, color: Colors.white),
          cursorColor: AppColors.primary,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppColors.w.withValues(alpha: 0.05),
            hintText: '搜索片名 / Id（如 傲骨贤妻）…',
            hintStyle: TextStyle(
              fontSize: 11.5,
              color: AppColors.w.withValues(alpha: 0.35),
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 16,
              color: AppColors.w.withValues(alpha: 0.45),
            ),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: AppColors.w.withValues(alpha: 0.45),
                    ),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                  ),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: BorderSide(color: AppColors.w.withValues(alpha: 0.10)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: BorderSide(color: AppColors.w.withValues(alpha: 0.10)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide:
                  BorderSide(color: AppColors.primary.withOpacity(0.55)),
            ),
          ),
        ),
      );

  Widget _body(List<Map<String, dynamic>> list, double hPad) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.only(top: 48),
        children: [
          EmptyState(
            icon: Icons.cloud_off_rounded,
            title: '拉取失败',
            reason: _error!,
            primaryLabel: '重试',
            onPrimary: _load,
          ),
        ],
      );
    }
    if (list.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的条目',
          style: TextStyle(fontSize: 12, color: AppColors.muted),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 120),
      itemCount: list.length,
      itemBuilder: (c, i) {
        final e = list[i];
        final name = e['Name'] as String? ?? '(无名)';
        final type = e['Type'] as String? ?? '?';
        final id = e['Id'] as String? ?? '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: LiquidPress(
            radius: 13,
            onTap: () => _openItem(e),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                color: AppColors.w.withValues(alpha: 0.045),
                border: Border.all(color: AppColors.w.withValues(alpha: 0.10)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$type · $id',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.copy_rounded,
                      size: 18,
                      color: AppColors.primary.withOpacity(0.9),
                    ),
                    onPressed: () => _copy(_pretty(e)),
                    tooltip: '复制此条 JSON',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openItem(Map<String, dynamic> e) async {
    final pretty = _pretty(e);
    await showAppDialog<void>(
      context: context,
      title: e['Name'] as String? ?? '条目 JSON',
      bodyBuilder: (ctx) => SingleChildScrollView(
        child: SelectableText(
          pretty,
          style: const TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.5,
            color: Color(0xFF9FB0CC),
          ),
        ),
      ),
      actions: [
        AppDialogAction(
          label: '复制',
          onTap: (ctx) {
            _copy(pretty);
            Navigator.pop(ctx);
          },
        ),
        const AppDialogAction(label: '关闭'),
      ],
    );
  }
}
