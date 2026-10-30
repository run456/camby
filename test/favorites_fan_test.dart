import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v1.7.63：收藏夹海报扇形「方案 B · 更克制」的守卫测试。
///
/// 背景：后卡原本 ±7° / 探出 6% / scale 0.86，旋转后横向外扩约 15dp/侧，
/// 越过 2 列网格的格子边界，把相邻收藏夹的封面压住（左格扇形压右格封面）。
///
/// 约束（来自设计稿 favorites_fan_proposal.html 方案 B）：
///   · 后卡角度 |angle| ≤ 0.05 rad（≈2.9°）
///   · 后卡探出 |dx| ≤ 2%
///   · 整体缩放 scale ≤ 0.85
/// 后续若把幅度再调大，测试立刻失败。
void main() {
  // 所有断言都在 test 里做：expect 写在 main 顶层会抛 OutsideTestException
  late String code;
  late Iterable<String> back;
  late String front;
  double val(String line, int i) {
    final nums = RegExp(r'(-?\d+\.\d+)').allMatches(line).toList();
    expect(nums.length, greaterThanOrEqualTo(3), reason: '分支参数不足: $line');
    return double.parse(nums[i].group(1)!);
  }

  setUp(() {
    final src = File('lib/pages/favorites_page.dart').readAsStringSync();
    final layerIdx = src.indexOf('Widget _layer(int depth');
    expect(layerIdx, greaterThanOrEqualTo(0), reason: '找不到 _layer()');
    final endIdx = src.indexOf('Widget get _placeholder', layerIdx);
    expect(endIdx, greaterThan(layerIdx), reason: '找不到 _layer() 结束位置');

    // 只保留代码行（锚点可能出现在注释里）
    code = src
        .substring(layerIdx, endIdx)
        .split('\n')
        .where((l) => !l.trim().startsWith('//'))
        .join('\n');

    final branches = code
        .split('\n')
        .where((l) => RegExp(r'^\s*(\d|_)\s*=>\s*\(').hasMatch(l))
        .toList();
    expect(branches.length, 3, reason: '应保留 depth 0/1/2 三个分支');
    back = branches.where((l) => l.trimLeft().startsWith(RegExp(r'\d')));
    front = branches.firstWhere((l) => l.trimLeft().startsWith('_'));
  });

  test('后卡扇角收到 ±2.5° 左右（|angle| ≤ 0.05 rad）', () {
    for (final line in back) {
      final a = val(line, 0);
      expect(a.abs(), lessThanOrEqualTo(0.05),
          reason: '扇角过大、会压住相邻收藏夹: ${line.trim()}');
    }
  });

  test('后卡探出 ≤ 2%，整体缩放 ≤ 0.85', () {
    for (final line in back) {
      expect(val(line, 1).abs(), lessThanOrEqualTo(0.020),
          reason: '探出过大: ${line.trim()}');
    }
    final m = RegExp(r'const scale = (\d+\.\d+);').firstMatch(code);
    expect(m, isNotNull);
    expect(double.parse(m!.group(1)!), lessThanOrEqualTo(0.85),
        reason: '缩放过大，留给扇形的格内空间不足');
  });

  test('前卡微倾与后层上探保留（层次结构不变）', () {
    expect(val(front, 0), -0.020, reason: '前卡 -0.020 微倾应保留');
    for (final line in back) {
      expect(val(line, 2), lessThan(0), reason: '后卡应向上探出，露出顶部边缘');
    }
  });
}
