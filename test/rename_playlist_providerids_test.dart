import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.4 回归守卫：收藏夹改名 400。
///
/// 根因：Emby `ItemUpdateService.UpdateItem`（`ItemUpdateService.cs:327`）
/// 对 `request.ProviderIds` 直接 `.ToList()`；而 `GET /Users/{uid}/Items/{id}`
/// 默认**不返回** `ProviderIds`（`DtoService.cs:861` 仅在请求 ProviderIds 字段
/// 时才塞进 DTO），于是回传的 DTO 里 `ProviderIds` 为 null → 服务端
/// `ArgumentNullException: source` → **400**。播放列表本就没有 ProviderIds。
///
/// 守卫点：改名时 POST /Items/{id} 的 body 必须带上非 null 的 `ProviderIds`，
/// 否则真实服务器会 400。
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
  test('改名 POST 的 body 必须含非 null 的 ProviderIds（否则 Emby 400）', () async {
    Map<String, dynamic>? posted;
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'AccessToken': 'tok', 'User': {'Id': 'u1'}}));
        await req.response.close();
        return;
      }
      // 模拟 Emby 默认 GET：返回的播放列表 DTO 里**没有 ProviderIds**
      if (req.method == 'GET' && req.uri.path.contains('/Users/u1/Items/pl1')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'Id': 'pl1',
            'Name': '人妻',
            'Type': 'Playlist',
            'Genres': const [],
            'Tags': const [],
          }));
        await req.response.close();
        return;
      }
      // 改名 POST
      if (req.method == 'POST' && req.uri.path.contains('/Items/pl1')) {
        final chunks = <int>[];
        await for (final c in req) {
          chunks.addAll(c);
        }
        posted = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }
      req.response.statusCode = 204;
      await req.response.close();
    });

    final emby = _client(srv.port);
    await emby.authenticate();
    final ok = await emby.renamePlaylist('pl1', '人妻改名后');

    expect(ok, isTrue, reason: '带上 ProviderIds 后改名应成功');
    expect(posted, isNotNull);
    // 关键：body 必须有 ProviderIds 且非空引用（null 会在服务端 .ToList() 抛 400）
    expect(posted!.containsKey('ProviderIds'), isTrue,
        reason: '必须带上 ProviderIds 字段');
    expect(posted!['ProviderIds'], isNotNull,
        reason: 'ProviderIds 为 null 会被 Emby .ToList() 抛 400');
    expect(posted!['ProviderIds'], isA<Map>());
    // 名称确实改了
    expect(posted!['Name'], '人妻改名后');
    await srv.close();
  });

  test('Emby 若收不到 ProviderIds 会 400：模拟该服务端行为，断言旧实现会失败', () async {
    // 用一个会“对 null ProviderIds 返回 400”的服务端，验证修复后不再触发
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'AccessToken': 'tok', 'User': {'Id': 'u1'}}));
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && req.uri.path.contains('/Users/u1/Items/plx')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'Id': 'plx', 'Name': '老名字', 'Type': 'Playlist'}));
        await req.response.close();
        return;
      }
      if (req.method == 'POST' && req.uri.path.contains('/Items/plx')) {
        final chunks = <int>[];
        await for (final c in req) {
          chunks.addAll(c);
        }
        final body = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
        // 复刻 Emby UpdateItem 的行为：ProviderIds 缺失/null → 400
        if (!body.containsKey('ProviderIds') || body['ProviderIds'] == null) {
          req.response.statusCode = 400;
        } else {
          req.response.statusCode = 204;
        }
        await req.response.close();
        return;
      }
      req.response.statusCode = 204;
      await req.response.close();
    });

    final emby = _client(srv.port);
    await emby.authenticate();
    final ok = await emby.renamePlaylist('plx', '新名字');
    expect(ok, isTrue, reason: '修复后 body 带 ProviderIds，服务端不再 400');
    await srv.close();
  });
}
