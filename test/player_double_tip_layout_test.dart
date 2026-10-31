import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v2.0.2：播放页快速连按快进时，「+10秒」提示气泡与中央按钮组重叠。
///
/// 旧布局把提示放在与按钮**同一条水平线上**（距屏幕中心 148dp），窄横屏
/// （如 1092×525）上恰好压在快进按钮上，出现气泡压住按钮的错位观感。
/// 现在改为按钮组正上方、按屏宽自适应上移量。
void main() {
  final player = File('lib/pages/player_page.dart').readAsStringSync();

  test('双击提示改为垂直上移，不再与按钮同一水平线', () {
    final i = player.indexOf('双击快进提示');
    expect(i, greaterThanOrEqualTo(0), reason: '找不到双击提示块');
    final block = player.substring(i, player.indexOf('亮度 / 音量指示', i));
    // 必须有纵向位移
    expect(block.contains('dy'), isTrue, reason: '提示气泡必须整体上移');
    // 旧实现用的是「距中心 148dp」的水平排布
    expect(block.contains('clamp(0.0, 148.0)'), isFalse,
        reason: '148dp 水平排布会压住快进按钮，必须移除');
  });

  test('上移量够高：窄屏 ≥ 44dp、常规 ≥ 58dp（按钮半高 33 + 气泡半高 ~20）', () {
    final i = player.indexOf('双击快进提示');
    final block = player.substring(i, player.indexOf('亮度 / 音量指示', i));
    final narrow = RegExp(r'w < 480 \? (\d+\.?\d*)').firstMatch(block);
    final normal = RegExp(r': (\d+\.?\d*)\)').firstMatch(block);
    expect(narrow, isNotNull, reason: '缺少窄屏上移量');
    expect(normal, isNotNull, reason: '缺少常规上移量');
    expect(double.parse(narrow!.group(1)!), greaterThanOrEqualTo(44));
    expect(double.parse(normal!.group(1)!), greaterThanOrEqualTo(58));
  });

  test('会话上报保留在生命周期钩子里（杀 App 前补发 Stopped）', () {
    expect(player.contains('WidgetsBindingObserver'), isTrue);
    expect(player.contains('addObserver(this)'), isTrue);
    expect(player.contains('removeObserver(this)'), isTrue,
        reason: '必须配对移除，否则 State 泄漏');
    expect(player.contains('didChangeAppLifecycleState'), isTrue);
  });
}
