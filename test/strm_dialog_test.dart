import 'package:camby/player/boot_watch.dart';
import 'package:camby/player/playback.dart';
import 'package:flutter_test/flutter_test.dart';

/// 起播加载弹窗的分阶段策略（v1.7.49）
///
/// 背景：设计稿要求「加载 strm 前有弹窗」，分 0–8s / >8s / >25s 三段给不同信息，
/// 并有「连接 → 探测 → 缓冲」三段进度点。这些阈值散落在 UI 里就没法测，
/// 所以全塞进 `BootWatchPolicy`，这里直接打靶。
void main() {
  group('三个阶段点', () {
    test('0–4 秒在「连接」', () {
      expect(BootWatchPolicy.stageIndex(0), 0);
      expect(BootWatchPolicy.stageIndex(3.9), 0);
    });

    test('4–12 秒走到「探测」（strm 的主要耗时区）', () {
      expect(BootWatchPolicy.stageIndex(4), 1);
      expect(BootWatchPolicy.stageIndex(11.9), 1);
    });

    test('12 秒之后是「缓冲」', () {
      expect(BootWatchPolicy.stageIndex(12), 2);
      expect(BootWatchPolicy.stageIndex(40), 2);
    });

    test('三段标签齐全', () {
      expect(BootWatchPolicy.stageLabels, ['连接', '探测', '缓冲']);
    });
  });

  group('标题随阶段变化', () {
    test('每个阶段都有非空标题，且互不相同', () {
      final titles = {
        for (final s in [0.0, 6.0, 15.0]) BootWatchPolicy.titleFor(s),
      };
      expect(titles.length, 3, reason: '三段应该有三种不同文案，让用户知道在推进');
      expect(titles.every((t) => t.trim().isNotEmpty), isTrue);
    });
  });

  group('操作出口的时机', () {
    test('MPV 8 秒后露「切 Exo」按钮', () {
      expect(
        BootWatchPolicy.showSwitchButton(
          engine: PlaybackEngine.mpv,
          waitedSecs: 7.9,
        ),
        isFalse,
      );
      expect(
        BootWatchPolicy.showSwitchButton(
          engine: PlaybackEngine.mpv,
          waitedSecs: 8,
        ),
        isTrue,
      );
    });

    test('Exo 已经是兜底内核，不给「切 Exo」按钮', () {
      // 给一个「切到自己」的按钮是纯废话，还会让用户以为点错了
      expect(
        BootWatchPolicy.showSwitchButton(
          engine: PlaybackEngine.exo,
          waitedSecs: 30,
        ),
        isFalse,
      );
    });

    test('25 秒后才提「装服务端插件」', () {
      expect(BootWatchPolicy.showPluginHint(24.9), isFalse);
      expect(BootWatchPolicy.showPluginHint(25), isTrue);
    });

    test('弹窗最短显示 1.2 秒，避免一闪而过', () {
      expect(BootWatchPolicy.minVisibleSecs, 1.2);
    });
  });

  group('自动回退规则', () {
    test('MPV 10 秒无首帧 → 自动切 Exo', () {
      expect(
        BootWatchPolicy.shouldFallback(
          engine: PlaybackEngine.mpv,
          alreadyFellBack: false,
          waitedSecs: 10,
        ),
        isTrue,
      );
    });

    test('本轮已回退过就不再回退（防 mpv→exo→mpv 来回跳）', () {
      expect(
        BootWatchPolicy.shouldFallback(
          engine: PlaybackEngine.mpv,
          alreadyFellBack: true,
          waitedSecs: 30,
        ),
        isFalse,
      );
    });

    test('Exo 不回退（没有更兜底的内核了）', () {
      expect(
        BootWatchPolicy.shouldFallback(
          engine: PlaybackEngine.exo,
          alreadyFellBack: false,
          waitedSecs: 30,
        ),
        isFalse,
      );
    });

    test('切换按钮比自动回退早 2 秒：先让用户看见，再自己动手', () {
      expect(
        BootWatchPolicy.showSwitchSecs < BootWatchPolicy.autoFallbackSecs,
        isTrue,
      );
      expect(BootWatchPolicy.autoFallbackSecs, 10.0);
    });
  });
}
