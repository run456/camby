import 'package:camby/app_state.dart';
import 'package:camby/widgets/folder_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 收藏夹弹窗 v2（v1.7.43）
///
/// 覆盖两件事：
/// 1. 红心胶囊的语义 —— 取消收藏必须同时把这条片子从所有收藏夹里摘掉，
///    重新收藏时不能「凭空」回到原来的夹子（这是 v1 只能收藏不能取消的根因）；
/// 2. 内联新建 —— 弹层里直接建夹子并并入选，不再走二级对话框。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState state;
  late String itemId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // path_provider 在 flutter test 里会挂起，收藏夹持久化改成只写内存
    AppState.disablePersistence = true;
    state = AppState();
    itemId = state.items.first.id;
  });

  group('收藏夹归属', () {
    test('多选归属：一条片子可同时进多个夹子', () async {
      final a = await state.createFolder('想看');
      final b = await state.createFolder('二刷');
      await state.setItemFolders(itemId, {a.id, b.id});
      expect(state.folderIdsOfItem(itemId), containsAll([a.id, b.id]));
    });

    test('取消勾选会从对应夹子移除', () async {
      final a = await state.createFolder('想看');
      final b = await state.createFolder('二刷');
      await state.setItemFolders(itemId, {a.id, b.id});
      await state.setItemFolders(itemId, {a.id});
      expect(state.folderIdsOfItem(itemId), {a.id});
      expect(state.folders.firstWhere((f) => f.id == b.id).itemIds, isEmpty);
    });

    test('取消收藏会连带清空收藏夹归属', () async {
      final a = await state.createFolder('想看');
      final item = state.items.firstWhere((e) => e.id == itemId);
      await state.toggleFavorite(item); // 收藏
      await state.setItemFolders(itemId, {a.id});
      expect(state.folderIdsOfItem(itemId), {a.id});

      await state.toggleFavorite(
        state.items.firstWhere((e) => e.id == itemId),
      ); // 取消
      expect(state.folderIdsOfItem(itemId), isEmpty);
    });

    test('重新收藏不会回到原夹子（取消已经清干净了）', () async {
      final a = await state.createFolder('想看');
      final item = state.items.firstWhere((e) => e.id == itemId);
      await state.toggleFavorite(item);
      await state.setItemFolders(itemId, {a.id});
      await state.toggleFavorite(
        state.items.firstWhere((e) => e.id == itemId),
      );
      await state.toggleFavorite(
        state.items.firstWhere((e) => e.id == itemId),
      );
      expect(state.folderIdsOfItem(itemId), isEmpty);
      expect(
        state.items.firstWhere((e) => e.id == itemId).userFavorite,
        isTrue,
      );
    });
  });

  group('弹层交互', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => Center(
                child: TextButton(
                  onPressed: () => showFolderSheet(c, state, state.items.first),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('打开后头部是「已收藏」红心 + 内联输入行', (tester) async {
      await open(tester);
      expect(find.text('已收藏'), findsOneWidget);
      expect(find.text('新建收藏夹，回车创建'), findsOneWidget);
      expect(find.text('创建'), findsOneWidget);
    });

    testWidgets('点红心切换成「收藏」，再点回「已收藏」', (tester) async {
      await open(tester);
      await tester.tap(find.text('已收藏'));
      await tester.pumpAndSettle();
      // toast 自带 1.6s 定时器，不消化掉会在测试收尾时报 pending timer
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('已收藏'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('内联输入行回车即建夹并选中', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '周末片单');
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(state.folders.map((f) => f.name), contains('周末片单'));
      // 选中是弹层里的草稿态，点「完成」才写回
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(
        state.folderIdsOfItem(itemId),
        contains(state.folders.firstWhere((f) => f.name == '周末片单').id),
      );
    });

    testWidgets('超过 20 字在提交时截断，不会挤爆输入行', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '这是一个特别特别长的收藏夹名字超过二十个字了呀');
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      final f = state.folders.firstWhere((e) => e.name.startsWith('这是一个'));
      expect(f.name.length, 20);
    });
  });
}
