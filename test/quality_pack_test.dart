import 'dart:io';

import 'package:camby/theme.dart';
import 'package:camby/widgets/cached_image.dart';
import 'package:camby/widgets/empty_state.dart';
import 'package:camby/widgets/haptics.dart';
import 'package:camby/widgets/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.64 质感包守卫（图片过渡 / 触觉 / token 收敛 / 空态 CTA）。
///
/// 这类改动「编译过了、页面也开了」，但很容易在后续重构里被悄悄改回去：
/// 占位又变回 SizedBox.shrink()、fadeIn 又变回 0、开关又变回假开关。
/// 所以用源码守卫锁住关键结构，再用 widget 测试锁住可点行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String src(String path) => File(path).readAsStringSync();

  group('设计 token 收敛', () {
    test('卡片标题 11 / 元信息 10 / 圆角四档', () {
      expect(AppType.caption.fontSize, 11);
      expect(AppType.cardTitle.fontSize, 11);
      expect(AppType.posterTitle.fontSize, 11);
      expect(AppType.micro.fontSize, 10);
      expect(AppType.cardMeta.fontSize, 10);
      expect(AppRadii.sm, 6);
      expect(AppRadii.md, 12);
      expect(AppRadii.lg, 20);
      expect(AppRadii.pill, 999);
    });

    test('TextTheme 与 token 对齐，不再用 11.5 / 10.5 两档', () {
      final t = AppTheme.dark().textTheme;
      expect(t.bodySmall?.fontSize, 11);
      expect(t.labelSmall?.fontSize, 10);
      expect(t.titleLarge?.fontSize, 20);
      expect(t.titleMedium?.fontSize, 15.5);
    });

    test('动效时长按对比稿：180 / 120 / 1500 / 90', () {
      expect(AppMotion.imageFade, const Duration(milliseconds: 180));
      expect(AppMotion.crossFade, const Duration(milliseconds: 120));
      expect(AppMotion.shimmer, const Duration(milliseconds: 1500));
      expect(AppMotion.press, const Duration(milliseconds: 90));
    });

    test('海报卡片源码不再手写 11.5 的卡片标题', () {
      final poster = src('lib/widgets/media_poster.dart');
      expect(poster.contains('AppType.cardTitle'), isTrue);
      expect(poster.contains('AppType.posterTitle'), isTrue);
      expect(poster.contains('fontSize: 11.5'), isFalse);
    });
  });

  group('图片过渡', () {
    test('CachedImage：渐变骨架 + 180ms 淡入 + 缓存命中 0ms', () {
      final s = src('lib/widgets/cached_image.dart');
      expect(s.contains('AppMotion.imageFade'), isTrue);
      expect(s.contains('fadeInDuration: instant ? Duration.zero'), isTrue);
      expect(s.contains('fadeInCurve: Anim.curve'), isTrue);
      expect(s.contains('getFileFromCache(imageCacheKey(u))'), isTrue);
      expect(s.contains('placeholder: (_, __) => _placeholder()'), isTrue);
      // 占位与失败回退都必须是骨架，不能退回空白。
      expect(s.contains('SkeletonBox('), isTrue);
      expect(s.contains('SizedBox.shrink()'), isTrue); // 仅无 url 时
      expect(s.contains('placeholder: (_, __) => const SizedBox.shrink()'),
          isFalse);
    });

    test('失败保底带片名，404 不出现黑洞', () {
      final s = src('lib/widgets/media_poster.dart');
      expect(s.contains('fallbackLabel:'), isTrue);
    });

    test('imageCacheKey 去掉 api_key，换 token 仍命中同一份缓存', () {
      const a = 'http://h:8096/Items/1/Images/Primary?tag=abc&api_key=K1';
      const b = 'http://h:8096/Items/1/Images/Primary?api_key=K2&tag=abc';
      expect(imageCacheKey(a), imageCacheKey(b));
      expect(imageCacheKey(a).contains('api_key'), isFalse);
    });
  });

  group('骨架', () {
    test('纯渐变，不引入 BackdropFilter / 第三方 shimmer 依赖', () {
      final s = src('lib/widgets/skeleton.dart');
      // 只看真实构造调用，注释里提到这两个类名是设计说明，不算引入。
      expect(RegExp(r'BackdropFilter\s*\(').hasMatch(s), isFalse);
      expect(RegExp(r'ImageFiltered\s*\(').hasMatch(s), isFalse);
      expect(s.contains('RepaintBoundary'), isTrue);
      expect(s.contains('AnimationController'), isTrue);
      expect(s.contains('AppMotion.shimmer'), isTrue);
      final pub = src('pubspec.yaml');
      expect(RegExp(r'^\s*shimmer:', multiLine: true).hasMatch(pub), isFalse);
    });

    test('网格列数走断点而非硬编码', () {
      final s = src('lib/widgets/skeleton.dart');
      expect(s.contains('crossAxisCount: context.mediaGridColumns'), isTrue);
    });

    testWidgets('LibrarySkeleton 能渲染出海报形状的卡片', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 470,
              child: LibrarySkeleton(shimmer: false),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SkeletonCard), findsWidgets);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ShimmerScope 单控制器扫光不报错', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShimmerScope(
              child: SizedBox(
                height: 200,
                width: 300,
                child: SkeletonBox(),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });

  group('触感反馈', () {
    test('三档实现齐全，且读的是 set_haptics', () {
      final s = src('lib/widgets/haptics.dart');
      expect(s.contains("prefs.getBool('set_haptics')"), isTrue);
      expect(s.contains('HapticFeedback.selectionClick'), isTrue);
      expect(s.contains('HapticFeedback.mediumImpact'), isTrue);
      expect(s.contains('HapticFeedback.heavyImpact'), isTrue);
      expect(s.contains('if (!_enabled) return;'), isTrue);
    });

    test('设置页有触感开关，且不是假开关', () {
      final settings = src('lib/pages/settings_page.dart');
      expect(settings.contains("'haptics': prefs.getBool('set_haptics')"),
          isTrue);
      expect(settings.contains("title: '触感反馈'"), isTrue);
      expect(settings.contains('AppHaptics.setEnabled(value)'), isTrue);
      // settings_effect_test.dart 会再独立校验 lib/ 内的读取点。
    });

    test('主要状态变化点都接了对应档位', () {
      expect(src('lib/main.dart').contains('AppHaptics.light()'), isTrue);
      expect(
        src('lib/widgets/library_index_segment.dart')
            .contains('AppHaptics.light()'),
        isTrue,
      );
      expect(
        src('lib/widgets/sort_chip_row.dart').contains('AppHaptics.light()'),
        isTrue,
      );
      expect(src('lib/app_state.dart').contains('AppHaptics.medium()'), isTrue);
      expect(
        src('lib/pages/settings_page.dart').contains('AppHaptics.heavy()'),
        isTrue,
      );
    });

    test('开关立即生效，关闭后调用不抛异常', () async {
      SharedPreferences.setMockInitialValues({'set_haptics': false});
      await AppHaptics.load();
      expect(AppHaptics.enabled, isFalse);
      expect(() {
        AppHaptics.light();
        AppHaptics.medium();
        AppHaptics.heavy();
      }, returnsNormally);
      await AppHaptics.setEnabled(true);
      expect(AppHaptics.enabled, isTrue);
      expect(() => AppHaptics.light(), returnsNormally);
      // 恢复默认，避免影响本文件后续测试。
      SharedPreferences.setMockInitialValues({});
      await AppHaptics.load();
    });
  });

  group('空态 CTA', () {
    test('13 类空态都换成带真实动作的组件', () {
      final checks = <String, List<String>>{
        'lib/pages/series_index_page.dart': ['EmptyState(', '同步合集', '_syncBoxSets'],
        'lib/pages/actor_index_page.dart': ['EmptyState(', '清除搜索'],
        'lib/pages/favorites_page.dart': ['EmptyState(', 'onSwitchTab'],
        'lib/pages/folder_page.dart': ['EmptyState(', '去全部收藏'],
        'lib/pages/tag_page.dart': ['EmptyState(', '返回媒体库'],
        'lib/pages/search_page.dart': ['EmptyState(', '_clearSearch'],
        'lib/pages/person_page.dart': ['EmptyHint(', '联网重试'],
        'lib/pages/library_page.dart': ['EmptyState(', 'LibrarySkeleton('],
        'lib/pages/stats_page.dart': ['_statsEmpty(', '了解统计口径'],
        'lib/pages/subtitle_filter_page.dart': ['EmptyState(', '返回媒体库'],
        'lib/widgets/folder_sheet.dart': ['EmptyHint(', '新建收藏夹'],
      };
      for (final entry in checks.entries) {
        final s = src(entry.key);
        for (final needle in entry.value) {
          expect(
            s.contains(needle),
            isTrue,
            reason: '${entry.key} 缺少 $needle',
          );
        }
      }
    });

    testWidgets('EmptyState 主 / 次行动都可点，且不是摆设', (tester) async {
      var primary = 0;
      var secondary = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.movie_outlined,
              title: '还没有内容',
              reason: '说明为什么空',
              primaryLabel: '去同步',
              onPrimary: () => primary++,
              secondaryLabel: '了解来源',
              onSecondary: () => secondary++,
            ),
          ),
        ),
      );
      expect(find.text('还没有内容'), findsOneWidget);
      expect(find.text('说明为什么空'), findsOneWidget);
      await tester.tap(find.text('去同步'));
      await tester.pump();
      await tester.tap(find.text('了解来源'));
      await tester.pump();
      expect(primary, 1);
      expect(secondary, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('EmptyHint 的动作可点', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyHint(
              message: '暂无数据',
              actionLabel: '联网重试',
              onAction: () => tapped++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('联网重试'));
      await tester.pump();
      expect(tapped, 1);
    });
  });

  group('版本', () {
    test('pubspec 版本号为 v2.0.72', () {
      expect(src('pubspec.yaml').contains('version: 2.0.72+272'), isTrue);
    });
  });
}
