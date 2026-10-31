// v1.7.69：起一个本地假 Emby HTTP 服务，验证播放列表 API 的**真实网络行为**——
// 1. createPlaylist 的 Name/Ids/UserId 必须在 URL query 上（v1.7.67 事故根因）；
// 2. 服务端 2xx 但空 body 不回 Id 时，按名字重新拉列表兜底；
// 3. renamePlaylist 先 GET 完整对象再 POST 写回（不丢字段）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Record {
  _Record(this.method, this.path, this.query, this.body);
  final String method;
  final String path;
  final Map<String, String> query;
  final String body;
}

void main() {
  late HttpServer server;
  late EmbyServer es;
  final records = <_Record>[];

  // 行为开关（每个用例自行设置）
  var createResponseBody = '{"Id":"PL1"}';

  setUp(() async {
    records.clear();
    createResponseBody = '{"Id":"PL1"}';
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      records.add(_Record(req.method, req.uri.path,
          Map<String, String>.from(req.uri.queryParameters), body));
      final path = req.uri.path;
      Future<void> json(Object o) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(o));
        await req.response.close();
      }

      if (path.endsWith('/Users/AuthenticateByName')) {
        await json({'AccessToken': 'tok123', 'User': {'Id': 'uid1'}});
      } else if (path == '/emby/Users/uid1/Playlists' ||
          path == '/emby/Playlists') {
        // 创建播放列表
        if (createResponseBody == '__500__') {
          req.response.statusCode = 500;
          req.response.write('Internal Server Error');
          await req.response.close();
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(createResponseBody);
          await req.response.close();
        }
      } else if (path == '/emby/Users/uid1/Items' &&
          req.uri.queryParameters['IncludeItemTypes'] == 'Playlist') {
        // listPlaylists
        await json({
          'Items': [
            {'Id': 'PL9', 'Name': '按名兜底', 'PlaylistItems': []},
          ],
          'TotalRecordCount': 1,
        });
      } else if (path == '/emby/Users/uid1/Items/PL1') {
        // GET 完整对象（rename 第一步）
        await json({'Id': 'PL1', 'Name': '旧名', 'Genres': ['Drama']});
      } else if (path == '/emby/Items/PL1') {
        await json({'Id': 'PL1'});
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
    es = EmbyServer(
      host: '127.0.0.1',
      port: server.port,
      secure: false,
      username: 'u',
      password: 'p',
    );
    await es.authenticate();
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('createPlaylist：Name/Ids/UserId 走 URL query，body 为空，返回服务端 Id',
      () async {
    final id = await es.createPlaylist('测试夹', ['i1', 'i2']);
    expect(id, 'PL1');
    final create = records
        .firstWhere((r) => r.path == '/emby/Users/uid1/Playlists');
    expect(create.method, 'POST');
    // v1.7.67 事故根因回归守卫：参数必须在 query 上
    expect(create.query['Name'], '测试夹');
    expect(create.query['Ids'], 'i1,i2');
    expect(create.query['UserId'], 'uid1');
    expect(create.query['MediaType'], 'Video');
    expect(create.body, isEmpty, reason: 'body 必须留空（Emby 不读 body 参数）');
  });

  test('createPlaylist：2xx 空 body 不回 Id → 按名字重新拉列表兜底', () async {
    createResponseBody = ''; // 模拟部分 Emby 版本不回 Id
    final id = await es.createPlaylist('按名兜底', const []);
    expect(id, 'PL9', reason: '空 body 时应通过 listPlaylists 按名字匹配');
    expect(es.lastPlaylistError, isEmpty);
  });

  test('createPlaylist：服务端 500 → 返回 null 且 lastPlaylistError 带状态码',
      () async {
    createResponseBody = '__500__';
    final id = await es.createPlaylist('会失败', const []);
    expect(id, isNull);
    expect(es.lastPlaylistError, contains('500'));
  });

  test('renamePlaylist：先 GET 完整对象再 POST，写回携带原有字段', () async {
    final ok = await es.renamePlaylist('PL1', '新名');
    expect(ok, isTrue);
    final get = records
        .firstWhere((r) => r.path == '/emby/Users/uid1/Items/PL1');
    expect(get.method, 'GET');
    final post = records.firstWhere(
        (r) => r.method == 'POST' && r.path == '/emby/Items/PL1');
    final sent = jsonDecode(post.body) as Map<String, dynamic>;
    expect(sent['Name'], '新名');
    expect(sent['Genres'], ['Drama'], reason: '原字段不能被整包覆盖丢掉');
  });
}
