import 'package:camby/app_state.dart';
import 'package:camby/pages/favorites_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('收藏页方案B：堆叠墙渲染无溢出', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = AppState();
    final favs = state.items.take(4).toList();
    for (final f in favs) {
      await state.toggleFavorite(f);
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: FavoritesPage(
          state: state,
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('影片收藏'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // v1.7.70 守卫：影片收藏墙一行 3 个
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('movies')),
    );
    final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);

    await expectLater(
      find.byType(FavoritesPage),
      matchesGoldenFile('goldens/favorites_wall.png'),
    );
  });

  testWidgets('演员收藏 Tab 渲染', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: FavoritesPage(
          state: state,
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('演员收藏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('还没有收藏演员'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(FavoritesPage),
      matchesGoldenFile('goldens/favorites_actors.png'),
    );
  });
}
