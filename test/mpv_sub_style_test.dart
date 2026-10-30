// v1.7.57 守卫：MPV 字幕样式下发修复。
//
// 背景：旧实现把不透明度下发到 `sub-opacity` —— 该属性在 mpv 中根本
// 不存在（0.36/0.37 实测 option not found），而 media_kit 的 setProperty
// 吞掉错误码从不抛异常，导致失败被 try/catch 静默掩盖，「面板调了没反应」。
// 修复后：不透明度烤进颜色 alpha（#AARRGGBB），描边属性带旧名回退。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback.dart: 不再下发不存在的 sub-opacity，透明度走颜色 alpha', () {
    final src = File('lib/player/playback.dart').readAsStringSync();
    // 有效代码行（去注释）
    final code = src
        .split('\n')
        .where((l) => !l.trim().startsWith('//'))
        .join('\n');

    expect(
      code.contains("'sub-opacity'"),
      isFalse,
      reason: 'mpv 没有 sub-opacity 属性，下发必然静默失败',
    );
    expect(
      code.contains('sub-ass-override'),
      isTrue,
      reason: 'force 覆盖必须保留，否则 ASS 字幕忽略 App 样式',
    );

    // 不透明度必须合成进颜色 alpha（_mpvColorWithAlpha：8 位 hex）
    expect(code.contains('_mpvColorWithAlpha'), isTrue);
    expect(
      code.contains("padLeft(8, '0')"),
      isTrue,
      reason: 'alpha 颜色串必须是 #AARRGGBB 8 位十六进制',
    );

    // 描边属性需要旧名回退（老 libmpv 用 sub-outline-*）
    expect(code.contains("'sub-border-size'"), isTrue);
    expect(code.contains("'sub-outline-size'"), isTrue);
    expect(code.contains('setWithFallback'), isTrue);
  });
}
