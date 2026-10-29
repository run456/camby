import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/widgets/liquid_press.dart';

void main() {
  testWidgets('LiquidPress 点击回调生效', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiquidPress(
              radius: 20,
              onTap: () => tapped++,
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(LiquidPress));
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  testWidgets('LiquidPress 按下时缩放并出现高光层', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiquidPress(
              radius: 20,
              onTap: null,
              child: SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    );

    // 常态：缩放为 1
    var scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1.0);

    final center = tester.getCenter(find.byType(LiquidPress));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 200));

    // 按下中：缩小（下沉）
    scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, lessThan(1.0));

    await gesture.up();
    await tester.pumpAndSettle();

    scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1.0);
  });

  testWidgets('LiquidPress 禁用时不响应点击', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiquidPress(
              radius: 20,
              enabled: false,
              onTap: () => tapped++,
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(LiquidPress));
    await tester.pumpAndSettle();
    expect(tapped, 0);
  });
}
