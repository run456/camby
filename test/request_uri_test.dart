import 'package:camby/emby_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.34 回归测试：请求 URI 必须**保留 path 内已内嵌的查询参数**。
///
/// 历史 bug：`Uri.parse(path).replace(queryParameters: qp)` 会把内嵌的
/// `?ParentId=..&Recursive=true` 整个覆盖掉，导致子项查询变成「查根目录全量」，
/// 表现就是「预告片子项永远查不到、只返回一堆媒体库」。
void main() {
  Uri build(String path, [Map<String, String>? query]) =>
      EmbyServer.buildRequestUri(path, query, 'TOKEN');

  test('path 内嵌的 ParentId / Recursive 不被覆盖', () {
    final u = build(
      'http://h:8096/emby/Users/u1/Items?ParentId=15512&Recursive=true',
      {'UserId': 'u1'},
    );
    expect(u.queryParameters['ParentId'], '15512');
    expect(u.queryParameters['Recursive'], 'true');
    expect(u.queryParameters['UserId'], 'u1');
    expect(u.queryParameters['X-Emby-Token'], 'TOKEN');
  });

  test('显式 query 与内嵌参数合并，显式优先', () {
    final u = build(
      'http://h:8096/emby/Items?Recursive=true',
      {'Recursive': 'false', 'Fields': 'Path'},
    );
    // 显式传入的覆盖内嵌
    expect(u.queryParameters['Recursive'], 'false');
    expect(u.queryParameters['Fields'], 'Path');
  });

  test('无内嵌 → 只有显式参数与 token', () {
    final u = build('http://h:8096/emby/Items/1/Trailer', {'UserId': 'u1'});
    expect(u.queryParameters.keys.toSet(),
        {'UserId', 'X-Emby-Token'});
  });

  test('中文/特殊字符路径参数被正确编码', () {
    final u = build('http://h:8096/emby/Items', {
      'PathStartsWith': '/media/本地珍藏/ABP-018/',
    });
    expect(u.queryParameters['PathStartsWith'], '/media/本地珍藏/ABP-018/');
    // 已编码（不应出现裸露空格/中文）
    expect(u.toString().contains('%'), isTrue);
  });
}
