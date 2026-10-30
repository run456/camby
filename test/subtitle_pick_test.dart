import 'package:camby/models.dart';
import 'package:camby/player/subtitle_pick.dart';
import 'package:flutter_test/flutter_test.dart';

/// 字幕自动选轨策略（v1.7.47）
///
/// 这些用例覆盖的是「设置页说选中文，实际挂上的到底是不是中文」——
/// 之前这个设置项完全没有读取点，所以一条测试都没有；现在把判定逻辑
/// 抽成纯函数，可以直接打靶。
SubtitleTrackInfo tr({
  required int index,
  String lang = '',
  String title = '',
  bool isDefault = false,
  bool isForced = false,
}) =>
    SubtitleTrackInfo(
      index: index,
      language: lang,
      displayTitle: title,
      isDefault: isDefault,
      isForced: isForced,
      url: 'http://x/$index.srt',
    );

void main() {
  group('SubtitlePref 编解码', () {
    test('存进去再读出来是同一个值', () {
      for (final p in SubtitlePref.values) {
        expect(SubtitlePrefX.fromCode(p.code), p);
      }
    });

    test('越界 / null 一律回落 auto，不抛异常', () {
      // 老用户配置被写坏、或以后枚举变短，都不能让播放页崩
      expect(SubtitlePrefX.fromCode(null), SubtitlePref.auto);
      expect(SubtitlePrefX.fromCode(-1), SubtitlePref.auto);
      expect(SubtitlePrefX.fromCode(999), SubtitlePref.auto);
    });

    test('每种语言都有可读标签', () {
      for (final p in SubtitlePref.values) {
        expect(p.label.trim(), isNotEmpty);
      }
    });
  });

  group('按语言选轨', () {
    test('选中中文轨（ISO 639-2 写法 chi）', () {
      final tracks = [
        tr(index: 0, lang: 'eng'),
        tr(index: 1, lang: 'chi'),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track?.index, 1);
    });

    test('选中中文轨（带地区的 zh-Hans）', () {
      final tracks = [
        tr(index: 0, lang: 'en'),
        tr(index: 1, lang: 'zh-Hans'),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track?.index, 1);
    });

    test('Language 为空时靠 displayTitle 认中文', () {
      // 外挂字幕在 Emby 里经常 Language 为空、标题写「简体中字」
      final tracks = [
        tr(index: 0, title: 'English'),
        tr(index: 1, title: '简体中字'),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track?.index, 1);
    });

    test('同语言多条轨时优先 IsDefault', () {
      final tracks = [
        tr(index: 0, lang: 'chi'),
        tr(index: 1, lang: 'chi', isDefault: true),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track?.index, 1);
    });

    test('同语言有正片轨和强制轨时，不被强制轨劫持', () {
      // 「Signs & Songs」这类强制轨只翻片头片尾，当正片字幕用会缺大半台词
      final tracks = [
        tr(index: 0, lang: 'chi', isForced: true, isDefault: true),
        tr(index: 1, lang: 'chi'),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track?.index, 1);
    });

    test('该语言只有强制轨时也接受，总比没字幕强', () {
      final tracks = [tr(index: 0, lang: 'chi', isForced: true)];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track?.index, 0);
    });

    test('没有该语言时回落「跟随片源」，而不是直接不挂', () {
      // 用户设了中文但片源只有英文字幕：静默无字幕体验更差
      final tracks = [
        tr(index: 0, lang: 'eng'),
        tr(index: 1, lang: 'jpn'),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track, isNotNull);
      expect(pick.track?.index, 0);
    });

    test('用户选「不自动挂载」→ 一条都不选', () {
      final tracks = [tr(index: 0, lang: 'chi')];
      expect(SubtitlePicker.pick(tracks, SubtitlePref.off).isEmpty, isTrue);
    });

    test('跟随片源：优先服务端默认轨', () {
      final tracks = [
        tr(index: 0, lang: 'eng'),
        tr(index: 1, lang: 'jpn', isDefault: true),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.auto);
      expect(pick.track?.index, 1);
    });

    test('跟随片源且都没标默认 → 取第一条非强制', () {
      final tracks = [
        tr(index: 0, lang: 'eng', isForced: true),
        tr(index: 1, lang: 'jpn'),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.auto);
      expect(pick.track?.index, 1);
    });

    test('片源一条字幕都没有 → 空结果（交给在线搜索）', () {
      expect(SubtitlePicker.pick(const [], SubtitlePref.chinese).isEmpty, isTrue);
      expect(SubtitlePicker.pick(const [], SubtitlePref.auto).isEmpty, isTrue);
    });

    test('语言优先于 IsDefault：用户说中文就不给英文默认轨', () {
      // Emby 封装时常把英文轨标成 default，用户的中文偏好不该被它盖掉
      final tracks = [
        tr(index: 0, lang: 'eng', isDefault: true),
        tr(index: 1, lang: 'chi'),
      ];
      final pick = SubtitlePicker.pick(tracks, SubtitlePref.chinese);
      expect(pick.track?.index, 1);
    });
  });
}
