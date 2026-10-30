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

  test('v1.7.61：叠加层不再画背景块，回到纯文字', () {
    // 只取「外挂字幕叠加层 → 控制层」之间那一段
    // （后面的控制层渐变遮罩也用 BoxDecoration，属正常）
    // 先在**原文**上切片（锚点文字本身位于注释行，过滤后就找不到了），
    // 再对该片段去掉注释行
    var seg = File('lib/pages/player_page.dart')
        .readAsStringSync()
        .split('外挂字幕叠加层')
        .last;
    if (seg.contains('ignoring: !_controlsVisible')) {
      seg = seg.split('ignoring: !_controlsVisible').first;
    }
    final overlay =
        seg.split('\n').where((l) => !l.trim().startsWith('//')).join('\n');
    expect(
      overlay.contains('BoxDecoration'),
      isFalse,
      reason: '用户要求取消字幕后面的黑色背景块',
    );
    expect(overlay.contains('255 * 0.55'), isFalse);
    // 文字仍居中 + 限宽（长句自动换行，不顶出屏幕）
    expect(overlay.contains('Alignment.bottomCenter'), isTrue);
    expect(overlay.contains('ConstrainedBox'), isTrue);
  });
}
