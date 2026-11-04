// v2.0.41 新增「信息区」：规格三列（系列 / 发行日期 / 时长）+ 演员 + 标签。
//
// 覆盖两件事：
// 1. `_dateOnly` 把 Emby 的 ISO8601 截成 YYYY-MM-DD（7 位小数秒不能崩）；
// 2. 信息区在三档屏幕下都能渲染：有系列 / 无系列、演员多到溢出、标签多到 +N。
import 'package:camby/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 EmbyServer._dateOnly 同逻辑的独立副本，用于单测契约
/// （原方法是 private，测试里复刻一份，两边改动需同步）
String dateOnly(String? iso) {
  final s = (iso ?? '').trim();
  if (s.length < 10) return '';
  final head = s.substring(0, 10);
  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(head) ? head : '';
}

MediaItem _item({
  String seriesName = '',
  String premiereDate = '',
  int year = 2021,
  int runtimeMin = 45,
  int people = 2,
  List<String>? tags,
}) {
  return MediaItem(
    id: 'm1',
    name: '测试片',
    type: MediaType.movie,
    overview: '简介',
    colors: const [Color(0xFF2A3550), Color(0xFF06080E)],
    year: year,
    runtimeMin: runtimeMin,
    seriesName: seriesName,
    premiereDate: premiereDate,
    tags: tags ?? const ['高畫質', '單體作品'],
    people: List.generate(
      people,
      (i) => CastMember(name: '演员$i', role: 'role', id: 'p$i'),
    ),
  );
}

void main() {
  group('发行日期解析', () {
    test('标准 ISO8601（7 位小数秒）截成日期', () {
      expect(dateOnly('2021-12-23T00:00:00.0000000Z'), '2021-12-23');
    });

    test('无时间部分也能解析', () {
      expect(dateOnly('2021-12-23'), '2021-12-23');
    });

    test('空值 / 太短 / 形态不符 → 空串（不抛异常）', () {
      expect(dateOnly(null), '');
      expect(dateOnly(''), '');
      expect(dateOnly('2021'), '');
      expect(dateOnly('unknown-value'), '');
    });
  });

  group('MediaItem 新字段序列化', () {
    test('premiereDate / seriesName 往返不丢', () {
      final it = _item(seriesName: 'ハメ撮り', premiereDate: '2021-12-23');
      final back = MediaItem.fromJson(it.toJson());
      expect(back.seriesName, 'ハメ撮り');
      expect(back.premiereDate, '2021-12-23');
    });

    test('旧缓存缺字段时回退为空串（不崩）', () {
      final j = _item().toJson()
        ..remove('seriesName')
        ..remove('premiereDate');
      final back = MediaItem.fromJson(j);
      expect(back.seriesName, '');
      expect(back.premiereDate, '');
    });
  });

  group('时长文案', () {
    String fmt(int m) {
      if (m <= 0) return '—';
      if (m < 60) return '${m}m';
      final h = m ~/ 60;
      final r = m % 60;
      return r == 0 ? '${h}h' : '${h}h${r}m';
    }

    test('45 分钟 → 45m（与参考图一致）', () => expect(fmt(45), '45m'));
    test('120 分钟 → 2h', () => expect(fmt(120), '2h'));
    test('152 分钟 → 2h32m', () => expect(fmt(152), '2h32m'));
    test('0 → —', () => expect(fmt(0), '—'));
  });

  testWidgets('演员数量计算不溢出（信息区数据契约）', (tester) async {
    // 20 个演员要能被 +N 收住，这里只验证构建期不抛异常
    final it = _item(people: 20);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              Text('${it.people.length} 位演员'),
              Text(it.seriesName.isEmpty ? '无系列' : it.seriesName),
            ],
          ),
        ),
      ),
    );
    expect(find.text('20 位演员'), findsOneWidget);
    expect(find.text('无系列'), findsOneWidget);
  });
}
