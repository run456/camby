import 'package:camby/emby_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.29：本地预告片识别回归测试。
///
/// Emby 对放在电影文件夹里的 trailer 文件有两种存储形态，且可能嵌套在
/// `trailer/` 子目录里。这里覆盖各类真实数据的判定，防止以后改坏。
void main() {
  bool detect(Map<String, dynamic> j) => EmbyServer.looksLikeTrailer(j);

  test('Type=Trailer 直接命中', () {
    expect(detect({'Type': 'Trailer', 'Path': '/media/Movie/trailer.mkv'}),
        isTrue);
  });

  test('Type=Video + ExtraType=Trailer 命中（Emby 常见形态）', () {
    expect(
      detect({
        'Type': 'Video',
        'ExtraType': 'Trailer',
        'Path': '/media/Movie/trailer.mp4',
      }),
      isTrue,
    );
  });

  test('父目录名为 trailer/ 的嵌套文件命中', () {
    expect(
      detect({
        'Type': 'Video',
        'Path': '/media/Movie/trailer/trailer.mkv',
      }),
      isTrue,
    );
  });

  test('大小写混写也能识别', () {
    expect(
      detect({'Type': 'video', 'ExtraType': 'TRAILER'}),
      isTrue,
    );
    expect(detect({'Type': 'Trailer'}), isTrue);
  });

  test('服务端不回 Path，但 Name 带 trailer 也能识别', () {
    expect(detect({'Type': 'Video', 'Name': 'Official Trailer'}), isTrue);
  });

  test('Path 被隐藏，但 MediaSources[].Path 带 trailer 也能识别', () {
    expect(
      detect({
        'Type': 'Video',
        'MediaSources': [
          {'Path': '/media/ABP-018/trailers/clip.mkv'},
        ],
      }),
      isTrue,
    );
  });

  test('剧集子集（Episode）不误判', () {
    expect(
      detect({
        'Type': 'Episode',
        'Path': '/media/Show/Season 1/S01E01.mkv',
      }),
      isFalse,
    );
  });

  test('普通正片视频不误判', () {
    expect(
      detect({
        'Type': 'Video',
        'ExtraType': '',
        'Path': '/media/Movie/Movie.2023.2160p.mkv',
      }),
      isFalse,
    );
  });

  test('缺少字段的条目安全返回 false', () {
    expect(detect({}), isFalse);
  });
}
