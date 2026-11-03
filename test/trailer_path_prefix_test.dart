import 'package:flutter_test/flutter_test.dart';

/// v2.0.33：`trailers/` 子目录的「父目录前缀」推导回归测试。
///
/// 方案 E 的做法是用影片 Path 截出父目录（含结尾分隔符）作为 `PathStartsWith`。
/// 结尾分隔符不能省 —— 否则 `/media/ABP-01/` 会把 `/media/ABP-018` 也匹配进来。
void main() {
  /// 与 EmbyServer._fetchByPathPrefix 中的推导保持一致
  String parentPrefix(String path) {
    if (path.isEmpty) return '';
    final sep = path.contains('\\') ? '\\' : '/';
    final idx = path.lastIndexOf(sep);
    if (idx <= 0) return '';
    return path.substring(0, idx + 1);
  }

  test('Unix 路径：截出父目录且保留结尾分隔符', () {
    expect(parentPrefix('/media/ABP-018/ABP-018.mkv'), '/media/ABP-018/');
  });

  test('Windows 路径：识别反斜杠分隔符', () {
    expect(parentPrefix(r'D:\media\ABP-018\ABP-018.mkv'), r'D:\media\ABP-018\');
  });

  test('前缀带结尾分隔符，不会误匹配同前缀的兄弟目录', () {
    final prefix = parentPrefix('/media/ABP-018/ABP-018.mkv');
    expect('/media/ABP-018/trailers/clip.mkv'.startsWith(prefix), isTrue);
    // 关键：ABP-01 不能被 ABP-018 的前缀误吞
    expect('/media/ABP-011/foo.mkv'.startsWith(prefix), isFalse);
  });

  test('空路径 / 无分隔符安全返回空串', () {
    expect(parentPrefix(''), '');
    expect(parentPrefix('ABP-018.mkv'), '');
  });
}
