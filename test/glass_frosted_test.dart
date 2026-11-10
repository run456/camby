import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/theme.dart';

void main() {
  group('v2.0.81 全站统一毛玻璃', () {
    testWidgets('blurEnabled:true 的 Glass 只挂一层 BackdropFilter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Glass(
                width: 200,
                height: 120,
                padding: const EdgeInsets.all(16),
                child: const Text(
                  'frosted',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('blurEnabled:false 的 Glass（播放页路径）不进滤镜，渲染不抛', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Glass(
                width: 200,
                height: 120,
                blurEnabled: false,
                child: const Text(
                  'play',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('同 sigma 的模糊滤镜复用同一实例', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Glass(width: 90, height: 90, blur: 20, child: SizedBox()),
                  Glass(width: 90, height: 90, blur: 20, child: SizedBox()),
                  Glass(width: 90, height: 90, blur: 30, child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final filters = tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .map((w) => w.filter)
          .toList();
      expect(filters.length, 3);
      expect(
        identical(filters[0], filters[1]),
        isTrue,
        reason: '相同 sigma 应命中缓存，避免重复创建引擎侧 ImageFilter',
      );
      expect(
        identical(filters[0], filters[2]),
        isFalse,
        reason: '不同 sigma 不应共用同一滤镜',
      );
    });

    test('液态玻璃链路已彻底移除', () {
      final theme = File('lib/theme.dart').readAsStringSync();
      expect(theme.contains('ImageFilter.compose'), isFalse);
      expect(theme.contains('ImageFilter.shader'), isFalse);
      expect(theme.contains('ColorFilter.matrix'), isFalse);
      expect(File('lib/liquid_glass.dart').existsSync(), isFalse);
      expect(File('shaders/liquid_glass.frag').existsSync(), isFalse);
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains('liquid_glass.frag'), isFalse);
      final main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('GlassConfig'), isFalse);
      expect(main.contains('ensureLoaded'), isFalse);
      final settings = File('lib/pages/settings_page.dart').readAsStringSync();
      expect(settings.contains('set_liquid_glass'), isFalse);
      expect(settings.contains("title: '液态玻璃'"), isFalse);
    });
  });

  group('v2.0.81 性能回归（动效不变）', () {
    test('P0/P1：Glass 单层模糊 + 静态滤镜缓存 + 背景光晕静态子树', () {
      final theme = File('lib/theme.dart').readAsStringSync();
      expect(theme.contains('_blurCache'), isTrue);
      expect(theme.contains('RepaintBoundary(child: body)'), isTrue);
      // 三层白色高光 / 内发光 / 分色边已全部移除
      expect(theme.contains('_innerGlow'), isFalse);
      expect(theme.contains('_specular'), isFalse);
      expect(theme.contains('_vibrancy'), isFalse);

      final main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('_barBlur'), isTrue);
      expect(main.contains('sigmaX: 14'), isTrue);

      final stats = File('lib/pages/stats_page.dart').readAsStringSync();
      expect(stats.contains('_blobLayers'), isTrue);
      expect(
        stats.contains('Duration(seconds: 26)'),
        isTrue,
        reason: '背景光晕公转周期必须保持 26s，动效不变',
      );
    });

    test('P2：两个页面级长列表改懒构造，且平板双栏不依赖提前建好的 Widget', () {
      final settings = File('lib/pages/settings_page.dart').readAsStringSync();
      expect(settings.contains('ListView.builder('), isTrue);
      expect(settings.contains('final cells = <WidgetBuilder>['), isTrue);
      expect(
        settings.contains('itemBuilder: (ctx, i) => cells[i](ctx)'),
        isTrue,
      );

      final stats = File('lib/pages/stats_page.dart').readAsStringSync();
      expect(stats.contains('ListView.builder('), isTrue);
      expect(stats.contains('final cells = <_StatCell>['), isTrue);
      expect(stats.contains('itemBuilder: (ctx, i) => rows[i](ctx)'), isTrue);
      expect(stats.contains('class _StatCell'), isTrue);
      expect(
        stats.contains('List<WidgetBuilder> _tabletColumns('),
        isTrue,
        reason: '双栏排布必须基于 WidgetBuilder 列表，避免首帧构造全部卡片',
      );
      expect(stats.contains('if (w is SizedBox) continue'), isFalse);
    });
  });
}
