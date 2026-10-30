import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 播放页「读设置 → 开播」的顺序守卫（v1.7.49）
///
/// 修的是一个真实 bug：`initState` 里原本是
///
///     _applySavedPreferences();   // async，要 await SharedPreferences
///     ...
///     _open();                    // 同步往下跑，立刻读 _engine
///
/// 两行并发执行，`_open()` 用 `_engine` 的时候设置还没读进来，
/// 于是**设置里选 MPV，实际永远开 Exo**（顶栏恒显示 Exo 就是这个原因）。
///
/// 这类问题没有异常、没有日志，跑起来「看起来正常」，只是设置不生效。
/// 单测也很难抓住（要真起播放器）。所以这里守源码结构：initState 里
/// 只允许调 `_boot()`，不允许再出现裸的 `_applySavedPreferences()` / `_open()`。
void main() {
  late String src;

  setUpAll(() {
    src = File('lib/pages/player_page.dart').readAsStringSync();
  });

  test('initState 里不再有裸的 _open()，起播统一走 _boot()', () {
    final initState = _slice(src, 'void initState() {');

    expect(
      initState.contains('_boot()'),
      isTrue,
      reason: 'initState 必须调用 _boot()（先读设置再开播）',
    );
    // 允许 `Future<void> _open() async {` 这种定义，只盯调用点
    expect(
      RegExp(r'^\s*_open\(\);', multiLine: true).hasMatch(initState),
      isFalse,
      reason: 'initState 里直接调 _open() 会和读设置并发，'
          '导致「设置里选 MPV 却总是开 Exo」',
    );
    expect(
      RegExp(r'^\s*_applySavedPreferences\(\);', multiLine: true)
          .hasMatch(initState),
      isFalse,
      reason: '设置读取必须在 _boot() 里被 await，不能裸调',
    );
  });

  test('_boot 里先 awaiting 读设置，再 await 开播', () {
    final boot = _slice(src, 'Future<void> _boot() async {');
    final iRead = boot.indexOf('await _applySavedPreferences()');
    final iOpen = boot.indexOf('await _open()');

    expect(iRead, greaterThanOrEqualTo(0), reason: '_boot 必须 await 读设置');
    expect(iOpen, greaterThanOrEqualTo(0), reason: '_boot 必须 await 开播');
    expect(
      iRead < iOpen,
      isTrue,
      reason: '读设置必须在开播之前完成，否则 _engine 还是默认值',
    );
  });

  test('_applySavedPreferences 读的是设置页仍在用的键', () {
    // 防「设置页写一套、播放页读另一套」。
    // v1.7.50：STRM 优先 Exo 已下架，故不再读 set_strm_exo。
    expect(src.contains("prefs.getInt('set_play_engine')"), isTrue);
    expect(src.contains("prefs.getInt('set_max_bitrate')"), isTrue);
    expect(src.contains("prefs.getInt('set_cache_size')"), isTrue);
    expect(src.contains("prefs.getBool('set_hw_decode')"), isTrue);
    expect(src.contains("prefs.getBool('set_record_history')"), isTrue);
    // 已下架的设置项不应再被播放页读取
    expect(src.contains('set_strm_exo'), isFalse);
  });

  test('弹窗能切内核：播放页对外暴露 switchToExo', () {
    // STRM 加载弹窗里点「切换 Exo」需要能驱动播放页，
    // 而不是重新推一个页面（那样进度、字幕全丢）
    expect(src.contains('Future<void> switchToExo()'), isTrue);
    expect(src.contains('class PlayerPageState'), isTrue,
        reason: 'State 要公开，外部才能通过 GlobalKey 拿到');
  });
}

/// 从 [marker] 开始截到下一处「方法级缩进 + }」为止，粗略取一个方法体
String _slice(String src, String marker) {
  final i = src.indexOf(marker);
  if (i < 0) return '';
  final rest = src.substring(i);
  final end = rest.indexOf('\n  }\n');
  return end < 0 ? rest : rest.substring(0, end);
}
