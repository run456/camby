import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../lara/lara_client.dart';
import '../layout.dart';
import '../widgets/liquid_press.dart';
import '../widgets/glass_toast.dart';
import '../models.dart';
import '../theme.dart';
import 'search_page.dart';

/// 设置页水平内边距：平板内容限宽 720 居中，手机保持 16。
double _horizontalPad(BuildContext context) {
  final w = MediaQuery.of(context).size.width;
  if (w < kTabletBreakpoint) return 16;
  final pad = (w - 720) / 2;
  return pad < 30 ? 30 : pad;
}

/// 「我的」设置页：所有控件可交互，选择持久化到 SharedPreferences
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.onTabChanged,
    required this.state,
    required this.onOpenDetail,
  });

  final void Function(int tab) onTabChanged;
  final AppState state;
  final OpenDetail onOpenDetail;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _caches = ['512 MB', '1 GB', '2 GB', '4 GB'];

  Map<String, dynamic> _s = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _openSearch() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 340),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) =>
            SearchPage(state: widget.state, onOpenDetail: widget.onOpenDetail),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _s = {
        'play_engine': prefs.getInt('set_play_engine') ?? 0,
        'hw_decode': prefs.getBool('set_hw_decode') ?? true,
        'cache_size': prefs.getInt('set_cache_size') ?? 0,
        'record_history': prefs.getBool('set_record_history') ?? true,
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
        // 平板（≥840）：内容限宽 720 居中，设置行不被拉到 1000+dp
        padding: EdgeInsets.fromLTRB(
          _horizontalPad(context),
          MediaQuery.of(context).padding.top + 14,
          _horizontalPad(context),
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
              const Spacer(),
              // v1.7.71：右上角搜索按钮（全局搜索的另一入口，与双击 Tab 并存）
              LiquidPress(
                onTap: _openSearch,
                radius: 18,
                scale: 0.9,
                semanticLabel: '搜索',
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0x3DFFFFFF), Color(0x14FFFFFF)],
                    ),
                    border: Border.all(color: const Color(0x42FFFFFF)),
                  ),
                  child: const Icon(
                    Icons.search_rounded,
                    size: 19,
                    color: Colors.white,
                  ),
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
          _LaraSection(),
          const SizedBox(height: 18),
          // v1.7.60：版本号改为运行时从包信息读取，不再手改硬编码
          // （以前每次发版都得记得同步这一行，漏一次就显示旧版本）
          const _VersionLine(),
        ],
      ),
    );
  }
}

/// 页脚版本行：运行时读包信息（v1.7.60 起不再硬编码版本号）。
class _VersionLine extends StatefulWidget {
  const _VersionLine();

  @override
  State<_VersionLine> createState() => _VersionLineState();
}

class _VersionLineState extends State<_VersionLine> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var v = '';
    try {
      v = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      v = '';
    }
    if (!mounted) return;
    setState(() => _version = v);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Camby ${_version.isEmpty ? '' : 'v$_version '}· arm64 · 隐私政策 · 开源许可',
        style: const TextStyle(fontSize: 10, color: Color(0xFF5D7291)),
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

  /// 切换服务器：给出明确反馈（进行中 / 成功 / 失败原因）。
  /// 已是当前服务器则直接打开编辑，避免无意义的重连。
  Future<void> _switchTo(BuildContext context, ServerProfile p) async {
    if (p.id == state.activeServerId &&
        !state.demoMode &&
        state.server != null) {
      _openSheet(context, p);
      return;
    }
    final label = p.name.isEmpty ? p.host : p.name;
    showToast(context, '正在切换到「$label」…');
    final ok = await state.connectProfile(p);
    if (!context.mounted) return;
    if (ok) {
      showToast(
        context,
        '已切换到「$label」',
        icon: Icons.check_circle_outline_rounded,
      );
    } else {
      final raw = state.error ?? '连接失败';
      final msg = raw.replaceFirst(RegExp(r'^(EmbyException|Exception):\s*'), '');
      showToast(context, msg, icon: Icons.error_outline_rounded);
    }
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
        const SizedBox(height: 7),
        const Text(
          '点按卡片切换 · 右侧铅笔编辑 · 垃圾桶删除',
          style: TextStyle(fontSize: 10.5, color: AppColors.muted),
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
              ],
            ),
          )
        else
          for (final p in servers) ...[
            _ServerCard(
              profile: p,
              active: p.id == activeId,
              connected: connected && p.id == activeId,
              onSwitch: () => _switchTo(context, p),
              onEdit: () => _openSheet(context, p),
              onDelete: () => _confirmDelete(context, p),
            ),
            const SizedBox(height: 8),
          ],
        if (connected) ...[
          const SizedBox(height: 2),
          LiquidPress(
            onTap: () async {
              showToast(context, '正在从服务器恢复收藏夹…');
              await state.syncFoldersFromServer();
              if (!context.mounted) return;
              showToast(
                context,
                '已与服务端播放列表同步',
                icon: Icons.check_circle_outline_rounded,
              );
            },
            radius: 8,
            scale: 0.94,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '从服务器恢复收藏夹',
                style: TextStyle(fontSize: 11, color: AppColors.accent),
              ),
            ),
          ),
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

/// 服务器卡片（v2.0.24 重做）：当前服务器高亮 + 显式的切换/编辑/删除操作，
/// 不再把编辑藏到长按里，切换也有明确反馈（见 [_ServersSection._switchTo]）。
class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.profile,
    required this.active,
    required this.connected,
    required this.onSwitch,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerProfile profile;
  final bool active;
  final bool connected;
  final VoidCallback onSwitch;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final statusText = active
        ? (connected ? '● 已连接' : '● 离线（显示缓存）')
        : '○ 点按卡片切换';
    final statusColor = active
        ? (connected ? AppColors.accent : AppColors.warn)
        : AppColors.muted;
    return Glass(
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: active
              ? Border.all(color: AppColors.accent.withOpacity(0.55), width: 1.3)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 9, 11),
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
                        if (active)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              color: const Color(0x2638E8C8),
                            ),
                            child: const Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 8.5,
                                color: AppColors.accent,
                                fontWeight: FontWeight.w700,
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
                    const SizedBox(height: 2),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (!active)
                LiquidPress(
                  onTap: onSwitch,
                  // v2.0.49：按钮实际只有 ~30px 高，14 圆角几乎等于胶囊，
                  // 与卡片 24 圆角、旁边方形的编辑/删除图标放一起显得别扭。
                  // 收成 8px 的小圆角矩形，和整页的圆角层级更协调。
                  radius: 8,
                  scale: 0.94,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: const LinearGradient(
                        colors: [AppColors.accent, Color(0xFF159F88)],
                      ),
                    ),
                    child: const Text(
                      '切换',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(width: 2),
              LiquidPress(
                onTap: onEdit,
                radius: 12,
                semanticLabel: '编辑服务器',
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 17,
                    color: AppColors.muted,
                  ),
                ),
              ),
              LiquidPress(
                onTap: onDelete,
                radius: 12,
                semanticLabel: '删除服务器',
                child: const Padding(
                  padding: EdgeInsets.all(5),
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

  /// 把底层 socket 错误翻译成人能看懂的提示，并针对局域网地址给网络诊断。
  /// 最常见原因：手机在移动数据下访问 192.168.x.x 这类内网地址，路由不可达，
  /// 系统表现为 ECONNABORTED("Software caused connection abort") 而非超时。
  String _friendlyConnectError(String host, String? raw) {
    final m = raw ?? '';
    final low = m.toLowerCase();
    String reason;
    if (low.contains('connection abort') || low.contains('software caused')) {
      reason = '连接被系统中断';
    } else if (low.contains('connection refused')) {
      reason = '服务器拒绝连接（端口不对或服务未启动）';
    } else if (low.contains('timeout') || low.contains('timed out')) {
      reason = '连接超时';
    } else if (low.contains('unreachable')) {
      reason = '网络不可达';
    } else if (low.contains('cleartext')) {
      reason = '系统禁止明文 HTTP';
    } else {
      reason = m;
    }
    // 私网 IPv4：10.x / 192.168.x / 172.16-31.x
    final ip = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(host);
    var isPrivate = false;
    if (ip != null) {
      final a = int.parse(ip.group(1)!);
      final b = int.parse(ip.group(2)!);
      isPrivate =
          a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
    }
    final hint = isPrivate
        ? '\n\n$host 是局域网地址：请确认手机已连接到与服务器相同的 Wi-Fi'
              '（当前可能在用移动数据），或改用公网地址/内网穿透。'
        : '';
    return '连接失败：$reason$hint';
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
          : _friendlyConnectError(host, widget.state.error);
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
          // 固定 48 高：和「协议」切换器（48）同高，两个控件顶底对齐。
          // TextField 要求祖先有 Material：底部弹层由 showModalBottomSheet 隐式提供，
          // 但设置主页的 ListView 没有，故这里自带一层透明 Material，令 _Field
          // 在任何宿主下都能独立渲染（不依赖调用方是否包了 Scaffold）。
          Material(
            type: MaterialType.transparency,
            child: SizedBox(
              height: 48,
              child: TextField(
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
                    borderSide:
                        BorderSide(color: Colors.white.withOpacity(0.12)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.primary),
                  ),
                ),
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

class _ProtocolToggle extends StatelessWidget {
  const _ProtocolToggle({required this.secure, required this.onChanged});

  final bool secure;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
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

/// Lara 翻译凭证：Access Key ID + Secret，存到 SharedPreferences（与 Emby 密码同风格）。
/// 仅在详情页点「翻译」且本地无凭证时引导至此；保存后可立即「测试连接」验证有效性。
class _LaraSection extends StatefulWidget {
  const _LaraSection();

  @override
  State<_LaraSection> createState() => _LaraSectionState();
}

class _LaraSectionState extends State<_LaraSection> {
  final _idCtl = TextEditingController();
  final _secretCtl = TextEditingController();
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    LaraCredentials.load().then((c) {
      if (c == null || !mounted) return;
      _idCtl.text = c.id;
      _secretCtl.text = c.secret;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _idCtl.dispose();
    _secretCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = _idCtl.text.trim();
    final secret = _secretCtl.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      showToast(context, 'Access Key ID 与 Secret 均需填写');
      return;
    }
    await LaraCredentials.save(LaraCredentials(id: id, secret: secret));
    if (!mounted) return;
    showToast(context, '已保存 Lara 凭证', icon: Icons.check_circle_outline_rounded);
  }

  Future<void> _test() async {
    final id = _idCtl.text.trim();
    final secret = _secretCtl.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      showToast(context, '请先填写 Access Key ID 与 Secret');
      return;
    }
    setState(() => _testing = true);
    try {
      await LaraClient(LaraCredentials(id: id, secret: secret)).testConnection();
      if (!mounted) return;
      showToast(context, '连接成功，凭证有效', icon: Icons.check_circle_outline_rounded);
    } on LaraAuthError catch (e) {
      if (!mounted) return;
      showToast(context, '鉴权失败：${e.message}');
    } on LaraApiError catch (e) {
      if (!mounted) return;
      showToast(context, '连接失败（${e.statusCode}）：${e.message}');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '连接失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Group(
      children: [
        const _RowItem(
          title: 'Lara 翻译',
          desc: '标题 / 简介一键翻译成中文（官方 API）',
          trailing: SizedBox.shrink(),
          last: true,
        ),
        _Field(
          controller: _idCtl,
          label: 'Access Key ID',
          hint: '在 laratranslate.com → API 凭证 获取',
        ),
        _Field(
          controller: _secretCtl,
          label: 'Access Key Secret',
          hint: '下载凭证后妥善保存',
          obscure: true,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _save,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: BorderSide(
                      color: AppColors.accent.withValues(alpha: 0.5),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('保存'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _test,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFC6D3E6),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.16),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _testing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Color(0xFFC6D3E6),
                          ),
                        )
                      : const Text('测试连接'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
