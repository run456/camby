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
