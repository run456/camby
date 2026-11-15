import 'package:camby/app_state.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:camby/theme.dart';
import 'package:camby/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.98 浅色玻璃主题：外观状态的持久化与推导。
void main() {
  final tc = ThemeController.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tc.debugReset();
    AppColors.apply(dark: true);
  });

  tearDown(() {
    tc.debugReset();
    AppColors.apply(dark: true);
  });

  test('默认深色：老用户升级后不该突然变白', () {
    expect(tc.mode, ThemeMode.dark);
    expect(tc.isDark, isTrue);
    expect(tc.followsSystem, isFalse);
  });

  test('setDark 切换并持久化', () async {
    await tc.setDark(false);
    expect(tc.isDark, isFalse);
    expect(tc.followsSystem, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');

    await tc.setDark(true);
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('跟随系统：系统亮暗驱动 isDark', () async {
    await tc.setMode(ThemeMode.system);
    expect(tc.followsSystem, isTrue);

    tc.setPlatformDark(true);
    expect(tc.isDark, isTrue);

    tc.setPlatformDark(false);
    expect(tc.isDark, isFalse);
  });

  test('固定模式时系统亮度变化不影响结果', () async {
    await tc.setMode(ThemeMode.dark);
    tc.setPlatformDark(false);
    expect(tc.isDark, isTrue, reason: '用户明确选了深色，系统切浅色也不该跟着变');
  });

  test('load 会还原上次选择', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'theme_mode': 'light',
    });
    tc.debugReset(mode: ThemeMode.dark);
    await tc.load();
    expect(tc.mode, ThemeMode.light);
    expect(tc.isDark, isFalse);
  });

  test('load 遇到脏数据不崩，回落到深色', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'theme_mode': 'purple',
    });
    tc.debugReset(mode: ThemeMode.dark);
    await tc.load();
    expect(tc.mode, ThemeMode.dark);
  });

  test('跟随系统时拨「深色模式」= 固化当前亮度', () async {
    tc.debugReset(mode: ThemeMode.system, platformDark: false);
    await tc.setDark(tc.isDark);
    expect(tc.followsSystem, isFalse);
    expect(tc.mode, ThemeMode.light);
  });

  test('两套调色板必须是两套：浅色下关键 token 与深色不同', () {
    const d = AppColors.darkPalette;
    const l = AppColors.lightPalette;

    expect(d.isDark, isTrue);
    expect(l.isDark, isFalse);
    for (final pair in <List<Object>>[
      [d.bg, l.bg],
      [d.ink, l.ink],
      [d.muted, l.muted],
      [d.glassBase, l.glassBase],
    ]) {
      expect(pair[0], isNot(pair[1]), reason: '深浅两套不能是同一个颜色');
    }
    // 叠加层是「深色提亮 / 浅色压暗」的分水岭
    expect(d.w, Colors.white);
    expect(l.w, Colors.black);
  });

  test('AppColors.apply 会改到门面读到的值', () {
    AppColors.apply(dark: false);
    expect(AppColors.isDark, isFalse);
    expect(AppColors.bg, AppColors.lightPalette.bg);
    expect(AppColors.ink, AppColors.lightPalette.ink);

    AppColors.apply(dark: true);
    expect(AppColors.bg, AppColors.darkPalette.bg);
  });

  test('ThemeData 的亮度与调色板一致', () {
    AppColors.apply(dark: false);
    final light = AppTheme.build(dark: false);
    expect(light.brightness, Brightness.light);
    expect(light.scaffoldBackgroundColor, AppColors.lightPalette.bg);
    expect(light.colorScheme.onSurface, AppColors.lightPalette.ink);

    AppColors.apply(dark: true);
    final dark = AppTheme.build(dark: true);
    expect(dark.brightness, Brightness.dark);
    expect(dark.scaffoldBackgroundColor, AppColors.darkPalette.bg);
  });

  testWidgets('设置页：深色开关能真的切到浅色', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(dark: true),
        home: SettingsPage(
          state: AppState(),
          onTabChanged: (_) {},
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final darkSwitch = find.byKey(const ValueKey('theme-dark-toggle'));
    expect(darkSwitch, findsOneWidget, reason: '设置页必须有「深色模式」开关');
    expect(find.byKey(const ValueKey('theme-system-toggle')), findsOneWidget);

    expect(ThemeController.instance.isDark, isTrue);
    await tester.tap(darkSwitch);
    await tester.pumpAndSettle();
    expect(ThemeController.instance.isDark, isFalse, reason: '拨开关必须真的切到浅色');
  });
}
