import 'package:camby/app_state.dart';
import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.7.65：收藏夹与服务端播放列表的合并逻辑（纯函数，不触碰网络）。
void main() {
  final remote = [
    ServerPlaylist('pid1', '云端A', ['m1', 'm2']),
    ServerPlaylist('pid2', '云端B', ['m3']),
    ServerPlaylist('pidNew', '云端新增', ['x1']),
  ];

  test('本地与服务端共有 → 以服务端成员为准取并集，名称取服务端', () {
    final local = [
      FavoriteFolder(
        id: 'f1',
        name: '本地A',
        itemIds: ['m1', 'm9'],
        playlistId: 'pid1',
        serverId: 's1',
      ),
    ];
    final out = AppState.reconcileFolders(local, remote, 's1');
    final a = out.firstWhere((f) => f.id == 'f1');
    expect(a.itemIds, containsAll(<String>['m1', 'm2', 'm9']));
    expect(a.name, '云端A');
  });

  test('服务端有、本地无 → 新建本地收藏夹（卸载重装后自动恢复）', () {
    final local = <FavoriteFolder>[];
    final out = AppState.reconcileFolders(local, remote, 's1');
    final created = out.where((f) => f.id == 'pl_pidNew').toList();
    expect(created, hasLength(1));
    expect(created.first.itemIds, ['x1']);
    expect(created.first.serverId, 's1');
    expect(created.first.playlistId, 'pidNew');
  });

  test('本地有 playlistId、服务端已删 → 本地一并移除（两端一致）', () {
    final local = [
      FavoriteFolder(
        id: 'f2',
        name: '已删',
        itemIds: ['m5'],
        playlistId: 'pidGone',
        serverId: 's1',
      ),
    ];
    final out = AppState.reconcileFolders(local, remote, 's1');
    expect(out.any((f) => f.playlistId == 'pidGone'), isFalse);
  });

  test('纯本地（playlistId==null）收藏夹必须保留', () {
    final local = [
      FavoriteFolder(id: 'f3', name: '纯本地', itemIds: ['m7']),
    ];
    final out = AppState.reconcileFolders(local, remote, 's1');
    expect(out.any((f) => f.id == 'f3'), isTrue);
  });

  test('跨服隔离：别的服务器 playlist 不算数', () {
    final local = [
      FavoriteFolder(
        id: 'f4',
        name: '本服',
        itemIds: ['m1'],
        playlistId: 'pid1',
        serverId: 's1',
      ),
    ];
    // 当前服务器是 s2，s1 的远程播放列表不应影响 f4
    final out = AppState.reconcileFolders(local, remote, 's2');
    final f = out.firstWhere((e) => e.id == 'f4');
    expect(f.itemIds, ['m1']); // 不被远程覆盖
  });

  test('决策①：服务端空名不能冲掉本地好名字（v1.7.68）', () {
    final local = [
      FavoriteFolder(
        id: 'f5',
        name: '本机好名字',
        itemIds: ['m1'],
        playlistId: 'pid1',
        serverId: 's1',
      ),
    ];
    final rem = [
      ServerPlaylist('pid1', '', ['m1']), // 服务端空名脏数据
    ];
    final out = AppState.reconcileFolders(local, rem, 's1');
    expect(out.firstWhere((f) => f.id == 'f5').name, '本机好名字');
  });

  test('决策②：服务端空名播放列表在下行模式不建成本地收藏夹（v1.7.68）', () {
    final local = <FavoriteFolder>[];
    final rem = [
      ServerPlaylist('pidJunk', '', const []), // 空名脏数据
      ServerPlaylist('pidOK', '正常收藏', ['m1']),
    ];
    final out = AppState.reconcileFolders(local, rem, 's1');
    expect(out.any((f) => f.playlistId == 'pidJunk'), isFalse);
    expect(out.any((f) => f.playlistId == 'pidOK'), isTrue);
  });
}
