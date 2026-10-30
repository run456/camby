import 'dart:ui' show Color;

import 'package:camby/models.dart';
import 'package:camby/player/boot_watch.dart';
import 'package:camby/player/playback.dart';
import 'package:flutter_test/flutter_test.dart';

/// STRM 起播策略（v1.7.44：A 加载态 / B MPV 调优 / D 智能内核）
void main() {
  MediaItem mk({
    String id = 'x',
    String filePath = '',
    String container = 'MKV',
  }) => MediaItem(
    id: id,
    name: id,
    overview: '',
    colors: const [Color(0xFF101820), Color(0xFF203040)],
    type: MediaType.movie,
    container: container,
    filePath: filePath,
  );

  group('strm 识别（D 方案的路由依据）', () {
    test('Path 以 .strm 结尾 → strm', () {
      expect(mk(filePath: '/media/movies/星际穿越.strm').isStrm, isTrue);
    });

    test('大小写不敏感', () {
      expect(mk(filePath: '/media/a.STRM').isStrm, isTrue);
    });

    test('容器名是 STRM 也认（服务端隐藏 Path 时的退路）', () {
      expect(mk(filePath: '', container: 'strm').isStrm, isTrue);
    });

    test('普通 mkv / 空路径不算 strm', () {
      expect(mk(filePath: '/media/a.mkv', container: 'MKV').isStrm, isFalse);
      expect(mk(filePath: '', container: '').isStrm, isFalse);
    });

    test('名字里带 strm 但路径是 mkv 的不算（避免误判）', () {
      expect(mk(id: 'strm专题', filePath: '/media/strm专题.mkv').isStrm, isFalse);
    });
  });

  group('起播看护阈值', () {
    test('阈值递增：先给按钮，再自动切，最后提示插件', () {
      expect(
        BootWatchPolicy.showSwitchSecs < BootWatchPolicy.autoFallbackSecs,
        isTrue,
      );
      expect(
        BootWatchPolicy.autoFallbackSecs < BootWatchPolicy.pluginHintSecs,
        isTrue,
      );
    });

    test('MPV 8 秒给按钮，7.9 秒不给', () {
      expect(
        BootWatchPolicy.showSwitchButton(
          engine: PlaybackEngine.mpv,
          waitedSecs: 8,
        ),
        isTrue,
      );
      expect(
        BootWatchPolicy.showSwitchButton(
          engine: PlaybackEngine.mpv,
          waitedSecs: 7.9,
        ),
        isFalse,
      );
    });

    test('Exo 永远不显示「切到 Exo」按钮（它本来就是兜底）', () {
      expect(
        BootWatchPolicy.showSwitchButton(
          engine: PlaybackEngine.exo,
          waitedSecs: 60,
        ),
        isFalse,
      );
    });

    test('MPV 10 秒自动回退，9.9 秒不回退', () {
      expect(
        BootWatchPolicy.shouldFallback(
          engine: PlaybackEngine.mpv,
          alreadyFellBack: false,
          waitedSecs: 10,
        ),
        isTrue,
      );
      expect(
        BootWatchPolicy.shouldFallback(
          engine: PlaybackEngine.mpv,
          alreadyFellBack: false,
          waitedSecs: 9.9,
        ),
        isFalse,
      );
    });

    test('已经回退过就不再回退（防止来回跳内核）', () {
      expect(
        BootWatchPolicy.shouldFallback(
          engine: PlaybackEngine.mpv,
          alreadyFellBack: true,
          waitedSecs: 30,
        ),
        isFalse,
      );
    });

    test('Exo 没首帧也不回退（无处可退）', () {
      expect(
        BootWatchPolicy.shouldFallback(
          engine: PlaybackEngine.exo,
          alreadyFellBack: false,
          waitedSecs: 30,
        ),
        isFalse,
      );
    });

    test('25 秒才提示插件', () {
      expect(BootWatchPolicy.showPluginHint(24.9), isFalse);
      expect(BootWatchPolicy.showPluginHint(25), isTrue);
    });
  });

  group('播放器 UA（B 方案）', () {
    test('UA 非空且带版本号，不能是 libmpv 默认的 Lavf', () {
      expect(kPlayerUserAgent, isNotEmpty);
      expect(kPlayerUserAgent, isNot(startsWith('Lavf')));
      expect(kPlayerUserAgent.toLowerCase(), contains('libvlc'));
    });
  });
}
