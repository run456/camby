import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/liquid_glass.dart';
import 'package:camby/theme.dart';

void main() {
  group('v2.0.72 玻璃材质 L2 液态（真折射 + 可见保底）', () {
    test('GlassConfig.liquidEnabled 默认开，可切换', () {
      GlassConfig.liquidEnabled = true;
      expect(GlassConfig.liquidEnabled, isTrue);
      GlassConfig.liquidEnabled = false;
      expect(GlassConfig.liquidEnabled, isFalse);
      GlassConfig.liquidEnabled = true; // 还原
    });

    // v2.0.76 真机 bug：设置页开关拨了，玻璃毫无变化。
    // 原因是裸 static bool 只在设置页 setState 里改，被 IndexedStack
    // 缓存的其它页面不会重建。改成 ValueNotifier 后由每块 Glass 自己监听。
    test('材质档位是 ValueNotifier：切换必通知、同值不重复通知', () {
      var hits = 0;
      void onChanged() => hits++;
      GlassConfig.liquid.addListener(onChanged);
      addTearDown(() {
        GlassConfig.liquid.removeListener(onChanged);
        GlassConfig.liquidEnabled = true;
      });

      GlassConfig.liquidEnabled = true; // 已是 true，不应通知
      expect(hits, 0);
      GlassConfig.liquidEnabled = false;
      expect(hits, 1);
      GlassConfig.liquidEnabled = false; // 同值，不应重复通知
      expect(hits, 1);
      GlassConfig.liquidEnabled = true;
      expect(hits, 2);
      expect(GlassConfig.liquid, isA<ValueNotifier<bool>>());
    });

    testWidgets('Glass 自己监听档位：切换后无需父级 setState 即重建', (tester) async {
      GlassConfig.liquidEnabled = true;
      var parentBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                parentBuilds++;
                return const Center(
                  child: Glass(
                    width: 180,
                    height: 100,
                    child: Text('t', style: TextStyle(color: Colors.white)),
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(parentBuilds, 1);

      GlassConfig.liquidEnabled = false;
      await tester.pump();
      // 父 Builder 没重建，说明是 Glass 内部（ValueListenableBuilder）自己刷的
      expect(parentBuilds, 1);
      expect(tester.takeException(), isNull);

      GlassConfig.liquidEnabled = true;
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    test('LiquidGlass.ensureLoaded 不抛错（失败则静默降级）', () async {
      await LiquidGlass.ensureLoaded();
      expect(LiquidGlass.supported, isA<bool>());
    });

    test('shader 装配的源码存在且声明了 ImageFilter.shader 的硬契约', () {
      final src = File('shaders/liquid_glass.frag').readAsStringSync();
      // 首个 uniform 必须是 vec2（引擎注入纹理尺寸）
      expect(src.contains('uniform vec2 u0_size'), isTrue);
      // 至少一个 sampler2D（引擎注入滤镜输入）
      expect(src.contains('sampler2D'), isTrue);
      // GLES 后端 Y 轴翻转
      expect(src.contains('IMPELLER_TARGET_OPENGLES'), isTrue);
    });

    testWidgets('blurEnabled:true 的 Glass 渲染不抛（L2 或降级 L1）', (tester) async {
      GlassConfig.liquidEnabled = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Glass(
                width: 200,
                height: 120,
                padding: const EdgeInsets.all(16),
                child: const Text('L2', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('blurEnabled:false 的 Glass（播放页路径）不进滤镜，渲染不抛',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Glass(
                width: 200,
                height: 120,
                blurEnabled: false,
                child: const Text('play', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭开关时强制走 L1（supported 与否都不抛）', (tester) async {
      GlassConfig.liquidEnabled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Glass(
                width: 180,
                height: 100,
                child: const Text('L1', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      GlassConfig.liquidEnabled = true; // 还原
    });
  });
}
