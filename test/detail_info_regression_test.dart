import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camby/app_state.dart';
import 'package:camby/metadata/nfo_reader.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';

const _ppChannel = MethodChannel('plugins.flutter.io/path_provider');

/// v2.0.54 回归：详情页信息区 4 项改动；v2.0.55 追加独立行与点击筛选。
/// ① 简介/媒体信息卡改半透明纯色框、内层滚动接入模糊降级；
/// ② 标签行全部渲染、横滑可查看；
/// ③ 导演 / 制造商信息标签（v2.0.55 起从演员行拆出独立成行，可点筛选）；
/// ④ NFO 系列名兜底 + 长名省略号缩略。
void main() {
  // ── ④ NFO 解析（用用户提供的 IPZZ-077-C.nfo 真实字段） ──
  group('NFO 系列名兜底', () {
    const realNfo = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  <num>IPZZ-077</num>
  <series>濃厚な接吻とSEX</series>
  <set>
    <name>濃厚な接吻とSEX</name>
  </set>
  <studio>IDEA POCKET</studio>
  <maker>IDEA POCKET</maker>
  <director>うさぴょん。</director>
</movie>
''';

    test('解析 <series>（真实 NFO）', () {
      expect(parseNfoSeries(realNfo), '濃厚な接吻とSEX');
    });

    test('无 <series> 时回退 <set><name>', () {
      expect(
        parseNfoSeries('<movie><set><name>样例系列</name></set></movie>'),
        '样例系列',
      );
    });

    test('CDATA / 实体 / 换行容错', () {
      expect(
        parseNfoSeries(
          '<movie><series><![CDATA[ A &amp; B  系列 ]]></series></movie>',
        ),
        'A & B 系列',
      );
    });

    test('没有系列字段时返回 null', () {
      expect(parseNfoSeries('<movie><title>x</title></movie>'), isNull);
    });

    testURLDerivation();
  });

  // ── ① 性能改动的源码守卫 ──
  group('性能改动守卫', () {
    test('简介/媒体信息卡改用与标签同款半透明纯色框', () {
      final src = File('lib/pages/detail_page.dart').readAsStringSync();
      final hits = 'color: Colors.white.withValues(alpha: 0.06)'
          .allMatches(src)
          .length;
      expect(hits, 2,
          reason: '两张卡片都应是纯色 + 1px 边框，不再是渐变 + 18px 模糊阴影');
    });

    test('内层横向滚动统一接入 _degradedVN 降级', () {
      final src = File('lib/pages/detail_page.dart').readAsStringSync();
      expect(src.contains('NotificationListener<ScrollNotification>'), isTrue);
      expect(src.contains('_anyScrollNotification'), isTrue,
          reason: '剧照 / 标签行横滑时顶栏 BackdropFilter 必须一起降级');
    });
  });

  // ── ②③ 信息区真实渲染 ──
  group('信息区渲染', () {
    late final Directory docsDir;
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      docsDir = Directory.systemTemp.createTempSync('camby_info_docs');
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_ppChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      });
    });

    Future<void> pumpDetail(WidgetTester tester, MediaItem item) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: item,
            onPlay: (_, _, {bool resume = false}) {},
            onPlayPart: (_, _) {},
            state: AppState(),
            onOpenDetail: (_, {heroTag}) {},
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final manyTags = List<String>.generate(12, (i) => '标签${i + 1}');

    testWidgets('标签过多：全部渲染、无不可点的 +N 折叠', (tester) async {
      await pumpDetail(
        tester,
        MediaItem(
          id: 'm1',
          name: 'IPZZ-077 测试影片',
          type: MediaType.movie,
          overview: '简介',
          colors: [const Color(0xFF3366CC), const Color(0xFF101010)],
          tags: manyTags,
        ),
      );

      // 修复前会渲染 visible(约 4) + 1 个 +N；修复后必须 >= 全部标签数
      final counts = <int>[];
      for (final e in find.byType(ListView).evaluate()) {
        final d = (e.widget as ListView).childrenDelegate;
        if (d is SliverChildBuilderDelegate && d.childCount != null) {
          counts.add(d.childCount!);
        }
      }
      expect(counts.any((c) => c >= manyTags.length), isTrue,
          reason: '标签行必须把全部标签塞进横向 ListView 才能滑动查看');

      final plusN = find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^\+\d+$').hasMatch(w.data ?? ''),
      );
      expect(plusN, findsNothing, reason: '不应再有不可点的 +N 占位卡');
    });

    MediaItem creditItem() => MediaItem(
      id: 'm2',
      name: 'IPZZ-077 测试影片',
      type: MediaType.movie,
      overview: '简介',
      colors: [const Color(0xFF3366CC), const Color(0xFF101010)],
      director: 'うさぴょん。',
      studio: 'IDEA POCKET',
      people: [const CastMember(name: '三上悠亜')],
    );

    testWidgets('导演/制造商独立成行，演员行不再混入制作信息', (tester) async {
      await pumpDetail(tester, creditItem());

      expect(find.text('导演 / 制造商'), findsOneWidget);
      expect(find.text('演员'), findsOneWidget);
      expect(find.text('导演 うさぴょん。'), findsOneWidget);
      expect(find.text('制造商 IDEA POCKET'), findsOneWidget);
      expect(find.text('三上悠亜'), findsOneWidget);

      // 两个独立横向胶囊行：制作信息行 2 项、演员行 1 项。
      // 混排时会是一个 3 项的行，这里同时排除它。
      final counts = <int>[];
      for (final e in find.byType(ListView).evaluate()) {
        final lv = e.widget as ListView;
        final d = lv.childrenDelegate;
        if (lv.scrollDirection == Axis.horizontal &&
            d is SliverChildBuilderDelegate &&
            d.childCount != null) {
          counts.add(d.childCount!);
        }
      }
      expect(counts, contains(2), reason: '导演 + 制造商必须独占一行');
      expect(counts, contains(1), reason: '演员必须独占一行');
      expect(counts.contains(3), isFalse, reason: '不应再出现三者混排');
    });

    Future<void> tapCredit(
      WidgetTester tester,
      String capText,
      String expectedTitle,
    ) async {
      await pumpDetail(tester, creditItem());
      final finder = find.text(capText);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text(expectedTitle), findsOneWidget,
          reason: '点 $capText 应打开对应的全库筛选页');
    }

    testWidgets('点导演胶囊 → 按导演筛出全库影片', (tester) async {
      await tapCredit(tester, '导演 うさぴょん。', '导演 · うさぴょん。');
    });

    testWidgets('点制造商胶囊 → 按制造商筛出全库影片', (tester) async {
      await tapCredit(tester, '制造商 IDEA POCKET', '制造商 · IDEA POCKET');
    });

    testWidgets('超长系列名用省略号缩略，不撑破三列', (tester) async {
      const longName = '濃厚な接吻とSEX 特別完全版 ディレクターズカット ブルーレイ 限定版 長すぎるシリーズ名';
      await pumpDetail(
        tester,
        MediaItem(
          id: 'm3',
          name: '测试影片',
          type: MediaType.movie,
          overview: '简介',
          colors: [const Color(0xFF3366CC), const Color(0xFF101010)],
          seriesName: longName,
        ),
      );

      final text = find.byWidgetPredicate(
        (w) => w is Text && w.data == longName,
      );
      expect(text, findsOneWidget);
      final w = text.evaluate().single.widget as Text;
      expect(w.maxLines, 1);
      expect(w.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull, reason: '长系列名不能造成布局溢出');
    });
  });
}

/// URL 派生单独放这里，避免 group 内 test 定义顺序干扰阅读。
void testURLDerivation() {
  test('http 直链换扩展名为 .nfo 并保留 query', () {
    expect(
      nfoUrlFromMediaPath(
        'http://192.168.5.29:5445/d/movies/IPZZ-077-C.mp4?sign=abc',
      ),
      'http://192.168.5.29:5445/d/movies/IPZZ-077-C.nfo?sign=abc',
    );
  });

  test('中文路径也能派生（Uri 负责百分号编码）', () {
    final u = nfoUrlFromMediaPath('http://h/片库/IPZZ-077-C.mp4');
    expect(u, isNotNull);
    expect(Uri.decodeFull(Uri.parse(u!).path), '/片库/IPZZ-077-C.nfo');
  });

  test('.strm 与无扩展名也能派生', () {
    expect(
      nfoUrlFromMediaPath('https://h/x/ABC.strm'),
      'https://h/x/ABC.nfo',
    );
    expect(
      nfoUrlFromMediaPath('https://h/x/ABC'),
      'https://h/x/ABC.nfo',
    );
  });

  test('本地文件路径 / 目录不可派生', () {
    expect(nfoUrlFromMediaPath('/volume1/media/ABC.mp4'), isNull);
    expect(nfoUrlFromMediaPath('https://h/x/'), isNull);
  });
}
