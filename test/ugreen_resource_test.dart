import 'dart:io';

import 'package:camby/ugreen_resource.dart';
import 'package:camby/widgets/image_ssl.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.89：绿联图片 / 播放资源「候选自适应 + 真实 HTTP 自检」的回归守卫。
///
/// v2.0.88 把资源地址写死成「根路径 + api_key + tag」，真机仍裂图；
/// 本版改为把路径前缀、鉴权参数名、tag 有无列成候选，让 App 自己试，
/// 并把每个候选的真实状态码摆到诊断面板上，不再靠猜。
String src(String path) => File(path).readAsStringSync();

const String kPoster =
    'https://192.168.5.29:9443/Items/7755/Images/Primary'
    '?maxWidth=800&api_key=TOKEN&tag=984fcfead462a79e';

void main() {
  setUp(() => ResourcePolicy.instance.reset());

  group('图片候选生成', () {
    test('关闭自适应时原样返回，标准 Emby 行为不变', () {
      expect(imageUrlCandidates(kPoster), <String>[kPoster]);
      expect(imageUrlCandidates(kPoster, enabled: false), <String>[kPoster]);
    });

    test('非图片 / 非法 URL 不生成候选', () {
      expect(imageUrlCandidates('https://h/a.jpg', enabled: true),
          <String>['https://h/a.jpg']);
      expect(imageUrlCandidates('not a url', enabled: true),
          <String>['not a url']);
    });

    test('绿联模式生成 6 个候选，覆盖前缀 × 鉴权名 × tag', () {
      final list = imageUrlCandidates(kPoster, enabled: true);
      expect(list.length, 6);
      // 第一个就是 App 原本会用的那条（文档 5.1 模板顺序）
      expect(list.first.contains('/Items/7755/Images/Primary'), isTrue);
      expect(list.first.contains('tag=984fcfead462a79e'), isTrue);
      expect(list.first.contains('api_key=TOKEN'), isTrue);
      expect(list.any((u) => u.contains('/emby/Items/7755/Images/Primary')),
          isTrue);
      expect(list.any((u) => u.contains('X-Emby-Token=TOKEN')), isTrue);
      expect(list.any((u) => !u.contains('tag=')), isTrue);
      for (final u in list) {
        expect(u.startsWith('https://192.168.5.29:9443/'), isTrue);
        expect(u.contains('api_key=') || u.contains('X-Emby-Token='), isTrue);
      }
      expect(list.toSet().length, 6, reason: '候选不能重复');
    });

    test('输入自带 /emby 前缀时，候选顺序反过来（先保留、再去前缀）', () {
      final withPrefix = kPoster.replaceFirst('/Items/', '/emby/Items/');
      final list = imageUrlCandidates(withPrefix, enabled: true);
      expect(list.length, 6);
      expect(list.first.contains('/emby/Items/'), isTrue);
      expect(list.any((u) => u.contains(':9443/Items/7755/Images/')), isTrue);
    });
  });

  group('播放候选生成', () {
    test('绿联模式列出 4 条：根路径 / /emby × Static 有无', () {
      const url = 'https://192.168.5.29:9443/Videos/7755/stream?api_key=TOKEN';
      final list = streamUrlCandidates(url, enabled: true);
      expect(list.length, 4);
      expect(list.first, 'https://192.168.5.29:9443/Videos/7755/stream?api_key=TOKEN');
      expect(list.any((u) => u.contains('Static=true')), isTrue);
      expect(list.any((u) => u.contains('/emby/Videos/')), isTrue);
    });

    test('关闭自适应 / 非视频路径时原样返回', () {
      const url = 'https://h/Videos/1/stream?api_key=T';
      expect(streamUrlCandidates(url), <String>[url]);
      expect(streamUrlCandidates('https://h/Items/1', enabled: true),
          <String>['https://h/Items/1']);
    });
  });

  group('Emby 鉴权头', () {
    test('从 api_key 提取 token，两种头都发', () {
      final h = embyAuthHeaders(kPoster, enabled: true);
      expect(h['X-Emby-Token'], 'TOKEN');
      expect(h['X-Emby-Authorization'], contains('Token="TOKEN"'));
      expect(h['Accept'], contains('image/'));
    });

    test('关闭自适应 / 无 token 时不注入任何头', () {
      expect(embyAuthHeaders(kPoster), isEmpty);
      expect(
        embyAuthHeaders('https://h/Items/1/Images/Primary', enabled: true),
        isEmpty,
      );
    });
  });

  group('探测结果与策略', () {
    test('2xx 才算可用，错误与状态码都进摘要', () {
      const ok = ResourceProbeResult(
        label: '图片候选 1',
        url: 'https://h/a',
        statusCode: 200,
        contentType: 'image/jpeg',
      );
      expect(ok.ok, isTrue);
      expect(ok.summary, contains('✓'));
      expect(ok.summary, contains('HTTP 200'));

      const miss = ResourceProbeResult(
        label: '图片候选 2',
        url: 'https://h/b',
        statusCode: 404,
      );
      expect(miss.ok, isFalse);
      expect(miss.summary, contains('✗'));

      const ssl = ResourceProbeResult(
        label: '图片候选 3',
        url: 'https://h/c',
        error: 'TLS 证书被拒（HandshakeException）',
      );
      expect(ssl.ok, isFalse);
      expect(ssl.summary, contains('HandshakeException'));
    });

    test('自检报告区分「已采用模板」与「全部失败」', () {
      final p = ResourcePolicy.instance;
      expect(p.probeReport, contains('尚未自检'));
      p.lastProbe = const [
        ResourceProbeResult(
          label: '图片候选 1',
          url: 'u',
          statusCode: 200,
          contentType: 'image/jpeg',
        ),
      ];
      p.preferredImageIndex = 0;
      expect(p.probeReport, contains('候选 1'));
      p.preferredImageIndex = null;
      expect(p.probeReport, contains('403'));
      expect(p.probeReport, contains('404'));
      expect(p.probeReport, contains('TLS'));
    });
  });

  group('真实 HTTP 自检（本地 HttpServer）', () {
    test('probe 返回真实状态码与 content-type，且失败不带异常抛出', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        try {
          if (req.uri.path == '/ok') {
            req.response.headers.contentType = ContentType('image', 'jpeg');
            req.response.write('fake-jpeg');
          } else {
            req.response.statusCode = HttpStatus.notFound;
            req.response.write('missing');
          }
          await req.response.close();
        } catch (_) {
          // 客户端拿到响应头就会取消 body，服务端 close 可能撞上断管。
        }
      });
      final base = 'http://127.0.0.1:${server.port}';

      final ok = await ImageSsl.probe('$base/ok', label: '图片候选 1');
      expect(ok.error, isNull);
      expect(ok.statusCode, 200);
      expect(ok.contentType, contains('image/jpeg'));
      expect(ok.ok, isTrue);

      final miss = await ImageSsl.probe('$base/missing', label: '图片候选 2');
      expect(miss.error, isNull);
      expect(miss.statusCode, 404);
      expect(miss.ok, isFalse);

      final dead = await ImageSsl.probe('http://127.0.0.1:1/x', label: '不可达');
      expect(dead.error, isNotNull, reason: '连接失败必须转成可读错误，不能抛出');

      await server.close(force: true);
    });
  });

  group('源码守卫', () {
    test('CachedImage 注入鉴权头、失败切候选、所有候选共用缓存 key', () {
      final s = src('lib/widgets/cached_image.dart');
      expect(s.contains('imageUrlCandidates('), isTrue);
      expect(s.contains('httpHeaders: embyAuthHeaders('), isTrue);
      expect(s.contains('cacheKey: imageCacheKey(widget.url!)'), isTrue);
      expect(s.contains('_onImageError()'), isTrue);
      expect(s.contains('ValueKey<int>(_index)'), isTrue);
      expect(s.contains('policy.preferredImageIndex'), isTrue);
    });

    test('AppState 连接时开启绿联模式、跑自检、断开时复位', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('ResourcePolicy.instance.ugreenMode ='), isTrue);
      expect(s.contains('unawaited(runResourceProbe())'), isTrue);
      expect(s.contains('Future<void> runResourceProbe()'), isTrue);
      expect(s.contains('String get resourceProbeReport'), isTrue);
      expect('ResourcePolicy.instance.reset()'.allMatches(s).length,
          greaterThanOrEqualTo(2));
      expect(s.contains('samplePosterUrl:'), isTrue);
    });

    test('诊断面板可重新自检，并优先展示真实 posterUrl', () {
      final s = src('lib/pages/settings_page.dart');
      expect(s.contains('bodyBuilder: (ctx) => _DiagnosticsBody'), isTrue);
      expect(s.contains('重新自检（图片与播放候选）'), isTrue);
      expect(s.contains('state.resourceProbeReport'), isTrue);
      final e = src('lib/emby_client.dart');
      expect(e.contains('samplePosterUrl'), isTrue);
      expect(e.contains('streamUrlCandidates('), isTrue);
    });

    test('版本与文档同步到 v2.0.96', () {
      expect(src('pubspec.yaml').contains('version: 2.0.96+296'), isTrue);
      expect(src('README.md').contains('v2.0.96 (296)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.96 (296)'), isTrue);
      expect(src('VERIFICATION.md').contains('§108'), isTrue);
      expect(src('lib/dlna/dlna_protocol.dart').contains('Camby/2.0.96'),
          isTrue);
    });
  });
}
