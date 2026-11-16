import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/cached_image.dart';
import 'package:camby/widgets/library_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.103：用户三条反馈一起改 —— 收藏封面完整 / 收藏夹网格 + 管理弹窗
/// 可点进 / 媒体库 chip 横滑 6 个 / 弹窗卡片换成「最近的影片封面」。
///
/// 这里锁住最容易悄悄改坏的部分：弹窗封面**不能**再只靠 parentId 匹配
/// （标准 Emby 的 ParentId 常指向库内文件夹），必须复用按库预览缓存；
/// 以及数量不能拿预览条数假报。
String src(String path) => File(path).readAsStringSync();

MediaItem _item(
  String id, {
  String? parentId,
  String? posterUrl,
  int addedDaysAgo = 0,
}) => MediaItem(
  id: id,
  name: '片 $id',
  type: MediaType.movie,
  overview: '',
  colors: const [Color(0xFF112233)],
  parentId: parentId,
  posterUrl: posterUrl,
  addedDaysAgo: addedDaysAgo,
);

/// 假服务端：故意让条目 parentId 指向「库内文件夹」而不是 UserView，
/// 复现真机上弹窗全部退化成库名首字的场景。
class _PreviewServer extends EmbyServer {
  _PreviewServer()
    : super(
        host: 'h',
        port: 8096,
        secure: false,
        username: 'u',
        password: 'p',
        kind: ServerKind.emby,
      );

  final previewCalls = <String>[];
  final itemsCalls = <String>[];

  @override
  Future<List<MediaItem>> libraryPreview(
    String viewId, {
    int limit = 12,
  }) async {
    previewCalls.add(viewId);
    return [
      _item(
        '$viewId-new',
        parentId: 'folder-$viewId',
        posterUrl: 'http://img/$viewId-new.jpg',
        addedDaysAgo: 1,
      ),
      _item(
        '$viewId-old',
        parentId: 'folder-$viewId',
        posterUrl: 'http://img/$viewId-old.jpg',
        addedDaysAgo: 9,
      ),
    ];
  }

  @override
  Future<List<MediaItem>> libraryItems(
    String viewId, {
    String sortBy = 'DateCreated',
  }) async {
    itemsCalls.add(viewId);
    return [
      _item(
        '$viewId-a',
        parentId: 'folder-$viewId',
        posterUrl: 'http://img/$viewId-a.jpg',
        addedDaysAgo: 2,
      ),
      _item(
        '$viewId-b',
        parentId: 'folder-$viewId',
        posterUrl: 'http://img/$viewId-b.jpg',
        addedDaysAgo: 7,
      ),
    ];
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppState.disablePersistence = true;
  });
  tearDown(() {
    AppState.disablePersistence = false;
  });

  group('按库最近封面 · 数据层', () {
    test('未连接服务器时预热安全返回，不抛也不发请求', () async {
      final s = AppState();
      await s.prewarmViewPreviews();
      expect(s.viewPosterUrls('v1'), isEmpty);
      expect(s.viewCountFor('v1'), 0);
    });

    test('parentId 命中时按入库时间新→旧、去重、跳过无海报', () {
      final s = AppState();
      s.installTestViews([const LibraryView(id: 'v1', name: '电影')]);
      s.installTestItems([
        _item('a', parentId: 'v1', posterUrl: 'u-old', addedDaysAgo: 20),
        _item('b', parentId: 'v1', posterUrl: 'u-new', addedDaysAgo: 1),
        _item('c', parentId: 'v1', posterUrl: '', addedDaysAgo: 0),
        _item('d', parentId: 'v1', posterUrl: 'u-new', addedDaysAgo: 2),
      ]);
      expect(s.viewPosterUrls('v1'), ['u-new', 'u-old']);
      expect(s.viewCountFor('v1'), 4);
    });

    test('parentId 不命中时，全量库缓存仍能给出封面与真实数量', () async {
      final s = AppState();
      final server = _PreviewServer();
      s.installTestServer(server, 'srv-A', const []);
      const view = LibraryView(id: 'v2', name: '本地珍藏');
      s.installTestViews([view]);
      s.installTestItems([]);

      // 没拉过全量时也别谎报成真实数
      expect(s.viewCountFor('v2'), 0);
      await s.itemsForView(view);
      expect(server.itemsCalls, ['v2']);
      expect(s.viewPosterUrls('v2'), [
        'http://img/v2-a.jpg',
        'http://img/v2-b.jpg',
      ]);
      expect(s.viewCountFor('v2'), 2);
    });

    test('limit 生效，且不会把别的库的封面串进来', () {
      final s = AppState();
      s.installTestViews([
        const LibraryView(id: 'v1', name: '电影'),
        const LibraryView(id: 'v2', name: '剧集'),
      ]);
      s.installTestItems([
        for (var i = 0; i < 5; i++)
          _item('a$i', parentId: 'v1', posterUrl: 'a$i', addedDaysAgo: i),
        _item('b0', parentId: 'v2', posterUrl: 'b0', addedDaysAgo: 0),
      ]);
      expect(s.viewPosterUrls('v1', limit: 3), ['a0', 'a1', 'a2']);
      expect(s.viewPosterUrls('v2'), ['b0']);
    });
  });

  group('弹窗渲染', () {
    testWidgets('传入 posters / counts 时显示真实封面与数量，不退化成首字', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showLibraryPickerSheet(
                    c,
                    views: const [LibraryView(id: 'v1', name: '电影')],
                    items: const [],
                    selectedId: null,
                    recentCount: 0,
                    continueCount: 0,
                    posters: const {
                      'v1': ['http://img/recent.jpg'],
                    },
                    counts: const {'v1': 12},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.text('12 部'), findsOneWidget);
      expect(find.byType(CachedImage), findsOneWidget);
      // 库名首字兜底只在没有海报时出现
      expect(find.text('电'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没传 posters 时仍用库名首字兜底（不退化成灰方块）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showLibraryPickerSheet(
                    c,
                    views: const [LibraryView(id: 'v1', name: '电影')],
                    items: const [],
                    selectedId: null,
                    recentCount: 0,
                    continueCount: 0,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.text('电'), findsOneWidget);
      expect(find.byType(CachedImage), findsNothing);
    });
  });

  group('源码守卫', () {
    test('AppState：预热复用首页预览缓存、带超时、空结果不假报', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('Future<void> prewarmViewPreviews('), isTrue);
      expect(s.contains('previewForView(v, limit: limit)'), isTrue);
      expect(
        s.contains('if (cached != null && cached.isNotEmpty) continue;'),
        isTrue,
        reason: '已缓存的库不能重复发请求',
      );
      expect(s.contains('timeout(const Duration(seconds: 3))'), isTrue);
      expect(s.contains('Future.wait(pending)'), isTrue);
      expect(s.contains('List<String> viewPosterUrls('), isTrue);
      expect(
        s.contains('a.addedDaysAgo.compareTo(b.addedDaysAgo)'),
        isTrue,
        reason: '最近的影片排最前',
      );
      expect(s.contains('int viewCountFor('), isTrue);
      expect(
        s.contains('if (full != null && full.isNotEmpty) return full.length;'),
        isTrue,
        reason: '只有全量缓存才能报真实数量',
      );
    });

    test('library_page：最多 6 个真实库可横滑 + 末尾全部媒体库 + 预热链路', () {
      final s = src('lib/pages/library_page.dart');
      expect(s.contains('_kMaxRealChips = 6'), isTrue);
      expect(s.contains('all.take(_kMaxRealChips)'), isTrue);
      expect(s.contains('..._realChips(state)'), isTrue);
      expect(s.contains('_currentRealChip'), isFalse);
      expect(
        s.contains('picked[picked.length - 1] = selected'),
        isTrue,
        reason: '选中项必须留在 6 个里，不能被滑出视野',
      );
      expect(s.contains("label: '全部媒体库'"), isTrue);
      expect(s.contains('await state.prewarmViewPreviews()'), isTrue);
      expect(s.contains('state.viewPosterUrls(v.id)'), isTrue);
      expect(s.contains('state.viewCountFor(v.id)'), isTrue);
      expect(s.contains('posters: posters'), isTrue);
      expect(s.contains('counts: counts'), isTrue);
    });

    test('library_picker_sheet：优先用传入封面，卡片是单张完整海报', () {
      final s = src('lib/widgets/library_picker_sheet.dart');
      expect(s.contains('widget.posters[v.id]'), isTrue);
      expect(s.contains('widget.counts[v.id]'), isTrue);
      expect(s.contains('previews.first'), isTrue);
      expect(s.contains('BoxFit.contain'), isTrue);
      expect(s.contains('width: 48,'), isTrue);
      expect(s.contains('height: 72,'), isTrue);
      expect(s.contains('Transform.rotate('), isFalse, reason: '3 张小图倾斜叠放已移除');
      expect(s.contains('最近入库'), isTrue,
          reason: '文档要写明封面来自最近入库的影片');
    });

    test('favorites_page：网格 + 单张完整封面 + 管理弹窗可点进', () {
      final s = src('lib/pages/favorites_page.dart');
      expect(s.contains("ValueKey('folder-grid')"), isTrue);
      expect(s.contains("ValueKey('folder-rail')"), isFalse);
      expect(s.contains('Widget _layer(int depth'), isFalse);
      expect(s.contains('BoxFit.contain'), isTrue);
      expect(s.contains('_openFolder(f.id, f.name)'), isTrue);
      expect(s.contains('isScrollControlled: true'), isTrue);
      expect(s.contains('点开即进入'), isTrue);
    });
  });

  test('版本与文档同步到 v2.0.106', () {
    expect(src('pubspec.yaml').contains('version: 2.0.106+306'), isTrue);
    expect(src('README.md').contains('v2.0.106 (306)'), isTrue);
    expect(src('CHANGELOG.md').contains('v2.0.106 (306)'), isTrue);
    expect(
      src('lib/models.dart').contains("kClientVersion = '2.0.106'"),
      isTrue,
    );
    expect(
      src('lib/dlna/dlna_protocol.dart').contains("'Camby/2.0.106 "),
      isTrue,
    );
    expect(src('VERIFICATION.md').contains('§113 发布 v2.0.103'), isTrue);
  });
}
