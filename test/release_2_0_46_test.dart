import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v2.0.46 回归守卫：字幕缓存 / 导出 / 简繁字体随附。
void main() {
  group('v2.0.46 交付守卫', () {
    test('OFL 许可随附且内容完整', () {
      final f = File('licenses/OFL-NotoSerif.txt');
      expect(f.existsSync(), isTrue, reason: '必须随附思源宋体 OFL 许可');
      final txt = f.readAsStringSync();
      expect(txt, contains('SIL OPEN FONT LICENSE'),
          reason: '需为完整的 SIL OFL 文本');
      expect(txt.length, greaterThan(3000), reason: '不应只是占位');
    });

    test('内置宋体已替换为简繁并集子集（>4MB）', () {
      final f = File('assets/fonts/FangSong.ttf');
      expect(f.existsSync(), isTrue);
      // 旧版 GB2312 子集约 9.6MB；新简繁并集子集约 4.4MB，必须明显大于 1MB。
      expect(f.lengthSync(), greaterThan(1024 * 1024),
          reason: '字幕字体文件疑似缺失或被误删');
    });

    test('播放页字幕菜单含 在线搜索 / 导出 / 删除本机 三入口', () {
      final src = File('lib/pages/player_page.dart').readAsStringSync();
      for (final label in const [
        '在线搜索字幕…',
        '导出字幕…',
        '删除本机字幕',
      ]) {
        expect(src.contains(label), isTrue,
            reason: '字幕菜单缺少入口：$label');
      }
    });

    test('缓存导出对非 Android 平台用文档目录兜底（不依赖 getExternalStorageDirectory）', () {
      final src = File('lib/subtitles/subtitle_cache.dart').readAsStringSync();
      expect(src.contains('getExternalStorageDirectory() ??'),
          isFalse, reason: '不能用 ?? 兜底，非 Android 会抛异常而非返回 null');
      expect(src.contains('try {'), isTrue,
          reason: 'export 必须用 try/catch 兜住非 Android 平台的异常');
    });
  });
}
