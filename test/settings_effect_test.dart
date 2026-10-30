import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「假开关」守卫（v1.7.47）
///
/// 背景：设置页里一度有 4 个开关是纯装饰 —— UI 能点、值也存了，但整个
/// lib/ 里**没有任何地方读它**。用户点完毫无变化，而这类问题编译不报错、
/// 现有测试也全绿（因为没人测「这个设置到底有没有生效」）。
///
/// 这里用静态扫描守两道线：
///   1. 每个出现在设置页 UI 上的 `set_xxx` 键，必须在**设置页以外**
///      至少被读取一次（否则就是个假开关）；
///   2. 白名单里登记「已知并已如实标注」的例外，新增例外必须写理由。
///
/// 这是纯文本扫描，不依赖运行时，跑得快，也不会因为改了别的页面而漏。
void main() {
  /// 已确认无消费端、且 UI 上已如实告知用户的键 → 理由
  const documented = <String, String>{
    'set_online_subtitle':
        'App 未接入任何在线字幕源（无 OpenSubtitles 等），字幕轨全部来自 '
            'Emby 的 MediaStreams。设置页副标题已写明「本版未接入字幕源（预留）」，'
            '开启时会弹提示说明。',
  };

  test('设置页里的每个开关都有人读，不存在纯装饰的假开关', () {
    final settings = File('lib/pages/settings_page.dart')
        .readAsStringSync();

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
      final consumed = readPattern.hasMatch(haystack);
      if (!consumed && !documented.containsKey(key)) orphans.add(key);
    }

    expect(
      orphans,
      isEmpty,
      reason: '这些设置在设置页有 UI，但 lib/ 里没有任何读取点 —— '
          '点了不会生效，属于假开关。要么接上消费端，要么像 '
          'set_online_subtitle 那样在 UI 上如实标注并登记进 documented：\n'
          '${orphans.map((k) => '  · $k').join('\n')}',
    );
  });

  test('白名单里的键确实仍然没有消费端，避免白名单长期腐烂', () {
    // 万一以后真接上了在线字幕源，这条会失败，提醒把白名单清掉
    final libFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    final haystack = libFiles.map((f) => f.readAsStringSync()).join('\n');

    for (final key in documented.keys) {
      final readPattern = RegExp(
        "get(Int|Bool|String|Double)\\('${RegExp.escape(key)}'\\)",
      );
      // 设置页自己那次读取不算「消费端」
      final count = readPattern.allMatches(haystack).length;
      expect(
        count,
        lessThanOrEqualTo(1),
        reason: '$key 已经有真正的消费端了，请从 documented 白名单移除',
      );
    }
  });
}
