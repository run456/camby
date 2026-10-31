import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0：活动日志「本账号」归属判定回归测试。
///
/// 背景：1.7.72 用严格 `UserId == _userId` 过滤，把本账号网页/TV 的播放也一并
/// 丢弃（Emby 同一账号在不同接口里 GUID 可能带/不带连字符，播放事件还可能
/// 不带 UserId），导致统计页三条卡片全空。这里用本地 mock 服务器还原该场景。
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

const _myId = 'a1b2c3d4-0000-0000-0000-000000000001';

EmbyServer _client(int port) => EmbyServer(
      host: '127.0.0.1',
      port: port,
      secure: false,
      username: 'u',
      password: 'p',
      kind: ServerKind.emby,
    );

void main() {
  test('本账号播放不被误杀：GUID 带/不带连字符、大小写、空 UserId 都算本人', () async {
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'AccessToken': 'tok',
            'User': {'Id': _myId},
          }));
        await req.response.close();
        return;
      }
      if (req.uri.path.contains('ActivityLog/Entries')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'Items': [
              // 本人：带连字符、大写
              {
                'Type': 'PlaybackStart',
                'Date': '2026-10-30T10:00:00.0000000Z',
                'ItemId': 'itemA',
                'UserId': _myId.toUpperCase(),
              },
              // 本人：不带连字符、小写（同一账号的另一种写法）
              {
                'Type': 'PlaybackStop',
                'Date': '2026-10-30T11:00:00.0000000Z',
                'ItemId': 'itemA',
                'UserId': _myId.replaceAll('-', '').toLowerCase(),
              },
              // 本人：播放事件没带 UserId（单账号服务器常态）
              {
                'Type': 'PlaybackStart',
                'Date': '2026-10-30T12:00:00.0000000Z',
                'ItemId': 'itemB',
              },
              // 别人的播放：必须排除
              {
                'Type': 'PlaybackStart',
                'Date': '2026-10-30T13:00:00.0000000Z',
                'ItemId': 'itemC',
                'UserId': 'ffffffff-0000-0000-0000-000000000009',
              },
            ],
          }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      await req.response.close();
    });

    final emby = _client(srv.port);
    await emby.authenticate();
    final summary = await emby.activityLog();

    expect(summary, isNotNull);
    // itemA（本人）+ itemB（空 UserId 视为本人）= 2，itemC 排除
    expect(summary!.total, 2);
    expect(summary.itemPlays.containsKey('itemA'), isTrue);
    expect(summary.itemPlays.containsKey('itemB'), isTrue);
    expect(summary.itemPlays.containsKey('itemC'), isFalse);
    // itemA 10:00→11:00 配对出 60 分钟
    expect(summary.totalMinutes, closeTo(60, 0.001));
    await srv.close();
  });

  test('全是他人账号 → 返回 null，但诊断信息给出原因', () async {
    final srv = await _startServer((req) async {
      if (req.uri.path.contains('AuthenticateByName')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'AccessToken': 'tok',
            'User': {'Id': _myId},
          }));
        await req.response.close();
        return;
      }
      if (req.uri.path.contains('ActivityLog/Entries')) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'Items': [
              {
                'Type': 'PlaybackStart',
                'Date': '2026-10-30T10:00:00.0000000Z',
                'ItemId': 'itemX',
                'UserId': 'ffffffff-0000-0000-0000-000000000009',
              },
            ],
          }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      await req.response.close();
    });

    final emby = _client(srv.port);
    await emby.authenticate();
    final summary = await emby.activityLog();
    expect(summary, isNull);
    expect(emby.lastActivityDiag, contains('日志播放 1 条'));
    expect(emby.lastActivityDiag, contains('本账号 0 条'));
    await srv.close();
  });
}
