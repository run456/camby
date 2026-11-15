import 'dart:io';

import 'package:camby/ugreen_resource.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.91：绿联「点播放全部 404」的回归守卫。
///
/// 真机证据（v2.0.90 播放诊断）：
/// ```
/// ✗ /Videos/9669/stream                  HTTP 404
/// ✗ /Videos/9669/stream?Static=true      HTTP 404
/// ✗ /emby/Videos/9669/stream             HTTP 404 · text/plain
/// ✗ /emby/Videos/9669/stream?Static=true HTTP 404 · text/plain
/// ```
/// 而登录、拉库、海报都正常。结论：**404 不是「路径拼错」**——绿联只在
/// Item 的 `MediaSources[].SupportedStreamingProtocols` 登记过的协议上
/// 才暴露流端点，没登记一律 404。所以正确做法是先读声明，再按声明取流，
/// 而不是继续枚举 URL。
String src(String path) => File(path).readAsStringSync();

const String kRoot = 'https://192.168.5.29:9443';

void main() {
  group('SupportedStreamingProtocols 解析', () {
    test('标准 Emby 的逗号串（含大小写混杂 / 空格 / 重复）被归一', () {
      final p = parseStreamingProtocols(<dynamic>[
        <String, dynamic>{'SupportedStreamingProtocols': 'Http,Http,Sync'},
      ]);
      expect(p, <String>['http', 'sync']);
    });

    test('数组形态与多条 MediaSource 合并去重', () {
      final p = parseStreamingProtocols(<dynamic>[
        <String, dynamic>{
          'SupportedStreamingProtocols': <String>['HLS', 'Http'],
        },
        <String, dynamic>{'SupportedStreamingProtocols': 'file'},
      ]);
      expect(p, <String>['hls', 'http', 'file']);
    });

    test('缺字段 / 空 / 非列表输入都返回空，不抛异常', () {
      expect(parseStreamingProtocols(null), isEmpty);
      expect(parseStreamingProtocols(<dynamic>[]), isEmpty);
      expect(parseStreamingProtocols(<dynamic>[
        <String, dynamic>{'SupportedStreamingProtocols': ''},
      ]), isEmpty);
      expect(parseStreamingProtocols(<String, dynamic>{}), isEmpty);
    });
  });

  group('按声明协议拼端点', () {
    test('声明 http → 根路径 stream（含无 Static 与 Static 两种）', () {
      final u = urlsForProtocols(
        protocols: <String>['http'],
        rootUrl: kRoot,
        itemId: '9669',
        apiKey: 'T',
        enabled: true,
      );
      expect(u.first, '$kRoot/Videos/9669/stream?api_key=T');
      expect(u[1], '$kRoot/Videos/9669/stream?Static=true&api_key=T');
      // 声明的协议是 http，就不该再去试 /emby 前缀
      expect(u.any((e) => e.contains('/emby/')), isFalse);
    });

    test('声明 hls → master.m3u8', () {
      final u = urlsForProtocols(
        protocols: <String>['hls'],
        rootUrl: kRoot,
        itemId: '9669',
        apiKey: 'T',
        enabled: true,
      );
      expect(u, <String>['$kRoot/Videos/9669/master.m3u8?api_key=T']);
    });

    test('只声明 file → /Items/{id}/File（没有 stream 路由）', () {
      final u = urlsForProtocols(
        protocols: <String>['file'],
        rootUrl: kRoot,
        itemId: '9669',
        apiKey: 'T',
        enabled: true,
      );
      expect(u, <String>['$kRoot/Items/9669/File?api_key=T']);
    });

    test('http + file 同时声明时两种都给，stream 在前', () {
      final u = urlsForProtocols(
        protocols: <String>['http', 'file'],
        rootUrl: kRoot,
        itemId: '9669',
        apiKey: 'T',
        enabled: true,
      );
      expect(u.first, contains('/Videos/9669/stream'));
      expect(u.last, contains('/Items/9669/File'));
    });

    test('一个都没声明时只回 fallback，绝不凭空造 URL', () {
      final u = urlsForProtocols(
        protocols: const <String>[],
        rootUrl: kRoot,
        itemId: '9669',
        apiKey: 'T',
        fallback: '$kRoot/Videos/9669/stream?api_key=T',
        enabled: true,
      );
      expect(u, <String>['$kRoot/Videos/9669/stream?api_key=T']);
      // 不带 fallback 时应当为空 —— 让上层走「诊断 + 提示」
      expect(
        urlsForProtocols(
          protocols: const <String>[],
          rootUrl: kRoot,
          itemId: '9669',
          enabled: true,
        ),
        isEmpty,
      );
    });
  });

  group('状态码语义', () {
    test('404 不再被当成「路径写错」', () {
      expect(describeStreamStatus(404), contains('未声明'));
      expect(describeStreamStatus(404), contains('不是路径拼错'));
    });

    test('404 / 401 / 403 不值得换路径重试，5xx 与 416 值得', () {
      expect(shouldTryNextStream(404), isFalse);
      expect(shouldTryNextStream(403), isFalse);
      expect(shouldTryNextStream(401), isFalse);
      expect(shouldTryNextStream(500), isTrue);
      expect(shouldTryNextStream(416), isTrue);
      expect(shouldTryNextStream(null), isTrue); // 超时 / 无响应
    });

    test('能力结论文案覆盖四条主分支', () {
      const none = StreamCapability();
      expect(none.verdict, contains('MediaSources'));

      const undeclared = StreamCapability(mediaSourceCount: 1);
      expect(undeclared.verdict, contains('没有 SupportedStreamingProtocols'));

      const forbidden = StreamCapability(
        protocols: <String>['http'],
        statusCode: 403,
        mediaSourceCount: 1,
      );
      expect(forbidden.verdict, contains('允许第三方软件访问'));

      const ok = StreamCapability(
        protocols: <String>['http'],
        statusCode: 200,
        mediaSourceCount: 1,
      );
      expect(ok.canPlayDirect, isTrue);
      expect(ok.verdict, contains('可用'));

      // 声明了却 404：明确指出「声明与实现不一致」，便于上报
      const mismatch = StreamCapability(
        protocols: <String>['http'],
        statusCode: 404,
        mediaSourceCount: 1,
      );
      expect(mismatch.verdict, contains('不一致'));
    });

    test('summary 同时给出声明协议、探测结果与来源条数', () {
      const c = StreamCapability(
        protocols: <String>['http', 'hls'],
        statusCode: 404,
        mediaSourceCount: 1,
      );
      final s = c.summary;
      expect(s, contains('http / hls'));
      expect(s, contains('HTTP 404'));
      expect(s, contains('MediaSources 1 条'));
    });
  });

  group('源码守卫', () {
    test('emby_client 先读协议再决定端点，不再枚举猜测', () {
      final s = src('lib/emby_client.dart');
      expect(
        s.contains('Future<StreamCapability> probeStreamCapability('),
        isTrue,
      );
      expect(s.contains('parseStreamingProtocols(sources)'), isTrue);
      expect(s.contains('Future<List<String>> resolveStreamUrls('), isTrue);
      // 声明优先：直连原文只在「没声明 http」时才抢第一位
      expect(
        s.contains("isHttpPath && !cap.protocols.contains('http')"),
        isTrue,
      );
    });

    test('播放页按能力探测结果取址，并保留预检排序', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains('resolveStreamUrls(widget.item)'), isTrue);
      expect(s.contains('_capability'), isTrue);
      // 诊断面板要把能力结论摆到最前面
      expect(s.contains('服务端取流能力'), isTrue);
      expect(s.contains('shouldTryNextStream'), isTrue);
    });

    test('设置页自检对绿联走协议探测，不再拿一串 URL 白试', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('probeStreamCapability(first.id)'), isTrue);
      expect(s.contains('resolveStreamUrls(first)'), isTrue);
      expect(s.contains('取流能力'), isTrue);
    });

    test('MPV 打开失败时回读 path 里的 ffmpeg 结论', () {
      final s = src('lib/player/playback.dart');
      expect(s.contains('_captureMpvError'), isTrue);
      expect(s.contains("getProperty(prop)"), isTrue);
    });
  });

  group('版本与文档', () {
    test('版本与文档同步到 v2.0.95', () {
      expect(src('pubspec.yaml').contains('version: 2.0.95+295'), isTrue);
      expect(src('README.md').contains('v2.0.95 (295)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.95 (295)'), isTrue);
      expect(src('VERIFICATION.md').contains('§108'), isTrue);
      expect(src('lib/models.dart').contains("kClientVersion = '2.0.95'"),
          isTrue);
    });
  });
}
