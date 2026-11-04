// 滚动降级 回归测试（v2.0.42 起，v2.0.44 调整分工）。
//
// 详情页实时模糊共 4 处：顶栏 3 个圆钮 + 状态栏带（底部那条已在 v2.0.43 移除）。
// v2.0.44 起按用户要求拆分：
//   - **状态栏带不再降级**，与首页（main.dart shell）完全一致，始终实时模糊；
//   - **3 个圆钮仍降级**（滚动时换纯渐变），它们才是压在滚动内容上的小面积模糊。
import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';
import 'package:camby/theme.dart';
import 'package:camby/widgets/status_bar_blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: child),
);

/// 内容足够长、能滚动的样例影片
MediaItem _longMovie() => MediaItem(
  id: 'macc-scroll-1',
  name: '滚动测试影片',
  type: MediaType.movie,
  overview: '用于验证滚动降级的样例。' * 20,
  colors: const [Color(0xFF204A80), Color(0xFF0C1524)],
  genres: const ['剧情', '悬疑'],
  year: 2021,
  runtimeMin: 120,
  backdrops: const [
    'https://example.invalid/b0.jpg',
    'https://example.invalid/b1.jpg',
  ],
  people: const [
    CastMember(name: '演员甲', role: '主演'),
    CastMember(name: '演员乙', role: '配角'),
  ],
);

void main() {
  testWidgets('手机详情页：滚动时圆钮降级，状态栏保持实时模糊', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        DetailPage(
          item: _longMovie(),
          state: AppState(),
          onPlay: (item, subtitle, {resume = false}) {},
          onPlayPart: (item, part) {},
          onOpenDetail: (_, {String? heroTag}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    StatusBarBlur blur() =>
        tester.widget<StatusBarBlur>(find.byType(StatusBarBlur));

    /// 顶栏圆钮的磨砂层（整页只有圆钮用 ClipOval 包 BackdropFilter）
    int glassButtons() => find
        .descendant(
          of: find.byType(ClipOval),
          matching: find.byType(BackdropFilter),
        )
        .evaluate()
        .length;

    // ── 静止 ──
    expect(blur().degraded, isFalse);
    expect(blur().sigma, 30, reason: 'sigma 应与首页一致（默认 30）');
    expect(glassButtons(), 3, reason: '静止时 3 个圆钮都带磨砂');

    // ── 拖动内容（从「剧情简介」起手，确保落在滚动区内）──
    await tester.drag(find.text('剧情简介'), const Offset(0, -260));
    await tester.pump();

    expect(blur().degraded, isFalse, reason: '状态栏与首页一致，滚动时不应降级');
    expect(glassButtons(), 0, reason: '滚动时 3 个圆钮降级为纯渐变');

    // ── 停下：等惯性 + 180ms 静默 ──
    // 不能用 pumpAndSettle：页面里有循环动画（占位图呼吸），永远不收敛。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(glassButtons(), 3, reason: '停下后圆钮恢复磨砂');
    expect(tester.takeException(), isNull);
  });
}
