import 'dart:io';

import 'package:camby/ugreen_resource.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.98：真机「诊断 206、起播全 404」的回归守卫。
///
/// 真机 v2.0.93 播放诊断原文：
/// ```
/// 服务端取流能力：
///   声明协议：（未声明） · 探测：HTTP 206 · video/x-matroska ·
///   MediaSources 1 条
///   → 未声明取流协议，但取流端点实测可用（HTTP 206 · video/x-matroska）
///     —— 地址和鉴权都没问题，问题在播放内核的取流方式……
/// 取流预检（只读响应头，不下载画面）：
///   ✗ /Videos/9761/stream: HTTP 404
///   ✗ /Videos/9761/stream?Static=true: HTTP 404
/// 内核起播记录：
///   1. Exo · /Videos/9761/stream → Source error
///   2. MPV · /Videos/9761/stream → Failed to open …/Videos/9761/stream…
/// ```
/// 结论被写反了：探测用的地址（服务端 MediaSources 给的直取地址）和播放
/// 用的地址（按空协议重新拼的 `/Videos/{id}/stream`）根本不是同一条。
/// v2.0.98 把实测 2xx 的地址留在 StreamCapability 上并要求起播原样复用。
String src(String path) => File(path).readAsStringSync();

const String kRoot = 'https://192.168.5.29:9443';

void main() {
  group('StreamCapability 保留实测可用地址', () {
    test('默认没有 verifiedUrl，hasVerifiedUrl 为假', () {
      const c = StreamCapability(statusCode: 206, mediaSourceCount: 1);
      expect(c.verifiedUrl, isNull);
      expect(c.hasVerifiedUrl, isFalse);
      expect(c.verifiedUrlLabel, isNull);
    });

    test('带上 verifiedUrl 后 toJson 与诊断标签都能取到', () {
      const c = StreamCapability(
        statusCode: 206,
        contentType: 'video/x-matroska',
        mediaSourceCount: 1,
        verifiedUrl: '$kRoot/Videos/9761/stream?MediaSourceId=abc&api_key=SECRET',
      );
      expect(c.hasVerifiedUrl, isTrue);
      expect(c.toJson()['verifiedUrl'], contains('/Videos/9761/stream'));
      // 脱敏：不能把 api_key 整串印到可复制的诊断文字里
      expect(c.verifiedUrlLabel, isNot(contains('SECRET')));
      expect(c.verifiedUrlLabel, contains('/Videos/9761/stream'));
      expect(c.verifiedUrlLabel, contains('ms'));
    });

    test('空串 verifiedUrl 不算可用', () {
      const c = StreamCapability(verifiedUrl: '');
      expect(c.hasVerifiedUrl, isFalse);
    });

    test('未声明协议 + 实测地址：结论直指「地址没传下去」', () {
      const c = StreamCapability(
        statusCode: 206,
        contentType: 'video/x-matroska',
        mediaSourceCount: 1,
        verifiedUrl: '$kRoot/Videos/9761/stream?api_key=T',
      );
      final v = c.verdict;
      expect(v, contains('MediaSources 给出了可直取地址'));
      expect(v, contains('HTTP 206'));
      expect(v, contains('404'));
      expect(v, contains('直接使用'));
      // 旧的错误定性一个字都不能留
      expect(v, isNot(contains('播放内核的取流方式')));
      expect(v, isNot(contains('自动改试 MPV')));
    });

    test('未声明协议、没拿到地址时仍走保守结论', () {
      const c = StreamCapability(statusCode: 206, mediaSourceCount: 1);
      expect(c.verdict, contains('取流端点实测可用'));
      expect(c.verdict, isNot(contains('MediaSources 给出了')));
    });

    test('206 且声明了 http 的旧分支不受影响', () {
      const c = StreamCapability(
        protocols: <String>['http'],
        statusCode: 206,
        mediaSourceCount: 1,
      );
      expect(c.canPlayDirect, isTrue);
      expect(c.verdict, contains('对应端点可用'));
    });
  });

  group('源码守卫：探测地址必须一路传到播放器', () {
    test('StreamCapability 声明 verifiedUrl 与 hasVerifiedUrl', () {
      final s = src('lib/ugreen_resource.dart');
      expect(s.contains('final String? verifiedUrl;'), isTrue);
      expect(s.contains('bool get hasVerifiedUrl'), isTrue);
      expect(s.contains('String? get verifiedUrlLabel'), isTrue);
    });

    test('probeStreamCapability 逐条实测并记录 2xx 的地址', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains('final serverUrls = <String>[];'), isTrue);
      expect(s.contains('verifiedUrl = urls[i];'), isTrue);
      expect(s.contains('r.statusCode! >= 200'), isTrue);
      expect(s.contains('verifiedUrl: verifiedUrl,'), isTrue);
      // 旧实现只取第一条地址、只探第一条 URL
      expect(s.contains('serverUrl ??= _ensurePlaybackAuth(v)'), isFalse);
      expect(s.contains('final first = await probeStream(urls.first'), isFalse);
    });

    test('resolveStreamUrls 把实测地址原样排第一', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains('add(cap.verifiedUrl);'), isTrue);
      expect(s.contains('实测能出数据的地址永远第一位'), isTrue);
      // 不能再出现「只回 declared」的旧写法
      expect(s.contains('return declared;'), isFalse);
    });

    test('播放诊断同时显示能力结论与实测地址', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains('实测可用地址：\${cap.verifiedUrlLabel}'), isTrue);
      expect(s.contains('起播列表首条应为此地址'), isTrue);
    });

    test('Exo 记忆只在地址确认可用后才写，不再被 404 误触发', () {
      final s = src('lib/pages/player_page.dart');
      expect(
        s.contains('(_capability?.hasVerifiedUrl ?? false)'),
        isTrue,
      );
      expect(s.contains('markExoStreamUnavailable()'), isTrue);
    });

    test('连接诊断里也列出实测地址，便于复制核对', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains("'实测可用地址：\${lastStreamCapability!.verifiedUrl}'"),
          isTrue);
    });
  });
}
