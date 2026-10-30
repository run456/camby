// v1.7.58 守卫：文本字幕（SRT/VTT）统一走 App 叠加层 + 半透明背景块。
//
// 背景：MPV 对文本字幕无法指定 BorderStyle（0.36/0.37 都没有
// sub-border-style，sub-ass-style-overrides 实测对 SRT 无效），样式面板
// 的项也不保证生效。因此除 ASS/SSA 外一律交给叠加层渲染，两个内核外观
// 统一为「白字 + 半透明黑底圆角块」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/pages/player_page.dart').readAsStringSync();
  final code = src
      .split('\n')
      .where((l) => !l.trim().startsWith('//'))
      .join('\n');

  test('MPV 只接管 ASS/SSA，其余字幕走叠加层', () {
    expect(code.contains('_isAssUrl'), isTrue);
    // open 时按类型决定是否把 subtitleUrl 交给内核
    expect(
      code.contains('subtitleUrl: (p.nativeSubtitles && _isAssUrl('),
      isTrue,
      reason: 'open 不能再无条件把字幕交给 MPV',
    );
    // 非 ASS 一律加载叠加层 cue
    expect(
      code.contains('!(p.nativeSubtitles && _isAssUrl(sub.url))'),
      isTrue,
    );
  });

  test('切换到文本字幕时先摘掉内核字幕，避免两份字幕重叠', () {
    expect(code.contains('final useNative ='), isTrue);
    expect(
      code.contains("await _player?.setSubtitle(null)"),
      isTrue,
      reason: 'MPV 换 SRT 时必须先关掉内核字幕',
    );
  });

  test('切内核不再无条件清空叠加层（否则 MPV 下 SRT 变空白）', () {
    expect(
      code.contains('if (ok && target == PlaybackEngine.mpv && mounted)'),
      isFalse,
      reason: '旧的无条件清 cues 会误伤 MPV 下的文本字幕',
    );
  });

  test('叠加层渲染半透明背景块', () {
    expect(code.contains('borderRadius: BorderRadius.circular(7)'), isTrue);
    expect(
      code.contains('255 * 0.55'),
      isTrue,
      reason: '背景块为 55% 不透明黑底，并跟随字幕不透明度',
    );
  });
}
