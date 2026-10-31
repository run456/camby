import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.2：会话上报的**双形态**契约 + 播放历史兜底。
///
/// 背景：真机上 2.0.1 仍看不到活动记录。Emby 10.9 起 `/Sessions/Playing`
/// 等接口用 `[FromQuery]` 绑定模型，只认 query 参数、忽略 body JSON ——
/// 参数发在 body 里时服务端 204 但 ItemId 为空，活动日志一条不落。
/// 和 addToPlaylist 踩的是同一个坑。这里锁死「两种形态都发、任一成功即成功」。
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

Future<void> _auth(HttpRequest req) async {
  req.response
    ..statusCode = 200
    ..headers.contentType = ContentType.json
    ..write(jsonEncode({'AccessToken': 'tok', 'User': {'Id': 'u1'}}));
  await req.response.close();
}

void main() {
  test('会话事件先按 query 发（Emby 10.9+），ItemId 必须在 query 里', () async {
    final queries = <String, Map<String, String>>{};
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) return _auth(req);
      final p = req.uri.path;
      final key = p.endsWith('/Sessions/Playing')
          ? 'start'
          : p.endsWith('/Sessions/Playing/Progress')
              ? 'progress'
              : p.endsWith('/Sessions/Stopped')
                  ? 'stop'
                  : null;
      if (key != null) {
        queries[key] = req.uri.queryParameters;
        await _readBody(req);
      }
      req.response.statusCode = 204;
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();

    await emby.reportPlaybackStart('item1', positionTicks: 50000000);
    await emby.reportPlaybackProgress('item1', 600000000);
    await emby.reportPlaybackStop('item1', 900000000, played: true);

    expect(queries['start']?['ItemId'], 'item1');
    expect(queries['start']?['PlaySessionId'], isNotEmpty);
    expect(queries['start']?['PositionTicks'], '50000000');
    // 三个事件共用同一个 PlaySessionId，服务端才能算成一段播放
    expect(queries['progress']?['PlaySessionId'], queries['start']?['PlaySessionId']);
    expect(queries['progress']?['PositionTicks'], '600000000');
    expect(queries['stop']?['PlaySessionId'], queries['start']?['PlaySessionId']);
    expect(queries['stop']?['PositionTicks'], '900000000');
    expect(queries['stop']?['Played'], 'true');
    expect(emby.lastSessionError, isEmpty);
    await srv.close();
  });

  test('服务端只认 body（Jellyfin/旧版 Emby）：query 被拒后自动改发 body', () async {
    String? body;
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) return _auth(req);
      final b = await _readBody(req);
      if (req.uri.path.endsWith('/Sessions/Playing')) {
        // 模拟「不接受 query 参数」的服务端
        if (req.uri.queryParameters.containsKey('ItemId')) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        body = b;
      }
      req.response.statusCode = 204;
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();

    await emby.reportPlaybackStart('item9', positionTicks: 100);
    expect(body, contains('"ItemId":"item9"'));
    expect(emby.lastSessionError, isEmpty);
    await srv.close();
  });

  test('两种形态都失败时把原因写进 lastSessionError（不再静默）', () async {
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) return _auth(req);
      req.response.statusCode = 500;
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();
    await emby.reportPlaybackStart('item1');
    expect(emby.lastSessionError, contains('开始播放上报失败'));
    await srv.close();
  });

  test('停止事件在会话缺失时先补一次 Playing，避免被服务端忽略', () async {
    final paths = <String>[];
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) return _auth(req);
      paths.add(req.uri.path);
      await _readBody(req);
      req.response.statusCode = 204;
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();
    // 模拟 App 被杀后重进、直接退出的情况：没有会话就发 Stopped
    await emby.reportPlaybackStop('item2', 1000);
    expect(paths.first, endsWith('/Sessions/Playing'));
    expect(paths.last, endsWith('/Sessions/Stopped'));
    await srv.close();
  });

  test('播放历史走 /Users/{id}/Items?Filters=IsPlayed（不依赖活动日志权限）', () async {
    Uri? got;
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) return _auth(req);
      got = req.uri;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'Items': [
            {'Id': 'm1', 'Name': '片一', 'Type': 'Movie', 'UserData': {'Played': true}},
          ],
        }));
      await req.response.close();
    });
    final emby = _client(srv.port);
    await emby.authenticate();
    final list = await emby.playedHistory(limit: 5);
    expect(got?.path, contains('/Users/u1/Items'));
    expect(got?.queryParameters['Filters'], 'IsPlayed');
    expect(got?.queryParameters['Limit'], '5');
    expect(list.map((e) => e.id), contains('m1'));
    await srv.close();
  });
}
