// v2.0.40 回归：分段（-cd2）被「ChildCount==0 闸门」挡掉。
//
// 实测：15607 = IPZ-018-C-cd1.mp4，同目录有 -cd2.mp4。
// 两个文件属于**同一个 Emby 条目**，所以 ChildCount 天然是 0。
// 旧代码 `if (dir.isEmpty || childCount == 0) return out;` 直接把兜底
// （按目录前缀全库反查）掐死，cd2 永远取不到。
//
// 本测试起假 Emby：
//   - /Users/uid1/Items/15607 详情：Path 指向目录，ChildCount=0
//   - 所有 SpecialFeatures / ParentId 子项：返回空（模拟真实 404 那套）
//   - /Items 全库：同目录下有 cd1（本条）、cd2（独立条目）、trailer
// 断言：extraParts('15607') 必须拿到 cd2，且排除自身与预告片。
import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = '/media/本地珍藏-顶级美女/(1987-归档) 美雪ありす/1080P FHD版本/'
    '[2013] IPZ-018-C 黑丝女教师美雪艾莉丝的淫语教学/';

void main() {
  late HttpServer server;
  late EmbyServer es;

  setUp(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final path = req.uri.path;
      final q = req.uri.queryParameters;
      void json(Object o) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(o));
      }

      if (path.endsWith('/Users/AuthenticateByName')) {
        json({
          'AccessToken': 'tok',
          'User': {'Id': 'uid1'},
        });
      } else if (path == '/emby/Users/uid1/Items/15607') {
        // 关键：ChildCount = 0（分段影片的典型值）
        json({
          'Id': '15607',
          'Path': '${_dir}IPZ-018-C-cd1.mp4',
          'ChildCount': 0,
          'MediaSources': [
            {'Id': 'ms-cd1', 'Path': '${_dir}IPZ-018-C-cd1.mp4', 'Index': 0},
          ],
        });
      } else if (path.contains('SpecialFeatures') ||
          q['ParentId'] == '15607') {
        // 子项/花絮入口一律空（复现实测里的 0 项 / 404）
        json({'Items': const [], 'TotalRecordCount': 0});
      } else if (path == '/emby/Items') {
        // 全库扫描：同目录下的三个条目
        json({
          'Items': [
            {
              'Id': '15607',
              'Name': '正片',
              'Type': 'Movie',
              'Path': '${_dir}IPZ-018-C-cd1.mp4',
            },
            {
              'Id': 'cd2-id',
              'Name': 'IPZ-018-C-cd2',
              'Type': 'Video',
              'ExtraType': 'Clip',
              'Path': '${_dir}IPZ-018-C-cd2.mp4',
            },
            {
              'Id': 'trailer-id',
              'Name': 'Trailer',
              'Type': 'Video',
              'ExtraType': 'Trailer',
              'Path': '${_dir}trailers/trailer.mp4',
            },
            {
              // 同盘但不同影片目录，必须被前缀过滤掉
              'Id': 'other-id',
              'Name': '别的片',
              'Type': 'Movie',
              'Path': '/media/别的片/other.mp4',
            },
          ],
          'TotalRecordCount': 4,
        });
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

  test('ChildCount=0 也要走同目录兜底，拿到 cd2', () async {
    final parts = await es.extraParts('15607');
    final names = parts.map((e) => e.name).toList();
    expect(names, contains('IPZ-018-C-cd2'), reason: 'ChildCount=0 不应阻断兜底');
    expect(names, isNot(contains('正片')), reason: '不应把影片自身列进来');
  });

  test('同目录兜底排除预告片（预告片归「预告片」栏目）', () async {
    final parts = await es.extraParts('15607');
    expect(parts.map((e) => e.id), isNot(contains('trailer-id')));
  });

  test('同目录兜底只认同一影片文件夹，不串到别的片', () async {
    final parts = await es.extraParts('15607');
    expect(parts.map((e) => e.id), isNot(contains('other-id')));
  });
}
