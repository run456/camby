import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v1.7.62：两个播放器手势修复的守卫测试。
///
/// 1. 拖动进度条时中央大时间气泡必须订阅 _posNv（否则整页不 setState，
///    气泡冻结在起拖附近的旧时间，底部小字却是实时值）。
/// 2. 亮度/音量指示条必须显示在手势对侧：左半屏调亮度 → 指示条在右，
///    右半屏调音量 → 指示条在左（避免被手指挡住）。
void main() {
  final src = File('lib/pages/player_page.dart').readAsStringSync();

  // 对原文切片再过滤注释，避免锚点出现在注释里被误匹配
  String section(String startAnchor, String endAnchor) {
    final i = src.indexOf(startAnchor);
    expect(i, greaterThanOrEqualTo(0), reason: '找不到锚点: $startAnchor');
    final j = src.indexOf(endAnchor, i + startAnchor.length);
    expect(j, greaterThanOrEqualTo(0), reason: '找不到结束锚点: $endAnchor');
    final raw = src.substring(i, j);
    final buf = StringBuffer();
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.startsWith('//')) continue;
      buf.writeln(line.replaceAll('//.*', ''));
    }
    return buf.toString();
  }

  test('中央拖动时间气泡订阅 _posNv，不再直接读 _scrubPos', () {
    final block = section(
      '拖动进度时的大时间提示',
      '外挂字幕叠加层',
    );
    expect(block.contains('ValueListenableBuilder'), isTrue,
        reason: '气泡必须用 ValueListenableBuilder 订阅 _posNv 才能实时刷新');
    expect(block.contains('_posNv'), isTrue);
    // 气泡文本应使用监听值 pos，而不是会冻结的 _scrubPos
    expect(block.contains('_fmt(_scrubPos)'), isFalse,
        reason: '_fmt(_scrubPos) 只在整页 setState 时重建，会冻结');
  });

  test('亮度/音量指示条显示在手势对侧', () {
    final block = section(
      '亮度 / 音量指示',
      '外挂字幕叠加层',
    );
    expect(block.contains("left: _adjustSide == 'volume' ? 48 : null"), isTrue,
        reason: '右半屏调音量 → 指示条显示在左侧（v1.7.64 起离边 48dp）');
    expect(block.contains("right: _adjustSide == 'brightness' ? 48 : null"),
        isTrue, reason: '左半屏调亮度 → 指示条显示在右侧（v1.7.64 起离边 48dp）');
    // 旧的同侧写法必须移除
    expect(block.contains("left: _adjustSide == 'brightness'"), isFalse);
    expect(block.contains("right: _adjustSide == 'volume'"), isFalse);
  });
}
