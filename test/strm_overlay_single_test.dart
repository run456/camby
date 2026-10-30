import 'dart:io';

import 'package:camby/player/boot_watch.dart';
import 'package:camby/player/playback.dart';
import 'package:flutter_test/flutter_test.dart';

/// 起播加载弹窗「只有一套」+ 两个出口真的能用的守卫（v1.7.55）
///
/// 修的是用户报的两个真 bug，根因是同一件事：
///
///   1. **两套弹窗同时存在**：`strm_loading_dialog.dart`（独立路由，盖在播放页
///      上面）和播放页自己的 `_bootOverlay()`（黑屏期的小胶囊）。两套各记各的
///      计时，用户看到的就是「一会一个样式」。
///   2. **点「切换 Exo」没反应、超时也不自动切**：那个弹窗是**另一个路由**，
///      它的「切内核」只是把自己的路由 pop 掉、顺手调一下播放页的方法；
///      而真正卡在 MPV 上的播放页 State 一点没变。再加 `_switchEngine()` 是
///      **取反**语义（当前是 Exo 时会切回 MPV），点一次等于没点。
///
/// 现在弹窗由播放页自己渲染（`StrmBootOverlay`），切内核与超时回退都在同一
/// 个 State 里，出口只有一条。这些都没有异常可抓，所以守源码结构。
void main() {
  late String player;
  late String mainSrc;
  late String overlay;

  setUpAll(() {
    player = File('lib/pages/player_page.dart').readAsStringSync();
    mainSrc = File('lib/main.dart').readAsStringSync();
    overlay = File('lib/widgets/strm_boot_overlay.dart').readAsStringSync();
  });

  group('只有一套加载弹窗', () {
    test('旧的独立弹窗文件已经删掉', () {
      expect(
        File('lib/widgets/strm_loading_dialog.dart').existsSync(),
        isFalse,
        reason: '它和播放页内嵌的那套会同时出现，是「两种弹窗」的根源',
      );
    });

    test('main.dart 不再自己推载荷弹窗', () {
      expect(mainSrc.contains('showStrmLoading'), isFalse);
      expect(mainSrc.contains('_bootWithDialog'), isFalse);
    });

    test('播放页里不再有旧的胶囊加载层', () {
      expect(
        player.contains('_bootOverlay()'),
        isFalse,
        reason: '旧胶囊与 StrmBootOverlay 是同一件事的两份实现',
      );
    });

    test('播放页只渲染 StrmBootOverlay 这一套', () {
      expect(player.contains('StrmBootOverlay('), isTrue);
      expect(
        'StrmBootOverlay('.allMatches(player).length,
        1,
        reason: '出现两次说明又分叉出第二套了',
      );
    });
  });

  group('切 Exo / 自动回退都能真的执行', () {
    test('switchToExo 显式切到 exo，而不是「取反当前内核」', () {
      final body = _slice(player, 'Future<void> switchToExo() async {');
      expect(
        body.contains('PlaybackEngine.exo'),
        isTrue,
        reason: '必须按目标内核显式切；取反的写法在已是 Exo 时会切回 MPV',
      );
      expect(body.contains('_switchTo(PlaybackEngine.exo'), isTrue);
    });

    test('自动回退也走显式的 _switchTo(exo)', () {
      final body = _slice(player, 'Future<void> _autoFallbackToExo() async {');
      expect(body.contains('_switchTo(PlaybackEngine.exo'), isTrue);
    });

    test('切到 Exo 后不再复位自动回退标记（否则 10 秒后又被切一次）', () {
      final body = _slice(player, 'Future<void> _switchTo(');
      // 只允许「切到 MPV 时复位」，不能无条件复位
      expect(
        RegExp(r'if \(target == PlaybackEngine\.mpv\) _autoFellBack = false;')
            .hasMatch(body),
        isTrue,
        reason: '无条件 _autoFellBack = false 会让手动切 Exo 之后又被回退',
      );
      expect(
        RegExp(r'^\s*_autoFellBack = false;\s*$', multiLine: true)
            .hasMatch(body),
        isFalse,
      );
    });

    test('弹窗里的切换按钮直接回调播放页，不 pop 自己', () {
      expect(overlay.contains('widget.onSwitchEngine'), isTrue);
      expect(
        overlay.contains('Navigator'),
        isFalse,
        reason: '弹窗不该自己关自己，否则又会回到「关了但没人切」',
      );
    });
  });

  group('加载弹窗期间的控制层', () {
    test('等待中隐藏播放控件（否则会盖住弹窗的按钮）', () {
      final top = _slice(player, 'Widget _topBar(BuildContext context, MediaItem item) {');
      expect(top.contains('_bootOverlayVisible'), isTrue);
    });

    test('showSwitchSecs 早于 autoFallbackSecs', () {
      expect(
        BootWatchPolicy.showSwitchSecs < BootWatchPolicy.autoFallbackSecs,
        isTrue,
      );
      expect(BootWatchPolicy.autoFallbackSecs, 10.0);
    });
  });
}

/// 从 [from] 起截到下一个顶层 `\n  }` 为止（粗略但足够做结构守卫）
String _slice(String src, String from) {
  final i = src.indexOf(from);
  if (i < 0) return '';
  final rest = src.substring(i);
  final end = rest.indexOf('\n  }\n');
  return end < 0 ? rest : rest.substring(0, end);
}
