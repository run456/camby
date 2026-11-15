import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.94：用户反馈「添加服务器，选择绿联时，弹窗高度突然高一截」。
///
/// 原因：绿联分支在表单里额外叠了三段条件文字（证书未开警告 / 协议警告 /
/// 「不广播发现包」说明），加上标题说明、SSL 说明、底部说明都会折成两行，
/// 比 Emby 多出 4~5 行。弹窗是 `SingleChildScrollView` + `mainAxisSize.min`，
/// 内容多高弹窗就多高，切换分段时整张卡片往上跳。
///
/// 修法：不硬编码弹窗高度，而是让**表单行数与类型无关** —— 可变文案一律
/// 单行省略，三段条件提示合并进底部本来就有的一行说明里。
String src(String path) => File(path).readAsStringSync();

void main() {
  group('serverSheetNote：三种类型共用一行提示', () {
    test('Emby / Jellyfin 给通用保存提示', () {
      final note = serverSheetNote(
        isUgreen: false,
        compat: false,
        ignoreSsl: true,
        secure: true,
        port: 8096,
      );
      expect(note, contains('配置会保存在本地'));
      expect(note, isNot(contains('⚠')));
    });

    test('绿联给「手动填地址 + 进度不同步」要点', () {
      final note = serverSheetNote(
        isUgreen: true,
        compat: true,
        ignoreSsl: true,
        secure: true,
        port: 9443,
      );
      expect(note, contains('手动填地址'));
      expect(note, contains('进度同步'));
    });

    test('证书未开的警告优先于其它提示', () {
      final note = serverSheetNote(
        isUgreen: true,
        compat: true,
        ignoreSsl: false,
        secure: true,
        port: 9443,
      );
      expect(note, contains('⚠'));
      expect(note, contains('忽略证书校验'));
    });

    test('9443 却选了 HTTP 时提示切协议', () {
      final note = serverSheetNote(
        isUgreen: false,
        compat: true,
        ignoreSsl: true,
        secure: false,
        port: 9443,
      );
      expect(note, contains('只提供 HTTPS'));
    });

    test('任何组合都返回非空单行文本，提示槽高度才恒定', () {
      for (final ug in <bool>[true, false]) {
        for (final ssl in <bool>[true, false]) {
          for (final secure in <bool>[true, false]) {
            for (final port in <int>[9443, 8096]) {
              final note = serverSheetNote(
                isUgreen: ug,
                compat: ug || port == 9443,
                ignoreSsl: ssl,
                secure: secure,
                port: port,
              );
              expect(note.isNotEmpty, isTrue);
              expect(note.contains('\n'), isFalse);
            }
          }
        }
      }
    });
  });

  group('源码守卫：表单行数不随服务器类型变化', () {
    test('三段会撑高弹窗的条件文字已移除', () {
      final s = src('lib/pages/settings_page.dart');
      expect(s.contains('if (ugreen && !_ignoreSsl)'), isFalse);
      expect(s.contains('if (detectedPort == 9443 && !_secure)'), isFalse);
      expect(s.contains('if (ugreen)\n'), isFalse);
      // 旧的两行长文案不能留在 build 里
      expect(s.contains('该源不广播 Emby 发现包，请手动填地址；\n'), isFalse);
    });

    test('可变文案统一单行省略，底部提示槽固定高度', () {
      final s = src('lib/pages/settings_page.dart');
      // 标题说明 / SSL 说明 / 底部说明三处都是 maxLines: 1
      final single = 'maxLines: 1'.allMatches(s).length;
      expect(single, greaterThanOrEqualTo(3));
      expect(s.contains('String _sslNote()'), isTrue);
      expect(s.contains('height: 14'), isTrue);
      expect(s.contains('String serverSheetNote({'), isTrue);
      expect(s.contains('overflow: TextOverflow.ellipsis'), isTrue);
    });

    test('绿联下仍然保留「已自动勾选 / 中间人风险」等关键提示词', () {
      final s = src('lib/pages/settings_page.dart');
      expect(s.contains('已自动勾选'), isTrue);
      expect(s.contains('中间人风险'), isTrue);
      expect(s.contains("'HTTPS · 强制'"), isTrue);
    });
  });

  group('真实 widget：切换分段不改变弹窗高度', () {
    testWidgets('Emby → 绿联 → Jellyfin，底部弹层高度保持一致', (tester) async {
      // 给足高度，避免表单被屏幕上限钳制而掩盖差异
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());

      SharedPreferences.setMockInitialValues({});
      AppState.disablePersistence = true;
      final state = AppState();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SettingsPage(
              state: state,
              onTabChanged: (_) {},
              onOpenDetail: (item, {heroTag}) {},
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      await tester.tap(find.text('添加').first);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);

      double sheetHeight() => tester.getSize(find.byType(BottomSheet)).height;
      final embyH = sheetHeight();

      await tester.tap(find.text('绿联'));
      await tester.pumpAndSettle();
      final ugreenH = sheetHeight();

      await tester.tap(find.text('Jellyfin'));
      await tester.pumpAndSettle();
      final jellyfinH = sheetHeight();

      expect(
        ugreenH,
        embyH,
        reason: '切到绿联后弹窗高了 ${ugreenH - embyH}px，说明又有类型专属文字撑高',
      );
      expect(jellyfinH, embyH, reason: '切到 Jellyfin 后高度也应回到基准');
      expect(tester.takeException(), isNull);
    });
  });
}
