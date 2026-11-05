import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:camby/pages/detail_page.dart';

const _ppChannel = MethodChannel('plugins.flutter.io/path_provider');

/// v2.0.52 回归：手机详情页「继续播放 / 剧情简介」必须紧跟标题块，不能被推到
/// 海报底部之后。
///
/// 背景：v2.0.51 把标题块从 `Transform.translate` 改成 `Stack` 里的 Positioned，
/// 修好了标题旁翻译按钮点不动，但作为 ListView 第一个 child 的 Stack 仍占「完整
/// 海报高度 posterH」，标题块只是压在海报内部，后续板块却从 posterH 之后才排 →
/// 中间凭空空出 titleLift（56~150px）。修复是把第一个 child 的布局占位缩短为
/// `posterH - titleLift`（SizedBox + OverflowBox 让内部 Stack 仍以 posterH 布局并
/// 溢出显示），后续板块自然上抬；且不用 Transform，布局/视觉位置一致，按钮仍可点。
void main() {
  late final Directory docsDir;
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = Directory.systemTemp.createTempSync('camby_banner_docs');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ppChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return docsDir.path;
      }
      return null;
    });
  });

  testWidgets('手机布局：继续播放紧跟标题块，且按钮仍可点击', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 强制手机布局（width < 840），与用户截图一致
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    // 与 build() 中同款计算
    const width = 390.0;
    const posterAspect = 0.6667;
    final posterH = width / posterAspect;
    final titleLift = (posterH * 0.18).clamp(56.0, 150.0);

    final item = MediaItem(
      id: 'm1',
      name: 'ABF-072 どちゃくそエロい最高級ギャル',
      type: MediaType.movie,
      overview: '一段用于布局测试的剧情简介。',
      colors: [const Color(0xFF3366CC), const Color(0xFF101010)],
      resumeProgress: 0.11, // 让播放按钮文案为「继续播放」
    );

    var playTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: item,
          onPlay: (_, _, {bool resume = false}) => playTaps++,
          onPlayPart: (_, _) {},
          state: AppState(),
          onOpenDetail: (_, {heroTag}) {},
        ),
      ),
    );
    // DetailPage 有持续动画定时器，pumpAndSettle 会超时，手动 pump
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final titleRect = tester.getRect(find.text(item.name));
    final playRect = tester.getRect(find.text('继续播放'));
    final posterRect = tester.getRect(find.byType(AspectRatio).first);
    final synopsisRect = tester.getRect(find.text('剧情简介').first);
    final gap = playRect.top - titleRect.bottom;

    // 核心：播放行必须落在「缩短后的 banner 占位」附近，而不是完整海报之后。
    // 修复前 play.top ≈ posterH + 16（≈601），修复后 ≈ posterH - titleLift + 20（≈512）。
    expect(playRect.top, lessThan(posterH - titleLift + 60),
        reason: '继续播放按钮不能仍排在完整海报底部之后（应与标题块紧贴）');
    // 用户感知：标题 → 播放按钮的垂直距离不应被拉开到 150px 以上。
    expect(gap, lessThan(150),
        reason: '继续播放离标题太远（v2.0.51 的空白间距回归）');
    // 剧情简介（用户说的「信息页」）同样要跟着上移，不能留在海报底部之后。
    expect(synopsisRect.top - playRect.top, lessThan(120),
        reason: '剧情简介卡片应紧跟播放行，不能被 banner 空白推开');
    // 缩短的是「布局占位」，海报本身仍须按原始比例完整显示（不能被压扁/裁切）。
    expect(posterRect.height, closeTo(posterH, 1.0),
        reason: 'OverflowBox 方案不能改变海报的实际渲染高度');

    // 布局修复不能重演 v2.0.51 的命中测试错位：播放按钮仍必须可点。
    await tester.tap(find.text('继续播放'), warnIfMissed: true);
    await tester.pump();
    expect(playTaps, 1,
        reason: '缩短 banner 布局占位后继续播放按钮仍必须能收到点击');
  });
}
