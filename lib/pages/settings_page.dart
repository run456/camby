import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../lara/lara_client.dart';
import '../layout.dart';
import '../routes.dart';
import '../pages/diagnostics_dump_page.dart';
import '../widgets/liquid_press.dart';
import '../theme_controller.dart';
import '../widgets/glass_toast.dart';
import '../widgets/haptics.dart';
import '../models.dart';
import '../server_address.dart';
import '../theme.dart';
import '../widgets/glass_sheet.dart';

/// 设置页水平内边距：平板内容限宽 720 居中，手机保持 16。
double _horizontalPad(BuildContext context) {
  final w = MediaQuery.of(context).size.width;
  if (w < kTabletBreakpoint) return 16;
  final pad = (w - 720) / 2;
  return pad < 30 ? 30 : pad;
}

/// v2.0.94：「添加服务器」弹窗里**唯一**的一行类型提示。
///
/// 之前绿联分支在表单里额外叠了三段条件文字（证书未开警告、协议警告、
/// 「不广播发现包」说明），Emby / Jellyfin 则一行都没有；切换分段时
/// `SingleChildScrollView` 的自然高度一下多出 4~5 行，弹窗就往上跳一大截。
///
/// 现在三种类型共用同一个固定高度的提示槽，按优先级只显示最要紧的一条，
/// 表单行数与所选类型完全无关 —— 弹窗高度恒定，不需要硬编码高度，也不
/// 强迫用户在弹窗里滚动才能看到保存按钮。
String serverSheetNote({
  required bool isUgreen,
  required bool compat,
  required bool ignoreSsl,
  required bool secure,
  required int port,
}) {
  if (compat && !ignoreSsl) {
    return '⚠ 绿联 / 自签 HTTPS 源必须开启忽略证书校验，否则 TLS 握手会直接失败。';
  }
  if (port == 9443 && !secure) {
    return '⚠ 绿联影视中心只提供 HTTPS，请把「协议」切到 HTTPS。';
  }
  if (isUgreen) {
    return '该源不广播 Emby 发现包，请手动填地址；不支持进度同步，记录仅存本机。';
  }
  return '配置会保存在本地，可添加多个 Emby / Jellyfin 服务器随时切换。';
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

  // v2.0.68：搜索已升为一级 Tab（index 2），「我的」页右上角的重复入口
  // 与双击 Tab 手势一并移除，全局只剩「点搜索 Tab」一条路径。

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _s = {
        'play_engine': prefs.getInt('set_play_engine') ?? 0,
        'hw_decode': prefs.getBool('set_hw_decode') ?? true,
        'cache_size': prefs.getInt('set_cache_size') ?? 0,
        // v2.0.83：设备的 libmpv 不带 gpu-next 时，让服务端把 DV 片
        // 重编码成 SDR，牺牲画质换取绝不发绿发紫。默认关。
        'dv_transcode': prefs.getBool('set_dv_transcode') ?? false,
        'record_history': prefs.getBool('set_record_history') ?? true,
        // v2.0.64 质感包：默认开，系统层面是否震动仍由 Android 决定。
        'haptics': prefs.getBool('set_haptics') ?? true,
      };
    });
  }

  Future<void> _set(String key, dynamic value) async {
    setState(() => _s[key] = value);
    final prefs = await SharedPreferences.getInstance();
    if (value is int) await prefs.setInt('set_$key', value);
    if (value is bool) await prefs.setBool('set_$key', value);
    if (value is double) await prefs.setDouble('set_$key', value);
    if (key == 'haptics' && value is bool) {
      // 立即生效（不必重启 / 重进页面）。打开时给一次轻震动作为预览；
      // 关闭时什么都不会震，AppHaptics 内部直接 return。
      unawaited(AppHaptics.setEnabled(value));
      if (value) AppHaptics.light();
    }
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
        child: Center(
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
    // v2.0.81 P2：主列表改「懒构造」。原先 children: [...] 在首帧就会把
    // 服务器区、Lara 区等重型子树全部建一遍；builder 只在 item 进入视口时
    // 才调用对应的 WidgetBuilder，滚动物理、间距、内容顺序完全不变。
    final cells = <WidgetBuilder>[
      (_) => Row(
        children: [
          Icon(Icons.person_rounded, size: 20, color: AppColors.ink),
          SizedBox(width: 10),
          Text(
            '我的',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          // v2.0.68：右上角搜索按钮已移除（搜索是一级 Tab，无需重复入口）。
        ],
      ),
      (_) => const SizedBox(height: 14),
      (_) => _ServersSection(state: widget.state),
      (_) => const SizedBox(height: 12),
      (_) => const _AppearanceSection(),
      (_) => const SizedBox(height: 12),
      (_) => _Group(
        children: [
          _RowItem(
            title: '默认播放内核',
            desc: _s['play_engine'] == 0 ? 'ExoPlayer · 兼容性最佳' : 'MPV · 硬解更强',
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
          ),
          _RowItem(
            title: 'DV 片源保底转码',
            desc: '若杜比视界仍发绿发紫，由服务端转成 SDR（会损失画质）',
            trailing: _Toggle(
              value: _s['dv_transcode'],
              onChanged: (v) => _set('dv_transcode', v),
            ),
            last: true,
          ),
        ],
      ),
      (_) => const SizedBox(height: 12),
      (_) => _Group(
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
            title: '触感反馈',
            desc: '点按、收藏等状态变化时的轻震动 · 跟随系统触感设置',
            trailing: _Toggle(
              value: _s['haptics'],
              onChanged: (v) => _set('haptics', v),
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
      (_) => const SizedBox(height: 12),
      (_) => const _LaraSection(),
      (_) => const SizedBox(height: 18),
      // v1.7.60：版本号改为运行时从包信息读取，不再手改硬编码
      // （以前每次发版都得记得同步这一行，漏一次就显示旧版本）
      (_) => const _VersionLine(),
    ];

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.bgTop, AppColors.bg],
        ),
      ),
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        // 平板（≥840）：内容限宽 720 居中，设置行不被拉到 1000+dp
        padding: EdgeInsets.fromLTRB(
          _horizontalPad(context),
          MediaQuery.of(context).padding.top + 14,
          _horizontalPad(context),
          110,
        ),
        itemCount: cells.length,
        itemBuilder: (ctx, i) => cells[i](ctx),
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
    final ok = await showAppDialog<bool>(
      context: context,
      title: '删除服务器',
      message: '确定删除「${p.name}」？只删除保存的配置，不会影响服务器上的数据。',
      actions: const [
        AppDialogAction(label: '取消', value: false),
        AppDialogAction(label: '删除', value: true),
      ],
    );
    if (ok == true) {
      AppHaptics.heavy();
      await state.deleteServer(p.id);
    }
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
      final msg = raw.replaceFirst(
        RegExp(r'^(EmbyException|Exception):\s*'),
        '',
      );
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
            Icon(Icons.dns_rounded, size: 15, color: AppColors.muted),
            const SizedBox(width: 7),
            Text(
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
              child: Row(
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
        Text(
          '点按卡片切换 · 右侧铅笔编辑 · 垃圾桶删除',
          style: TextStyle(fontSize: 10.5, color: AppColors.muted),
        ),
        const SizedBox(height: 9),
        // v2.0.92：绿联收回到「添加服务器」表单里当第三种类型。
        // v2.0.88 曾在这里放一张独立的绿联入口卡，等于把同一套 Emby
        // 接口拆成两个 App 两套入口；现在只留一个添加动作，类型在表单里选。
        if (servers.isEmpty)
          LiquidPress(
            radius: 20,
            scale: 0.985,
            onTap: () => _openSheet(context, null),
            child: Glass(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: AppColors.ctaGradient,
                    ),
                    child: const Icon(
                      Icons.add_to_queue_rounded,
                      size: 21,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '添加服务器',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'Emby / Jellyfin / 绿联影视中心，同一个入口',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: AppColors.accent,
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
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
                Text(
                  '支持 Emby / Jellyfin / 绿联影视中心，可保存多个并随时切换',
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
        // v2.0.87：绿联影视中心不开放进度接口，连上就明确告知，
        // 避免用户把「进度不同步」当成 bug 反馈。
        if (connected && !state.progressSyncSupported) ...[
          const SizedBox(height: 2),
          Glass(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: AppColors.warn,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    kUgreenProgressHint,
                    style: TextStyle(fontSize: 10.5, color: AppColors.ink),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
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
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '从服务器恢复收藏夹',
                style: TextStyle(fontSize: 11, color: AppColors.accent),
              ),
            ),
          ),
          const SizedBox(height: 2),
          LiquidPress(
            onTap: () {
              AppHaptics.heavy();
              state.disconnect();
            },
            radius: 8,
            scale: 0.94,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '断开当前连接',
                style: TextStyle(fontSize: 11, color: AppColors.danger),
              ),
            ),
          ),
          // v2.0.88：文档 5.3 第 3 条。把拼好的图片 / 播放 URL 与首条
          // Item 原始字段摊开，用户可按 5.4 顺序逐条贴进浏览器自检。
          LiquidPress(
            onTap: () => showAppDialog<void>(
              context: context,
              title: '连接诊断',
              bodyBuilder: (ctx) => _DiagnosticsBody(state: state),
              actions: const [AppDialogAction(label: '知道了', value: null)],
            ),
            radius: 8,
            scale: 0.94,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '连接诊断 · 图片与播放地址',
                style: TextStyle(fontSize: 11, color: AppColors.accent),
              ),
            ),
          ),
          // v2.0.95：把服务端原始条目 JSON 摊开，供定位绿联字段差异（问题 2/4）。
          LiquidPress(
            onTap: () => Navigator.of(context).push(
              CambyRoutes.fade(
                builder: (_) => DiagnosticsDumpPage(state: state),
              ),
            ),
            radius: 8,
            scale: 0.94,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '导出原始条目 JSON（绿联诊断）',
                style: TextStyle(fontSize: 11, color: AppColors.accent),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// v2.0.89：连接诊断弹窗正文。除静态 URL 外，提供「重新自检」并把每个
/// 候选的真实 HTTP 状态码列出来，不再靠猜判断是路径、权限还是证书问题。
class _DiagnosticsBody extends StatefulWidget {
  const _DiagnosticsBody({required this.state});

  final AppState state;

  @override
  State<_DiagnosticsBody> createState() => _DiagnosticsBodyState();
}

class _DiagnosticsBodyState extends State<_DiagnosticsBody> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.state.runResourceProbe();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final bodyStyle = TextStyle(
      fontSize: 10.5,
      height: 1.55,
      color: AppColors.ink,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 400),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(widget.state.serverDiagnostics, style: bodyStyle),
            const SizedBox(height: 14),
            Text(
              '资源自检 · 真实 HTTP 状态码',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(widget.state.resourceProbeReport, style: bodyStyle),
            const SizedBox(height: 10),
            LiquidPress(
              onTap: () {
                if (!_busy) _run();
              },
              radius: 8,
              scale: 0.96,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  _busy ? '自检中…' : '重新自检（图片与播放候选）',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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
              ? Border.all(
                  color: AppColors.accent.withOpacity(0.55),
                  width: 1.3,
                )
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
                    colors: switch (p.kind) {
                      ServerKind.jellyfin => const [
                        Color(0xFF7B5CFF),
                        Color(0xFF4F8CFF),
                      ],
                      ServerKind.ugreen => const [
                        Color(0xFF19B394),
                        Color(0xFF0E7C86),
                      ],
                      ServerKind.emby => [
                        AppColors.accent,
                        Color(0xFF159F88),
                      ],
                    },
                  ),
                ),
                child: Center(
                  child: Text(
                    switch (p.kind) {
                      ServerKind.jellyfin => 'J',
                      ServerKind.ugreen => '绿',
                      ServerKind.emby => 'E',
                    },
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
                            color: AppColors.w.withValues(alpha: 0.08),
                          ),
                          child: Text(
                            p.kindLabel,
                            style: TextStyle(
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
                            child: Text(
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
                      style: TextStyle(
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
                      gradient: LinearGradient(
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
                child: Padding(
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
                child: Padding(
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

  /// v2.0.87 方案 A：忽略 SSL 证书校验，默认关闭。
  late bool _ignoreSsl;

  /// 防止「粘贴完整地址 → 自动拆分 → 重写 TextField」触发监听器重入。
  bool _splitting = false;

  bool _loading = false;
  String? _result;
  bool _resultOk = false;

  bool get _editing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    // v2.0.88：绿联是独立入口（不从 Emby 表单混进来），预设 HTTPS 9443
    // 并自动勾选忽略证书，用户只需要填 IP 和影视中心账号。
    final isUgreenPreset =
        (p?.kind ?? widget.presetKind) == ServerKind.ugreen;
    _name = TextEditingController(text: p?.name ?? '');
    _host = TextEditingController(text: p?.host ?? '');
    _port = TextEditingController(
      text: (p?.port ?? (isUgreenPreset ? 9443 : 8096)).toString(),
    );
    _user = TextEditingController(text: p?.username ?? '');
    _pwd = TextEditingController(text: p?.password ?? '');
    _kind = p?.kind ?? widget.presetKind ?? ServerKind.emby;
    _secure = p?.secure ?? isUgreenPreset;
    _ignoreSsl = p?.ignoreSsl ?? isUgreenPreset;
    _host.addListener(_onHostChanged);
  }

  @override
  void dispose() {
    _host.removeListener(_onHostChanged);
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  /// v2.0.87：允许直接粘贴 `https://nasip:9443` 这种完整地址。
  /// 旧版只剥 `://` 和路径、不拆端口，会拼出 `https://ip:9443:8096/emby`
  /// 这种必然连不上的地址 —— 正是绿联接入的第一步坑。
  /// 粘贴后自动把协议/端口拆到对应控件，用户仍可手动改。
  void _onHostChanged() {
    if (_splitting) return;
    final raw = _host.text;
    if (!raw.contains('://') && !raw.contains(':')) return;
    final parsed = parseServerAddress(
      raw,
      fallbackPort: int.tryParse(_port.text.trim()) ?? 8096,
      fallbackSecure: _secure,
    );
    if (parsed.host.isEmpty) return;
    _splitting = true;
    _host.text = parsed.host;
    _port.text = '${parsed.port}';
    _secure = parsed.secure;
    _splitting = false;
    if (mounted) setState(() {});
  }

  /// 切换服务器类型：只改「与之绑定的默认值」，不覆盖用户已填的内容。
  ///
  /// 绿联没有 HTTP、也不存在 8096，所以切进来时把协议/端口/证书一键带好，
  /// 切回 Emby/Jellyfin 时再把端口回落到 8096（若用户没动过）。
  void _switchKind(int i) {
    final next = switch (i) {
      1 => ServerKind.jellyfin,
      2 => ServerKind.ugreen,
      _ => ServerKind.emby,
    };
    if (next == _kind) return;
    final prevPort = int.tryParse(_port.text.trim()) ?? 0;
    setState(() {
      final wasUgreen = _kind == ServerKind.ugreen;
      _kind = next;
      if (next == ServerKind.ugreen) {
        _secure = true;
        _ignoreSsl = true;
        if (prevPort == 8096 || prevPort == 0) _port.text = '9443';
      } else {
        _ignoreSsl = false;
        if (wasUgreen && prevPort == 9443) {
          _port.text = '8096';
          _secure = false;
        }
      }
      _result = null;
    });
  }

  /// 「忽略 SSL 证书校验」下面那行说明（v2.0.94 抽出成单行）。
  ///
  /// 文案本身要保留「中间人风险 / 已自动勾选」这些关键词，但**渲染时恒为
  /// 一行**：绿联的警告最长，折成两行就把整张弹窗撑高了。
  String _sslNote() {
    if (_ignoreSsl && !isLanHost(_host.text)) {
      return '⚠ 非局域网地址：关闭校验有中间人风险，建议仅局域网使用';
    }
    if (_kind == ServerKind.ugreen) {
      return '绿联影视中心为自签证书，接入必须开启（已自动勾选）';
    }
    return '自签 HTTPS 源需开启；建议仅局域网使用，默认关闭';
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
    } else if (low.contains('handshake') ||
        low.contains('certificate') ||
        low.contains('ssl') ||
        low.contains('cert')) {
      reason = '证书校验失败（自签证书请勾选「忽略 SSL 证书校验」）';
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
    final addr = parseServerAddress(
      _host.text,
      fallbackPort: int.tryParse(_port.text.trim()) ?? 8096,
      fallbackSecure: _secure,
    );
    final host = addr.host;
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
    final isUgreen = _kind == ServerKind.ugreen;
    final p = ServerProfile(
      id: widget.profile?.id ?? 's${DateTime.now().microsecondsSinceEpoch}',
      name: _name.text.trim().isEmpty ? host : _name.text.trim(),
      host: host,
      port: addr.port,
      // 绿联影视中心不提供 HTTP，强制 HTTPS，避免粘贴 http:// 后落到 9443 明文
      secure: isUgreen ? true : addr.secure,
      username: user,
      password: _pwd.text,
      kind: _kind,
      ignoreSsl: _ignoreSsl,
    );
    final ok = await widget.state.connectProfile(p);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _resultOk = ok;
      _result = ok
          ? '连接成功，已载入 ${widget.state.items.length} 个条目'
                '${isUgreen || isUgreenCompatSource(port: addr.port, secure: addr.secure) ? '\n$kUgreenProgressHint' : ''}'
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
    final detectedPort = int.tryParse(_port.text.trim()) ?? 8096;
    final isUgreen = _kind == ServerKind.ugreen;
    // 填了 9443 这类兼容源地址也给同样的风险提示。
    final ugreen = isUgreen ||
        isUgreenCompatSource(port: detectedPort, secure: _secure);
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
                        isUgreen
                            ? (_editing ? '编辑绿联影视中心' : '连接绿联影视中心')
                            : (_editing
                                  ? '编辑${_kind == ServerKind.jellyfin ? ' Jellyfin ' : '服务器'}'
                                  : '添加服务器'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // v2.0.92：绿联回到同一个表单里当第三种类型。
                    // v2.0.88 曾把它拆成设置页上一张独立入口卡片，实际用下来
                    // 更像「两个 App 两套入口」——它们本来就是同一套 Emby
                    // 接口，只是地址规则和能力不同，收进一个表单按需切换即可。
                    _Segment(
                      items: const ['Emby', 'Jellyfin', '绿联'],
                      value: switch (_kind) {
                        ServerKind.emby => 0,
                        ServerKind.jellyfin => 1,
                        ServerKind.ugreen => 2,
                      },
                      onSelect: _switchKind,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // v2.0.94：固定单行。绿联这句最长，之前会折成两行，光这一处
                // 就让弹窗比 Emby 高一行；类型说明属于补充信息，超出省略即可。
                Text(
                  switch (_kind) {
                    ServerKind.jellyfin =>
                      'Jellyfin 走根路径（无 /emby 前缀），登录与媒体读取通用',
                    ServerKind.emby =>
                      'Emby 走 /emby 路径，支持 Playback Reporting 统计',
                    ServerKind.ugreen =>
                      '绿联影视中心（UGOS Pro）· HTTPS 9443 · 自动跳过证书校验',
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: AppColors.muted),
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
                          Text(
                            '协议',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.muted,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (isUgreen)
                            // 绿联没有 HTTP、也不存在 8096，协议不允许切换。
                            Container(
                              height: 48,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: const Color(0x1419B394),
                                border: Border.all(
                                  color: const Color(0x4419B394),
                                ),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.lock_outline_rounded,
                                    size: 14,
                                    color: Color(0xFF4BE0BE),
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'HTTPS · 强制',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF4BE0BE),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
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
                  hint: isUgreen
                      ? '影视中心媒体服务器账号（非 NAS 管理员）'
                      : _kind == ServerKind.jellyfin
                      ? 'Jellyfin 账号'
                      : 'Emby 账号',
                ),
                _Field(
                  controller: _pwd,
                  label: '密码',
                  hint: '••••••',
                  obscure: true,
                ),

                // ── v2.0.87 方案 A：忽略 SSL 证书校验（默认关闭）──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '忽略 SSL 证书校验',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          // v2.0.94：固定单行 + 省略。警告文案在绿联下最长，
                          // 折行会让整张弹窗比 Emby 高一行；完整措辞仍保留
                          // 在 _sslNote() 里，点开诊断面板可看全。
                          Text(
                            _sslNote(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: _ignoreSsl && !isLanHost(_host.text)
                                  ? AppColors.warn
                                  : AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _Toggle(
                      value: _ignoreSsl,
                      onChanged: (v) => setState(() => _ignoreSsl = v),
                    ),
                  ],
                ),
                // v2.0.94：原来这里按条件叠了三段文字（证书未开 / 协议不
                // 对 / 绿联说明），绿联最长能多出 4~5 行，切换分段时整张
                // 弹窗突然往上跳一大截。三段已合并进底部那行本来就有
                // 的提示（serverSheetNote），这里不再新增任何 widget，
                // Emby 的高度严格保持原样。
                const SizedBox(height: 10),
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
                // v2.0.94：这一行本来就有，现在由 serverSheetNote 统一供给
                // 内容（含原先三段绿联专属提示的要点），并固定单行高度。
                // 绿联原本这句折两行，是弹窗变高的最后一处来源。
                SizedBox(
                  height: 14,
                  child: Text(
                    serverSheetNote(
                      isUgreen: isUgreen,
                      compat: ugreen,
                      ignoreSsl: _ignoreSsl,
                      secure: _secure,
                      port: detectedPort,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: (ugreen && !_ignoreSsl) ||
                              (detectedPort == 9443 && !_secure)
                          ? AppColors.warn
                          : AppColors.muted,
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
            style: TextStyle(fontSize: 11, color: AppColors.muted),
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
                keyboardType: numeric
                    ? TextInputType.number
                    : TextInputType.text,
                style: TextStyle(fontSize: 13, color: AppColors.ink),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF5D7291),
                  ),
                  filled: true,
                  fillColor: AppColors.w.withValues(alpha: 0.06),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: AppColors.w.withValues(alpha: 0.12),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: AppColors.primary),
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
            : Border(bottom: BorderSide(color: AppColors.w.withValues(alpha: 0.08))),
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
                      style: TextStyle(
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
  const _Toggle({super.key, required this.value, this.onChanged});
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
              ? LinearGradient(
                  colors: [AppColors.primary, AppColors.accent],
                )
              : null,
          color: value ? null : AppColors.w.withValues(alpha: 0.18),
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
        color: AppColors.w.withValues(alpha: 0.08),
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
                    ? LinearGradient(
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
        color: AppColors.w.withValues(alpha: 0.06),
        border: Border.all(color: AppColors.w.withValues(alpha: 0.12)),
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
      await LaraClient(LaraCredentials(id: id, secret: secret))
          .testConnection();
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
                      color: AppColors.w.withValues(alpha: 0.16),
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


/// 外观（v2.0.98）：深色 / 浅色 / 跟随系统。
///
/// 用户的原话是「在设置有切换亮/暗开关」，所以主交互就是一个开关；
/// 「跟随系统」单独一行 —— 打开它之后深色开关的值会跟着系统走，
/// 此时再拨深色开关等于把当前亮度**固化**下来（见 ThemeController.setDark）。
/// 这样两个控件不会互相打架，也不会出现「开关是关的但界面是黑的」。
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final tc = ThemeController.instance;
    return ListenableBuilder(
      listenable: tc,
      builder: (context, _) {
        final dark = tc.isDark;
        final systemHint = tc.platformDark ? '深色' : '浅色';
        return _Group(
          children: [
            _RowItem(
              title: '深色模式',
              desc: tc.followsSystem
                  ? '跟随系统中（当前系统：$systemHint）'
                  : dark
                  ? '深色 · 白字暗底，适合暗光环境'
                  : '浅色 · 黑字白底，适合白天',
              trailing: _Toggle(
                key: const ValueKey('theme-dark-toggle'),
                value: dark,
                onChanged: (v) => tc.setDark(v),
              ),
            ),
            _RowItem(
              title: '跟随系统',
              desc: '随系统亮暗自动切换，无需手动拨',
              trailing: _Toggle(
                key: const ValueKey('theme-system-toggle'),
                value: tc.followsSystem,
                onChanged: (v) => tc.setMode(
                  v
                      ? ThemeMode.system
                      : (tc.isDark ? ThemeMode.dark : ThemeMode.light),
                ),
              ),
              last: true,
            ),
          ],
        );
      },
    );
  }
}
