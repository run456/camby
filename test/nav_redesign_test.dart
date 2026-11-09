// v2.0.67 导航改造回归（手机方案 A / 平板方案 B）
//
// 用户确认：圆形玻璃按钮效果不更改；手机选中项为青蓝渐变胶囊（图标 + 文字）、
// 未选中项只剩线性图标；平板从左侧 Rail 改为底部居中悬浮条。
// 这里锁住「不该被改动的东西」与「已经改对的东西」，避免后续版本
// 又把手机 / 平板分裂回两套导航语言。
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
      onSearch: () {},
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
    test('外壳不再有左侧 Rail，手机 / 平板共用 GlassNavBar', () {
      final main = _src('lib/main.dart');
      expect(main.contains('_buildRail('), isFalse);
      expect(main.contains('class _RailButton'), isFalse);
      expect(main.contains('context.useRail'), isFalse);
      expect(main.contains('AppNav.tabletBarWidth'), isTrue,
          reason: '平板方案 B：悬浮条限宽居中');
      expect(main.contains('context.isTablet'), isTrue);
    });

    test('整条导航只挂 1 个模糊层，胶囊内不再嵌滤镜', () {
      final main = _src('lib/main.dart');
      expect(
        'BackdropFilter('.allMatches(main).length,
        1,
        reason: '5 个格子各挂滤镜会让列表滚动时触发 5 次背景重采样',
      );
    });

    test('导航仍是 5 个 Tab，顺序不变', () {
      final main = _src('lib/main.dart');
      final block =
          RegExp(r'static const _items = \[([\s\S]*?)\];')
              .firstMatch(main)
              ?.group(1) ??
          '';
      expect('(Icons.'.allMatches(block).length, 5);
      expect(block.indexOf('home_rounded'),
          lessThan(block.indexOf('grid_view_rounded')));
      expect(block.contains("'演员'"), isFalse);
      expect(block.contains("'系列'"), isFalse);
    });

    test('视觉 token 集中在 AppNav，圆钮组件本版零改动', () {
      final theme = _src('lib/theme.dart');
      for (final k in [
        'class AppNav',
        'capsuleGradient',
        'tabletBarWidth',
        'idleWidth = 48',
        'selectedWidth = 108',
        'itemHeight = 48',
      ]) {
        expect(theme.contains(k), isTrue, reason: '缺少 $k');
      }
      // 用户明确否决《圆形玻璃按钮设计稿》：按钮本体不在本版改动范围。
      expect(theme.contains('class Glass extends StatelessWidget'), isTrue);
      expect(
        theme.contains('class GlassIconButton extends StatelessWidget'),
        isTrue,
      );
    });

    test('双击搜索 / 触感 / 转场 / 懒加载全部保留', () {
      final main = _src('lib/main.dart');
      expect(main.contains('AppHaptics.light()'), isTrue);
      expect(main.contains('widget.onSearch?.call()'), isTrue);
      expect(main.contains('_tabAnim.forward(from: 0)'), isTrue);
      expect(main.contains('_visited.add(i)'), isTrue);
    });
  });

  group('组件行为', () {
    testWidgets('方案 A：只有选中项显示文字，5 个图标始终齐全', (tester) async {
      await tester.pumpWidget(_bar(0));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('首页'), findsOneWidget);
      for (final label in ['媒体库', '收藏', '数据', '我的']) {
        expect(find.text(label), findsNothing, reason: '未选中项不显示文字');
      }
      for (final icon in const [
        Icons.home_rounded,
        Icons.grid_view_rounded,
        Icons.favorite_rounded,
        Icons.insert_chart_rounded,
        Icons.person_rounded,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('切换选中项：胶囊展开全程无布局溢出，文字跟着走', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _LiveNavHost()));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.favorite_rounded));
      // 走完 260ms 宽度动画，逐帧检查是否有 RenderFlex 溢出
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('首页'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('尺寸 / 动效 token 达标（触控 ≥48、平板限宽、动画 260ms）', () {
      expect(AppNav.itemHeight, greaterThanOrEqualTo(48));
      expect(AppNav.idleWidth, greaterThanOrEqualTo(48));
      expect(AppNav.selectedWidth, 108);
      expect(AppNav.tabletBarWidth, 320);
      expect(AppNav.barHeight, 62);
      expect(AppNav.duration.inMilliseconds, 260);
      expect(AppNav.badgeColor, const Color(0xFFFF5A5F));
    });
  });
}
