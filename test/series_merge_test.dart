import 'dart:async';
import 'dart:io';

import 'package:camby/models.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/season_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.93：同一部剧被服务端拆成多条 Series 时的合并
///
/// 真机反馈：「选集有了，但是同一部剧还是没有合起来，你看绿联的图，
/// 它是先选季再选集」。
///
/// 根因：绿联影视中心把**每一季登记成一条独立的 Series**
/// （`瑞克和莫蒂 第5季` 与 `瑞克和莫蒂 第7季` 各是一条），点进第 5 季的
/// 详情页，季标签自然只有第 5 季。合并靠名字：剥掉「第N季 / Season N /
/// Sxx」后缀得到基名，基名相同的 Series 视为同一部剧的不同季。
///
/// 这批测试盯三件事：
///  ① 名字归一化（不能把《梦魇绝镇：起源》并进《梦魇绝镇》）；
///  ② 合并结果（季号去重、带分集的优先、顺序稳定）；
///  ③ 播放链路的「Exo 拉不动就记住」不再让它每次黑屏一轮。

String src(String rel) => File(rel).readAsStringSync();

MediaItem series(String id, String name, {int childCount = 0}) => MediaItem(
  id: id,
  name: name,
  type: MediaType.series,
  overview: '',
  colors: const [],
  childCount: childCount,
);

void main() {
  group('基名归一化', () {
    test('剥掉中文季后缀', () {
      expect(seriesBaseName('瑞克和莫蒂 第5季'), '瑞克和莫蒂');
      expect(seriesBaseName('梦魇绝镇 第1季'), '梦魇绝镇');
      expect(seriesBaseName('梦魇绝镇 第四季'), '梦魇绝镇');
      expect(seriesBaseName('瑞克和莫蒂第7季'), '瑞克和莫蒂');
    });

    test('剥掉英文季后缀', () {
      expect(seriesBaseName('From Season 2'), 'From');
      expect(seriesBaseName('From season 10'), 'From');
      expect(seriesBaseName('Rick and Morty S05'), 'Rick and Morty');
      expect(seriesBaseName('Rick and Morty S5'), 'Rick and Morty');
    });

    test('没有季后缀时原样返回', () {
      expect(seriesBaseName('梦魇绝镇'), '梦魇绝镇');
      expect(seriesBaseName('瑞克和莫蒂'), '瑞克和莫蒂');
      expect(seriesBaseName('S.W.A.T.'), 'S.W.A.T.');
      expect(seriesBaseName(''), '');
    });

    test('整名就是季号时不剥（避免得到空基名）', () {
      expect(seriesBaseName('第5季'), '第5季');
    });

    test('不同剧不会被并到一起', () {
      // 这是合并逻辑最危险的地方：宁可漏合，不能错并
      expect(seriesBaseName('梦魇绝镇 第1季'), isNot(seriesBaseName('梦魇绝镇：起源 第1季')));
      expect(seriesBaseName('From 第2季'), isNot(seriesBaseName('From Beyond 第2季')));
    });
  });

  group('从剧名取季号', () {
    test('阿拉伯数字', () {
      expect(seasonFromSeriesName('瑞克和莫蒂 第5季'), 5);
      expect(seasonFromSeriesName('From Season 2'), 2);
      expect(seasonFromSeriesName('Rick and Morty S07'), 7);
    });

    test('中文数字', () {
      expect(seasonFromSeriesName('梦魇绝镇 第一季'), 1);
      expect(seasonFromSeriesName('梦魇绝镇 第四季'), 4);
      expect(seasonFromSeriesName('梦魇绝镇 第十季'), 10);
      expect(seasonFromSeriesName('梦魇绝镇 第十二季'), 12);
    });

    test('没有季号返回 null（标准 Emby 的剧名走这条路）', () {
      expect(seasonFromSeriesName('梦魇绝镇'), isNull);
      expect(seasonFromSeriesName('瑞克和莫蒂'), isNull);
      expect(seasonFromSeriesName(''), isNull);
    });
  });

  group('同剧其它季的识别', () {
    test('从全库列表里挑出基名相同的 Series', () {
      final pool = [
        series('s5', '瑞克和莫蒂 第5季'),
        series('s7', '瑞克和莫蒂 第7季'),
        series('s1', '瑞克和莫蒂 第1季'),
        series('other', '梦魇绝镇 第1季'),
        series('plain', '瑞克和莫蒂'),
      ];
      final got = siblingSeasonGroups(pool[0], pool);
      expect(got.map((g) => g.index), [1, 7]);
      expect(got.map((g) => g.seriesId), ['s1', 's7']);
      // 自己不能被算进去
      expect(got.any((g) => g.seriesId == 's5'), isFalse);
    });

    test('基名相同但名字里没季号的 Series 不参与合并', () {
      final pool = [
        series('s5', '瑞克和莫蒂 第5季'),
        series('plain', '瑞克和莫蒂'),
      ];
      expect(siblingSeasonGroups(pool[0], pool), isEmpty);
    });

    test('同名季只留一条，季号升序', () {
      final pool = [
        series('a', '梦魇绝镇 第2季'),
        series('b', '梦魇绝镇 第1季'),
        series('c', '梦魇绝镇 第二季'),
      ];
      final got = siblingSeasonGroups(pool[0], pool);
      expect(got.map((g) => g.index), [1, 2]);
      expect(got.length, 2);
    });

    test('电影条目 / 空列表直接返回空', () {
      final movie = MediaItem(
        id: 'm',
        name: '雨中曲',
        type: MediaType.movie,
        overview: '',
        colors: const [],
      );
      expect(siblingSeasonGroups(movie, [movie]), isEmpty);
      expect(siblingSeasonGroups(series('s', '某剧 第1季'), const []), isEmpty);
    });
  });

  group('季列表合并', () {
    test('本剧的季与兄弟季合并后按季号升序', () {
      final current = [
        SeasonGroup(
          index: 5,
          episodes: [
            MediaItem(
              id: 'e1',
              name: 'E1',
              type: MediaType.episode,
              overview: '',
              colors: const [],
              seasonNumber: 5,
              episodeNumber: 1,
            ),
          ],
        ),
      ];
      final siblings = [
        const SeasonGroup(index: 7, seriesId: 's7'),
        const SeasonGroup(index: 1, seriesId: 's1'),
      ];
      final merged = mergeSeasonGroups(current, siblings);
      expect(merged.map((g) => g.index), [1, 5, 7]);
      // 第 5 季是我们点进来的那条，必须保留它的分集
      expect(merged[1].episodes.length, 1);
      expect(merged[0].hasEpisodes, isFalse);
    });

    test('同季号以带分集的那份为准', () {
      final current = [const SeasonGroup(index: 2, seriesId: 'cur')];
      final siblings = [
        SeasonGroup(
          index: 2,
          seriesId: 'sib',
          episodes: [
            MediaItem(
              id: 'x',
              name: 'E1',
              type: MediaType.episode,
              overview: '',
              colors: const [],
              seasonNumber: 2,
              episodeNumber: 1,
            ),
          ],
        ),
      ];
      final merged = mergeSeasonGroups(current, siblings);
      expect(merged.length, 1);
      expect(merged.single.hasEpisodes, isTrue);
      expect(merged.single.seriesId, 'sib');
    });

    test('空输入不炸', () {
      expect(mergeSeasonGroups(const [], const []), isEmpty);
      expect(mergeSeasonGroups(const [], [const SeasonGroup(index: 3)]).length, 1);
    });
  });

  group('面板按需加载兄弟季', () {
    Widget wrap(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets('点空的季会触发 onLoadSeason，加载后显示集号', (tester) async {
      final asked = <int>[];
      Completer<void>? loadDone;
      final groups = [
        SeasonGroup(
          index: 5,
          episodes: [
            for (var n = 1; n <= 3; n++)
              MediaItem(
                id: '5-$n',
                name: 'E$n',
                type: MediaType.episode,
                overview: '',
                colors: const [],
                seasonNumber: 5,
                episodeNumber: n,
              ),
          ],
        ),
        const SeasonGroup(index: 7, seriesId: 's7'),
      ];
      await tester.pumpWidget(
        wrap(
          SeasonPicker(
            seasons: groups,
            onPlay: (_) {},
            initialSeason: 5,
            onLoadSeason: (g) async {
              asked.add(g.index);
              // 由测试控制何时完成，好观察加载态
              final gate = loadDone;
              if (gate != null) await gate.future;
              return [
                for (var n = 1; n <= 2; n++)
                  MediaItem(
                    id: '7-$n',
                    name: 'E$n',
                    type: MediaType.episode,
                    overview: '',
                    colors: const [],
                    seasonNumber: 7,
                    episodeNumber: n,
                  ),
              ];
            },
          ),
        ),
      );
      await tester.pump();
      expect(asked, isEmpty);

      // 用 Completer 卡住回调，才能观察到「加载中」这一帧；
      // 回调里直接 return 的话同步就完成了，断不到中间态。
      loadDone = Completer<void>();
      await tester.tap(find.text('第7季'));
      await tester.pump();
      expect(asked, [7]);
      // 加载中给可读提示，而不是空白
      expect(find.text('正在读取这一季…'), findsOneWidget);

      loadDone.complete();
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // 同一季不会被重复请求
      await tester.tap(find.text('第5季'));
      await tester.pump();
      await tester.tap(find.text('第7季'));
      await tester.pump();
      expect(asked, [7]);
    });

    testWidgets('没有 onLoadSeason 时点空季不崩', (tester) async {
      await tester.pumpWidget(
        wrap(
          SeasonPicker(
            seasons: [
              SeasonGroup(
                index: 1,
                episodes: [
                  MediaItem(
                    id: 'e',
                    name: 'E1',
                    type: MediaType.episode,
                    overview: '',
                    colors: const [],
                    seasonNumber: 1,
                    episodeNumber: 1,
                  ),
                ],
              ),
              const SeasonGroup(index: 2, seriesId: 'x'),
            ],
            onPlay: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('第2季'));
      await tester.pump();
      expect(find.text('这一季还没有分集数据'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('播放：Exo 拉不动就记住', () {
    test('AppState 暴露开关并在连接 / 断开 / 演示模式时重置', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('bool exoStreamUnavailable = false;'), isTrue);
      expect(s.contains('void markExoStreamUnavailable()'), isTrue);
      // 连接成功、断开、演示模式三处都要清零
      expect(
        'exoStreamUnavailable = false;'.allMatches(s).length,
        greaterThanOrEqualTo(3),
      );
    });

    test('播放页：已知 Exo 不可用就直接上 MPV，不再陪它黑屏', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains('widget.state.exoStreamUnavailable'), isTrue);
      expect(s.contains('widget.state.markExoStreamUnavailable()'), isTrue);
      // 只有绿联才这么判，普通 Emby 不受影响
      expect(s.contains('widget.state.server?.isUgreen ?? false'), isTrue);
    });

    test('MPV 起播后回读 path，有错就当场判失败', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains('PlaybackEngine.mpv &&'), isTrue);
      expect(s.contains("throw StateError('libmpv: \$mpvErr')"), isTrue);
    });

    test('起播记录带内核标签，一眼分清是哪条网络栈失败', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains("final tag = engine == PlaybackEngine.exo ? 'Exo' : 'MPV';"),
          isTrue);
      expect(s.contains("'\$tag · \${_shortUrl(url)} → '"), isTrue);
    });

    test('416 单独翻译成「不支持 Range」，不再混在未知里', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains('HTTP 416（不支持 Range）'), isTrue);
    });
  });

  group('取流：端点可用时的 Static 兜底', () {
    test('探测到 200/206 才追加 Static 变体，未声明协议也有两条可试', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains('if (cap.statusCode == 200 || cap.statusCode == 206)'), isTrue);
      expect(s.contains(r"'$assetUrl/Videos/${item.id}/stream?Static=true$q'"),
          isTrue);
    });

    test('v2.0.98 诊断结论改为「实测地址没传下去」，不再是内核定性', () {
      final s = src('lib/ugreen_resource.dart');
      expect(s.contains('hasVerifiedUrl'), isTrue);
      expect(s.contains('此前起播误用了另拼的 stream 端点（404）'), isTrue);
      // 旧的错误定性必须清掉：它把 404 地址问题误判成 Exo 拉不动流
      expect(s.contains('地址和鉴权都没问题，问题在播放内核的取流方式'), isFalse);
      expect(s.contains('本机已自动改试 MPV，下次开播会直接走它'), isFalse);
    });
  });

  group('版本与文档', () {
    test('版本与文档同步到 v2.0.103', () {
      expect(src('pubspec.yaml').contains('version: 2.0.103+303'), isTrue);
      expect(src('README.md').contains('v2.0.103 (303)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.103 (303)'), isTrue);
      expect(src('VERIFICATION.md').contains('§108'), isTrue);
      expect(src('lib/models.dart').contains("kClientVersion = '2.0.103'"),
          isTrue);
      expect(src('lib/dlna/dlna_protocol.dart').contains('Camby/2.0.103'),
          isTrue);
    });
  });
}
