import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:inspire_blur/inspire_blur.dart';
import 'package:media_kit/media_kit.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subtitles/online_subtitle.dart';
import 'app_state.dart';
import 'models.dart';
import 'theme.dart';
import 'liquid_glass.dart';
import 'widgets/liquid_press.dart';
import 'widgets/status_bar_blur.dart';
import 'widgets/haptics.dart';
import 'pages/home_page.dart';
import 'pages/detail_page.dart';
import 'pages/player_page.dart';
import 'pages/stats_page.dart';
import 'pages/library_page.dart';
import 'pages/settings_page.dart';
import 'pages/search_page.dart';

Future<void> main() async {
  // 在线字幕：迅雷字幕是 GBK 编码，注入解码器避免中文乱码。
  // 漏掉这一步不会报错，但字幕会显示成乱码，属于「静默失败」。
  OnlineSubtitleConfig.gbkDecoder = (bytes) => gbk_bytes.decode(bytes);

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
  // 触感开关要在首个可交互帧之前读好，否则第一次点按会用错档位。
  // load() 内部自带兜底，插件未注册也不会阻断启动。
  await AppHaptics.load();
  _guard('Inspire.warmUp', Inspire.warmUp);
  _guard('imageCache', () {
    // 图片内存缓存：千部库滚动时减少「解码→淘汰→再解码」抖动
    PaintingBinding.instance.imageCache
      ..maximumSize = 1200
      ..maximumSizeBytes = 192 << 20;
  });
  _guard('MediaKit', MediaKit.ensureInitialized);
  // L2 液态玻璃：启动期预加载 fragment shader（失败静默降级 L1），并读取用户开关。
  // ensureLoaded 内部自带 try/catch，不会阻断启动；shader 未就绪时首帧先用 L1。
  await LiquidGlass.ensureLoaded();
  try {
    final prefs = await SharedPreferences.getInstance();
    GlassConfig.liquidEnabled = prefs.getBool('set_liquid_glass') ?? true;
  } catch (_) {
    // 偏好读取失败不影响启动，保持默认开液态。
  }
  // 全局动态镜面光源：启动即运行（幂等），导航条等大玻璃订阅后可获得流动高光。
  LiquidLightSource.start();
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

/// 路由出栈时清掉输入框焦点。
///
/// 详情页是半透明路由，pop 回首页 / Tab 时 Flutter 偶尔会把焦点还给上一条
/// 路由里曾经聚焦的 TextField，于是「返回首页却弹出键盘」。这里统一收口：
/// 任何一次 pop 都把主焦点收掉，键盘只由用户主动点输入框唤起。
class _FocusResetObserver extends NavigatorObserver {
  _FocusResetObserver();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }
}

class CambyApp extends StatelessWidget {
  const CambyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camby',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      // v2.0.69：路由出栈时一律清掉输入框焦点。详情页是半透明路由，
      // pop 时 Flutter 偶尔会把焦点还给上一条路由里曾经聚焦的 TextField，
      // 于是「返回首页却弹出键盘」。这里统一收口，键盘只由用户点输入框唤起。
      navigatorObservers: [_FocusResetObserver()],
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

  /// v2.0.68：搜索升为一级 Tab（index 2），双击当前 Tab 唤起搜索与
  /// 「我的」页右上角搜索按钮一并取消，全局只剩「点搜索 Tab」一条路径。
  /// 因此这里不再保留旧的半透明搜索路由转场。

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
          // v2.0.65：版本下拉选中的非主版本，带 MediaSourceId 起播。
          // 字幕传 null 让播放页按该源自动挑轨（item 级字幕 index
          // 属于主版本，硬套到另一文件可能对不上）。
          onPlayVersion: (
            it, {
            required MediaExtraPart version,
            resume = true,
          }) =>
              _openPlayer(
                it,
                null,
                resume: resume,
                mediaSourceId: version.id,
                sourceLabel: version.name,
                version: version,
              ),
          onPlayPart: _openExtraPart,
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

  /// v2.0.64：空态 CTA 的真实跳转（去媒体库 / 去「我的」连接服务器）。
  /// 与底部 Tab 点击走同一套过渡，避免「点了一下界面像没反应」。
  void _goTab(int i) {
    setState(() {
      _tab = i;
      _visited.add(i);
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

  /// 播放「额外部分」：同一影片的其它 MediaSource（-Cd1 / -Cd2 等分段）。
  ///
  /// 与 [_openPlayer] 的区别只有两点：起播时带上 `MediaSourceId`，保证播的是
  /// 指定那一段而不是主版本；不携带续播位置（分段各自独立，续播点对不上）。
  void _openExtraPart(MediaItem item, MediaExtraPart part) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => ListenableBuilder(
          listenable: _state,
          builder: (_, __) => PlayerPage(
            key: _playerKey,
            // v2.0.66：分段/额外部分同样把该 MediaSource 的规格带给播放页，
            // 顶栏与播放信息面板才不会显示主版本的分辨率。
            item: item.withMediaSource(part),
            state: _state,
            startSeconds: 0,
            mediaSourceId: part.id,
            sourceLabel: part.name,
          ),
        ),
      ),
    );
  }

  void _openPlayer(
    MediaItem item,
    SubtitleTrackInfo? subtitle, {
    bool resume = true,
    // v2.0.65：详情页版本下拉选中非主版本时，带上该 MediaSourceId 起播；
    // 不传时行为与以前完全一致（服务端默认主版本）。
    String? mediaSourceId,
    String? sourceLabel,
    // v2.0.66：非主版本的完整规格。播放页顶栏 / 播放信息面板读的是 item，
    // 起播前覆盖一次，选 4K 就不会再显示主版本的 1080p。
    MediaExtraPart? version,
  }) {
    final playItem = version != null ? item.withMediaSource(version) : item;
    final double startAt = resume ? (playItem.resumeSeconds ?? 0) : 0;

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
            item: playItem,
            state: _state,
            subtitle: subtitle,
            startSeconds: startAt,
            mediaSourceId: mediaSourceId,
            sourceLabel: sourceLabel,
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
          LibraryPage(
            onOpenDetail: _openDetail,
            state: _state,
            onGoSettings: () => _goTab(4),
          ),
          // v2.0.69：搜索页不再自动聚焦，切走再切回保留上次查询且键盘不弹。
          SearchPage(
            state: _state,
            onOpenDetail: _openDetail,
          ),
          StatsPage(state: _state),
          SettingsPage(
            onTabChanged: (i) {
              AppHaptics.light();
              setState(() => _tab = i);
            },
            state: _state,
            onOpenDetail: _openDetail,
          ),
        ];

        // 内容体（页面保活 + 状态栏模糊）。
        // v2.0.68：低干扰雾面导航，手机 / 平板统一 280dp 居中悬浮，
        // 不再按 isTablet 分支给不同宽度；左侧 Rail 依旧保持废弃。
        final body = _buildBody(context, pages);

        return Scaffold(
          backgroundColor: AppColors.bg,
          // v2.0.69：点到非输入区域一律收起键盘。deferToChild 让子 widget
          // 的点击优先，所以点搜索框本身不会误触发 unfocus；只有点空白、
          // 卡片、按钮时才会顺手把键盘收掉。
          body: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onTap: () => FocusScope.of(context).unfocus(),
            child: Stack(
              children: [
                body,
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.of(context).padding.bottom + 20,
                  child: Center(
                    child: SizedBox(
                      width: AppNav.tabletBarWidth,
                      child: GlassNavBar(
                        index: _tab,
                        onChanged: (i) {
                          // 切 Tab 不该把上一个页面的键盘带过去。
                          FocusScope.of(context).unfocus();
                          setState(() {
                            _tab = i;
                            _visited.add(i);
                          });
                          _tabAnim.forward(from: 0);
                          _blur.value = false;
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 内容体：页面保活（Offstage+TickerMode）+ 切 Tab 柔和过渡 + 顶部状态栏模糊。
  /// 与导航外壳解耦，供手机（底部 Tab）与平板（左侧 Rail）复用。
  Widget _buildBody(BuildContext context, List<Widget> pages) {
    return Stack(
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
      ],
    );
  }

  // v2.0.67：平板改方案 B（底部居中悬浮条），左侧 Rail 与 _RailButton
  // 一并移除；手机 / 平板两端共用同一个 GlassNavBar。
}

/// 全局低干扰雾面 Tab 栏（v2.0.68 · 手机 / 平板共用）。
///
/// 视觉语言与媒体库顶部 `LibraryIndexSegment` 同源：白 6% 底、白 10%
/// 描边、白雾面选中项、无彩色渐变 / 无发光 / 无镜面高光线。
/// v2.0.67 的 260ms 胶囊展开动画、LiquidPress 按压与轻触感原样保留。
class GlassNavBar extends StatefulWidget {
  const GlassNavBar({
    required this.index,
    required this.onChanged,
  });
  final int index;
  final ValueChanged<int> onChanged;

  /// v2.0.68：全部换成设计稿里的空心线性图标（用户明确反馈实心款不好看）。
  /// 收藏并入媒体库第 4 类，一级 index 2 改为搜索。
  static const _items = [
    (Icons.home_outlined, '首页'),
    (Icons.grid_view_outlined, '媒体库'),
    (Icons.search_outlined, '搜索'),
    (Icons.insert_chart_outlined, '数据'),
    (Icons.person_outline_rounded, '我的'),
  ];

  @override
  State<GlassNavBar> createState() => GlassNavBarState();
}

class GlassNavBarState extends State<GlassNavBar> {
  void _onTap(int i) {
    // v2.0.68：双击当前 Tab 唤起搜索已取消，不再记录时间戳 / 上次索引。
    // 切 Tab 是明确的状态变化，给一次最轻的 selectionClick。
    AppHaptics.light();
    widget.onChanged(i);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final useLiquid =
        GlassConfig.liquidEnabled && LiquidGlass.supported;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppNav.barRadius),
      // 动态镜面：光源匀速公转，仅导航条这一块大玻璃订阅，性能可控。
      child: ValueListenableBuilder<double>(
        valueListenable: LiquidLightSource.angle,
        builder: (_, a, __) {
          final light = Offset(cos(a), sin(a));
          final filter = useLiquid
              ? ImageFilter.compose(
                  // 整面折射作用于清晰背景，再轻模糊柔化 → 真实透镜弯曲
                  inner: ImageFilter.shader(
                    LiquidGlass.shader(
                      radius: AppNav.barRadius * dpr,
                      refraction: 16 * dpr,
                      dispersion: 0.30,
                      specular: 0.6,
                      full: true,
                      light: light,
                    ),
                  ),
                  outer: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                )
              : ImageFilter.blur(sigmaX: 20, sigmaY: 20);
          return BackdropFilter(
            filter: filter,
            child: Container(
              height: AppNav.barHeight,
              padding: const EdgeInsets.all(AppNav.barInset),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppNav.barRadius),
                // 与 LibraryIndexSegment 完全同款的雾面底：纯色、无三段渐变。
                color: Colors.white.withValues(alpha: 0.06),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.10),
                  width: 1,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x47000000),
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              // 5 项整体居中：312 − 2 描边 − 6 内距 = 304，正好等于
              // 112 + 4×48，定宽 Row 不会挤出像素。
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children:
                    List.generate(GlassNavBar._items.length, _navItem),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 单项：选中 = 96dp 白雾面药丸（图标 + 文字），未选中 = 44dp 纯图标。
  Widget _navItem(int i) {
    final item = GlassNavBar._items[i];
    final sel = i == widget.index;
    return LiquidPress(
      onTap: () => _onTap(i),
      radius: AppNav.itemRadius,
      scale: 0.94,
      glow: 0.30,
      // 未选中项没有文字，语义标签保证读屏与自动化测试仍能定位每个 Tab
      semanticLabel: item.$2,
      child: AnimatedContainer(
        duration: AppNav.duration,
        curve: AppNav.curve,
        width: sel ? AppNav.selectedWidth : AppNav.idleWidth,
        height: AppNav.itemHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppNav.itemRadius),
          // v2.0.68：选中态换成媒体库分段同款白雾面渐变，
          // 彩色投影与青色发光全部清空，只留 1px 白 26% 内描边。
          gradient: sel ? AppNav.capsuleGradient : null,
          border: sel
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.26),
                  width: 1,
                )
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppNav.itemRadius),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.$1,
                  size: 22,
                  color: Colors.white.withValues(alpha: sel ? 0.96 : 0.55),
                ),
                // 文字宽度从 0 展开，与胶囊 44 → 96 共用同一条曲线：
                // 任意时刻内容都比容器窄，不会触发 RenderFlex 溢出。
                AnimatedSize(
                  duration: AppNav.duration,
                  curve: AppNav.curve,
                  alignment: Alignment.centerLeft,
                  clipBehavior: Clip.hardEdge,
                  child: sel
                      ? Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            item.$2,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                              color: Colors.white,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
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
