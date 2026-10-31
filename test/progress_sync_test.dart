import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用临时本地 HTTP server 验证报告进度接口的契约。
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

Future<String> _readBody(HttpRequest req) async {
  final buf = <int>[];
  await for (final chunk in req) {
    buf.addAll(chunk);
  }
  return utf8.decode(buf);
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
  test('reportProgress 写 Played、返回 true（服务端 200）', () async {
    String? captured;
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'AccessToken': 'tok', 'User': {'Id': 'u1'}}));
        await req.response.close();
        return;
      }
      if (req.uri.path.contains('UserData')) captured = await _readBody(req);
      req.response.statusCode = 200;
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();
    final ok = await emby.reportProgress('item1', 12345, played: true);
    expect(ok, isTrue);
    expect(captured, contains('"PlaybackPositionTicks":12345'));
    expect(captured, contains('"Played":true'));

    // played=false 时不应再带 Played 字段
    await emby.reportProgress('item2', 999, played: false);
    expect(captured, contains('"ItemId":"item2"'));
    expect(captured, isNot(contains('"Played":true')));
    await srv.close();
  });

  test('reportProgress 服务端 500 → 返回 false 且不抛', () async {
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
    final ok = await emby.reportProgress('item1', 1);
    expect(ok, isFalse); // 旧实现会把 500 当成成功，这里必须返回 false
    await srv.close();
  });

  test('reportProgress 未登录（无 token）→ 直接 false 不抛', () async {
    final emby = EmbyServer(
      host: '127.0.0.1',
      port: 1,
      secure: false,
      username: 'u',
      password: 'p',
      kind: ServerKind.emby,
    );
    final ok = await emby.reportProgress('item1', 1);
    expect(ok, isFalse);
  });
}
