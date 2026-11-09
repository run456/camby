import 'dart:math' as math;

import '../app_state.dart';
import '../emby_client.dart';
import '../models.dart';
import 'nfo_reader.dart';

/// 全库 NFO 系列回填（v2.0.62）。
///
/// Emby 官方明确不会把 NFO 的 `<set><name>` 解析成任何可通过 API 读取的字段
/// （只把它原样留给 Kodi），所以系列只能靠直读 .nfo。而详情页逐条懒读又必须
/// 「先浏览过才累积」——这正是「无论是否刷新，系列还是没有」的体感来源。
///
/// 这个服务提供一次性主动补全：遍历全库 `seriesName` 为空的电影，按
/// [buildNfoCandidates] 直读 .nfo，命中 `<set><name>` / `<series>` 就批量
/// 写回 [AppState]，系列总览、系列胶囊、媒体库「系列」筛选随即全部可用。
///
/// 关键防御：**先试跑少量样本**。若环境根本取不到 .nfo（路径全空、代理端点
/// 不通、直链签名失效），立刻停下并把逐候选诊断交给 UI，绝不对上千部影片
/// 逐个耗满超时 —— 那只会让用户干等几分钟再得到一句「失败」。
class NfoBackfillResult {
  /// 待补全的影片数（seriesName 为空的电影）。
  int targets = 0;

  /// 成功写回系列名的影片数。
  int filled = 0;

  /// 条目没有 filePath，完全派生不出 NFO 地址。
  int noPath = 0;

  /// 所有候选都拿不到 NFO 正文（HTTP 错误 / 超时 / 返回的不是 NFO）。
  int noNfo = 0;

  /// NFO 读到了，但里面没有 `<set><name>` / `<series>`。
  int noSetField = 0;

  /// 试跑判定环境不通，提前中止了全库扫描。
  bool abortedByProbe = false;

  bool cancelled = false;

  final List<NfoProbe> probes = <NfoProbe>[];

  bool get anyHit => filled > 0;

  /// 给用户看的失败样例：脱敏、去重、最多 5 条。
  List<String> get samples {
    final out = <String>[];
    for (final p in probes) {
      if (p.status == NfoProbeStatus.hit) continue;
      if (out.length >= 5) break;
      if (!out.contains(p.describe)) out.add(p.describe);
    }
    return out;
  }
}

class NfoSeriesBackfill {
  NfoSeriesBackfill._();

  static Future<NfoBackfillResult> run({
    required AppState state,
    required EmbyServer server,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 6,
    int probeLimit = 3,
  }) async {
    final r = NfoBackfillResult();
    final targets = state.items
        .where((e) => e.type == MediaType.movie && e.seriesName.trim().isEmpty)
        .toList();
    r.targets = targets.length;
    if (targets.isEmpty) return r;

    final withPath =
        targets.where((e) => e.filePath.trim().isNotEmpty).toList();
    r.noPath = targets.length - withPath.length;
    if (withPath.isEmpty) {
      r.abortedByProbe = true;
      return r;
    }

    Future<NfoReadResult> read(MediaItem e) => loadNfoSeriesDetailed(
          buildNfoCandidates(
            e.filePath,
            embyBase: server.baseUrl,
            embyToken: server.token,
            itemId: e.id,
          ),
          timeout: const Duration(seconds: 3),
        );

    final updates = <String, String>{};

    void record(NfoReadResult one, MediaItem e) {
      r.probes.addAll(one.probes);
      if (one.ok) {
        updates[e.id] = one.series!.trim();
      } else if (one.probes
          .any((p) => p.status == NfoProbeStatus.noSeriesField)) {
        r.noSetField++;
      } else {
        r.noNfo++;
      }
    }

    // ① 试跑：通道不通就立刻停，避免全库空转。
    final probeCount = math.min(probeLimit, withPath.length);
    for (var i = 0; i < probeCount; i++) {
      if (isCancelled?.call() == true) {
        r.cancelled = true;
        return r;
      }
      final e = withPath[i];
      record(await read(e), e);
      onProgress?.call(i + 1, withPath.length);
    }
    if (r.probes.isEmpty ||
        r.probes.every((p) =>
            p.status == NfoProbeStatus.httpError ||
            p.status == NfoProbeStatus.networkError ||
            p.status == NfoProbeStatus.notNfo)) {
      // 所有候选都没拿到 NFO 正文：继续扫全库没有意义。
      r.abortedByProbe = true;
    }
    if (r.abortedByProbe) {
      state.replaceSeriesNames(updates);
      r.filled = updates.length;
      return r;
    }

    // ② 通道可用：分块并发扫剩余条目，每批只 await 一次。
    final rest = withPath.skip(probeCount).toList();
    var done = probeCount;
    for (var s = 0; s < rest.length; s += concurrency) {
      if (isCancelled?.call() == true) {
        r.cancelled = true;
        break;
      }
      final batch = rest.skip(s).take(concurrency).toList();
      final results = await Future.wait(batch.map(read));
      for (var i = 0; i < batch.length; i++) {
        record(results[i], batch[i]);
      }
      done += batch.length;
      onProgress?.call(done, withPath.length);
    }

    state.replaceSeriesNames(updates);
    r.filled = updates.length;
    return r;
  }
}
