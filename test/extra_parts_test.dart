import 'package:flutter_test/flutter_test.dart';
import 'package:camby/models.dart';

/// 「额外部分」（Emby 同一影片的多个 MediaSource，如 -Cd1 / -Cd2 分段）
/// 的解析与展示文案测试。
void main() {
  group('MediaExtraPart.fromJson', () {
    test('优先用 Name，并解析分辨率/编码/时长', () {
      final p = MediaExtraPart.fromJson({
        'Id': 'src-2',
        'Name': 'ABP-018-Cd2',
        'Path': '/media/ABP-018/ABP-018-Cd2.mkv',
        'RunTimeTicks': 120 * 10000000, // 120 秒 = 2 分钟
        'Container': 'mkv',
        'Size': 123456,
        'MediaStreams': [
          {'Type': 'Video', 'Height': 1080, 'Codec': 'hevc'},
          {'Type': 'Audio', 'Codec': 'aac'},
        ],
      })!;
      expect(p.id, 'src-2');
      expect(p.name, 'ABP-018-Cd2');
      expect(p.height, 1080);
      expect(p.videoCodec, 'hevc');
      expect(p.audioCodec, 'aac');
      expect(p.runtimeMin, 2);
      expect(p.specLine, contains('1080P'));
      expect(p.specLine, contains('2分钟'));
    });

    test('Name 缺失时退化为文件名去扩展名', () {
      final p = MediaExtraPart.fromJson({
        'Id': 'src-3',
        'Path': r'E:\media\DV-1242\DV-1242-C.mp4',
      })!;
      expect(p.name, 'DV-1242-C');
    });

    test('Name 与 Path 都缺失时也要给出可读名称（不抛异常）', () {
      final p = MediaExtraPart.fromJson({'Id': 'src-9'})!;
      expect(p.name, isNotEmpty);
    });

    test('Id 与 Path 全空 → 无法起播，返回 null', () {
      expect(MediaExtraPart.fromJson({}), isNull);
    });

    test('时长格式化：超过 60 分钟显示「N小时M分钟」', () {
      final p = MediaExtraPart.fromJson({
        'Id': 's',
        'Name': 'A',
        // 2小时32分 = 152 分钟
        'RunTimeTicks': 152 * 60 * 10000000,
      })!;
      expect(p.runtimeMin, 152);
      expect(p.specLine, contains('2小时32分钟'));
    });
  });
}
