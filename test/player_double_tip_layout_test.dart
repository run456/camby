import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:camby/layout.dart';

/// v2.0.3：双击 ±10 秒提示的布局统一 ——
///   · +10 秒贴在快进按钮**右侧**、-10 秒贴在快退按钮**左侧**，
///     都与对应按钮**同一水平线**（不再堆在按钮组正上方）。
///   · 与按钮的间距 == 快进↔播放 / 快退↔播放 的间隔（手机 26dp、平板 44dp）。
///
/// v2.0.8：尺寸改由 [PlayerUi] 度量驱动，测试从「写死 181/92」升级为
/// 「源码走度量 + 度量公式本身正确」双保险。
void main() {
  final player = File('lib/pages/player_page.dart').readAsStringSync();

  String tipBlock() {
    final i = player.indexOf('双击 ±10 秒提示');
    expect(i, greaterThanOrEqualTo(0), reason: '找不到双击提示块');
    return player.substring(i, player.indexOf('亮度 / 音量指示', i));
  }

  test('提示贴在对应按钮旁、同一水平线（无纵向 dy）', () {
    final block = tipBlock();
    // v2.0.3 改为水平贴边，不应再有「整体上移」的纵向位移
    expect(block.contains('dy'), isFalse,
        reason: 'v2.0.3 改为水平贴边，不应再有纵向 dy 位移');
    // v2.0.8：位移量不再写死，改走 PlayerUi 度量
    expect(block.contains('ui.tipOffset'), isTrue,
        reason: '位移必须由 PlayerUi.tipOffset 提供，平/板手机各一套');
    // -10 秒（快退，左侧）用负位移、+10 秒（快进，右侧）用正位移
    expect(block.contains('-ui.tipOffset'), isTrue,
        reason: '-10秒 应在快退钮左侧（负位移）');
    expect(block.contains(': ui.tipOffset'), isTrue,
        reason: '+10秒 应在快进钮右侧（正位移）');
    // 气泡宽度同样度量驱动，否则位移对不上
    expect(block.contains('width: ui.tipW'), isTrue,
        reason: '气泡宽需与位移同源，平板 112 / 手机 92');
  });

  test('tipOffset 公式 = 播放钮半宽+间隔+快进退钮整宽+间隔+气泡半宽', () {
    for (final ui in <PlayerUi>[PlayerUi.phone(), PlayerUi.tablet()]) {
      final expectOffset =
          ui.playBtn / 2 + ui.clusterGap + ui.sideBtn + ui.clusterGap + ui.tipW / 2;
      expect(ui.tipOffset, closeTo(expectOffset, 0.001),
          reason: '${ui.tablet ? "平板" : "手机"} tipOffset 公式不符');
    }
    // v2.0.3 定稿的手机数值必须保持 181（回归保护）
    expect(PlayerUi.phone().tipOffset, closeTo(181.0, 0.001));
    // 平板按设计稿放大后为 242
    expect(PlayerUi.tablet().tipOffset, closeTo(242.0, 0.001));
  });

  test('气泡不会压住快进/快退按钮（左缘 >= 按钮右缘）', () {
    for (final ui in <PlayerUi>[PlayerUi.phone(), PlayerUi.tablet()]) {
      final btnRightEdge = ui.playBtn / 2 + ui.clusterGap + ui.sideBtn;
      final tipLeftEdge = ui.tipOffset - ui.tipW / 2;
      expect(tipLeftEdge, greaterThanOrEqualTo(btnRightEdge),
          reason: '${ui.tablet ? "平板" : "手机"} 气泡压在快进钮上');
      // 且间距正好是一个 clusterGap
      expect(tipLeftEdge - btnRightEdge, closeTo(ui.clusterGap, 0.001));
    }
  });

  test('会话上报保留在生命周期钩子里（杀 App 前补发 Stopped）', () {
    expect(player.contains('WidgetsBindingObserver'), isTrue);
    expect(player.contains('addObserver(this)'), isTrue);
    expect(player.contains('removeObserver(this)'), isTrue,
        reason: '必须配对移除，否则 State 泄漏');
    expect(player.contains('didChangeAppLifecycleState'), isTrue);
  });
}
