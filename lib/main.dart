import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:inspire_blur/inspire_blur.dart';
import 'package:media_kit/media_kit.dart';

import 'app_state.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets/liquid_press.dart';
import 'widgets/status_bar_blur.dart';
import 'pages/home_page.dart';
import 'pages/detail_page.dart';
import 'pages/player_page.dart';
import 'pages/stats_page.dart';
import 'pages/library_page.dart';
import 'pages/favorites_page.dart';
import 'pages/settings_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 预加载模糊着色器，避免首次上滑时掉帧
  Inspire.warmUp();
  // 图片内存缓存：千部库滚动时减少「解码→淘汰→再解码」抖动
  PaintingBinding.instance.imageCache
    ..maximumSize = 1200
    ..maximumSizeBytes = 192 << 20;
  // 初始化 MPV 内核（libmpv + FFmpeg）
  MediaKit.ensureInitialized();
  runApp(const CambyApp());
}

class CambyApp extends StatelessWidget {
  const CambyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camby',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with SingleTickerProviderStateMixin {
  int _tab = 0;
  late final AppState _state;

  /// 已访问过的 Tab：IndexedStack 只构建访问过的页面，其余放占位
  final Set<int> _visited = {0};

  /// 当前页是否已上滑（决定状态栏模糊是否出现）
  final ValueNotifier<bool> _blur = ValueNotifier(false);

  /// 切 Tab 的柔和过渡：淡入 + 轻微上浮（页面本身保活，只做视觉过渡）
  late final AnimationController _tabAnim;

  @override
  void initState() {
    super.initState();
    _state = AppState();
    _state.restore();
    _tabAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      value: 1,
    );
  }

  @override
  void dispose() {
    _tabAnim.dispose();
    _blur.dispose();
    _state.dispose();
    super.dispose();
  }

  /// 详情改为真正的路由，转场与「搜索页」一致（MaterialPageRoute 原生动画），
  /// 同时首页保留在栈下方，返回时不会重建、也不会黑屏。
  void _openDetail(MediaItem item, {String? heroTag}) {
    Navigator.of(context).push(_detailRoute(item, heroTag));
  }

  /// 详情页转场：淡入 + 轻微上浮（进入）/ 淡出（返回）
  /// 不用 Material 默认的 zoom 转场：整页（含全幅海报与玻璃层）缩放会显得"弹"
  Route<void> _detailRoute(MediaItem item, String? heroTag) {
    return PageRouteBuilder<void>(
      // 半透明路由：转场时能看到下层页面，返回时是"淡出回上一层"而不是先黑一下
      opaque: false,
      barrierColor: Colors.transparent,
      // 时长即 Hero 飞行时长
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) => ListenableBuilder(
        listenable: _state,
        builder: (_, __) => DetailPage(
          item: item,
          onPlay: _openPlayer,
          state: _state,
          onOpenDetail: _openDetail,
          heroTag: heroTag,
        ),
      ),
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        // 内容淡入/淡出，位置交给 Hero：封面从卡片位置放大到详情头图
        return FadeTransition(opacity: curved, child: child);
      },
    );
  }

  void _openLibrary(LibraryView view) {
    setState(() {
      _state.selectedViewId = view.id;
      _tab = 1;
      _visited.add(1);
    });
    _tabAnim.forward(from: 0);
    _blur.value = false;
  }

  void _openAllLibrary() {
    setState(() {
      _state.selectedViewId = null;
      _tab = 1;
      _visited.add(1);
    });
    _tabAnim.forward(from: 0);
    _blur.value = false;
  }

  /// 只关注页面最外层纵向滚动：上滑超过阈值才显示状态栏模糊
  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _blur.value = n.metrics.pixels > 4;
    }
    return false;
  }

  void _openPlayer(
    MediaItem item,
    SubtitleTrackInfo? subtitle, {
    bool resume = true,
  }) {
    Navigator.of(context).push(
      // 不透明纯黑路由 + 淡入淡出：横竖屏切换全程藏在播放页黑幕后面，
      // 不会再出现详情页被系统旋转动画带着歪斜旋转的怪异转场
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => ListenableBuilder(
          listenable: _state,
          builder: (_, __) => PlayerPage(
            item: item,
            state: _state,
            subtitle: subtitle,
            startSeconds: resume ? (item.resumeSeconds ?? 0) : 0,
          ),
        ),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOut,
            reverseCurve: Curves.easeIn,
          );
          return FadeTransition(opacity: curved, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final pages = <Widget>[
          HomePage(
            onOpenDetail: _openDetail,
            state: _state,
            onOpenLibrary: _openLibrary,
            onOpenAll: _openAllLibrary,
          ),
          LibraryPage(onOpenDetail: _openDetail, state: _state),
          FavoritesPage(state: _state, onOpenDetail: _openDetail),
          StatsPage(state: _state),
          SettingsPage(
            onTabChanged: (i) => setState(() => _tab = i),
            state: _state,
          ),
        ];

        final shell = Scaffold(
          backgroundColor: AppColors.bg,
          body: Stack(
            children: [
              Positioned.fill(
                // 保活：切 Tab 不再销毁重建整页（图片不重解码、滚动位置保留）
                // 未访问过的页面先放占位，避免启动时一次性构建 5 页
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: AnimatedBuilder(
                    animation: _tabAnim,
                    builder: (_, inner) {
                      final t = Curves.easeOutCubic.transform(_tabAnim.value);
                      return Opacity(
                        opacity: 0.55 + 0.45 * t,
                        child: Transform.translate(
                          offset: Offset(0, 10 * (1 - t)),
                          child: inner,
                        ),
                      );
                    },
                    child: RepaintBoundary(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          for (var i = 0; i < pages.length; i++)
                            // Offstage：保留 State 但跳过布局/绘制；
                            // TickerMode：停掉隐藏页的动画
                            Offstage(
                              offstage: i != _tab,
                              child: TickerMode(
                                enabled: i == _tab,
                                child: _visited.contains(i)
                                    ? pages[i]
                                    : const SizedBox.shrink(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 顶部状态栏：上滑后才出现的渐进动态模糊，五个标签页统一
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _blur,
                    builder: (_, active, __) => StatusBarBlur(
                      height: MediaQuery.of(context).padding.top + 24,
                      active: active,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 10,
                child: _GlassNavBar(
                  index: _tab,
                  onChanged: (i) {
                    setState(() {
                      _tab = i;
                      _visited.add(i);
                    });
                    _tabAnim.forward(from: 0);
                    _blur.value = false;
                  },
                ),
              ),
            ],
          ),
        );

        return shell;
      },
    );
  }
}

/// 全局液态玻璃 Tab 栏：悬浮胶囊 + 选中项玻璃高亮胶囊
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  static const _items = [
    (Icons.home_rounded, '首页'),
    (Icons.grid_view_rounded, '媒体库'),
    (Icons.favorite_rounded, '收藏'),
    (Icons.insert_chart_rounded, '数据'),
    (Icons.person_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(33),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(33),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.16),
                Colors.white.withOpacity(0.05),
                Colors.white.withOpacity(0.10),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.16), width: 1),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 36,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Stack(
            children: [
              // 顶部镜面高光线（玻璃上缘反光）
              Positioned(
                left: 40,
                right: 40,
                top: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withOpacity(0.0),
                          Colors.white.withOpacity(0.5),
                          Colors.white.withOpacity(0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: List.generate(_items.length, (i) {
                  final item = _items[i];
                  final sel = i == index;
                  return Expanded(
                    child: LiquidPress(
                      onTap: () => onChanged(i),
                      radius: 24,
                      scale: 0.92,
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          width: 58,
                          height: 48,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            gradient: sel
                                ? LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Colors.white.withOpacity(0.26),
                                      Colors.white.withOpacity(0.10),
                                    ],
                                  )
                                : null,
                            border: sel
                                ? Border.all(
                                    color: Colors.white.withOpacity(0.30),
                                    width: 1,
                                  )
                                : null,
                            boxShadow: sel
                                ? const [
                                    BoxShadow(
                                      color: Color(0x33000000),
                                      blurRadius: 16,
                                      offset: Offset(0, 6),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                item.$1,
                                size: 18,
                                color: sel
                                    ? Colors.white.withOpacity(0.90)
                                    : Colors.white.withOpacity(0.90),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.$2,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: sel
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: sel
                                      ? Colors.white.withOpacity(0.90)
                                      : Colors.white.withOpacity(0.90),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
