import 'package:camby/app_state.dart';
import 'package:camby/pages/subtitle_filter_page.dart';
import 'package:camby/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('中文字幕筛选页渲染', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: SubtitleFilterPage(
          state: state,
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('中文字幕'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
