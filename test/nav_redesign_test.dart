// v2.0.68 低干扰导航 + 媒体库 4 类 + 空心图标回归
//
// 用户确认：保留 260ms 切换动画；底栏改用媒体库分段同款白雾面；
// 手机 / 平板统一 312dp 居中；收藏并入媒体库成为第 4 类；原收藏一级 Tab
// 换成搜索页；双击唤起搜索取消；一级 Tab 图标全部换成空心线性款。
import 'dart:io';

import 'package:camby/main.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

Widget _bar(int index) => MaterialApp(
  home: Scaffold(
    bottomNavigationBar: GlassNavBar(
      index: index,
      onChanged: (_) {},
    ),
  ),
);

/// 真实可切换的宿主：用于验证 260ms 胶囊展开动画期间不会布局溢出。
class _LiveNavHost extends StatefulWidget {
  const _LiveNavHost();

  @override
  State<_LiveNavHost> createState() => _LiveNavHostState();
}

class _LiveNavHostState extends State<_LiveNavHost> {
  int index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: GlassNavBar(
      index: index,
      onChanged: (i) => setState(() => index = i),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('源码守卫', () {
    test('外壳无左侧 Rail，手机 / 平板共用同一条 312dp 悬浮导航', () {
      final main = _src('lib/main.dart');
      expect(main.contains('_buildRail('), isFalse);
      expect(main.contains('class _RailButton'), isFalse);
      expect(main.contains('context.useRail'), isFalse);
      expect(main.contains('context.isTablet'), isFalse,
          reason: 'v2.0.68 两端统一 312dp，外壳不再按平板分支给宽度');
      expect(main.contains('AppNav.tabletBarWidth'), isTrue,
          reason: '限宽居中，且手机 / 平板共用');
      expect(main.contains('left: 0,'), isTrue);
      expect(main.contains('right: 0,'), isTrue);
    });

    test('双击唤起搜索已彻底移除，搜索是一级 Tab', () {
      final main = _src('lib/main.dart');
      expect(main.contains('onSearch'), isFalse);
      expect(main.contains('_lastTap'), isFalse);
      expect(main.contains('_lastIndex'), isFalse);
      expect(main.contains('_openSearch('), isFalse);
      expect(main.contains('_searchRoute('), isFalse);
      expect(main.contains('widget.onSearch?.call()'), isFalse);
      // index 2 = 搜索，收藏页不再挂在一级 pages 里。
      expect(main.contains('SearchPage('), isTrue);
      expect(main.contains('FavoritesPage('), isFalse);
      expect(main.contains('active: _tab == 2'), isFalse,
          reason: 'v2.0.69 搜索页不再接收外壳可见性，也不自动聚焦');
    });

    test('整条导航只挂 1 个模糊层，胶囊内不再嵌滤镜', () {
      final main = _src('lib/main.dart');
      expect(
        'BackdropFilter('.allMatches(main).length,
        1,
        reason: '5 个格子各挂滤镜会让列表滚动时触发 5 次背景重采样',
      );
      expect(main.contains('sigmaX: 20'), isTrue,
          reason: 'v2.0.68 模糊由 30 降到 20，弱化存在感');
      expect(main.contains('0x47000000'), isTrue,
          reason: '投影从黑 40% / blur36 降为黑 28% / blur20');
      expect(main.contains('0x66000000'), isFalse);
    });

    test('5 个 Tab 全为空心图标，收藏位换成搜索', () {
      final main = _src('lib/main.dart');
      final block =
          RegExp(r'static const _items = \[([\s\S]*?)\];')
              .firstMatch(main)
              ?.group(1) ??
          '';
      expect('(Icons.'.allMatches(block).length, 5);
      for (final icon in const [
        'home_outlined',
        'grid_view_outlined',
        'search_outlined',
        'insert_chart_outlined',
        'person_outline_rounded',
      ]) {
        expect(block.contains(icon), isTrue, reason: '缺少空心图标 $icon');
      }
      // 用户明确反馈实心款不好看：5 个旧 *_rounded 实心图标一个都不能留。
      for (final icon in const [
        'home_rounded',
        'grid_view_rounded',
        'favorite_rounded',
        'insert_chart_rounded',
        'person_rounded',
      ]) {
        expect(block.contains(icon), isFalse, reason: '仍残留实心图标 $icon');
      }
      expect(block.contains("'搜索'"), isTrue);
      expect(block.contains("'收藏'"), isFalse);
      expect(block.contains("'演员'"), isFalse);
      expect(block.contains("'系列'"), isFalse);
    });

    test('媒体库分段扩为 4 类，新增收藏且图标为空心', () {
      final seg = _src('lib/widgets/library_index_segment.dart');
      expect(seg.contains('enum LibraryIndexTab { movies, actors, series, favorites }'),
          isTrue);
      expect(seg.contains("'收藏'"), isTrue);
      expect(seg.contains('favorite_border_rounded'), isTrue);
      final lib = _src('lib/pages/library_page.dart');
      expect(lib.contains('LibraryIndexTab.favorites'), isTrue);
      expect(lib.contains('FavoritesPage('), isTrue,
          reason: '收藏页收进媒体库第 4 类分支');
    });

    test('视觉 token 集中在 AppNav，圆钮组件本版零改动', () {
      final theme = _src('lib/theme.dart');
      for (final k in [
        'class AppNav',
        'capsuleGradient',
        'tabletBarWidth',
        'idleWidth = 48',
        'selectedWidth = 112',
        'itemHeight = 48',
        'barHeight = 56',
      ]) {
        expect(theme.contains(k), isTrue, reason: '缺少 $k');
      }
      // 白雾面渐变与媒体库分段同源；青蓝高饱和渐变已删除。
      expect(theme.contains('0x38FFFFFF'), isTrue);
      expect(theme.contains('0x14FFFFFF'), isTrue);
      expect(theme.contains('0xFF2FD8B6'), isFalse);
      // 用户明确否决《圆形玻璃按钮设计稿》：按钮本体不在本版改动范围。
      expect(theme.contains('class Glass extends StatelessWidget'), isTrue);
      expect(
        theme.contains('class GlassIconButton extends StatelessWidget'),
        isTrue,
      );
    });

    test('触感 / 转场 / 懒加载 / 切换动画全部保留', () {
      final main = _src('lib/main.dart');
      expect(main.contains('AppHaptics.light()'), isTrue);
      expect(main.contains('_tabAnim.forward(from: 0)'), isTrue);
      expect(main.contains('_visited.add(i)'), isTrue);
      expect(main.contains('AnimatedContainer('), isTrue);
      expect(main.contains('AnimatedSize('), isTrue);
      expect(main.contains('duration: AppNav.duration'), isTrue);
      expect(main.contains('curve: AppNav.curve'), isTrue);
    });
  });

  group('组件行为', () {
    testWidgets('只有选中项显示文字，5 个空心图标始终齐全', (tester) async {
      await tester.pumpWidget(_bar(0));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('首页'), findsOneWidget);
      for (final label in ['媒体库', '搜索', '数据', '我的']) {
        expect(find.text(label), findsNothing, reason: '未选中项不显示文字');
      }
      for (final icon in const [
        Icons.home_outlined,
        Icons.grid_view_outlined,
        Icons.search_outlined,
        Icons.insert_chart_outlined,
        Icons.person_outline_rounded,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('切换选中项：胶囊展开全程无布局溢出，文字跟着走', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _LiveNavHost()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.search_outlined));
      // 走完 260ms 宽度动画，逐帧检查是否有 RenderFlex 溢出
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('搜索'), findsOneWidget);
      expect(find.text('首页'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('尺寸 / 动效 token 达标（低干扰雾面值）', () {
      expect(AppNav.itemHeight, 48);
      expect(AppNav.idleWidth, 48);
      expect(AppNav.selectedWidth, 112);
      expect(AppNav.tabletBarWidth, 312);
      expect(AppNav.barHeight, 56);
      expect(AppNav.barInset, 3);
      // 312 − 2 描边 − 6 内距 = 304 = 112 + 4×48，定宽 Row 零余量。
      expect(
        AppNav.tabletBarWidth - 2 - 2 * AppNav.barInset,
        AppNav.selectedWidth + 4 * AppNav.idleWidth,
      );
      expect(AppNav.duration.inMilliseconds, 260);
      expect(AppNav.badgeColor, const Color(0xFFFF5A5F));
    });
  });
}
