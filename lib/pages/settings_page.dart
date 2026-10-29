import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../widgets/liquid_press.dart';
import '../widgets/glass_toast.dart';
import '../models.dart';
import '../theme.dart';

/// 「我的」设置页：所有控件可交互，选择持久化到 SharedPreferences
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.onTabChanged,
    required this.state,
  });

  final void Function(int tab) onTabChanged;
  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _bitrates = ['自动', '40 Mbps', '20 Mbps', '10 Mbps'];
  static const _caches = ['512 MB', '1 GB', '2 GB', '4 GB'];
  static const _subLangs = ['简体中文', '繁體中文', 'English', '关闭'];

  Map<String, dynamic> _s = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _s = {
        'play_engine': prefs.getInt('set_play_engine') ?? 0,
        'hw_decode': prefs.getBool('set_hw_decode') ?? true,
        'auto_next': prefs.getBool('set_auto_next') ?? true,
        'max_bitrate': prefs.getInt('set_max_bitrate') ?? 0,
        'cache_size': prefs.getInt('set_cache_size') ?? 0,
        'sub_lang': prefs.getInt('set_sub_lang') ?? 0,
        'ass_subtitle': prefs.getBool('set_ass_subtitle') ?? true,
        'online_subtitle': prefs.getBool('set_online_subtitle') ?? true,
        'danmaku': prefs.getBool('set_danmaku') ?? true,
        'danmaku_anti': prefs.getBool('set_danmaku_anti') ?? true,
        'danmaku_opacity': prefs.getDouble('set_danmaku_opacity') ?? 0.35,
        'monet': prefs.getBool('set_monet') ?? true,
        'glass_strength': prefs.getDouble('set_glass_strength') ?? 0.7,
        'theme_idx': prefs.getInt('set_theme_idx') ?? 0,
        'record_history': prefs.getBool('set_record_history') ?? true,
        'pip': prefs.getBool('set_pip') ?? true,
        'bubble': prefs.getBool('set_bubble') ?? false,
      };
    });
  }

  Future<void> _set(String key, dynamic value) async {
    setState(() => _s[key] = value);
    final prefs = await SharedPreferences.getInstance();
    if (value is int) await prefs.setInt('set_$key', value);
    if (value is bool) await prefs.setBool('set_$key', value);
    if (value is double) await prefs.setDouble('set_$key', value);
  }

  void _toast(String msg) => showToast(context, msg);

  /// 导出统计数据：JSON 复制到剪贴板
  Future<void> _exportStats() async {
    final st = widget.state.stats;
    final json =
        '''
{
  "来源": "${widget.state.sourceLabel}",
  "电影": ${st.movieCount},
  "剧集": ${st.seriesCount},
  "总时长小时": ${st.totalLibraryHours},
  "已看完": ${st.watchedCount},
  "收藏": ${st.favoriteCount},
  "播放次数": ${st.playCount},
  "完成率": "${(st.completionRate * 100).toStringAsFixed(1)}%",
  "类型分布": {${st.genreDistribution.entries.map((e) => '"${e.key}": ${(e.value * 100).round()}').join(", ")}}
}''';
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    _toast('统计数据已复制到剪贴板');
  }

  @override
  Widget build(BuildContext context) {
    if (_s.isEmpty) {
      return Container(
        color: AppColors.bg,
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B1120), AppColors.bg],
        ),
      ),
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + 14,
          16,
          110,
        ),
        children: [
          Row(
            children: [
              const Icon(Icons.person_rounded, size: 20, color: AppColors.ink),
              const SizedBox(width: 10),
              const Text(
                '我的',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ServersSection(state: widget.state),
          const SizedBox(height: 12),
          _Group(
            children: [
              _RowItem(
                title: '默认播放内核',
                desc: _s['play_engine'] == 0
                    ? 'ExoPlayer · 兼容性最佳'
                    : 'MPV · 硬解更强',
                trailing: _Segment(
                  items: const ['Exo', 'MPV'],
                  value: _s['play_engine'],
                  onSelect: (i) => _set('play_engine', i),
                ),
              ),
              _RowItem(
                title: '硬件解码优先',
                desc: '关闭则走软解',
                trailing: _Toggle(
                  value: _s['hw_decode'],
                  onChanged: (v) => _set('hw_decode', v),
                ),
              ),
              _RowItem(
                title: '自动连播下一集',
                trailing: _Toggle(
                  value: _s['auto_next'],
                  onChanged: (v) => _set('auto_next', v),
                ),
              ),
              _RowItem(
                title: '最大码率',
                desc: _bitrates[_s['max_bitrate']],
                trailing: _Value(
                  _bitrates[_s['max_bitrate']],
                  onTap: () => _set(
                    'max_bitrate',
                    ((_s['max_bitrate'] as int) + 1) % _bitrates.length,
                  ),
                ),
              ),
              _RowItem(
                title: '缓存大小',
                desc: _caches[_s['cache_size']],
                trailing: _Value(
                  _caches[_s['cache_size']],
                  onTap: () => _set(
                    'cache_size',
                    ((_s['cache_size'] as int) + 1) % _caches.length,
                  ),
                ),
                last: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Group(
            children: [
              _RowItem(
                title: '字幕默认语言',
                trailing: _Value(
                  _subLangs[_s['sub_lang']],
                  onTap: () => _set(
                    'sub_lang',
                    ((_s['sub_lang'] as int) + 1) % _subLangs.length,
                  ),
                ),
              ),
              _RowItem(
                title: 'ASS 特效字幕渲染',
                desc: '需 MPV 内核',
                trailing: _Toggle(
                  value: _s['ass_subtitle'],
                  onChanged: (v) => _set('ass_subtitle', v),
                ),
              ),
              _RowItem(
                title: '在线字幕搜索',
                desc: '自动匹配字幕',
                trailing: _Toggle(
                  value: _s['online_subtitle'],
                  onChanged: (v) => _set('online_subtitle', v),
                ),
                last: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Group(
            children: [
              _RowItem(
                title: '播放弹幕',
                trailing: _Toggle(
                  value: _s['danmaku'],
                  onChanged: (v) => _set('danmaku', v),
                ),
              ),
              _RowItem(
                title: '弹幕人物防遮挡',
                trailing: _Toggle(
                  value: _s['danmaku_anti'],
                  onChanged: (v) => _set('danmaku_anti', v),
                ),
              ),
              _RowItem(
                title: '弹幕透明度',
                desc: '${(_s['danmaku_opacity'] * 100).round()}%',
                trailing: _SliderRow(
                  value: _s['danmaku_opacity'],
                  onChanged: (v) => _set('danmaku_opacity', v),
                ),
                last: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Group(
            children: [
              _RowItem(
                title: '主题',
                desc: '深海 · 夜间',
                trailing: _ThemeDots(
                  value: _s['theme_idx'],
                  onSelect: (i) => _set('theme_idx', i),
                ),
              ),
              _RowItem(
                title: 'Monet 动态取色',
                desc: '跟随系统壁纸色',
                trailing: _Toggle(
                  value: _s['monet'],
                  onChanged: (v) => _set('monet', v),
                ),
              ),
              _RowItem(
                title: '液态玻璃强度',
                desc: '${(_s['glass_strength'] * 40).round()} px',
                trailing: _SliderRow(
                  value: _s['glass_strength'],
                  onChanged: (v) => _set('glass_strength', v),
                ),
                last: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Group(
            children: [
              _RowItem(
                title: '记录观看明细',
                desc: '用于时段热力图与趋势',
                trailing: _Toggle(
                  value: _s['record_history'],
                  onChanged: (v) => _set('record_history', v),
                ),
              ),
              _RowItem(
                title: '导出统计数据',
                desc: 'JSON · 复制到剪贴板',
                trailing: _Value('导出', onTap: _exportStats),
                last: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Group(
            children: [
              _RowItem(
                title: '交互式画中画',
                desc: 'Android 17 新能力',
                trailing: _Toggle(
                  value: _s['pip'],
                  onChanged: (v) => _set('pip', v),
                ),
              ),
              _RowItem(
                title: '悬浮气泡小窗',
                desc: 'App Bubbles',
                trailing: _Toggle(
                  value: _s['bubble'],
                  onChanged: (v) => _set('bubble', v),
                ),
                last: true,
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Center(
            child: Text(
              'Camby v1.7.16 (56) · arm64 · 隐私政策 · 开源许可',
              style: TextStyle(fontSize: 10, color: Color(0xFF5D7291)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServersSection extends StatelessWidget {
  const _ServersSection({required this.state});

  final AppState state;

  void _openSheet(
    BuildContext context,
    ServerProfile? p, {
    ServerKind? presetKind,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) =>
          _ServerSheet(state: state, profile: p, presetKind: presetKind),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ServerProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161E2E),
        title: const Text('删除服务器', style: TextStyle(fontSize: 16)),
        content: Text(
          '确定删除「${p.name}」？只删除保存的配置，不会影响服务器上的数据。',
          style: const TextStyle(fontSize: 13, color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteServer(p.id);
  }

  @override
  Widget build(BuildContext context) {
    final servers = state.servers;
    final activeId = state.activeServerId;
    // 离线读缓存时 server 为 null，不能算"已连接"
    final connected = !state.demoMode && state.server != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.dns_rounded, size: 15, color: AppColors.muted),
            const SizedBox(width: 7),
            const Text(
              '我的服务器',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppColors.muted,
                letterSpacing: 0.2,
              ),
            ),
            const Spacer(),
            LiquidPress(
              onTap: () => _openSheet(context, null),
              radius: 8,
              scale: 0.94,
              child: const Row(
                children: [
                  Icon(Icons.add_rounded, size: 15, color: AppColors.accent),
                  SizedBox(width: 3),
                  Text(
                    '添加',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        if (servers.isEmpty)
          Glass(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            child: Column(
              children: [
                Icon(
                  Icons.cloud_off_rounded,
                  size: 26,
                  color: AppColors.muted.withOpacity(0.7),
                ),
                const SizedBox(height: 9),
                const Text(
                  '还没有保存的服务器',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                const Text(
                  '支持 Emby / Jellyfin，可保存多个并随时切换',
                  style: TextStyle(fontSize: 10.5, color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: '添加服务器',
                  icon: Icons.add_link_rounded,
                  height: 40,
                  onTap: () => _openSheet(context, null),
                ),
                const SizedBox(height: 8),
                const Text(
                  '支持 Emby / Jellyfin，可保存多个并随时切换',
                  style: TextStyle(fontSize: 10.5, color: AppColors.muted),
                ),
              ],
            ),
          )
        else
          for (final p in servers) ...[
            Glass(
              padding: EdgeInsets.zero,
              child: LiquidPress(
                radius: 24,
                scale: 0.985,
                glow: 0.16,
                tint: 0.12,
                onTap: () async {
                  if (p.id == activeId && connected) {
                    _openSheet(context, p);
                    return;
                  }
                  await state.connectProfile(p);
                },
                onLongPress: () => _openSheet(context, p),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 11, 12, 11),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(
                            colors: p.kind == ServerKind.jellyfin
                                ? const [Color(0xFF7B5CFF), Color(0xFF4F8CFF)]
                                : const [AppColors.accent, Color(0xFF159F88)],
                          ),
                        ),
                        child: Center(
                          child: Text(
                            p.kind == ServerKind.jellyfin ? 'J' : 'E',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    p.name.isEmpty ? p.host : p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(5),
                                    color: Colors.white.withOpacity(0.08),
                                  ),
                                  child: Text(
                                    p.kindLabel,
                                    style: const TextStyle(
                                      fontSize: 8.5,
                                      color: AppColors.muted,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${p.address} · ${p.username}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (p.id == activeId && connected)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: const Color(0x2638E8C8),
                            border: Border.all(color: const Color(0x5538E8C8)),
                          ),
                          child: const Text(
                            '已连接',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.accent,
                            ),
                          ),
                        )
                      else if (p.id == activeId)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: const Color(0x26FFC55A),
                            border: Border.all(color: const Color(0x55FFC55A)),
                          ),
                          child: const Text(
                            '离线',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.warn,
                            ),
                          ),
                        )
                      else
                        const Icon(
                          Icons.play_arrow_rounded,
                          size: 18,
                          color: AppColors.muted,
                        ),
                      const SizedBox(width: 2),
                      LiquidPress(
                        onTap: () => _confirmDelete(context, p),
                        radius: 12,
                        semanticLabel: '删除服务器',
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.delete_outline_rounded,
                            size: 17,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        if (connected) ...[
          const SizedBox(height: 2),
          LiquidPress(
            onTap: () => state.disconnect(),
            radius: 8,
            scale: 0.94,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '断开当前连接',
                style: TextStyle(fontSize: 11, color: AppColors.danger),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ServerSheet extends StatefulWidget {
  const _ServerSheet({required this.state, this.profile, this.presetKind});

  final AppState state;
  final ServerProfile? profile;

  /// 预设类型（Jellyfin 默认走根路径）
  final ServerKind? presetKind;

  @override
  State<_ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends State<_ServerSheet> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _pwd;
  late bool _secure;
  late ServerKind _kind;
  bool _loading = false;
  String? _result;
  bool _resultOk = false;

  bool get _editing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _name = TextEditingController(text: p?.name ?? '');
    _host = TextEditingController(text: p?.host ?? '');
    _port = TextEditingController(text: (p?.port ?? 8096).toString());
    _user = TextEditingController(text: p?.username ?? '');
    _pwd = TextEditingController(text: p?.password ?? '');
    _kind = p?.kind ?? widget.presetKind ?? ServerKind.emby;
    _secure = p?.secure ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  /// 清洗地址：剥离 http(s):// 前缀与路径，只留主机名/IP
  String _cleanHost(String raw) {
    var h = raw.trim();
    final idx = h.indexOf('://');
    if (idx >= 0) h = h.substring(idx + 3);
    h = h.split('/').first;
    return h.trim();
  }

  Future<void> _submit() async {
    final host = _cleanHost(_host.text);
    final user = _user.text.trim();
    if (host.isEmpty || user.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '请填写服务器地址和用户名';
      });
      return;
    }
    setState(() {
      _loading = true;
      _result = null;
    });
    final p = ServerProfile(
      id: widget.profile?.id ?? 's${DateTime.now().microsecondsSinceEpoch}',
      name: _name.text.trim().isEmpty ? host : _name.text.trim(),
      host: host,
      port: int.tryParse(_port.text.trim()) ?? 8096,
      secure: _secure,
      username: user,
      password: _pwd.text,
      kind: _kind,
    );
    final ok = await widget.state.connectProfile(p);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _resultOk = ok;
      _result = ok
          ? '连接成功，已载入 ${widget.state.items.length} 个条目'
          : '配置已保存，但连接失败：${widget.state.error ?? '未知错误'}';
    });
    if (ok) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Glass(
          radius: 30,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _editing ? '编辑服务器' : '添加服务器',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _Segment(
                      items: const ['Emby', 'Jellyfin'],
                      value: _kind.index,
                      onSelect: (i) =>
                          setState(() => _kind = ServerKind.values[i]),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  switch (_kind) {
                    ServerKind.jellyfin =>
                      'Jellyfin 走根路径（无 /emby 前缀），登录与媒体读取通用',
                    ServerKind.emby =>
                      'Emby 走 /emby 路径，支持 Playback Reporting 统计',
                  },
                  style: const TextStyle(fontSize: 10, color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                _Field(controller: _name, label: '备注名（可选）', hint: '家里的服务器'),
                _Field(controller: _host, label: '服务器地址', hint: '192.168.1.24'),
                Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: _Field(
                        controller: _port,
                        label: '端口',
                        hint: '8096',
                        numeric: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '协议',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.muted,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _ProtocolToggle(
                            secure: _secure,
                            onChanged: (v) => setState(() => _secure = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                _Field(
                  controller: _user,
                  label: '用户名',
                  hint:
                      '${_kind == ServerKind.jellyfin ? 'Jellyfin' : 'Emby'} 账号',
                ),
                _Field(
                  controller: _pwd,
                  label: '密码',
                  hint: '••••••',
                  obscure: true,
                ),
                const SizedBox(height: 6),
                if (_result != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      _result!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: _resultOk ? AppColors.accent : AppColors.warn,
                      ),
                    ),
                  ),
                PrimaryButton(
                  label: _loading ? '连接中…' : (_editing ? '保存并连接' : '保存并连接'),
                  icon: Icons.link_rounded,
                  onTap: _loading ? null : _submit,
                ),
                const SizedBox(height: 6),
                const Text(
                  '配置会保存在本地，可添加多个 Emby / Jellyfin 服务器随时切换',
                  style: TextStyle(fontSize: 10, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
    this.numeric = false,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.muted),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: numeric ? TextInputType.number : TextInputType.text,
            style: const TextStyle(fontSize: 13, color: AppColors.ink),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(
                fontSize: 13,
                color: Color(0xFF5D7291),
              ),
              filled: true,
              fillColor: Colors.white.withOpacity(0.06),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Glass(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      radius: 24,
      blur: 22,
      child: Column(children: children),
    );
  }
}

class _RowItem extends StatelessWidget {
  const _RowItem({
    required this.title,
    this.desc,
    required this.trailing,
    this.last = false,
  });
  final String title;
  final String? desc;
  final Widget trailing;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: Colors.white.withOpacity(0.08))),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (desc != null)
                    Text(
                      desc!,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.muted,
                      ),
                    ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Container(
        width: 40,
        height: 23,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: value
              ? const LinearGradient(
                  colors: [AppColors.primary, AppColors.accent],
                )
              : null,
          color: value ? null : Colors.white.withOpacity(0.18),
        ),
        child: Align(
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 17,
            height: 17,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? Colors.white : const Color(0xFFD6E2F5),
            ),
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.items, required this.value, this.onSelect});
  final List<String> items;
  final int value;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withOpacity(0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(items.length, (i) {
          final sel = i == value;
          return LiquidPress(
            radius: 9,
            scale: 0.94,
            enabled: onSelect != null && !sel,
            onTap: onSelect == null || sel ? null : () => onSelect!(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                gradient: sel
                    ? const LinearGradient(
                        colors: [AppColors.primary, AppColors.secondary],
                      )
                    : null,
              ),
              child: Text(
                items[i],
                style: TextStyle(
                  fontSize: 10.5,
                  color: sel ? Colors.white : const Color(0xFF93A8C6),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text, {this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidPress(
      onTap: onTap,
      radius: 8,
      scale: 0.94,
      enabled: onTap != null,
      child: Text(
        '$text ›',
        style: TextStyle(
          fontSize: 11,
          color: onTap != null ? AppColors.accent : AppColors.muted,
          fontWeight: onTap != null ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.value, this.onChanged});
  final double value;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 5,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.5),
          activeTrackColor: AppColors.accent,
          inactiveTrackColor: Colors.white.withOpacity(0.14),
          thumbColor: Colors.white,
        ),
        child: Slider(value: value, min: 0, max: 1, onChanged: onChanged),
      ),
    );
  }
}

class _ThemeDots extends StatelessWidget {
  const _ThemeDots({required this.value, this.onSelect});
  final int value;
  final ValueChanged<int>? onSelect;

  static const colors = [
    [Color(0xFF4F8CFF), Color(0xFF2A5AD6)],
    [Color(0xFF7B5CFF), Color(0xFF4B31C9)],
    [Color(0xFF38E8C8), Color(0xFF159F88)],
    [Color(0xFFFFB64D), Color(0xFFD9821F)],
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(colors.length, (i) {
        final sel = i == value;
        return LiquidPress(
          radius: 6,
          scale: 0.9,
          enabled: onSelect != null,
          onTap: onSelect == null ? null : () => onSelect!(i),
          child: Container(
            width: 17,
            height: 17,
            margin: const EdgeInsets.only(left: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              gradient: LinearGradient(colors: colors[i]),
              border: sel ? Border.all(color: Colors.white, width: 1.6) : null,
            ),
          ),
        );
      }),
    );
  }
}

/// 协议切换：与「连接服务器」主按钮同款渐变胶囊
class _ProtocolToggle extends StatelessWidget {
  const _ProtocolToggle({required this.secure, required this.onChanged});

  final bool secure;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(23),
        color: Colors.white.withOpacity(0.06),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Row(
        children: [
          _seg('HTTP', !secure, () => onChanged(false)),
          _seg('HTTPS', secure, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _seg(String label, bool on, VoidCallback tap) {
    return Expanded(
      child: LiquidPress(
        radius: 20,
        scale: 0.96,
        onTap: tap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: on ? AppColors.ctaGradient : null,
            boxShadow: on
                ? const [
                    BoxShadow(
                      color: Color(0x554F8CFF),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                color: on ? Colors.white : AppColors.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
