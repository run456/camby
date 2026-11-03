import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.26：偏好演员并入「完成观看」+ 偏好影片本地播放次数 Top10
void main() {
  MediaItem _mk(
    String id, {
    bool played = false,
    double progress = 0,
    List<CastMember> people = const [],
    MediaType type = MediaType.movie,
  }) =>
      MediaItem(
        id: id,
        name: '片$id',
        overview: '',
        colors: const [Color(0xFF101820), Color(0xFF203040)],
        type: type,
        userPlayed: played,
        resumeProgress: progress,
        people: people,
      );

  test('偏好演员：完成观看影片的演员也计入（不再只算继续观看）', () {
    // 「继续观看」影片：进度 0.5，演员 A
    final cont = _mk('c1', progress: 0.5, people: const [CastMember(name: 'A')]);
    // 「完成观看」影片：userPlayed 标记，演员 B
    final done = _mk('d1', played: true, people: const [CastMember(name: 'B')]);
    // 仅进度 0 的影片：演员 C 不应计入
    final none = _mk('n1', progress: 0, people: const [CastMember(name: 'C')]);

    final stats = LibraryStats.compute([cont, done, none]);
    final names = stats.topPeople.map((e) => e['name'] as String).toList();
    expect(names, contains('A'));
    expect(names, contains('B'));
    expect(names, isNot(contains('C')));
  });

  test('偏好影片：按本地播放次数取前 10 部，且只收电影', () {
    final movies = List.generate(
      12,
      (i) => _mk('m$i', people: const [CastMember(name: 'X')]),
    );
    // 一部剧（非电影）播放 999 次，应当被排除
    final series = _mk(
      's1',
      type: MediaType.series,
      people: const [CastMember(name: 'Y')],
    );
    final items = [...movies, series];

    // m0..m9 各播放 1..10 次；m10/m11/series 0 次
    final playCounts = <String, int>{};
    for (var i = 0; i <= 9; i++) playCounts['m$i'] = i + 1;
    playCounts['s1'] = 999;

    final stats = LibraryStats.compute(items, playCounts: playCounts);

    expect(stats.topMovies.length, 10);
    // 第一名应是播放 10 次的 m9
    expect((stats.topMovies.first['item'] as MediaItem).id, 'm9');
    // 榜内不应出现非电影的 series
    final ids = stats.topMovies.map((e) => (e['item'] as MediaItem).id);
    expect(ids, isNot(contains('s1')));
  });

  test('AppState：addPlayCount 累加并暴露 getPlayCount', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final s = AppState();
    expect(s.getPlayCount('x'), 0);
    s.addPlayCount('x');
    s.addPlayCount('x');
    expect(s.getPlayCount('x'), 2);
  });
}
