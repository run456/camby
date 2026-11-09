import '../app_state.dart';
import '../emby_client.dart';
import '../models.dart';

/// 一组「合集名 → 成员 Id」，供 [BoxSetSeriesSync.mergeMappings] 合并。
class BoxSetMembers {
  const BoxSetMembers(this.name, this.ids);

  final String name;
  final List<String> ids;
}

/// 全库「系列 ← 服务端合集（BoxSet）」同步结果（v2.0.63）。
class BoxSetSyncResult {
  /// 服务端合集总数。
  int boxSets = 0;

  /// 待补系列名的电影数。
  int targets = 0;

  /// 成功写入系列名的影片数。
  int filled = 0;

  /// 反查后确认没有关联任何合集的影片数。
  int noCollection = 0;

  /// 是否用了 `ListItemIds` 逐条反查兜底。
  bool usedItemLookup = false;

  bool cancelled = false;
  bool failed = false;
  String? error;

  final List<String> notes = <String>[];

  bool get anyHit => filled > 0;
}

/// 把服务端的「合集」同步为客户端的「系列」（v2.0.63）。
///
/// 这是对用户反馈「系列应该读取的是合集字段」的正面修复。之前两版去直读
/// `.nfo` 属于绕远路：Emby 已经把 `<set><name>` 建成了独立的 BoxSet 对象
/// （网页端详情页的「所属合集」区块就是证据），服务端 API 直接可读，
/// 不需要影片文件路径、不需要 HTTP 直链、不需要签名处理。
///
/// 双路径：
///  ① 列出所有 BoxSet → 逐个 `ParentId` 拉成员 → 反建 itemId → 合集名；
///  ② 仍未命中的影片用网页端同款 `ListItemIds` 逐条反查（部分 Emby 版本
///     的 ParentId 对 BoxSet 不返回成员，这一步是必要兜底）。
///
/// NFO 直读不再进入这条链路，只保留在详情页作为最后的离线兜底。
class BoxSetSeriesSync {
  BoxSetSeriesSync._();

  /// 合并「合集 → 成员」为 itemId → 合集名。先到的合集优先（一部影片
  /// 同时属于多个合集时只取第一个，系列名只有一个槽位）。抽成纯函数便于单测。
  static Map<String, String> mergeMappings(Iterable<BoxSetMembers> groups) {
    final out = <String, String>{};
    for (final g in groups) {
      final name = g.name.trim();
      if (name.isEmpty) continue;
      for (final id in g.ids) {
        if (id.isEmpty) continue;
        out.putIfAbsent(id, () => name);
      }
    }
    return out;
  }

  static Future<BoxSetSyncResult> run({
    required AppState state,
    required EmbyServer server,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 6,
    int maxItemLookups = 400,
  }) async {
    final r = BoxSetSyncResult();
    final targets = state.items
        .where((e) => e.type == MediaType.movie && e.seriesName.trim().isEmpty)
        .toList();
    r.targets = targets.length;
    if (targets.isEmpty) {
      r.notes.add('全部影片都已有系列名，无需同步。');
      return r;
    }

    List<BoxSetInfo> boxSets;
    try {
      boxSets = await server.allBoxSets();
    } catch (e) {
      r.failed = true;
      r.error = '读取合集列表失败：${_short(e)}';
      return r;
    }
    r.boxSets = boxSets.length;
    if (boxSets.isEmpty) {
      r.notes.add('服务器上没有找到任何合集（BoxSet）。'
          '请先在服务端确认「所属合集」里确实有内容。');
      return r;
    }

    // ① 主路径：合集 → 成员，反建映射。
    final groups = <BoxSetMembers>[];
    var done = 0;
    for (var s = 0; s < boxSets.length; s += concurrency) {
      if (isCancelled?.call() == true) {
        r.cancelled = true;
        break;
      }
      final batch = boxSets.skip(s).take(concurrency).toList();
      final members = await Future.wait(
        batch.map((b) => _safeMembers(server, b.id)),
      );
      for (var i = 0; i < batch.length; i++) {
        groups.add(BoxSetMembers(batch[i].name, members[i]));
      }
      done += batch.length;
      onProgress?.call(done, boxSets.length);
    }

    final targetIds = targets.map((e) => e.id).toSet();
    final updates = mergeMappings(groups)
      ..removeWhere((id, _) => !targetIds.contains(id));

    // ② 兜底：仍未命中的影片逐条反查。ParentId 在部分 Emby 版本上对
    //    BoxSet 不返回成员，这时 ListItemIds 是唯一能拿到归属的查询。
    final missing = targets.where((e) => !updates.containsKey(e.id)).toList();
    if (missing.isNotEmpty && !r.cancelled) {
      r.usedItemLookup = true;
      r.notes.add('已用网页端同款 ListItemIds 反查未命中的影片。');
      final limited = missing.take(maxItemLookups).toList();
      if (missing.length > limited.length) {
        r.notes.add('影片较多，本轮最多反查 $maxItemLookups 部；'
            '再点一次「同步合集」会继续处理剩下的。');
      }
      var d2 = 0;
      for (var s = 0; s < limited.length; s += concurrency) {
        if (isCancelled?.call() == true) {
          r.cancelled = true;
          break;
        }
        final batch = limited.skip(s).take(concurrency).toList();
        final names = await Future.wait(
          batch.map((e) => _safeNames(server, e.id)),
        );
        for (var i = 0; i < batch.length; i++) {
          if (names[i].isNotEmpty) {
            updates[batch[i].id] = names[i].first;
          } else {
            r.noCollection++;
          }
        }
        d2 += batch.length;
        onProgress?.call(d2, limited.length);
      }
    }

    state.replaceSeriesNames(updates);
    r.filled = updates.length;
    if (r.filled == 0 && !r.cancelled) {
      r.notes.add('这些影片在服务端没有关联任何合集。'
          '若服务端「所属合集」里明明有内容，请把结果截图发回排查。');
    }
    return r;
  }

  static Future<List<String>> _safeMembers(EmbyServer s, String id) async {
    try {
      return await s.boxSetMemberIds(id);
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<List<String>> _safeNames(EmbyServer s, String id) async {
    try {
      return await s.boxSetNamesForItem(id);
    } catch (_) {
      return const <String>[];
    }
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }
}
