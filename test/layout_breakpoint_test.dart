import 'dart:io';

import 'package:camby/layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('breakpoint 三档对齐设计稿 840/1200', (tester) async {
    Future<Breakpoint> at(double w) async {
      Breakpoint? r;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(w, 900)),
            child: Builder(
              builder: (c) {
                r = c.breakpoint;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return r!;
    }

    // 手机
    expect(await at(390), Breakpoint.phone); // 手机竖屏
    expect(await at(833), Breakpoint.phone); // 刚好低于 840
    // 中等（840–1199）：多为竖屏平板 / 折叠展开
    expect(await at(840), Breakpoint.medium); // 边界命中中等
    expect(await at(1110), Breakpoint.medium); // MagicPad3 竖屏 ≈1110
    expect(await at(1199), Breakpoint.medium);
    // 扩展（≥1200）：横屏平板主从分栏
    expect(await at(1200), Breakpoint.expanded); // 边界命中扩展
    expect(await at(1660), Breakpoint.expanded); // MagicPad3 横屏 ≈1660
  });

  testWidgets('v2.0.67：useRail 恒 false，平板不再启用左侧 Rail', (
    tester,
  ) async {
    Future<bool> railAt(double w) async {
      bool? r;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(w, 900)),
            child: Builder(
              builder: (c) {
                r = c.useRail;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return r!;
    }

    expect(await railAt(390), isFalse);
    expect(await railAt(840), isFalse, reason: '平板方案 B 改底部悬浮条');
    expect(await railAt(1660), isFalse);
  });

  testWidgets('isTablet 仍按 840 分档（页面分栏 / 列数继续可用）', (
    tester,
  ) async {
    Future<bool> tabletAt(double w) async {
      bool? r;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(w, 900)),
            child: Builder(
              builder: (c) {
                r = c.isTablet;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return r!;
    }

    expect(await tabletAt(390), isFalse);
    expect(await tabletAt(840), isTrue);
    expect(await tabletAt(1660), isTrue);
  });

  test('断点阈值与废弃的 Rail 常量', () {
    expect(kRailWidth, 96);
    expect(kTabletBreakpoint, 840);
    expect(kExpandedBreakpoint, 1200);
    // 外壳不得再引用轨道宽度或 Rail 构造器
    final main = File('lib/main.dart').readAsStringSync();
    expect(main.contains('_buildRail('), isFalse);
    expect(main.contains('context.useRail'), isFalse);
  });
}
