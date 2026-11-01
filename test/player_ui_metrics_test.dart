import 'dart:io';

import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

import 'package:camby/layout.dart';

/// v2.0.8：播放器控件度量 [PlayerUi] ——
/// 手机端必须**逐项等于**改造前的写死值（零漂移），平板端按设计稿整体放大。
void main() {
  final phone = PlayerUi.phone();
  final tablet = PlayerUi.tablet();

  test('手机端度量 = 改造前写死值（逐项回归）', () {
    expect(phone.tablet, isFalse);
    expect(phone.sideBtn, 50);
    expect(phone.sideIcon, 23);
    expect(phone.playBtn, 66);
    expect(phone.playIcon, 30);
    expect(phone.clusterGap, 26);
    expect(phone.topPadH, 14);
    expect(phone.topPadV, 8);
    expect(phone.topIcon, 15);
    expect(phone.topTitle, 13.5);
    expect(phone.topMeta, 10);
    expect(phone.topChipH, 34);
    expect(phone.topChipFont, 11);
    expect(phone.topChipPadH, 12);
    expect(phone.topIconGap, 8);
    expect(phone.topTitleGap, 10);
    expect(phone.barInset, 16);
    expect(phone.barBottom, 10);
    expect(phone.barGap, 8);
    expect(phone.barInnerGap, 10);
    expect(phone.barHitH, 34);
    expect(phone.barTrackH, 4);
    expect(phone.barActiveH, 8);
    expect(phone.timeFont, 11);
    expect(phone.chipH, 30);
    expect(phone.chipFont, 11);
    expect(phone.chipIcon, 13);
    expect(phone.chipGap, 8);
    expect(phone.tipW, 92);
    expect(phone.tipFont, 17);
    expect(phone.tipPadH, 14);
    expect(phone.tipPadV, 12);
    expect(phone.scrubFont, 32);
    expect(phone.scrubSubFont, 12);
    expect(phone.adjustW, 68);
    expect(phone.adjustEdge, 48);
    expect(phone.adjustIcon, 17);
    expect(phone.adjustBarH, 150);
    expect(phone.panelMaxW, 470);
    expect(phone.subtitleScale, 1.0);
  });

  test('平板端度量 = 设计稿（按钮/间距/字号整体放大）', () {
    expect(tablet.tablet, isTrue);
    expect(tablet.sideBtn, 56);
    expect(tablet.playBtn, 84);
    expect(tablet.clusterGap, 44);
    expect(tablet.topPadH, 26);
    expect(tablet.topPadV, 16);
    expect(tablet.barInset, 30);
    expect(tablet.barBottom, 18);
    expect(tablet.barHitH, 46);
    expect(tablet.barTrackH, 6);
    expect(tablet.barActiveH, 11);
    expect(tablet.topChipPadH, 16);
    expect(tablet.topIconGap, 12);
    expect(tablet.topTitleGap, 14);
    expect(tablet.tipW, 112);
    expect(tablet.tipFont, 21);
    expect(tablet.scrubFont, 44);
    expect(tablet.adjustW, 84);
    expect(tablet.adjustBarH, 190);
    expect(tablet.panelMaxW, 620);
    expect(tablet.subtitleScale, 1.6);
    // 平板每一项都不小于手机，且间距放大幅度 > 按钮放大幅度（设计稿意图）
    expect(
      tablet.clusterGap / phone.clusterGap,
      greaterThan(tablet.playBtn / phone.playBtn),
    );
  });

  test('of()/forSize() 按屏幕短边取档（620 为界，横屏亦不误判）', () {
    // 手机横屏 852×393 → 短边 393
    expect(PlayerUi.forSize(const Size(852, 393)).tablet, isFalse);
    // 平板横屏 2560×1600 → 短边 1600
    expect(PlayerUi.forSize(const Size(2560, 1600)).tablet, isTrue);
    // 平板竖屏 1600×2560 → 短边仍是 1600（靠短边才不会误判）
    expect(PlayerUi.forSize(const Size(1600, 2560)).tablet, isTrue);
    // 折叠屏展开 2200×1800
    expect(PlayerUi.forSize(const Size(2200, 1800)).tablet, isTrue);
    // 边界：短边正好 620 走平板
    expect(PlayerUi.forSize(const Size(1200, 620)).tablet, isTrue);
    expect(PlayerUi.forSize(const Size(1200, 619)).tablet, isFalse);
  });

  test('播放页已无遗留的播放器控件硬编码尺寸', () {
    final src = File('lib/pages/player_page.dart').readAsStringSync();
    // 顶/底栏与中央控件组必须走度量，不能出现写死的旧值
    final banned = <String>[
      'SizedBox(width: 26)', // clusterGap
      'width: 66', // playBtn
      'width: 92', // tipW
      'fontSize: 17', // tipFont
      'width: 68', // adjustW
      'left: 48', // adjustEdge
      'height: 150', // adjustBarH
      'height: 34', // 进度条热区
      'fontSize: 10.5', // 缓冲速率字号
    ];
    for (final b in banned) {
      expect(src.contains(b), isFalse, reason: '播放页遗留硬编码 $b');
    }
    // 度量必须真的被用上
    expect(src.contains('PlayerUi.of(context)'), isTrue);
    expect(src.contains('import \'../layout.dart\''), isTrue);
  });
}
