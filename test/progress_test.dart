import 'package:camby/app_state.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放进度回写（v1.7.29 bug2 / v1.7.41 复核补齐）
void main() {
  final target = demoLibrary.first;
  const total = 7200.0; // 2 小时

  late AppState state;
  setUp(() => state = AppState());

  MediaItem current() => state.items.firstWhere((e) => e.id == target.id);

  test('2 小时电影跳到 01:00 记为 50%', () {
    state.updateProgress(target.id, seconds: 3600, total: total);
    expect(current().resumeProgress, closeTo(0.5, 0.001));
    expect(current().resumeSeconds, 3600);
  });

  test('进度只增不减：退出瞬间拿到 0 不清掉已看记录', () {
    state.updateProgress(target.id, seconds: 3600, total: total);
    state.updateProgress(target.id, seconds: 0, total: total);
    expect(current().resumeProgress, closeTo(0.5, 0.001));
  });

  test('看到 95% 以上标记成已看完', () {
    state.updateProgress(target.id, seconds: total * 0.96, total: total);
    expect(current().userPlayed, isTrue);
  });

  test('时长未知（0）时不写入，避免算出 NaN/Inf', () {
    state.updateProgress(target.id, seconds: 100, total: 0);
    expect(current().resumeProgress, isNull);
  });

  test('未知 id 不抛异常', () {
    expect(
      () => state.updateProgress('no-such-id', seconds: 10, total: total),
      returnsNormally,
    );
  });

  test('更新后「继续观看」立刻能查到（无需重新拉库）', () {
    state.updateProgress(target.id, seconds: 3600, total: total);
    expect(
      state.continueWatching.any((e) => e.id == target.id),
      isTrue,
    );
  });

  test('copyWith 保留 resumeSeconds，不会被其它字段更新清掉', () {
    final withProgress = target.copyWith(
      resumeProgress: 0.4,
      resumeSeconds: 1200,
    );
    final faved = withProgress.copyWith(userFavorite: true);
    expect(faved.resumeSeconds, 1200);
    expect(faved.resumeProgress, 0.4);
    expect(faved.userFavorite, isTrue);
  });
}
