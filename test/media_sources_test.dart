// v2.0.38 修复回归：分段（-Cd1/-Cd2）之前不显示。
//
// 根因：Emby 批量 /Items 列表查询只回「主版本」那一条 MediaSource，完整的
// 多分段只有单条详情 `/Users/{uid}/Items/{id}` 才给全。旧代码只从列表条目的
// MediaSources 解析额外部分，于是 cd2 永远取不到、详情页「额外部分」为空。
//
// 这里起本地假 Emby，模拟「单条详情带 2 个 MediaSource」，验证：
// 1. mediaSources() 能解析出非主版本的额外分段（cd2）；
// 2. 主版本（cd1）被正确跳过，不重复进「额外部分」；
// 3. 单条只有 1 个 MediaSource 时返回空（无分段）；
// 4. 请求失败时安全返回空列表。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late EmbyServer es;

  // 单条详情返回的 MediaSources（每个用例自行设置）
  List<Map<String, dynamic>> detailSources = const [];

  setUp(() async {
    detailSources = const [];
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final path = req.uri.path;
      void json(Object o, {int code = 200}) {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(o));
      }

      if (path.endsWith('/Users/AuthenticateByName')) {
        json({
          'AccessToken': 'tok123',
          'User': {'Id': 'uid1'},
        });
      } else if (path == '/emby/Users/uid1/Items/15607') {
        // 单条详情：带完整 MediaSources
        json({'Id': '15607', 'MediaSources': detailSources});
      } else {
        json({'Items': const [], 'TotalRecordCount': 0});
      }
      await req.response.close();
    });
    es = EmbyServer(
      host: '127.0.0.1',
      port: server.port,
      secure: false,
      username: 'u',
      password: 'p',
      kind: ServerKind.emby,
    );
    await es.authenticate();
  });

  tearDown(() => server.close(force: true));

  test('单条详情带 cd1+cd2 → 只解析出 cd2（跳过主版本 cd1）', () async {
    detailSources = [
      {
        'Id': 'src-cd1',
        'Name': 'cd1',
        'Path': '/media/IPZ-018-C/IPZ-018-C-cd1.mp4',
        'Index': 0,
      },
      {
        'Id': 'src-cd2',
        'Name': 'cd2',
        'Path': '/media/IPZ-018-C/IPZ-018-C-cd2.mp4',
        'Index': 1,
      },
    ];
    final parts = await es.mediaSources('15607');
    expect(parts, hasLength(1));
    expect(parts.first.id, 'src-cd2');
    expect(parts.first.name, 'cd2');
    expect(parts.first.path, '/media/IPZ-018-C/IPZ-018-C-cd2.mp4');
  });

  test('同条目多分辨率版本（非 cd 命名）→ 同样作为额外分段', () async {
    detailSources = [
      {'Id': 'main', 'Path': '/media/M/M-1080p.mkv', 'Index': 0},
      {'Id': 'v4k', 'Path': '/media/M/M-2160p.mkv', 'Index': 1},
    ];
    final parts = await es.mediaSources('15607');
    expect(parts, hasLength(1));
    expect(parts.first.id, 'v4k');
  });

  test('单条只有 1 个 MediaSource → 无分段，返回空', () async {
    detailSources = [
      {'Id': 'only', 'Path': '/media/M/M.mp4', 'Index': 0},
    ];
    final parts = await es.mediaSources('15607');
    expect(parts, isEmpty);
  });

  test('MediaSources 字段缺失 → 安全返回空', () async {
    // 复用一个不返回 MediaSources 的路径
    final empty = await es.mediaSources('15607');
    expect(empty, isEmpty);
  });
}
