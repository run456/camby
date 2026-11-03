import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.23：本地累计播放秒数达到门槛（15 分钟）即计为「已看」。
void main() {
  // 用 demoLibrary 现成条目（copyWith 会保留原始 id，便于按 id 映射本地时长）
  final fresh = demoLibrary[0].copyWith(
    userPlayed: false,
    resumeProgress: 0.0,
    resumeSeconds: 0,
  );
  final id = fresh.id;

  test('无累计播放时长时，进度不足的影片不计入已看', () {
    final stats = LibraryStats.compute([fresh], localPlaySeconds: const {});
    expect(stats.watchedCount, 0);
  });

  test('累计播放达到 15 分钟门槛（900s）即计为已看', () {
    final stats = LibraryStats.compute(
      [fresh],
      localPlaySeconds: {id: 900},
    );
    expect(stats.watchedCount, 1);
  });

  test('差 1 秒不到门槛不计入已看', () {
    final stats = LibraryStats.compute(
      [fresh],
      localPlaySeconds: {id: 899},
    );
    expect(stats.watchedCount, 0);
  });

  test('与服务端已看标记 / 进度 90% 为「或」关系，复用同一判定', () {
    final marked = demoLibrary[1].copyWith(userPlayed: true);
    final progress = demoLibrary[2].copyWith(resumeProgress: 0.95);
    final local = fresh; // 进度仅 0.0，靠本地累计时长补成已看
    final stats = LibraryStats.compute(
      [marked, progress, local],
      // 只对 local 这一条补本地时长，验证「或」关系
      localPlaySeconds: {local.id: 900},
    );
    // 已看标记 + 进度 90% + 本地累计 15 分钟 = 3
    expect(stats.watchedCount, 3);
  });
}
