import 'dart:io';

import 'package:camby/models.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/season_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.92：剧集「选季 → 选集」
///
/// 解决两个真机反馈：
///  ① 剧集分集没被正确识别，只显示一个单集 —— 根因是扁平分集条把各季混在
///    一起，且没按季分组，集数一多就看不到后面的集；
///  ② 这套选集面板要同时适用于 Emby / Jellyfin / 绿联影视中心。
///
/// 下面既有纯函数单测（分组 / 排序 / 续看），也有源码守卫（两端布局、
/// 服务端能力回落、设置页入口合并）。

String src(String rel) => File(rel).readAsStringSync();

MediaItem ep(
  String id, {
  int? season,
  int? number,
  String name = '',
  double? resume,
  bool played = false,
}) => MediaItem(
  id: id,
  name: name.isEmpty ? 'S${season}E$number' : name,
  type: MediaType.episode,
  overview: '',
  colors: const [],
  seasonNumber: season,
  episodeNumber: number,
  resumeProgress: resume,
  userPlayed: played,
);

void main() {
  group('分集排序', () {
    test('跨季按季号、同季按集号升序', () {
      final list = [
        ep('c', season: 2, number: 1),
        ep('b', season: 1, number: 10),
        ep('a', season: 1, number: 2),
        ep('d', season: 3, number: 1),
      ];
      list.sort(compareEpisodes);
      expect(list.map((e) => e.id), ['a', 'b', 'c', 'd']);
    });

    test('集号缺失时退到名字里的数字，不会排到最前', () {
      final list = [
        ep('x', season: 1, name: '第10集'),
        ep('y', season: 1, name: '第2集'),
        ep('z', season: 1, name: '第1集'),
      ];
      list.sort(compareEpisodes);
      expect(list.map((e) => e.id), ['z', 'y', 'x']);
    });
  });

  group('按季分组', () {
    test('四季各 10 集切成 4 组，组内有序、季号升序', () {
      final eps = [
        for (var s = 4; s >= 1; s--)
          for (var n = 10; n >= 1; n--) ep('$s-$n', season: s, number: n),
      ];
      final groups = seasonGroups(eps);
      expect(groups.length, 4);
      expect(groups.map((g) => g.index), [1, 2, 3, 4]);
      for (final g in groups) {
        expect(g.episodes.length, 10);
        expect(g.episodes.first.episodeNumber, 1);
        expect(g.episodes.last.episodeNumber, 10);
      }
    });

    test('缺季号的分集归到第 1 季，不能从面板上消失', () {
      final groups = seasonGroups([
        ep('a', season: null, number: 1),
        ep('b', season: 1, number: 2),
      ]);
      expect(groups.length, 1);
      expect(groups.first.index, 1);
      expect(groups.first.episodes.length, 2);
    });

    test('单季只回一组，季标签文案与集数', () {
      final groups = seasonGroups([
        for (var n = 1; n <= 3; n++) ep('s1e$n', season: 1, number: n),
      ]);
      expect(groups.length, 1);
      expect(groups.first.label, '第1季');
      expect(groups.first.countLabel, '3集');
      expect(groups.first.isSpecial, isFalse);
    });

    test('第 0 季是特别篇，空列表不炸', () {
      final g = seasonGroups([ep('sp1', season: 0, number: 1)]).first;
      expect(g.isSpecial, isTrue);
      expect(g.label, '特别篇');
      expect(seasonGroups(const []), isEmpty);
    });

    test('服务端给了季名就用季名', () {
      const g = SeasonGroup(index: 2, name: 'Season 2');
      expect(g.label, 'Season 2');
    });
  });

  group('续看下一集', () {
    test('季内顺延', () {
      final all = [
        for (var n = 1; n <= 3; n++) ep('1-$n', season: 1, number: n),
      ];
      expect(nextEpisode(all, all[0])?.id, '1-2');
      expect(nextEpisode(all, all[2]), isNull);
    });

    test('越过季边界顺延到下一季第 1 集', () {
      final all = [
        ep('1-1', season: 1, number: 1),
        ep('2-1', season: 2, number: 1),
      ];
      expect(nextEpisode(all, all[0])?.id, '2-1');
    });

    test('找不到当前集 / 空列表返回 null', () {
      expect(nextEpisode(const [], ep('a', season: 1, number: 1)), isNull);
      expect(
        nextEpisode([ep('a', season: 1, number: 1)], ep('zz', season: 1)),
        isNull,
      );
    });
  });

  group('集号角标', () {
    test('正常情况 S1E3', () {
      expect(episodeBadge(ep('a', season: 1, number: 3)), 'S1E3');
    });

    test('集号缺失用列表序号兜底，不出现 S1E0', () {
      expect(episodeBadge(ep('a', season: 1), fallbackIndex: 2), 'S1E3');
      expect(episodeBadge(ep('a', season: 1)), 'S1E1');
    });
  });

  group('类型识别', () {
    test('MediaType 现在能区分 Season / Episode', () {
      expect(MediaType.values.contains(MediaType.season), isTrue);
      final s = MediaItem(
        id: 'ss1',
        name: '第 1 季',
        type: MediaType.season,
        overview: '',
        colors: const [],
        seasonNumber: 1,
        childCount: 10,
      );
      expect(s.isSeason, isTrue);
      expect(s.isSeries, isFalse);
      expect(s.childCount, 10);
    });

    test('emby_client 解析 Type=Season，季号取 IndexNumber、集号留空', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains("'Season' => MediaType.season"), isTrue);
      expect(s.contains("j['Type'] == 'Season' ? (j['IndexNumber'] as int?) : null"),
          isTrue);
      expect(s.contains("j['Type'] == 'Season' ? null : (j['IndexNumber'] as int?)"),
          isTrue);
      expect(s.contains("parentId: j['ParentId'] as String?"), isTrue);
      expect(s.contains("childCount: (j['ChildCount'] as num?)"), isTrue);
    });
  });

  group('服务端能力回落', () {
    test('seasons() 标准路由失败时退回分集推导', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains("/Shows/\$seriesId/Seasons"), isTrue);
      expect(s.contains('return seasonGroups(eps)'), isTrue);
    });

    test('seasonEpisodes 按季号二次过滤，绿联不认 SeasonId 也不会串季', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains('Future<List<MediaItem>> seasonEpisodes('), isTrue);
      expect(
        s.contains('.where((e) => (e.seasonNumber ?? 1) == seasonIndex)'),
        isTrue,
      );
      // 分集回来后统一排序，避免固件乱序导致「第 3 集」排在第 1 集前面
      expect(s.contains('list.sort(compareEpisodes);'), isTrue);
    });
  });

  group('选集面板', () {
    test('组件只吃数据、不认服务端类型', () {
      final s = src('lib/widgets/season_picker.dart');
      expect(s.contains('class SeasonPicker extends StatefulWidget'), isTrue);
      expect(s.contains('required this.seasons'), isTrue);
      expect(s.contains('final List<SeasonGroup> seasons'), isTrue);
      // 面板里不该出现任何服务端类型判断
      expect(s.contains('ServerKind'), isFalse);
      expect(s.contains('ugreen'), isFalse);
    });

    test('单季不出季标签行，多季才有', () {
      final s = src('lib/widgets/season_picker.dart');
      expect(s.contains('if (widget.seasons.length > 1) ...['), isTrue);
    });

    test('看过的集打勾、看一半的集留进度条', () {
      final s = src('lib/widgets/season_picker.dart');
      expect(s.contains('e.userPlayed'), isTrue);
      expect(s.contains('LinearProgressIndicator('), isTrue);
    });
  });

  group('详情页接线', () {
    test('手机与平板都用同一个选集面板', () {
      final s = src('lib/pages/detail_page.dart');
      expect('_episodePicker()'.allMatches(s).length, greaterThanOrEqualTo(2));
      expect(s.contains("import '../widgets/season_picker.dart';"), isTrue);
      // 旧的横向分集条已经退场
      expect(s.contains('Widget _episodeList()'), isFalse);
      expect(s.contains("'S\${e.seasonNumber ?? 1}E\${e.episodeNumber ?? i + 1}'"),
          isFalse);
    });

    test('手机上剧集区块紧贴播放行（主操作先看到）', () {
      final s = src('lib/pages/detail_page.dart');
      final phone = s.substring(
        s.indexOf('List<Widget> _phoneSections'),
        s.indexOf('List<Widget> _tabletSections'),
      );
      expect(phone.contains('if (item.isSeries) ...['), isTrue);
      expect(phone.contains('_episodePicker()'), isTrue);
      // 播放行在前、选集紧随其后、简介再往后
      expect(
        phone.indexOf('_playRow(item)') < phone.indexOf('_episodePicker()'),
        isTrue,
      );
      expect(
        phone.indexOf('_episodePicker()') < phone.indexOf('_overviewCard(item)'),
        isTrue,
      );
    });

    test('初始定位到上次观看的那一季', () {
      final s = src('lib/pages/detail_page.dart');
      expect(s.contains('initialSeason: initial'), isTrue);
      // v2.0.93：本剧的季与「同剧其它季」合并后才落到 _seasons
      expect(s.contains('_seasons = merged'), isTrue);
      expect(s.contains('mergeSeasonGroups('), isTrue);
    });
  });

  group('选集面板渲染（widget）', () {
    Widget wrap(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    List<SeasonGroup> fourSeasons() => seasonGroups([
      for (var s = 1; s <= 4; s++)
        for (var n = 1; n <= 10; n++)
          ep('$s-$n', season: s, number: n, played: s == 1 && n <= 3),
    ]);

    testWidgets('四季都在、季标签可切换、切换后只显示该季集号', (tester) async {
      final picked = <MediaItem>[];
      await tester.pumpWidget(
        wrap(
          SeasonPicker(
            seasons: fourSeasons(),
            onPlay: picked.add,
            initialSeason: 1,
          ),
        ),
      );
      await tester.pump();

      // 标题与总数
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('共 40 集'), findsOneWidget);

      // 四个季标签都在
      for (final l in ['第1季', '第2季', '第3季', '第4季']) {
        expect(find.text(l), findsOneWidget);
      }

      // 第 1 季有 10 格：集号 1..10
      expect(find.text('10'), findsOneWidget);

      // 切到第 2 季
      await tester.tap(find.text('第2季'));
      await tester.pump();

      // 点第 2 季的第 5 集
      await tester.tap(find.text('5').first);
      await tester.pump();
      expect(picked, hasLength(1));
      expect(picked.first.seasonNumber, 2);
      expect(picked.first.episodeNumber, 5);
    });

    testWidgets('单季不渲染季标签行', (tester) async {
      await tester.pumpWidget(
        wrap(
          SeasonPicker(
            seasons: seasonGroups([
              for (var n = 1; n <= 8; n++) ep('1-$n', season: 1, number: n),
            ]),
            onPlay: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('第1季'), findsNothing);
      expect(find.text('共 8 集'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
    });

    testWidgets('空数据给可读占位，不崩', (tester) async {
      await tester.pumpWidget(
        wrap(SeasonPicker(seasons: const [], onPlay: (_) {}, loading: false)),
      );
      await tester.pump();
      expect(find.text('暂无分集信息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('续看按钮给出下一集并可直接播放', (tester) async {
      final picked = <MediaItem>[];
      final groups = seasonGroups([
        ep('1-1', season: 1, number: 1, resume: 0.4),
        ep('1-2', season: 1, number: 2),
      ]);
      await tester.pumpWidget(
        wrap(
          SeasonPicker(
            seasons: groups,
            onPlay: picked.add,
            onPlayNext: () => groups.first.episodes.elementAt(1),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('续看 S1E2'), findsOneWidget);
      await tester.tap(find.text('续看 S1E2'));
      await tester.pump();
      expect(picked.single.episodeNumber, 2);
    });
  });

  group('版本与文档', () {
    test('版本与文档同步到 v2.0.96', () {
      expect(src('pubspec.yaml').contains('version: 2.0.96+296'), isTrue);
      expect(src('README.md').contains('v2.0.96 (296)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.96 (296)'), isTrue);
      expect(src('VERIFICATION.md').contains('§108'), isTrue);
      expect(src('lib/models.dart').contains("kClientVersion = '2.0.96'"),
          isTrue);
      expect(src('lib/dlna/dlna_protocol.dart').contains('Camby/2.0.96'),
          isTrue);
    });
  });

  group('设置页：绿联并入统一入口', () {
    test('类型分段扩到三项，设置页不再有独立绿联卡', () {
      final s = src('lib/pages/settings_page.dart');
      expect(s.contains("items: const ['Emby', 'Jellyfin', '绿联']"), isTrue);
      expect(s.contains('void _switchKind(int i)'), isTrue);
      expect(s.contains("'Emby / Jellyfin / 绿联影视中心，同一个入口'"), isTrue);
      // 旧独立入口的痕迹必须清掉
      expect(s.contains('UGOS Pro · HTTPS 9443 · 自签证书'), isFalse);
      expect(s.contains('presetKind: ServerKind.ugreen,'), isFalse);
    });

    test('切到绿联自动带好 HTTPS / 9443 / 忽略证书，切回时回落', () {
      final s = src('lib/pages/settings_page.dart');
      expect(s.contains('if (next == ServerKind.ugreen) {'), isTrue);
      expect(s.contains('_ignoreSsl = true;'), isTrue);
      expect(s.contains("_port.text = '9443'"), isTrue);
      expect(s.contains("_port.text = '8096'"), isTrue);
    });
  });
}
