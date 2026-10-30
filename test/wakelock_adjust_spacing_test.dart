import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v1.7.64：三项修复守卫。
/// 1. 播放页屏幕常亮（WakelockPlus），播放中不黑屏
/// 2. 亮度/音量指示条加高、离屏幕边缘更远
/// 3. 收藏页标题区与封面间距收紧
void main() {
  final player = File('lib/pages/player_page.dart').readAsStringSync();
  final fav = File('lib/pages/favorites_page.dart').readAsStringSync();

  test('播放页接入 WakelockPlus：ticker 翻转触发 + dispose 解除', () {
    expect(player.contains("import 'package:wakelock_plus/wakelock_plus.dart'"),
        isTrue, reason: '缺少 wakelock_plus 导入');
    expect(player.contains('WakelockPlus.toggle(enable: shouldStayOn)'),
        isTrue, reason: '必须按状态翻转触发，不能每帧都调');
    expect(player.contains('_wakelockOn'), isTrue);
    expect(player.contains('WakelockPlus.disable()'), isTrue,
        reason: '退出播放页必须解除常亮');
  });

  test('亮度/音量指示条：进度条 ≥ 150、离边 ≥ 48dp', () {
    final i = player.indexOf('亮度 / 音量指示');
    expect(i, greaterThanOrEqualTo(0));
    final block = player.substring(i, player.indexOf('外挂字幕叠加层', i));
    expect(block.contains('height: 150'), isTrue, reason: '进度条 88 太矮');
    expect(block.contains('height: 88'), isFalse, reason: '旧的矮进度条还在');
    expect(block.contains('? 48 : null'), isTrue, reason: '离边 22dp 太贴边');
  });

  test('收藏页标题区与封面收紧（网格顶留白 ≤ 6）', () {
    expect(fav.contains('EdgeInsets.fromLTRB(18, 6, 18, 112)'), isTrue,
        reason: '影片/演员网格顶部留白应收至 6');
    expect(fav.contains('EdgeInsets.fromLTRB(18, 16, 18, 112)'), isFalse);
    expect(fav.contains('EdgeInsets.fromLTRB(18, 18, 18, 112)'), isFalse);
  });
}
