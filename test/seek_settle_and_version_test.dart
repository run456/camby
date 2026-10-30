// v1.7.60 守卫：
// 1) 拖动松手不应露出「回弹到起点」的中间帧（scrubbing/seeking 同帧切换 + 粘滞显示）
// 2) 设置页版本号运行时读取，不得再硬编码
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _code(String path) => _read(path)
    .split('\n')
    .where((l) => !l.trim().startsWith('//'))
    .join('\n');

void main() {
  final player = _code('lib/pages/player_page.dart');

  test('_endScrub 在同一次 setState 里关 scrubbing、开 seeking', () {
    // 分开写会露出「既不拖动也还没跳转」的一帧，显示回落到真实位置
    expect(
      RegExp(
        r'setState\(\(\)\s*\{\s*_scrubbing\s*=\s*false;\s*_seeking\s*=\s*true;',
      ).hasMatch(player),
      isTrue,
      reason: 'scrubbing→seeking 必须同帧切换',
    );
  });

  test('跳转完成后有粘滞显示，等真实位置追上', () {
    expect(player.contains('_settlePos'), isTrue);
    expect(player.contains('_settleUntil'), isTrue);
    expect(player.contains('_settleActive'), isTrue);
    expect(player.contains('_waitSettleOut'), isTrue);
    expect(
      player.contains('_settleActive ? _settlePos! : _positionSeconds'),
      isTrue,
      reason: '_syncPos 必须在跳转后优先用目标位置',
    );
  });

  test('设置页版本号运行时读取，不再硬编码', () {
    final settings = _code('lib/pages/settings_page.dart');
    expect(
      RegExp(r'Camby v1\.\d+\.\d+').hasMatch(settings),
      isFalse,
      reason: '版本号硬编码会随发版过期',
    );
    expect(settings.contains('PackageInfo.fromPlatform'), isTrue);
    expect(settings.contains('_VersionLine'), isTrue);
  });
}
