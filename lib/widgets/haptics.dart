library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 触感反馈（v2.0.64 质感包）
///
/// 三档约定（见《质感包前后对比稿》04）：
///  · [light]  selectionClick：切 Tab / 分段、排序与筛选 chip、海报卡片按下
///  · [medium] mediumImpact：收藏切换、长按菜单、播放页锁定 / 解锁
///  · [heavy]  heavyImpact：删除确认、清空缓存、断开服务器等破坏性操作
///
/// 绝不用于：图片淡入、骨架扫光、列表滚动、播放进度更新、toast 弹出 ——
/// 只在**有状态变化**的时刻给一次。
///
/// 开关默认开，写入 `set_haptics`；系统层面是否真的震动由平台决定
/// （Android 会遵循系统触感设置）。所有调用都做了静默兜底：桌面宿主、
/// 单元测试环境没有 vibrator 通道时不能影响业务。
class AppHaptics {
  const AppHaptics._();

  static bool _enabled = true;

  static bool get enabled => _enabled;

  /// 在 main() 的启动补丁里调用一次，把持久化的开关读进内存。
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool('set_haptics') ?? true;
    } catch (_) {
      _enabled = true;
    }
  }

  /// 设置页切换时调用：立即生效 + 持久化。
  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('set_haptics', value);
    } catch (_) {
      // 持久化失败不该让开关点不动，内存值已经生效。
    }
  }

  static void light() => _fire(HapticFeedback.selectionClick);
  static void medium() => _fire(HapticFeedback.mediumImpact);
  static void heavy() => _fire(HapticFeedback.heavyImpact);

  static void _fire(Future<void> Function() body) {
    if (!_enabled) return;
    try {
      unawaited(body().onError((Object? _, StackTrace __) {}));
    } catch (_) {
      // 无 vibrator 的平台 / 测试宿主：静默忽略。
    }
  }
}
