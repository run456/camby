import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/actor_index_page.dart';
import 'package:camby/pages/person_page.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/gender_badge.dart';
import 'package:camby/widgets/library_index_segment.dart';
import 'package:camby/widgets/media_filter_sheet.dart';

/// v2.0.61 演员详情页改造回归（用户确认：方案 A / 头像框 A / S1 / G4 /
/// 「女演员」标注近似 / 总数 A / ①② 一并修）。
///
/// 三条反馈的根因：
///  ① 演员总览 ClipOval 在 loose 约束下变竖椭圆 → 补 tight 正方形约束
///  ② 详情页把 ♀ 写死成每个演员的默认装饰 → 改按 gender 渲染，无则中性
///  ③ 200px 小头像放大成 340dp 满幅 banner + 无参演总数 → 资料卡 + 吸顶筛选
void main() {
  MediaItem mk(
    String id, {
    List<CastMember> people = const [],
    int year = 2020,
    MediaType type = MediaType.movie,
  }) =>
      MediaItem(
        id: id,
        name: '影片$id',
        type: type,
        overview: '简介',
        colors: const [Color(0xFF3366CC), Color(0xFF101010)],
        people: people,
        year: year,
      );

  const p1 = CastMember(name: '三上悠亜', id: 'p1', imageTag: 't1');

  // a/b/c 含 p1（3 部），d 不含 —— 本地聚合总数应为 3
  AppState stateWith() => AppState()
    ..installTestItems([
      mk('a', people: const [p1], year: 2021),
      mk('b', people: const [p1], year: 2022),
      mk('c', people: const [p1], year: 2023, type: MediaType.series),
      mk('d', people: const [CastMember(name: '别人')], year: 2020),
    ]);

  Future<void> pumpPerson(
    WidgetTester tester, {
    required CastMember person,
    required AppState state,
    double width = 393,
    double height = 852,
  }) async {
    tester.view.physicalSize = Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: PersonPage(
            person: person,
            state: state,
            onOpenDetail: (_, {String? heroTag}) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpActors(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ActorIndexPage(
            state: state,
            onOpenDetail: (_, {String? heroTag}) {},
            tab: LibraryIndexTab.actors,
            onTabChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // ---------------- 源码守卫 ----------------

  group('源码守卫', () {
    test('② 详情页演员行不再写死 ♀，改按 genderLeading(p.gender) 渲染', () {
      final detail = File('lib/pages/detail_page.dart').readAsStringSync();
      expect(detail.contains('leading: genderLeading(p.gender)'), isTrue,
          reason: 'G4：按服务端 gender 渲染，未知走中性');
      expect(detail.contains('leading: const Text('), isFalse,
          reason: '演员胶囊前缀不能再是硬编码的 Text');
      expect(detail.contains('统一用 ♀'), isFalse,
          reason: '旧注释「统一用 ♀ 造型符号」必须移除');
    });

    test('CastMember 增 gender + 保守归一；emby_client 解析性别、头像可传 maxWidth',
        () {
      final models = File('lib/models.dart').readAsStringSync();
      expect(models.contains('final String? gender'), isTrue);
      expect(models.contains('String? normalizeGender('), isTrue);
      expect(models.contains("const String kGenderFemale = 'female'"), isTrue);
      final client = File('lib/emby_client.dart').readAsStringSync();
      expect(client.contains('gender: normalizeGender('), isTrue);
      expect(
        client.contains(
            'String personImageUrl(String personId, String? tag, {int maxWidth = 200})'),
        isTrue,
      );
    });

    test('③ 详情页去掉 340dp 满幅 banner，改资料卡 + 吸顶筛选 + 400 头像', () {
      final src = File('lib/pages/person_page.dart').readAsStringSync();
      expect(src.contains('height: 340'), isFalse,
          reason: '满幅 340dp banner 必须删除');
      expect(src.contains('ShaderMask'), isFalse);
      expect(src.contains('_avatarFrame'), isTrue, reason: '头像框起来');
      expect(src.contains('maxWidth: 400'), isTrue, reason: '资料卡请求更大头像');
      expect(src.contains('SliverPersistentHeader'), isTrue,
          reason: '筛选条吸顶');
      expect(src.contains('pinned: true'), isTrue);
      expect(src.contains('MediaFilterButton'), isTrue,
          reason: '漏斗筛选框原样保留');
      expect(src.contains('部影片'), isTrue, reason: '资料卡大数字');
      expect(src.contains('genderLabel('), isTrue, reason: 'G4 性别徽标');
    });

    test('① 演员总览 / 收藏页头像都补 tight 正方形约束', () {
      for (final f in [
        'lib/pages/actor_index_page.dart',
        'lib/pages/favorites_page.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src.contains('SizedBox.expand('), isTrue,
            reason: '$f 图片需拿 tight 约束');
        expect(
          RegExp(r'width:\s*size,\s*height:\s*size').hasMatch(src),
          isTrue,
          reason: '$f 裁剪框需显式正方形尺寸',
        );
      }
    });

    test('⑤ 女演员档保留但标注「按头像近似」，并加了 G4 性别优先', () {
      final src = File('lib/pages/actor_index_page.dart').readAsStringSync();
      expect(src.contains('按头像近似'), isTrue);
      expect(src.contains('_isLikelyFemale(e)'), isTrue);
      expect(src.contains('e.gender == kGenderFemale'), isTrue);
    });
  });

  // ---------------- G4 纯逻辑 ----------------

  group('G4 性别归一（有则显示、无则中性、绝不猜）', () {
    test('normalizeGender 只认明确值，其余一律 null', () {
      expect(normalizeGender('Female'), kGenderFemale);
      expect(normalizeGender('f'), kGenderFemale);
      expect(normalizeGender('女'), kGenderFemale);
      expect(normalizeGender('女性'), kGenderFemale);
      expect(normalizeGender('MALE'), kGenderMale);
      expect(normalizeGender('男'), kGenderMale);
      expect(normalizeGender(null), isNull);
      expect(normalizeGender(''), isNull);
      expect(normalizeGender('unknown'), isNull);
      expect(normalizeGender('Actor'), isNull);
      expect(normalizeGender(123), isNull,
          reason: '数字编码有歧义，绝不猜');
    });

    test('genderLabel：无数据返回 null（让字段隐藏，不摆「—」）', () {
      expect(genderLabel(kGenderFemale), '女');
      expect(genderLabel(kGenderMale), '男');
      expect(genderLabel(null), isNull);
      expect(genderLabel('x'), isNull);
    });

    test('genderLeading：♀/♂ 只在明确性别时出现，未知是中性 Icon', () {
      final f = genderLeading(kGenderFemale);
      expect(f, isA<Text>());
      expect((f as Text).data, '♀');
      final m = genderLeading(kGenderMale);
      expect(m, isA<Text>());
      expect((m as Text).data, '♂');
      expect(genderLeading(null), isA<Icon>(),
          reason: '未知性别用中性人物图标，绝不默认 ♀');
      expect(genderLeading('something'), isA<Icon>());
    });

    test('CastMember.gender 序列化往返 + 旧数据向后兼容', () {
      final c = CastMember(name: 'A', id: 'i', gender: kGenderMale);
      final j = c.toJson();
      expect(j['gender'], kGenderMale);
      expect(CastMember.fromJson(j).gender, kGenderMale);
      // 旧缓存没有 gender 字段 → fromJson 得 null
      final old = CastMember.fromJson({
        'name': 'B',
        'role': '',
        'id': null,
        'imageTag': null,
      });
      expect(old.gender, isNull);
      // 脏值也归一
      expect(CastMember.fromJson({'name': 'C', 'gender': 'FEMALE'}).gender,
          kGenderFemale);
    });
  });

  // ---------------- ① 头像几何 ----------------

  group('① 头像不变形', () {
    testWidgets('演员总览所有圆形头像拿到正方形裁剪框', (tester) async {
      await pumpActors(tester, stateWith());
      final ovals = find.descendant(
        of: find.byKey(const ValueKey('actor-index-grid')),
        matching: find.byType(ClipOval),
      );
      expect(ovals, findsWidgets, reason: '网格里应有圆形头像');
      for (final e in ovals.evaluate()) {
        final s = e.size!;
        expect((s.width - s.height).abs(), lessThan(0.6),
            reason: 'ClipOval 必须是正方形，否则竖图会被裁成竖椭圆');
      }
    });
  });

  // ---------------- ③ 演员详情页 ----------------

  group('③ 资料卡 + 总数 + 吸顶筛选（方案 A / 头像框 A / S1）', () {
    testWidgets('首屏：资料卡大数字 + 字段网格 + 吸顶筛选条 + 离线总数',
        (tester) async {
      await pumpPerson(tester, person: p1, state: stateWith());

      // 资料卡大数字（总数 A：资料卡 + 筛选条双处）
      expect(find.text('部影片'), findsOneWidget);
      expect(find.text('共 3 部'), findsOneWidget,
          reason: '筛选条右侧计数');
      expect(find.text('3 部'), findsOneWidget,
          reason: '字段网格「参演」');

      // S1 字段网格：只用现有可得字段，有值才显示
      expect(find.text('参演'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('最近'), findsOneWidget);
      expect(find.text('2023年'), findsOneWidget);
      // 性别 / 别名 / 出生地无数据 → 整格隐藏，不摆「—」
      expect(find.text('性别'), findsNothing);
      expect(find.text('别名'), findsNothing);
      expect(find.text('出生地'), findsNothing);

      // 筛选框原样保留：_Seg 三段 + 漏斗
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('电影'), findsOneWidget);
      expect(find.text('剧集'), findsOneWidget);
      expect(find.byType(MediaFilterButton), findsOneWidget);
      expect(find.byType(SliverPersistentHeader), findsOneWidget,
          reason: '筛选条为吸顶 pinned header');

      // 离线：网格只用服务端列表（空），但总数仍有数，并给明确提示
      expect(find.text('作品列表需联网加载 · 本地媒体库共 3 部'),
          findsOneWidget);

      // G4：p1 无 gender → 资料卡 / 字段都不出现任何性别符号
      expect(find.text('♀ 女'), findsNothing);
      expect(find.text('♂ 男'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('滚动后吸顶筛选条仍常驻', (tester) async {
      await pumpPerson(tester, person: p1, state: stateWith());
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -260));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(SliverPersistentHeader), findsOneWidget);
      expect(find.text('共 3 部'), findsOneWidget);
      expect(find.byType(MediaFilterButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切「剧集」tab 筛选框仍可点，计数逻辑不报错', (tester) async {
      await pumpPerson(tester, person: p1, state: stateWith());
      await tester.tap(find.text('剧集'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MediaFilterButton), findsOneWidget);
      expect(find.text('共 3 部'), findsOneWidget,
          reason: '离线网格为空时保持「共 N 部」，不显示 0/N');
      expect(tester.takeException(), isNull);
    });

    testWidgets('G4：服务端给了明确性别才显示 ♀ 徽标与性别字段',
        (tester) async {
      const female = CastMember(
        name: '三上悠亜',
        id: 'p1',
        imageTag: 't1',
        gender: kGenderFemale,
      );
      await pumpPerson(tester, person: female, state: stateWith());
      expect(find.text('♀ 女'), findsOneWidget, reason: '资料卡性别徽标');
      expect(find.text('性别'), findsOneWidget, reason: '字段网格性别格');
      expect(find.text('女'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('平板（≥840dp）左资料卡 + 右作品区正常渲染', (tester) async {
      await pumpPerson(
        tester,
        person: p1,
        state: stateWith(),
        width: 1200,
        height: 1600,
      );
      expect(find.byType(PersonPage), findsOneWidget);
      expect(find.text('共 3 部'), findsOneWidget);
      expect(find.text('部影片'), findsOneWidget);
      expect(find.byType(SliverPersistentHeader), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
