import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.21 实测反馈守卫：首页隐藏「播放列表」区块。
///
/// 收藏夹同步出的 Emby Playlist 视图（collectionType=playlists）不是媒体库，
/// 与「合集/BoxSets」一样从 /Users/{uid}/Views 结果里过滤掉。
/// 注意：本文件只能放纯 `test()`（不与 testWidgets 混用）——
/// flutter_test 一旦初始化 binding 会全局劫持 HttpClient，真 socket 假服务全部 400。
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
  test('userViews 过滤播放列表视图：collectionType=playlists 与同名兜底（v2.0.21）', () async {
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'AccessToken': 'tok',
              'User': {'Id': 'u1'},
            }),
          );
        await req.response.close();
        return;
      }
      if (req.uri.path.endsWith('/Views')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'Items': [
                {'Id': 'v1', 'Name': '电影', 'CollectionType': 'movies'},
                {'Id': 'v2', 'Name': '合集', 'CollectionType': 'boxsets'},
                {
                  'Id': 'v3',
                  'Name': '播放列表',
                  'CollectionType': 'playlists',
                },
                // 旧版 Emby 不带 collectionType，按名称兜底过滤
                {'Id': 'v4', 'Name': '播放列表'},
                {'Id': 'v5', 'Name': '电视剧', 'CollectionType': 'tvshows'},
              ],
            }),
          );
        await req.response.close();
        return;
      }
      req.response.statusCode = 204;
      await req.response.close();
    });

    final emby = _client(srv.port);
    await emby.authenticate();
    final views = await emby.userViews();
    // 只剩电影 + 电视剧；播放列表（收藏夹同步产物）与合集一样不进首页
    expect(views.map((v) => v.id), ['v1', 'v5']);
    await srv.close();
  });
}
