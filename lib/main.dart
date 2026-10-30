import 'dart:async';
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
  // ErrorWidget 兜底：正常情况下永远不会看到它；
  // 但如果真的某个组件构建失败，原来是一片纯黑（用户只会说「App 打不开」），
  // 现在至少能看见是哪个组件出错、错在哪一行。
  //
  // 必须放在 main 里而不是 build 里：放进 build 的话，每次重建都赋一次新匿名
  // 函数，会一直覆盖自己。
  ErrorWidget.builder = _errorWidget;
  // 未捕获的异步异常也记一条，否则只会在控制台刷一行、真机上什么都看不到
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[fatal] ${details.exceptionAsString()}');
  };
  // 启动阶段任何一步抛异常，都必须在 runApp **之前**兜住。
  // 这里原本是裸调用：`Inspire.warmUp()` / `MediaKit.ensureInitialized()`
  // 只要有一个抛错（shader 资源缺失、libmpv 在个别机型上加载失败），
  // runApp 就根本不会执行 —— 表现是「点开 App 一片黑，永远进不去」。
  // 现在改成逐个 try：启动补丁失败最多损失一点动效/播 MPV 的能力，不能连首页都打不开。
  WidgetsFlutterBinding.ensureInitialized();
  _guard('Inspire.warmUp', Inspire.warmUp);
  _guard('imageCache', () {
    // 图片内存缓存：千部库滚动时减少「解码→淘汰→再解码」抖动
    PaintingBinding.instance.imageCache
      ..maximumSize = 1200
      ..maximumSizeBytes = 192 << 20;
  });
  _guard('MediaKit', MediaKit.ensureInitialized);
  runApp(const CambyApp());
}

/// 启动补丁的统一保护壳：单独失败不影响其余初始化，也不阻断 runApp。
void _guard(String name, void Function() body) {
  try {
    body();
  } catch (error, stack) {
    debugPrint('[boot] $name 初始化失败，已跳过：$error\n$stack');
    _bootIssues.add(name);
  }
}

/// 启动期被跳过的补丁名（诊断用，目前只写日志）
final List<String> _bootIssues = <String>[];

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

  /// 播放页句柄：STRM 加载弹窗里点「切换 Exo」时，直接驱动播放页切内核，
  /// 而不是重新推一个页面（那样进度、字幕、音量全丢）。
  final GlobalKey<PlayerPageState> _playerKey = GlobalKey<PlayerPageState>();

  @override
  void initState() {
    super.initState();
    _state = AppState();
    // restore() 内部要读文件、连服务器。任何一步抛未捕获异常都会变成
    // 「启动即黑屏」，所以这里吞掉并只记日志 —— 首页该显示什么显示什么，
    // 大不了是「未连接」状态，用户还能进设置页重新连。
    unawaited(
      _state.restore().catchError((Object e, StackTrace st) {
        debugPrint('[boot] restore 失败：$e\n$st');
      }),
    );
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
    final double startAt = resume ? (item.resumeSeconds ?? 0) : 0;

    // STRM 片源：**先弹加载弹窗**，再进播放页（v1.7.49）
    //
    // 设计稿要求的是「加载 strm 前有弹窗」。之前实现成「进播放页后盖一层
    // 胶囊」，顺序反了，所以用户看不到弹窗。
    //
    // 做法：弹窗 + 播放页同时推入，弹窗在上层。播放页照常起播，
    // 首帧一出来就通过 onBootSettled 把弹窗关掉，用户看到的是
    // 「弹窗（等待中）→ 画面」，中间不会有黑屏空档。

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
            key: _playerKey,
            item: item,
            state: _state,
            subtitle: subtitle,
            startSeconds: startAt,
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
              // 注意：这里以前还挂着一个 `_ShaderWarmup`（隐形 2×2 BackdropFilter）。
              // BackdropFilter 会为它**下面**的所有内容建立离屏图层，而它是 Stack
              // 的最后一个子节点（压在最底层）——等于要求把各平台 view 下面的
              // 全部内容先渲进一张离屏纹理。加上 Activity 的 theme 背景是黑的，
              // 一旦这块离屏合成失败，整屏就是纯黑。预热省下的那点首帧掉帧
              // 不值得冒「App 进不去」的风险，已移除。
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
                      radius: 22,
                      scale: 0.92,
                      glow: 0.36,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // 图标坐在一颗圆形玻璃片上：选中常亮，
                            // 按下时 LiquidPress 的光晕叠加在圆片上
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOutCubic,
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: sel
                                    ? LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Colors.white.withOpacity(0.28),
                                          Colors.white.withOpacity(0.10),
                                        ],
                                      )
                                    : null,
                                border: sel
                                    ? Border.all(
                                        color: Colors.white.withOpacity(0.32),
                                        width: 1,
                                      )
                                    : null,
                                boxShadow: sel
                                    ? const [
                                        BoxShadow(
                                          color: Color(0x40000000),
                                          blurRadius: 14,
                                          offset: Offset(0, 5),
                                        ),
                                        BoxShadow(
                                          color: Color(0x2E4F8CFF),
                                          blurRadius: 18,
                                          offset: Offset(0, 4),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Icon(
                                item.$1,
                                size: 18,
                                color: Colors.white.withOpacity(
                                  sel ? 0.96 : 0.78,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.$2,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: sel
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: Colors.white.withOpacity(
                                  sel ? 0.95 : 0.75,
                                ),
                              ),
                            ),
                          ],
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

/// 构建失败时的可见替代品：把异常直接画在屏幕上。
Widget _errorWidget(FlutterErrorDetails details) => Container(
  color: const Color(0xFF06080E),
  padding: const EdgeInsets.all(18),
  alignment: Alignment.center,
  child: SingleChildScrollView(
    child: Text(
      '界面渲染出错\n\n${details.exceptionAsString()}',
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 12,
        height: 1.5,
        color: Color(0xFFFF8FA3),
      ),
    ),
  ),
);
