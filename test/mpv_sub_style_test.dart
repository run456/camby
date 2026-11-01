// v2.0.17 守卫：MPV 字幕样式下发为「固定影院风格」（白字加粗 + 黑描边）。
//
// 背景：v1.7.57 修过一次把不透明度下发到 mpv 不存在的 `sub-opacity` 导致静默
// 失败；v2.0.17 起样式不再可调颜色/描边，改为固定下发 + 新增 `sub-bold`。
// 本测试守住关键不变量，避免回归把样式重新写散。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback.dart: MPV 字幕样式固定为白字加粗 + 黑描边', () {
    final src = File('lib/player/playback.dart').readAsStringSync();
    // 有效代码行（去注释），避免注释里的描述误命中
    final code = src
        .split('\n')
        .where((l) => !l.trim().startsWith('//'))
        .join('\n');

    // 1. mpv 没有 sub-opacity 属性，下发必然静默失败，绝不能出现
    expect(
      code.contains("'sub-opacity'"),
      isFalse,
      reason: 'mpv 没有 sub-opacity 属性，下发必然静默失败',
    );

    // 2. 不透明度不再合成进 alpha（样式固定不透明，_mpvColorWithAlpha 已删除）
    expect(
      code.contains('_mpvColorWithAlpha'),
      isFalse,
      reason: 'v2.0.17 起样式固定，不再需要颜色 alpha 合成',
    );

    // 3. ASS 字幕必须 force 覆盖，否则忽略 App 样式
    expect(
      code.contains('sub-ass-override'),
      isTrue,
      reason: 'force 覆盖必须保留，否则 ASS 字幕忽略 App 样式',
    );

    // 4. 影院风格固定值：白字 + 黑描边 + 加粗
    expect(code.contains("'sub-color'"), isTrue);
    expect(code.contains("'#FFFFFFFF'"), isTrue, reason: '文字固定不透明白');
    expect(code.contains("'sub-border-color'"), isTrue);
    expect(code.contains("'#FF000000'"), isTrue, reason: '描边固定黑');
    expect(code.contains("'sub-bold'"), isTrue, reason: '系统黑体加粗');
    expect(code.contains("'yes'"), isTrue, reason: 'sub-bold = yes');

    // 5. 描边属性需要旧名回退（老 libmpv 用 sub-outline-*）
    expect(code.contains("'sub-border-size'"), isTrue);
    expect(code.contains("'sub-outline-size'"), isTrue);
    expect(code.contains('setWithFallback'), isTrue);

    // 6. 仿宋字体：内置 ttf 通过 sub-fonts-dir 暴露给 mpv，family 名 FangSong
    expect(code.contains("'sub-fonts-dir'"), isTrue, reason: 'mpv 需字体目录才能按 family 名匹配');
    expect(code.contains("'FangSong'"), isTrue, reason: '内置仿宋 family 名');
    expect(code.contains('_ensureFangSongFont'), isTrue, reason: '启动需抽取内置字体文件');
  });
}
