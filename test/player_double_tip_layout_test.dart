import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v2.0.3：双击 ±10 秒提示的布局统一 ——
///   · +10 秒贴在快进按钮**右侧**、-10 秒贴在快退按钮**左侧**，
///     都与对应按钮**同一水平线**（不再堆在按钮组正上方）。
///   · 与按钮的间距 == 快进↔播放 / 快退↔播放 的间隔（26dp）。
void main() {
  final player = File('lib/pages/player_page.dart').readAsStringSync();

  String tipBlock() {
    final i = player.indexOf('双击 ±10 秒提示');
    expect(i, greaterThanOrEqualTo(0), reason: '找不到双击提示块');
    return player.substring(i, player.indexOf('亮度 / 音量指示', i));
  }

  test('提示贴在对应按钮旁、同一水平线（dx=±181, 无纵向 dy）', () {
    final block = tipBlock();
    // v2.0.3 改为水平贴边，不应再有「整体上移」的纵向位移
    expect(block.contains('dy'), isFalse,
        reason: 'v2.0.3 改为水平贴边，不应再有纵向 dy 位移');
    // -10 秒（快退，左侧）用负位移、+10 秒（快进，右侧）用正位移
    expect(block.contains('-181.0'), isTrue,
        reason: '-10秒 应在快退钮左侧（负位移）');
    expect(block.contains('181.0'), isTrue,
        reason: '+10秒 应在快进钮右侧（正位移）');
  });

  test('与按钮间距 == 快进↔播放 间隔(26dp)，气泡固定宽 92 以便位移对齐', () {
    final block = tipBlock();
    // 几何：快进钮右缘 109 + 间隔 26 → 气泡左缘 135，半宽 46 → 中心 181
    expect(block.contains('width: 92'), isTrue,
        reason: '气泡需固定宽，位移才能精确对应 26dp 间距');
    // 间距常量被显式声明为 26，与 _centerControls 的 SizedBox(width:26) 一致
    expect(block.contains('间距 = 快进↔播放 的 26dp'), isTrue);
    expect(block.contains('间距 = 快退↔播放 的 26dp'), isTrue);
  });

  test('会话上报保留在生命周期钩子里（杀 App 前补发 Stopped）', () {
    expect(player.contains('WidgetsBindingObserver'), isTrue);
    expect(player.contains('addObserver(this)'), isTrue);
    expect(player.contains('removeObserver(this)'), isTrue,
        reason: '必须配对移除，否则 State 泄漏');
    expect(player.contains('didChangeAppLifecycleState'), isTrue);
  });
}
