import 'dart:convert';
import 'dart:io';

import 'package:camby/dlna/cast_subtitle_proxy.dart';
import 'package:camby/dlna/dlna_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const String _srt = '1\n'
    '00:00:00,000 --> 00:00:01,000\n'
    '中文字幕\n';

Future<HttpClientResponse> _get(Uri u, {String? range}) async {
  final req = await HttpClient().getUrl(u);
  if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
  return req.close();
}

Future<String> _body(HttpClientResponse res) => utf8.decoder.bind(res).join();

void main() {
  late CastSubtitleProxy proxy;

  setUp(() {
    proxy = CastSubtitleProxy(hostOverride: '127.0.0.1');
  });
  tearDown(() async {
    await proxy.stop();
  });

  test('发布地址：无 query、无鉴权、以 .srt 结尾', () async {
    final uri = await proxy.publish(utf8.encode(_srt));
    expect(uri.scheme, 'http');
    expect(uri.host, '127.0.0.1');
    expect(uri.port, isPositive);
    expect(uri.query, isEmpty);
    expect(uri.path.endsWith('.srt'), isTrue);
    expect(uri.toString().contains('api_key'), isFalse);
    expect(uri.toString().contains('X-Emby-Token'), isFalse);
    expect(proxy.isRunning, isTrue);
  });

  test('GET 拿到纯 UTF-8 文本，BOM 被剥离', () async {
    final withBom = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(_srt)];
    final uri = await proxy.publish(withBom);
    final res = await _get(uri);
    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers.contentType.toString(), contains('charset=utf-8'));
    final body = await _body(res);
    expect(body, _srt);
    expect(body.codeUnitAt(0), isNot(0xFEFF));
  });

  test('HEAD 返回头不带 body', () async {
    final uri = await proxy.publish(utf8.encode(_srt));
    final req = await HttpClient().headUrl(uri);
    final res = await req.close();
    expect(res.statusCode, HttpStatus.ok);
    expect(await _body(res), isEmpty);
  });

  test('Range 返回 206 与 Content-Range', () async {
    final bytes = utf8.encode(_srt);
    final uri = await proxy.publish(bytes);
    final res = await _get(uri, range: 'bytes=0-3');
    expect(res.statusCode, HttpStatus.partialContent);
    expect(res.headers.value('content-range'), 'bytes 0-3/${bytes.length}');
    expect(utf8.decode((await res.single)), equals(_srt.substring(0, 4)));
  });

  test('越界 Range 返回 416，未发布路径返回 404', () async {
    final uri = await proxy.publish(utf8.encode(_srt));
    final tooFar = await _get(uri, range: 'bytes=999999-');
    expect(tooFar.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    await _body(tooFar);

    final missing = await _get(uri.replace(path: '/sub/999999.srt'));
    expect(missing.statusCode, HttpStatus.notFound);
    await _body(missing);
  });

  test('多条字幕各自独立，不会互相覆盖', () async {
    final a = await proxy.publish(utf8.encode('AAA'));
    final b = await proxy.publish(utf8.encode('BBB'));
    expect(a.path, isNot(b.path));
    expect(await _body(await _get(a)), 'AAA');
    expect(await _body(await _get(b)), 'BBB');
  });

  test('stop 之后可以重新启动并复用', () async {
    final first = await proxy.publish(utf8.encode('AAA'));
    await proxy.stop();
    expect(proxy.isRunning, isFalse);
    final second = await proxy.publish(utf8.encode('BBB'));
    expect(proxy.isRunning, isTrue);
    expect(await _body(await _get(second)), 'BBB');
    expect(first.port, isPositive);
  });

  test('代理地址能原样进 DIDL-Lite，仍带三星与 LG/松下字段', () {
    const sub = 'http://192.168.1.5:38215/sub/1.srt';
    final didl = buildDidlLite(
      id: '0',
      title: '片',
      url: 'http://192.168.1.29:8096/Videos/1/stream?api_key=k&Static=true',
      subtitleUrl: sub,
    );
    expect(didl, contains(sub));
    expect(didl, contains('sec:CaptionInfoEx'));
    expect(didl, contains('pv:subtitleFileUri'));
    // 视频 URL 里的 & 必须已经转义，否则整段 metadata 解析失败
    expect(didl, contains('&amp;'));
  });
}
