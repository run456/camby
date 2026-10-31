import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置页渲染回归（v1.7.46）
///
/// 起因：v1.7.42 把 `_load()` 里的死键清掉了，但**页面 Widget 树还在引用**
/// 这些键（`_s['sub_lang']` 等）。`Map<String, dynamic>` 取不存在的键返回
/// `null`，随后 `null as int` 抛 `type 'Null' is not a subtype of type 'int'`，
/// 整个「我的」页渲染失败 —— 用户看到的就是「没法添加服务器」。
///
/// 这里的断言方式刻意做成「数据驱动」：从源码里把所有 `_s['xxx']` 抓出来，
/// 和 `_load()` 里实际写进 map 的键做差集。以后再删键忘了删 UI，测试直接红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('设置页能正常渲染，不抛类型错误', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppState.disablePersistence = true;
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SettingsPage(
            state: state,
            onTabChanged: (_) {},
            onOpenDetail: (item, {heroTag}) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    // 有任何 widget 构建异常都会被这里抓到。关键是它绝对不能是
    // "type 'Null' is not a subtype of type 'int'"
    final err = tester.takeException();
    expect(err, isNull, reason: '设置页渲染异常：$err');

    expect(find.text('我的服务器'), findsWidgets);
    expect(find.text('添加'), findsWidgets);
  });

  test('页面引用的设置键必须都在 _load() 里初始化', () {
    final src = _readSource();

    // _load() 里写入的键
    final loadBlock = _slice(src, 'Future<void> _load() async {', '});');
    final inited = RegExp(r"""'([a-z_0-9]+)':\s*prefs\.get""")
        .allMatches(loadBlock)
        .map((m) => m.group(1)!)
        .toSet();
    expect(inited, isNotEmpty, reason: '没解析到 _load() 里的键，测试本身要改');

    // 页面里读的键（排除 _set() 写回那一类，它们和 _load 是同一批）
    final read = RegExp(r"""_s\['([a-z_0-9]+)'\]""")
        .allMatches(src)
        .map((m) => m.group(1)!)
        .toSet();

    final missing = read.difference(inited);
    expect(
      missing,
      isEmpty,
      reason: '这些键在 UI 里被读取，但 _load() 没有初始化 → 运行时是 null：$missing',
    );
  });
}

String _readSource() {
  // flutter test 的工作目录是包根目录
  return File('lib/pages/settings_page.dart').readAsStringSync();
}

/// 取 [start] 到其后第一个 [end] 之间的片段
String _slice(String src, String start, String end) {
  final i = src.indexOf(start);
  expect(i, greaterThan(-1), reason: '找不到 $start');
  final j = src.indexOf(end, i);
  return src.substring(i, j == -1 ? src.length : j);
}
