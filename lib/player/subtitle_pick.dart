/// 字幕自动选轨策略（v1.7.47）
///
/// 设置页原本就有「字幕默认语言」这一项，但 1.7.36 清理时只删了读取逻辑、
/// 留下了 UI，于是开关能点、点了没用。这里把判定逻辑抽成纯函数：
///
///  · 不碰任何 Flutter / 网络 / 播放器状态 → 单测直接打靶
///  · 改口味只改 [SubtitlePref] 的映射表，不散落在播放页里
///
/// 设计取舍：**语言优先于「服务端默认」标记**。Emby 里 `IsDefault` 常常
/// 是封装时带上的（很多片源默认标英文轨），用户既然明确说了「我要中文」，
/// 就不该被这个标记覆盖；只有在用户选「跟随片源」时才尊重它。
library;

import '../models.dart';

/// 设置页「字幕默认语言」的可选项（顺序即设置页轮换顺序）
enum SubtitlePref {
  /// 跟随片源：优先用服务端标记的默认轨
  auto,
  chinese,
  english,
  japanese,
  korean,

  /// 不自动挂任何字幕
  off,
}

extension SubtitlePrefX on SubtitlePref {
  String get label {
    switch (this) {
      case SubtitlePref.auto:
        return '跟随片源';
      case SubtitlePref.chinese:
        return '中文';
      case SubtitlePref.english:
        return '英文';
      case SubtitlePref.japanese:
        return '日文';
      case SubtitlePref.korean:
        return '韩文';
      case SubtitlePref.off:
        return '不自动挂载';
    }
  }

  /// 该语言在 Emby / mkv 里可能的全部写法（ISO 639-1/2-B/2-T 混用）
  List<String> get codes {
    switch (this) {
      case SubtitlePref.chinese:
        return const ['zh', 'chi', 'zho', 'chs', 'cht', 'sc', 'tc', 'cn'];
      case SubtitlePref.english:
        return const ['en', 'eng'];
      case SubtitlePref.japanese:
        return const ['ja', 'jpn'];
      case SubtitlePref.korean:
        return const ['ko', 'kor'];
      case SubtitlePref.auto:
      case SubtitlePref.off:
        return const [];
    }
  }

  /// 落盘用：存 int，便于以后插值不改坏老用户的配置
  int get code => index;

  static SubtitlePref fromCode(int? v) {
    if (v == null || v < 0 || v >= SubtitlePref.values.length) {
      return SubtitlePref.auto;
    }
    return SubtitlePref.values[v];
  }
}

/// 判定结果：选中的轨道 + 是否需要给用户一个提示
class SubtitlePick {
  const SubtitlePick(this.track);

  /// 选中的字幕轨；null = 本次不自动挂字幕
  final SubtitleTrackInfo? track;

  bool get isEmpty => track == null;
}

class SubtitlePicker {
  SubtitlePicker._();

  /// 从 [tracks] 里按 [pref] 挑一条。
  ///
  /// 规则（自上而下，命中即返回）：
  ///  1. `off` → 不挂
  ///  2. 该语言有没有「非强制」轨？有 → 优先取服务端标了默认的，
  ///     没有再取第一条（避免把 "Signs & Songs" 这种强制轨当正片字幕）
  ///  3. 该语言只有强制轨 → 也接受（总比没有强）
  ///  4. 该语言一条都没有 → 退回「跟随片源」，而不是直接不挂字幕：
  ///     用户换了语言偏好但片源没有该语言时，静默无字幕体验更差
  ///  5. `auto` → 服务端默认轨，都没有就第一条
  ///
  /// 传空列表 → 返回空结果（无字幕资源，调用方据此决定是否搜在线字幕）。
  static SubtitlePick pick(
    List<SubtitleTrackInfo> tracks,
    SubtitlePref pref,
  ) {
    if (tracks.isEmpty) return const SubtitlePick(null);
    if (pref == SubtitlePref.off) return const SubtitlePick(null);

    final codes = pref.codes;
    if (codes.isNotEmpty) {
      final matched = tracks.where((t) => _langMatches(t, codes)).toList();
      if (matched.isNotEmpty) {
        return SubtitlePick(_best(matched));
      }
      // 语言没命中 → 落到「跟随片源」
    }
    return SubtitlePick(_best(tracks));
  }

  /// 语言是否命中：既看 ISO 码，也看标题里有没有语言名（很多片源
  /// `Language` 是空的，只在中文字幕标题里写「简体中字」）
  static bool _langMatches(SubtitleTrackInfo t, List<String> codes) {
    final lang = t.language.toLowerCase().trim();
    if (lang.isNotEmpty) {
      // zh-Hans / zh-CN 这类带地区的，取主标签
      final primary = lang.split(RegExp(r'[-_]')).first;
      if (codes.contains(primary) || codes.contains(lang)) return true;
    }
    // displayTitle 里常写「简体中字 / Chinese (SDH)」，比 Language 更可靠
    final title = t.displayTitle.toLowerCase();
    for (final hint in _titleHints(codes)) {
      if (title.contains(hint)) return true;
    }
    return false;
  }

  /// 标题里的语言线索
  static List<String> _titleHints(List<String> codes) {
    if (codes.contains('zh')) {
      return const ['中', '简', '繁', 'chs', 'cht', 'chinese', '中字', '国语', '粤'];
    }
    if (codes.contains('en')) return const ['english', '英'];
    if (codes.contains('ja')) return const ['japanese', '日', '日语'];
    if (codes.contains('ko')) return const ['korean', '韩', '韩语'];
    return const [];
  }

  /// 组内择优：先剔强制轨（除非整组都是强制轨），再优先 IsDefault，再取第一条
  static SubtitleTrackInfo _best(List<SubtitleTrackInfo> group) {
    final normal = group.where((t) => !t.isForced).toList();
    final pool = normal.isNotEmpty ? normal : group;
    for (final t in pool) {
      if (t.isDefault) return t;
    }
    return pool.first;
  }
}
