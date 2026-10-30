import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「假开关」守卫（v1.7.47 引入）
///
/// 背景：设置页里一度有 4 个开关是纯装饰 —— UI 能点、值也存了，但整个
/// lib/ 里**没有任何地方读它**。用户点完毫无变化，而这类问题编译不报错、
/// 原有测试也全绿（因为没人测「这个设置到底有没有生效」）。
///
/// v1.7.48 起**没有例外**：不再保留「预留开关」。凡是出现在设置页上的键，
/// 都必须在设置页以外被真正消费一次。做不了的功能就不该占一个开关位。
void main() {
  test('设置页里的每个开关都有人读，不存在纯装饰的假开关', () {
    final settings = File('lib/pages/settings_page.dart').readAsStringSync();

    // 1) 设置页 UI 上出现的键：`_set('xxx'` 与 `_s['xxx']`
    final uiKeys = <String>{
      for (final m in RegExp(r"_set\('([a-z_]+)'").allMatches(settings))
        'set_${m.group(1)}',
      for (final m in RegExp(r"_s\['([a-z_]+)'\]").allMatches(settings))
        'set_${m.group(1)}',
    };
    expect(uiKeys, isNotEmpty, reason: '没能扫到任何设置项，正则可能失效了');

    // 2) 全 lib 范围内，设置页之外的读取点
    final libFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('settings_page.dart'))
        .toList();
    expect(libFiles, isNotEmpty);

    final haystack = libFiles.map((f) => f.readAsStringSync()).join('\n');

    final orphans = <String>[];
    for (final key in uiKeys) {
      // 读法只有这几种：getInt / getBool / getString / getDouble
      final readPattern = RegExp(
        "get(Int|Bool|String|Double)\\('${RegExp.escape(key)}'\\)",
      );
      if (!readPattern.hasMatch(haystack)) orphans.add(key);
    }

    expect(
      orphans,
      isEmpty,
      reason: '这些设置在设置页有 UI，但 lib/ 里没有任何读取点 —— '
          '点了不会生效，属于假开关。\n'
          '要么接上消费端，要么把这个设置项删掉（本版不留「预留开关」）：\n'
          '${orphans.map((k) => '  · $k').join('\n')}',
    );
  });

  test('设置页不再出现「预留 / 暂未接入」这类占位开关', () {
    // 上一版留过一个「在线字幕搜索（预留）」，用户明确表示不需要这类东西。
    // 这条防止以后又用「先放个开关，以后再接」的方式糊上去。
    final settings = File('lib/pages/settings_page.dart').readAsStringSync();
    for (final word in ['预留', '暂未接入', '待接入', '敬请期待']) {
      expect(
        settings.contains(word),
        isFalse,
        reason: '设置页出现「$word」字样 —— 做不了的功能不要放开关占位',
      );
    }
  });
}
