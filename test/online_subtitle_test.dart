// v2.0.45 · 在线字幕集成回归测试
//
// 守住三件事：
// 1. 文件名清理 / 编码解码 / 内联标签这些纯逻辑，改坏了字幕会乱码或搜不到；
// 2. 弹层必须复用播放页的玻璃面板（居中卡片 + 手机/平板限宽），
//    不能退回底部抽屉或写死 68% 高度；
// 3. GBK 解码器注入、在线字幕状态字段这些「静默失败」点必须一直在。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';

import 'package:camby/subtitles/online_subtitle.dart';
import 'package:camby/subtitles/subtitles.dart';
import 'package:camby/widgets/glass_sheet.dart';

void main() {
  setUp(() {
    OnlineSubtitleConfig.gbkDecoder = null;
  });
  tearDown(() {
    OnlineSubtitleConfig.gbkDecoder = null;
  });

  group('文件名清理', () {
    test('画质 / 编码标签与扩展名被剥掉，保留片名 + 年份', () {
      expect(
        OnlineSubtitleService.cleanTitle(
            'Inception.2010.1080p.BluRay.x264.mkv'),
        'Inception 2010',
      );
    });

    test('站点前缀、方括号、末尾分隔标签', () {
      expect(
        OnlineSubtitleService.cleanTitle('[电影天堂www.dy.com]@SAME-008-C.mp4'),
        'SAME-008-C',
      );
      expect(
        OnlineSubtitleService.cleanTitle('Movie.Name.720p.BluRay.mkv'),
        'Movie Name',
      );
    });

    test('剧集：传入季集号时拼 SxxExx', () {
      expect(
        OnlineSubtitleService.cleanTitle('Breaking.Bad.mkv',
            season: 1, episode: 2),
        'Breaking Bad S01E02',
      );
      expect(
        OnlineSubtitleService.cleanTitle('Some.Show.mkv', season: 3),
        'Some Show S03',
      );
    });

    test('文件名已带 SxxExx 时不重复拼（否则搜不到）', () {
      expect(
        OnlineSubtitleService.cleanTitle('Show.S01E02.1080p.mkv',
            season: 1, episode: 2),
        'Show S01E02',
      );
    });

    test('番号提取', () {
      expect(OnlineSubtitleService.extractCode('SAME-008-C'), 'SAME-008');
      expect(OnlineSubtitleService.extractCode('ABCD123 中文字幕'), 'ABCD-123');
      expect(OnlineSubtitleService.extractCode('Inception 2010'), isEmpty);
    });
  });

  group('编码与文本清洗', () {
    test('UTF-8 与 UTF-8 BOM', () {
      expect(OnlineSubtitleService.decodeBytes(utf8.encode('中文字幕')),
          '中文字幕');
      expect(
        OnlineSubtitleService.decodeBytes(
            [0xEF, 0xBB, 0xBF, ...utf8.encode('带 BOM')]),
        '带 BOM',
      );
    });

    test('GBK 字幕：注入解码器后中文正确', () {
      OnlineSubtitleConfig.gbkDecoder = (bytes) => gbk_bytes.decode(bytes);
      final bytes = gbk.encode('时代华纳电影公司');
      // 先确认 fixture 确实不是合法 UTF-8，否则这条测试没有意义
      expect(() => utf8.decode(bytes), throwsFormatException);
      expect(OnlineSubtitleService.decodeBytes(bytes), '时代华纳电影公司');
    });

    test('未注入解码器：退化 latin1，中文乱码但时间轴仍可解析', () {
      const head = '1\r\n00:00:01,000 --> 00:00:02,000\r\n';
      final bytes = <int>[...utf8.encode(head), ...gbk.encode('中文字幕')];
      final decoded = OnlineSubtitleService.decodeBytes(bytes);
      expect(decoded, isNot(contains('中文字幕')));
      // ASCII 时间轴不受影响，叠加层至少还能对上时间（这也是「静默失败」的表现）
      final cues = Subtitles.parseAny(decoded);
      expect(cues.length, 1);
      expect(cues.single.start, 1.0);
    });

    test('SRT 内联标签与 &nbsp; 被去掉（叠加层是纯 Text）', () {
      expect(
        OnlineSubtitleService.stripInlineTags(
            '<font color="#4096d1">时代华纳</font>&nbsp;<b>公司</b>'),
        '时代华纳 公司',
      );
      expect(
        OnlineSubtitleService.stripInlineTags('<i>斜体</i><u>下划线</u>'),
        '斜体下划线',
      );
    });

    test('语言标签', () {
      expect(OnlineSubtitleService.langLabel('zh-CN'), '简体中文');
      expect(OnlineSubtitleService.langLabel('en'), 'English');
      expect(OnlineSubtitleService.langLabel('und'), '未知');
      expect(OnlineSubtitleService.langLabel('xx'), 'XX');
    });
  });

  group('数据模型', () {
    test('isChinese / isAss 便捷判定', () {
      const zh = OnlineSubtitle(
        id: 'x',
        title: 'x',
        source: OnlineSubtitleSource.xunlei,
        url: 'https://example.invalid/a.srt',
        format: 'srt',
        language: 'zh-CN',
      );
      expect(zh.isChinese, isTrue);
      expect(zh.isAss, isFalse);
      expect(zh.source.label, '迅雷');

      const ass = OnlineSubtitle(
        id: 'y',
        title: 'y',
        source: OnlineSubtitleSource.subtitleCat,
        url: 'https://example.invalid/b.SSA',
        format: 'ssa',
        language: 'en',
      );
      expect(ass.isChinese, isFalse);
      expect(ass.isAss, isTrue);
      expect(ass.source.label, 'SubtitleCat');
    });
  });

  group('弹层外观：玻璃面板 + 手机/平板限宽', () {
    Future<void> pumpAt(WidgetTester tester, Size size,
        {bool blur = false}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GlassPanel(
            blur: blur,
            // 故意给一个远超上限的宽度，验证约束真的生效
            child: const SizedBox(width: 1200, height: 100),
          ),
        ),
      ));
      await tester.pump();
    }

    double panelWidth(WidgetTester tester) => tester
        .getSize(find.descendant(
          of: find.byType(GlassPanel),
          matching: find.byType(Container),
        ).first)
        .width;

    testWidgets('手机（短边 <620）：面板不超过 470', (tester) async {
      await pumpAt(tester, const Size(430, 932));
      expect(panelWidth(tester), lessThanOrEqualTo(470));
      expect(panelWidth(tester), greaterThan(400));
    });

    testWidgets('平板（短边 ≥620）：面板不超过 620，不拉满整屏', (tester) async {
      await pumpAt(tester, const Size(1200, 800));
      expect(panelWidth(tester), lessThanOrEqualTo(620));
      expect(panelWidth(tester), greaterThan(560));
    });

    // v2.0.51：blur:true 必须真的产生背景磨砂（BackdropFilter），而不是只挂个
    // flag 走回高不透明纯色卡片——这正是「搜索字幕弹窗不是液态玻璃」的根因。
    testWidgets('blur:true 走 BackdropFilter，blur:false 为纯色卡片', (tester) async {
      await pumpAt(tester, const Size(430, 932), blur: true);
      expect(find.byType(BackdropFilter), findsOneWidget,
          reason: '液态玻璃必须真的做背景模糊');

      await pumpAt(tester, const Size(430, 932), blur: false);
      expect(find.byType(BackdropFilter), findsNothing,
          reason: '播放器弹层保持无模糊（性能）');
    });
  });

  group('源码守卫：静默失败点', () {
    test('在线字幕弹层走居中玻璃面板，不再是底部抽屉', () {
      final src = File('lib/subtitles/online_subtitle.dart').readAsStringSync();
      expect(src.contains('showModalBottomSheet'), isFalse,
          reason: '底部抽屉在横屏会压住进度条、平板上会拉成整屏色块');
      expect(src.contains('GlassPanelRoute<OnlineSubtitle>'), isTrue);
      expect(src.contains('GlassPanel('), isTrue);
      expect(src.contains('SheetRow('), isTrue);

      final glass = File('lib/widgets/glass_sheet.dart').readAsStringSync();
      expect(glass.contains('maxWidth: PlayerUi.of(context).panelMaxW'), isTrue,
          reason: '玻璃面板组件必须按短边断点限宽（手机 470 / 平板 620）');
    });

    test('v2.0.51：在线字幕搜索弹窗玻璃面板开启真实磨砂（blur:true）', () {
      final src = File('lib/subtitles/online_subtitle.dart').readAsStringSync();
      // 锁死 _OnlineSubtitleSheet 里的 GlassPanel 必须传 blur:true，避免退化成
      // 默认 blur:false 的高不透明纯色卡片（用户反馈「搜索字幕弹窗不是液态玻璃」）。
      final panelCall = RegExp(
        r'GlassPanel\(\s*blur:\s*true\s*,',
      );
      expect(panelCall.hasMatch(src), isTrue,
          reason: '在线字幕弹层的 GlassPanel 必须 blur:true，做真正的背景磨砂');
    });

    test('播放页：在线字幕状态 + 菜单入口 + 二次 mounted 检查', () {
      final src = File('lib/pages/player_page.dart').readAsStringSync();
      expect(src.contains('OnlineSubtitle? _onlineSubtitle'), isTrue);
      expect(src.contains("'在线搜索字幕…'"), isTrue);
      expect(src.contains(r"_subtitleFromCache ? '本机' : '在线'"), isTrue,
          reason: '底栏 chip 应区分「本机」缓存与「在线」现搜');
      expect(src.contains(r"'} · ${online.source.label}"), isTrue,
          reason: '_subInfoText 应区分本机/在线来源（在线/本机 后接 source.label）');
      // 下载期间退出播放页 → 第二个 await 之后必须再查一次 mounted
      final secondAwaitGuard = RegExp(
        r'setSubtitle\(null\);[\s\S]{0,240}?if \(!context\.mounted\) return;',
      );
      expect(secondAwaitGuard.hasMatch(src), isTrue,
          reason: 'await 之后再 setState 前必须校验 mounted');
    });

    test('GBK 解码器注入 + 依赖 + 上游许可 + 版本号', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('OnlineSubtitleConfig.gbkDecoder'), isTrue);
      expect(main.contains('gbk_bytes.decode'), isTrue);

      final pub = File('pubspec.yaml').readAsStringSync();
      expect(pub.contains('gbk_codec: ^0.4.0'), isTrue);
      expect(pub.contains('version: 2.0.55+255'), isTrue);

      final license = File('licenses/LICENSE-UPSTREAM.txt');
      expect(license.existsSync(), isTrue,
          reason: 'MIT 要求分发时随附许可全文');
      final text = license.readAsStringSync();
      expect(text.contains('Copyright (c) 2024 Exhen & Contributors'), isTrue,
          reason: '版权人必须原样保留');
      expect(text.contains('MIT License'), isTrue);
    });
  });
}
