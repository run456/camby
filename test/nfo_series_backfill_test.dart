import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/app_state.dart';
import 'package:camby/metadata/nfo_reader.dart';
import 'package:camby/metadata/nfo_series_backfill.dart';
import 'package:camby/models.dart';

/// v2.0.62：系列「无论如何都加载不出来」的根因回归。
///
/// Emby 官方不解析 NFO 的 `<set><name>`（只留给 Kodi），所以只能直读 .nfo；
/// 旧版卡在「_kItemFields 没要 Path → 路径为空」+「候选只有 1~2 个」。
/// 这组测试锁死：路径来源补齐、候选铺全、诊断可见、批量回填不覆盖已有值，
/// 以及演员页筛选条不再用那块冷蓝黑。
void main() {
  MediaItem mk(String id, {String seriesName = '', String filePath = ''}) =>
      MediaItem(
        id: id,
        name: '影片 $id',
        type: MediaType.movie,
        overview: '简介',
        colors: const [Color(0xFF3366CC), Color(0xFF101010)],
        seriesName: seriesName,
        filePath: filePath,
      );

  group('buildNfoCandidates 多候选', () {
    test('http 直链：同名 / movie.nfo × 保留 / 去签名 + 两态代理', () {
      final c = buildNfoCandidates(
        'http://h/d/IPZZ-077-C.mp4?sign=abc',
        embyBase: 'http://e:8096/emby',
        embyToken: 'TK',
        itemId: '9',
      );
      expect(c.length, 6);
      expect(c[0].url, contains('IPZZ-077-C.nfo'));
      expect(c[0].url, contains('sign=abc'));
      expect(c[1].url, startsWith('http://h/d/IPZZ-077-C.nfo'));
      expect(c[1].url, isNot(contains('sign')));
      expect(c[2].url, contains('movie.nfo'));
      expect(c[3].url, startsWith('http://h/d/movie.nfo'));
      expect(c[3].url, isNot(contains('sign')));
      expect(c[4].label, contains('Emby 代理'));
      expect(c[5].label, contains('movie.nfo'));
      // 候选不能重复，否则全库扫描会白发一轮请求
      expect(c.map((e) => e.url).toSet().length, c.length);
      // 代理候选必须带 token
      expect(c[4].url, contains('api_key=TK'));
    });

    test('本地路径：只有两态 Emby 代理，Path 参数指向 .nfo', () {
      final c = buildNfoCandidates(
        '/volume1/media/x.mp4',
        embyBase: 'http://e:8096/emby',
        embyToken: 'TK',
        itemId: '9',
      );
      expect(c.length, 2);
      expect(c[0].url, contains('%2Fvolume1%2Fmedia%2Fx.nfo'));
      expect(c[1].url, contains('movie.nfo'));
    });

    test('路径为空：候选为空，不再白跑一轮代理', () {
      expect(buildNfoCandidates(''), isEmpty);
      expect(buildNfoCandidates('   '), isEmpty);
    });

    test('无凭据时不产代理候选', () {
      final c = buildNfoCandidates('/volume1/media/x.mp4');
      expect(c, isEmpty);
    });
  });

  group('parseNfoSeries 对用户样例', () {
    test('多行缩进的 <set><name> 能解析出日文系列名', () {
      expect(
        parseNfoSeries(
          '<movie>\n  <set>    <name>憧れの競泳水着インストラクター</name>  </set>\n</movie>',
        ),
        '憧れの競泳水着インストラクター',
      );
    });

    test('CDATA 与实体也能取到', () {
      expect(
        parseNfoSeries('<set><name><![CDATA[A &amp; B]]></name></set>'),
        'A & B',
      );
    });
  });

  group('读取诊断', () {
    test('空候选返回 ok=false 且不抛异常', () async {
      final r = await loadNfoSeriesDetailed(const <NfoCandidate>[]);
      expect(r.ok, isFalse);
      expect(r.probes, isEmpty);
    });

    test('失败样例去重、最多 5 条、排除命中项', () {
      final r = NfoBackfillResult();
      r.probes.addAll([
        const NfoProbe('x', NfoProbeStatus.hit, detail: 'ok'),
        for (var i = 0; i < 8; i++)
          NfoProbe('y', NfoProbeStatus.httpError,
              detail: i < 3 ? '404' : 'err$i'),
      ]);
      expect(r.samples.length, 5);
      expect(r.samples.every((s) => !s.contains('命中')), isTrue);
      expect(r.samples.toSet().length, r.samples.length);
    });

    test('诊断文案脱敏：源码必须剔除 api_key / sign', () {
      final src = File('lib/metadata/nfo_reader.dart').readAsStringSync();
      expect(src.contains("remove('api_key')"), isTrue);
      expect(src.contains("remove('sign')"), isTrue);
      expect(src.contains('_safeUrl'), isTrue);
    });
  });

  group('路径来源与批量回填', () {
    test('_kItemFields 必须请求 Path，filePath 优先用顶层 Path', () {
      final src = File('lib/emby_client.dart').readAsStringSync();
      expect(src.contains("'Tags,TagItems,Studios,SeriesName,Path'"), isTrue);
      expect(src.contains('final itemPath = (j[\'Path\'] as String?) ?? \'\';'),
          isTrue);
      expect(src.contains('filePath: effectivePath'), isTrue);
    });

    test('replaceSeriesNames 只填空值、不覆盖已有系列名、trim 后写入', () {
      final s = AppState()
        ..installTestItems([
          mk('a'),
          mk('b', seriesName: '原系列'),
          mk('c'),
        ]);
      s.replaceSeriesNames({'a': '新系列', 'b': '不该覆盖', 'c': '  S3  '});
      expect(s.items.firstWhere((e) => e.id == 'a').seriesName, '新系列');
      expect(s.items.firstWhere((e) => e.id == 'b').seriesName, '原系列');
      expect(s.items.firstWhere((e) => e.id == 'c').seriesName, 'S3');
    });

    test('replaceSeriesNames 空 updates 不触发无谓通知', () {
      final s = AppState()..installTestItems([mk('a')]);
      final before = s.items.first.seriesName;
      s.replaceSeriesNames({});
      expect(s.items.first.seriesName, before);
    });
  });

  group('接入与样式源码守卫', () {
    test('详情页走新候选且「系列：无」可点看诊断', () {
      final src = File('lib/pages/detail_page.dart').readAsStringSync();
      expect(src.contains('buildNfoCandidates('), isTrue);
      expect(src.contains('loadNfoSeriesDetailed(candidates)'), isTrue);
      expect(src.contains('onNoSeriesTap: _showNfoDiagnosis'), isTrue);
      expect(src.contains('_showNfoDiagnosis()'), isTrue);
    });

    test('系列总览页挂上「补全系列」入口与进度', () {
      final src = File('lib/pages/series_index_page.dart').readAsStringSync();
      expect(src.contains('NfoSeriesBackfill.run('), isTrue);
      expect(src.contains("'补全系列'"), isTrue);
      expect(src.contains('LinearProgressIndicator('), isTrue);
      // 空态不再诱导用户「一部部浏览累积」
      expect(src.contains('浏览过的影片越多'), isFalse);
    });

    test('全库回填服务带试跑提前中止，避免空转', () {
      final src =
          File('lib/metadata/nfo_series_backfill.dart').readAsStringSync();
      expect(src.contains('abortedByProbe'), isTrue);
      expect(src.contains('probeLimit'), isTrue);
      expect(src.contains('replaceSeriesNames(updates)'), isTrue);
    });

    test('演员页筛选条不再用冷蓝黑实色块', () {
      final src = File('lib/pages/person_page.dart').readAsStringSync();
      expect(src.contains('0xF20B1020'), isFalse);
      expect(src.contains('Color(0xCC2B2321)'), isTrue);
      expect(src.contains('SliverPersistentHeader'), isTrue);
    });
  });
}
