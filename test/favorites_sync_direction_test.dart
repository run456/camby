import 'dart:io';

import 'package:camby/app_state.dart';
import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.105：收藏同步拆成「上传 / 下载」两个显式方向，各自可选
/// 「覆盖 / 合并」。本文件锁住四种组合的语义，防止再出现「平板旧数据
/// 反向覆盖手机新数据」的串台。
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

  @override
  Future<String?> createPlaylist(String name, List<String> ids) async {
    createdNames.add(name);
    return 'pl_$name';
  }

  @override
  Future<String?> renamePlaylist(
    String id,
    String name, {
    List<String>? itemIds,
  }) async {
    renamed[id] = name;
    return id;
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

bool _addedContains(_FakeServer s, String pid, String item) =>
    s.added.any((e) => e.$1 == pid && e.$2.contains(item));

bool _removedContains(_FakeServer s, String pid, String item) =>
    s.removed.any((e) => e.$1 == pid && e.$2.contains(item));

void main() {
  group('下载（服务端 → 本地）', () {
    test('覆盖：名称与片单都以服务端为准，本机独有夹被移除，跨服夹保留', () async {
      final s = _FakeServer()
        ..playlists = [ServerPlaylist('p1', '云端', ['m1', 'm2'])];
      final st = _state(s, [
        FavoriteFolder(
          id: 'fLocal',
          name: '本机独有',
          itemIds: ['x'],
          serverId: 's1',
        ), // 未上云
        FavoriteFolder(
          id: 'fSame',
          name: '旧名',
          itemIds: ['m1', 'm9'],
          serverId: 's1',
          playlistId: 'p1',
        ),
        FavoriteFolder(
          id: 'fOther',
          name: '别服夹',
          itemIds: ['o'],
          serverId: 's2',
          playlistId: 'pOther',
        ),
      ]);
      final n = await st.downloadFoldersFromServer(overwrite: true);
      expect(n, 1, reason: '当前服务器只剩服务端那一个夹');
      final f = st.folders.firstWhere((e) => e.playlistId == 'p1');
      expect(f.name, '云端');
      expect(f.itemIds, ['m1', 'm2'], reason: '覆盖 = 服务端快照，本机多出的 m9 被移除');
      expect(st.folders.any((e) => e.id == 'fLocal'), isFalse);
      expect(
        st.folders.any((e) => e.id == 'fOther'),
        isTrue,
        reason: '其它服务器的收藏夹不受影响',
      );
    });

    test('合并：两端取并集，本机未上云的夹也保留', () async {
      final s = _FakeServer()
        ..playlists = [ServerPlaylist('p1', '云端', ['m1', 'm2'])];
      final st = _state(s, [
        FavoriteFolder(
          id: 'fLocal',
          name: '本机独有',
          itemIds: ['x'],
          serverId: 's1',
        ),
        FavoriteFolder(
          id: 'fSame',
          name: '旧名',
          itemIds: ['m1', 'm9'],
          serverId: 's1',
          playlistId: 'p1',
        ),
      ]);
      await st.downloadFoldersFromServer(overwrite: false);
      final f = st.folders.firstWhere((e) => e.playlistId == 'p1');
      expect(f.itemIds, containsAll(<String>['m1', 'm2', 'm9']));
      expect(st.folders.any((e) => e.id == 'fLocal'), isTrue);
    });

    test('下载绝不写回服务端（无 create/rename/add/remove/delete）', () async {
      final s = _FakeServer()
        ..playlists = [ServerPlaylist('p1', '云端', ['m1'])];
      final st = _state(s, [
        FavoriteFolder(
          id: 'f1',
          name: '本机',
          itemIds: ['m1', 'm9'],
          serverId: 's1',
          playlistId: 'p1',
        ),
      ]);
      await st.downloadFoldersFromServer(overwrite: true);
      expect(s.createdNames, isEmpty);
      expect(s.renamed, isEmpty);
      expect(s.added, isEmpty);
      expect(s.removed, isEmpty);
      expect(s.deleted, isEmpty);
    });
  });

  group('上传（本地 → 服务端）', () {
    test('覆盖：服务端以本机为准，删多余夹与多余影片', () async {
      final s = _FakeServer()
        ..playlists = [
          ServerPlaylist('p1', '云端旧名', ['m1', 'm3']),
          ServerPlaylist('pOther', '别设备', ['z']),
        ];
      final st = _state(s, [
        FavoriteFolder(
          id: 'f1',
          name: '本机名',
          itemIds: ['m1', 'm2'],
          serverId: 's1',
          playlistId: 'p1',
        ),
      ]);
      await st.uploadFoldersToServer(overwrite: true);
      expect(s.renamed['p1'], '本机名');
      expect(_addedContains(s, 'p1', 'm2'), isTrue);
      expect(_removedContains(s, 'p1', 'm3'), isTrue, reason: '覆盖会删服务端多出的影片');
      expect(s.deleted, contains('pOther'), reason: '覆盖会删服务端独有的夹');
      expect(st.folders.length, 1);
      expect(st.folders.single.itemIds, ['m1', 'm2']);
    });

    test('合并：保留服务端独有夹与影片，并把它们带回本机', () async {
      final s = _FakeServer()
        ..playlists = [
          ServerPlaylist('p1', '云端旧名', ['m1', 'm3']),
          ServerPlaylist('pOther', '别设备', ['z']),
        ];
      final st = _state(s, [
        FavoriteFolder(
          id: 'f1',
          name: '本机名',
          itemIds: ['m1', 'm2'],
          serverId: 's1',
          playlistId: 'p1',
        ),
      ]);
      await st.uploadFoldersToServer(overwrite: false);
      expect(_addedContains(s, 'p1', 'm2'), isTrue);
      expect(_removedContains(s, 'p1', 'm3'), isFalse, reason: '合并不删服务端影片');
      expect(s.deleted, isNot(contains('pOther')), reason: '合并不删服务端独有的夹');
      final f = st.folders.firstWhere((e) => e.playlistId == 'p1');
      expect(f.itemIds, containsAll(<String>['m1', 'm2', 'm3']));
      expect(
        st.folders.any((e) => e.playlistId == 'pOther' && e.name == '别设备'),
        isTrue,
        reason: '服务端独有的夹被拉回本机',
      );
    });
  });

  group('入口与 UI 守卫', () {
    test('连接服务器与设置页恢复都只走下行，不再自动上行覆盖', () {
      final app = File('lib/app_state.dart').readAsStringSync();
      final connectAt = app.indexOf('Future<bool> connect(');
      final seg = app.substring(connectAt, connectAt + 6000);
      expect(
        seg.contains('downloadFoldersFromServer(overwrite: false)'),
        isTrue,
        reason: '连接时只能下行合并',
      );
      expect(
        seg.contains('await syncFoldersFromServer()'),
        isFalse,
        reason: '禁止连接时触发旧的上行覆盖',
      );
      final settings = File('lib/pages/settings_page.dart').readAsStringSync();
      expect(
        settings.contains('downloadFoldersFromServer(overwrite: false)'),
        isTrue,
      );
    });

    test('收藏页提供上传/下载双按钮与覆盖/合并选项', () {
      final src = File('lib/pages/favorites_page.dart').readAsStringSync();
      expect(src.contains("ValueKey('fav-upload')"), isTrue);
      expect(src.contains("ValueKey('fav-download')"), isTrue);
      expect(src.contains("title: '覆盖'"), isTrue);
      expect(src.contains("title: '合并'"), isTrue);
      expect(src.contains('uploadFoldersToServer('), isTrue);
      expect(src.contains('downloadFoldersFromServer('), isTrue);
      expect(src.contains('class _SyncButton '), isFalse);
    });
  });
}
