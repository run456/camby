import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.7.73：会话型播放上报（/Sessions/Playing|Progress|Stopped）契约测试。
///
/// 背景：统计页「每日观看时长/播放时段/常看作品」的数据源是服务器活动日志，
/// 只有会话型播放才写入。此前 APP 只走 UserData 直写，日志里没有本 APP 的
/// 播放事件，1.7.72 按账号过滤后统计页全空。这里验证会话三事件按预期发出。
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
  test('会话三事件：Playing → Progress → Stopped 依次正确发出', () async {
    final hits = <String, String>{};
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'AccessToken': 'tok', 'User': {'Id': 'u1'}}));
        await req.response.close();
        return;
      }
      final p = req.uri.path;
      if (p.endsWith('/Sessions/Playing')) {
        hits['start'] = await _readBody(req);
      } else if (p.endsWith('/Sessions/Playing/Progress')) {
        hits['progress'] = await _readBody(req);
      } else if (p.endsWith('/Sessions/Stopped')) {
        hits['stop'] = await _readBody(req);
      }
      req.response.statusCode = 204;
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();

    await emby.reportPlaybackStart('item1');
    await emby.reportPlaybackProgress('item1', 600000000);
    await emby.reportPlaybackStop('item1', 900000000, played: true);

    expect(hits['start'], contains('"ItemId":"item1"'));
    expect(hits['progress'], contains('"PositionTicks":600000000'));
    expect(hits['stop'], contains('"ItemId":"item1"'));
    expect(hits['stop'], contains('"PositionTicks":900000000'));
    expect(hits['stop'], contains('"Played":true'));
    await srv.close();
  });

  test('会话事件失败不抛、不影响播放（服务端 500）', () async {
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
    // 三个调用都不应抛异常
    await emby.reportPlaybackStart('item1');
    await emby.reportPlaybackProgress('item1', 1);
    await emby.reportPlaybackStop('item1', 1);
    await srv.close();
  });
}
