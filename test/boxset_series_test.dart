import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:camby/metadata/boxset_series.dart';

/// v2.0.63：系列改读服务端「合集 / BoxSet」的回归。
///
/// 用户指出影片详情里的「系列」其实对应 Emby 的「所属合集」。前两版直读
/// .nfo 是走错路：服务端已经把 `<set><name>` 建成了独立的 BoxSet 对象，
/// 网页端靠 `ListItemIds` 反查就能拿到，不需要影片文件路径或 HTTP 直链。
/// 这组测试锁死 API 形态、映射合并规则，以及详情页 / 系列总览的接线顺序。
void main() {
  String src(String path) => File(path).readAsStringSync();

  group('EmbyClient 的 BoxSet API', () {
    final emby = src('lib/emby_client.dart');

    test('反查所属合集用网页端同款 ListItemIds', () {
      expect(emby.contains("'ListItemIds': itemId"), isTrue);
      expect(emby.contains("'IncludeItemTypes': 'BoxSet'"), isTrue);
      expect(emby.contains('boxSetNamesForItem(String itemId)'), isTrue);
    });

    test('列出全部合集与合集成员两个端点都在', () {
      expect(emby.contains('Future<List<BoxSetInfo>> allBoxSets()'), isTrue);
      expect(emby.contains('Future<List<String>> boxSetMemberIds('), isTrue);
      expect(emby.contains("'ParentId': boxSetId"), isTrue);
    });

    test('合集是独立对象而不是 Movie 上的字段', () {
      expect(emby.contains('class BoxSetInfo'), isTrue);
      expect(emby.contains('BoxSet 对象'), isTrue);
    });
  });

  group('合集 → 系列 映射', () {
    test('空输入返回空表', () {
      expect(BoxSetSeriesSync.mergeMappings(const <BoxSetMembers>[]), isEmpty);
    });

    test('先到的合集优先，空 id / 空名被丢弃', () {
      final m = BoxSetSeriesSync.mergeMappings([
        const BoxSetMembers('  憧憬的系列  ', ['a', '', 'b']),
        const BoxSetMembers('第二个系列', ['a', 'c']),
        const BoxSetMembers('   ', ['d']),
      ]);
      expect(m.length, 3);
      expect(m['a'], '憧憬的系列');
      expect(m['b'], '憧憬的系列');
      expect(m['c'], '第二个系列');
      expect(m.containsKey('d'), isFalse);
    });
  });

  group('详情页与系列页接线', () {
    test('详情页先反查服务端合集，NFO 退到后面', () {
      final d = src('lib/pages/detail_page.dart');
      final lookup = d.indexOf('boxSetNamesForItem(_item.id)');
      final nfo = d.indexOf('buildNfoCandidates(');
      expect(lookup, greaterThan(-1));
      expect(nfo, greaterThan(-1));
      expect(lookup, lessThan(nfo), reason: '合集反查必须排在 NFO 兜底之前');
      expect(d.contains('_seriesSource'), isTrue);
      expect(d.contains('服务端「所属合集」'), isTrue);
    });

    test('系列总览改为同步合集，不再全库扫 NFO', () {
      final s = src('lib/pages/series_index_page.dart');
      expect(s.contains('BoxSetSeriesSync.run('), isTrue);
      expect(s.contains("'同步合集'"), isTrue);
      expect(s.contains('NfoSeriesBackfill.run('), isFalse);
      expect(s.contains("import '../metadata/nfo_series_backfill.dart';"),
          isFalse);
    });

    test('全库同步服务不再触碰 NFO 读取', () {
      final b = src('lib/metadata/boxset_series.dart');
      expect(b.contains('loadNfoSeries'), isFalse);
      expect(b.contains('ListItemIds'), isTrue);
      expect(b.contains('state.replaceSeriesNames(updates)'), isTrue);
    });
  });

  group('同步结果', () {
    test('默认字段与 anyHit', () {
      final r = BoxSetSyncResult();
      expect(r.anyHit, isFalse);
      expect(r.boxSets, 0);
      expect(r.failed, isFalse);
      expect(r.usedItemLookup, isFalse);
      r.filled = 3;
      expect(r.anyHit, isTrue);
    });
  });
}
