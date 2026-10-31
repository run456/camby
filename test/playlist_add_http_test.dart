import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.1 回归守卫：Emby 播放列表「加片」接口的参数必须走 query。
///
/// 旧实现把 `Ids` 放在 JSON body 里，Emby 返回 2xx 却一条都没加，
/// 表现就是「播放列表建出来了、片单是空的」。
Future<HttpServer> _startServer(
  FutureOr<void> Function(HttpRequest) handler,
) async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  s.listen((req) async {
    try {
      await handler(req);
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  });
  return s;
}

EmbyServer _client(int port) => EmbyServer(
      host: '127.0.0.1',
      port: port,
      secure: false,
      username: 'u',
      password: 'p',
      kind: ServerKind.emby,
    );

void main() {
  test('addToPlaylist 把 Ids/UserId 放 query，body 为空', () async {
    Uri? captured;
    String body = 'x';
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'AccessToken': 'tok', 'User': {'Id': 'u1'}}));
        await req.response.close();
        return;
      }
      if (req.uri.path.contains('/Playlists/pl1/Items')) {
        captured = req.uri;
        final chunks = <int>[];
        await for (final c in req) {
          chunks.addAll(c);
        }
        body = utf8.decode(chunks);
      }
      req.response.statusCode = 204;
      await req.response.close();
    });

    final emby = _client(srv.port);
    await emby.authenticate();
    final ok = await emby.addToPlaylist('pl1', ['a1', 'a2']);

    expect(ok, isTrue);
    expect(captured, isNotNull);
    expect(captured!.path, endsWith('/Playlists/pl1/Items'));
    expect(captured!.queryParameters['Ids'], 'a1,a2');
    expect(captured!.queryParameters['UserId'], 'u1');
    expect(body, isEmpty, reason: '加片参数不能再放 body');
    await srv.close();
  });

  test('addToPlaylist 服务端 500 → false 且写入 lastPlaylistError', () async {
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'AccessToken': 'tok', 'User': {'Id': 'u1'}}));
        await req.response.close();
        return;
      }
      req.response.statusCode = 500;
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();
    final ok = await emby.addToPlaylist('pl1', ['a1']);
    expect(ok, isFalse);
    expect(emby.lastPlaylistError, isNotEmpty);
    await srv.close();
  });
}
