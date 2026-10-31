import 'package:camby/app_state.dart';
import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假服务端：记录所有上云调用，按测试需要返回播放列表。
class _FakeServer extends EmbyServer {
  _FakeServer()
      : super(
          host: 'h',
          port: 80,
          secure: false,
          username: 'u',
          password: 'p',
          kind: ServerKind.emby,
        );

  final List<String> createdNames = [];
  final Map<String, String> renamed = {};
  final List<(String, List<String>)> added = [];
  final List<(String, List<String>)> removed = [];
  final List<String> deleted = [];
  List<ServerPlaylist> playlists = const [];
  bool failRename = false;
  bool failCreate = false;

  @override
  Future<String?> createPlaylist(String name, List<String> ids) async {
    if (failCreate) {
      lastPlaylistError = '请求失败 (500)';
      return null;
    }
    createdNames.add(name);
    return 'pl_$name';
  }

  @override
  Future<bool> renamePlaylist(String id, String name) async {
    if (failRename) {
      lastPlaylistError = '改名失败: 请求失败 (500)';
      return false;
    }
    renamed[id] = name;
    return true;
  }

  @override
  Future<bool> addToPlaylist(String id, List<String> ids) async {
    added.add((id, List<String>.from(ids)));
    return true;
  }

  @override
  Future<bool> removeFromPlaylist(String id, List<String> ids) async {
    removed.add((id, List<String>.from(ids)));
    return true;
  }

  @override
  Future<bool> deletePlaylist(String id) async {
    deleted.add(id);
    return true;
  }

  @override
  Future<List<ServerPlaylist>> listPlaylists() async => playlists;
}

AppState _state(_FakeServer s, List<FavoriteFolder> folders) {
  AppState.disablePersistence = true;
  final st = AppState();
  st.installTestServer(s, 's1', folders);
  return st;
}

void main() {
  test('上行模式：本地改名推到服务端，且服务端多出条目被补齐（APP 为准）', () async {
    final s = _FakeServer();
    s.playlists = [ServerPlaylist('pl1', '云端旧名', ['m1'])];
    final st = _state(
      s,
      [
        FavoriteFolder(
          id: 'f1',
          name: '本机新名',
          itemIds: ['m1', 'm2'],
          serverId: 's1',
          playlistId: 'pl1',
        ),
      ],
    );
    final n = await st.syncFoldersFromServer();
    expect(n, 1);
    expect(s.renamed['pl1'], '本机新名'); // 名称以 APP 为准推上去
    expect(s.added.single.$1, 'pl1');
    expect(s.added.single.$2, ['m2']); // 本地有、服务端缺的 m2 被补上
    final f = st.folders.first;
    expect(f.name, '本机新名');
    expect(f.pendingSync, isFalse);
  });

  test('上行模式：本地纯本地收藏夹被创建到服务端', () async {
    final s = _FakeServer();
    s.playlists = const [];
    final st = _state(
      s,
      [
        FavoriteFolder(
          id: 'f2',
          name: '新建夹',
          itemIds: ['x1'],
          serverId: 's1',
        ), // playlistId == null
      ],
    );
    await st.syncFoldersFromServer();
    expect(s.createdNames, contains('新建夹'));
    expect(st.folders.first.playlistId, 'pl_新建夹');
    expect(st.folders.first.pendingSync, isFalse);
  });

  test('上行模式：服务端独有空名播放列表被删，非空名被拉回本地', () async {
    final s = _FakeServer();
    s.playlists = [
      ServerPlaylist('plJunk', '', const []), // 事故脏数据 → 删
      ServerPlaylist('plOther', '另一台设备', ['z1']), // 其它设备 → 拉回
    ];
    final st = _state(
      s,
      [
        FavoriteFolder(
          id: 'f3',
          name: '我的夹',
          itemIds: ['m1'],
          serverId: 's1',
          playlistId: 'plMine',
        ),
      ],
    );
    final n = await st.syncFoldersFromServer();
    expect(s.deleted, contains('plJunk'));
    expect(n, 2); // 我的夹 + 另一台设备
    expect(
      st.folders.any((f) => f.playlistId == 'plOther' && f.name == '另一台设备'),
      isTrue,
    );
  });

  test('下行模式：本地无内容（新装）时以服务端为准拉回', () async {
    final s = _FakeServer();
    s.playlists = [
      ServerPlaylist('plA', '云端A', ['m1', 'm2']),
      ServerPlaylist('plJunk', '', const []), // 脏数据不拉回
    ];
    final st = _state(s, const []); // 本地对 s1 没有任何收藏夹
    final n = await st.syncFoldersFromServer();
    expect(n, 1);
    expect(
      st.folders.any((f) => f.playlistId == 'plA' && f.name == '云端A'),
      isTrue,
    );
    expect(s.deleted, contains('plJunk'));
  });

  test('上行模式：服务端播放列表已消失 → 用本地名称与片单重新创建（v1.7.69）', () async {
    final s = _FakeServer();
    s.playlists = const []; // 服务端空（脏数据已被清理），本地还带着旧 playlistId
    final st = _state(
      s,
      [
        FavoriteFolder(
          id: 'f5',
          name: '哈哈',
          itemIds: ['m1'],
          serverId: 's1',
          playlistId: 'plStale', // 服务端已不存在
        ),
      ],
    );
    final n = await st.syncFoldersFromServer();
    expect(s.createdNames, contains('哈哈'), reason: '必须重新创建，不能只标 pending');
    final f = st.folders.first;
    expect(f.playlistId, 'pl_哈哈');
    expect(f.pendingSync, isFalse);
    expect(st.pendingSyncCount, 0);
    expect(n, 1);
  });

  test('上行模式：改名失败 → pendingSync 置位且诊断带原因（v1.7.69）', () async {
    final s = _FakeServer();
    s.failRename = true;
    s.playlists = [ServerPlaylist('pl1', '云端旧名', ['m1'])];
    final st = _state(
      s,
      [
        FavoriteFolder(
          id: 'f6',
          name: '本机新名',
          itemIds: ['m1'],
          serverId: 's1',
          playlistId: 'pl1',
        ),
      ],
    );
    await st.syncFoldersFromServer();
    expect(st.folders.first.pendingSync, isTrue);
    expect(st.pendingSyncCount, 1);
    expect(st.folderSyncDiag, contains('改名失败'));
    expect(st.folderSyncDiag, contains('本机新名'));
    // 改名失败不应阻断片单同步
    expect(s.added, isEmpty, reason: '本地与服务端片单一致时无需加片');
  });

  test('上云失败时标记 pendingSync，诊断带具体原因', () async {
    final s = _FakeServer();
    s.failCreate = true; // createPlaylist 永远失败
    s.playlists = const [];
    final st = _state(
      s,
      [
        FavoriteFolder(
          id: 'f4',
          name: '上云失败',
          itemIds: const [],
          serverId: 's1',
        ),
      ],
    );
    await st.syncFoldersFromServer();
    expect(st.folders.first.pendingSync, isTrue);
    expect(st.pendingSyncCount, 1);
    expect(st.folderSyncDiag, contains('创建失败'));
  });
}
