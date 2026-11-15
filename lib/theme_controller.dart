import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外观（深色 / 浅色 / 跟随系统）的单一真源（v2.0.98）。
///
/// 为什么不塞进 [AppState]：主题要在 `MaterialApp` **之上**决定，
/// 而 AppState 是 `AppShell`（MaterialApp 的 home）里创建的 —— 放进去就
/// 得把整棵树倒过来。这里用独立单例，App 根与设置页都能直接读。
///
/// 持久化 key `theme_mode`，取值 `light` / `dark` / `system`。
/// **默认 dark**：App 从 v1.x 起一直是深色，老用户升级后不该突然变白。
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const String _prefsKey = 'theme_mode';

  ThemeMode _mode = ThemeMode.dark;

  /// 用户的选择（可能是「跟随系统」）。
  ThemeMode get mode => _mode;

  /// 系统当前是否为深色。由根 widget 的 `didChangePlatformBrightness` 维护。
  bool _platformDark = true;
  bool get platformDark => _platformDark;

  /// 只读：是否跟随系统。
  bool get followsSystem => _mode == ThemeMode.system;

  /// 最终生效的亮度 —— 全 App 唯一的答案。
  bool get isDark =>
      _mode == ThemeMode.dark ||
      (_mode == ThemeMode.system && _platformDark);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final parsed = switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => null,
      };
      if (parsed != null && parsed != _mode) {
        _mode = parsed;
        notifyListeners();
      }
    } catch (_) {
      // 读不到就按默认深色走，不影响启动。
    }
  }

  Future<void> setMode(ThemeMode next) async {
    if (_mode == next) return;
    _mode = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, next.name);
    } catch (_) {
      // 写失败只影响下次启动的记忆，本次切换照常生效。
    }
  }

  /// 设置页的「深色模式」开关。
  ///
  /// 跟随系统时拨开关 = 把当前亮度**固化**下来（关掉跟随），这符合用户
  /// 拨开关时的心理预期：我拨了，它就得停在我拨到的位置。
  Future<void> setDark(bool dark) =>
      setMode(dark ? ThemeMode.dark : ThemeMode.light);

  void setPlatformDark(bool value) {
    if (_platformDark == value) return;
    _platformDark = value;
    // 只在「跟随系统」时才需要刷新界面。
    if (_mode == ThemeMode.system) notifyListeners();
  }

  /// 仅供测试重置。
  @visibleForTesting
  void debugReset({ThemeMode mode = ThemeMode.dark, bool platformDark = true}) {
    _mode = mode;
    _platformDark = platformDark;
  }
}
