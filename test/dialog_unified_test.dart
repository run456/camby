import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/theme.dart';
import 'package:camby/widgets/glass_sheet.dart';

/// v2.0.82：全站居中弹窗统一到「选择字幕」那套 AppSheet，
/// 动作文字统一蓝色。这里同时锁住外观和「各页面不再自建 Dialog+Glass」。
void main() {
  group('v2.0.82 统一弹窗', () {
    testWidgets('标题 / 正文 / 蓝字动作 / 圆形关闭 / 返回值', (tester) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                host = ctx;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final result = showAppDialog<bool>(
        context: host,
        title: '统一标题',
        message: '统一正文',
        actions: const [
          AppDialogAction(label: '取消', value: false),
          AppDialogAction(label: '确定', value: true),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('统一标题'), findsOneWidget);
      expect(find.text('统一正文'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(find.byType(GlassPanel), findsOneWidget);
      expect(
        find.byType(BackdropFilter),
        findsOneWidget,
        reason: '与「选择字幕」同款：面板做真实背景磨砂',
      );

      final title = tester.widget<Text>(find.text('统一标题'));
      expect(title.style?.color, Colors.white);
      expect(title.style?.fontWeight, FontWeight.w800);

      final body = tester.widget<Text>(find.text('统一正文'));
      expect(body.style?.color, const Color(0xFF9FB0CC), reason: '正文用字幕面板同款蓝灰');

      for (final label in const ['取消', '确定']) {
        final t = tester.widget<Text>(find.text(label));
        expect(t.style?.color, AppColors.accent, reason: '$label 必须是统一蓝字');
      }

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('圆形关闭按钮返回 null，自定义 onTap 可接管', (tester) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                host = ctx;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final first = showAppDialog<String>(
        context: host,
        title: '关闭测试',
        message: '点 X',
        actions: const [AppDialogAction(label: '知道了')],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(await first, isNull);

      var tapped = 0;
      final second = showAppDialog<String>(
        context: host,
        title: '自定义动作',
        message: '点复制',
        actions: [
          AppDialogAction<String>(
            label: '复制',
            onTap: (ctx) {
              tapped++;
              Navigator.of(ctx).pop('copied');
            },
          ),
        ],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
      expect(await second, 'copied');
      expect(tester.takeException(), isNull);
    });

    test('源码守卫：各页面不再自建 Dialog + Glass，标准面板走 AppSheet', () {
      const pages = [
        'lib/pages/detail_page.dart',
        'lib/pages/series_index_page.dart',
        'lib/pages/settings_page.dart',
        'lib/pages/stats_page.dart',
        'lib/widgets/folder_sheet.dart',
      ];
      for (final f in pages) {
        final src = File(f).readAsStringSync();
        expect(
          src.contains('builder: (ctx) => Dialog('),
          isFalse,
          reason: '$f 仍有私有卡片弹窗，应改走 showAppDialog',
        );
        expect(
          src.contains('blur: 30'),
          isFalse,
          reason: '$f 仍有旧的 Glass(blur:30) 诊断弹窗',
        );
      }

      final glass = File('lib/widgets/glass_sheet.dart').readAsStringSync();
      expect(glass.contains('class AppSheet'), isTrue);
      expect(glass.contains('Future<T?> showAppDialog<T>'), isTrue);
      final actionPart = glass.substring(
        glass.indexOf('class AppDialogAction'),
      );
      expect(
        actionPart.contains('color: AppColors.accent'),
        isTrue,
        reason: '动作文字必须统一蓝色',
      );
      expect(actionPart.contains('AppColors.cyan'), isFalse);
      expect(actionPart.contains('AppColors.danger'), isFalse);

      final player = File('lib/pages/player_page.dart').readAsStringSync();
      expect(
        player.contains('class _Sheet '),
        isFalse,
        reason: '私有 _Sheet 应已上提为公共 AppSheet',
      );
      expect(player.contains('AppSheet('), isTrue);
      expect(player.contains("title: '选择字幕'"), isTrue, reason: '标准弹窗仍然保留');

      // 统计页的青绿只用于数据卡片，弹窗动作里不能再出现
      final stats = File('lib/pages/stats_page.dart').readAsStringSync();
      final fnStart = stats.indexOf('void _showExplainDialog');
      // 只截函数体：文件后面统计卡片仍合法使用青绿色，不能算进守卫
      final explain = stats.substring(fnStart, stats.indexOf('\n}\n', fnStart));
      expect(
        explain.contains('AppColors.cyan'),
        isFalse,
        reason: '「知道了」不能再是青绿色',
      );
      expect(explain.contains('showAppDialog'), isTrue);
    });
  });
}
