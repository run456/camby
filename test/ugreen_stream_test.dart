import 'dart:io';

import 'package:camby/ugreen_resource.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.90：绿联**取流**链路的回归守卫。
///
/// 与 `ugreen_resource_test.dart`（图片）分开，是因为这一版修的是另一条
/// 独立链路：海报走 App 自己的 Dart HttpClient，取流走 ExoPlayer / libmpv
/// 各自的网络栈。绿联只认 `X-Emby-Token` 请求头，所以「图片出来了、视频
/// 放不了」正是两套栈只有一套带了头。
String src(String path) => File(path).readAsStringSync();

const String kRoot = 'https://192.168.5.29:9443';

void main() {
  group('取流候选', () {
    test('关闭自适应时只回原地址，标准 Emby 行为不变', () {
      const u = '$kRoot/Videos/7755/stream?Static=true&api_key=T';
      expect(playbackCandidates(streamUrl: u), <String>[u]);
    });

    test('STRM 原文地址排第一，其余按根路径 → Static → /emby → HLS', () {
      final list = playbackCandidates(
        streamUrl: '$kRoot/Videos/7755/stream?api_key=T',
        filePath: 'https://cdn.example.com/movie/rain.mkv',
        hlsUrl: '$kRoot/Videos/7755/master.m3u8?api_key=T',
        enabled: true,
      );
      expect(list.first, 'https://cdn.example.com/movie/rain.mkv');
      // 第二条是文档 6.3 坑 1 的标准答案：根路径、无 /emby
      expect(list[1], '$kRoot/Videos/7755/stream?api_key=T');
      expect(list[2], contains('Static=true'));
      expect(list.any((u) => u.contains('/emby/Videos/7755/stream')), isTrue);
      expect(list.last, contains('/master.m3u8'));
    });

    test('非 strm 的本地路径不会被当成候选', () {
      final list = playbackCandidates(
        streamUrl: '$kRoot/Videos/7755/stream?api_key=T',
        filePath: '/volume1/media/rain.mkv',
        enabled: true,
      );
      expect(list.any((u) => u.contains('/volume1/')), isFalse);
    });

    test('候选去重：hls 与 stream 相同时不重复', () {
      const u = '$kRoot/Videos/7755/stream?api_key=T';
      final list = playbackCandidates(
        streamUrl: u,
        hlsUrl: u,
        enabled: true,
      );
      expect(list.where((e) => e == u).length, 1);
    });

    test('空 streamUrl 不产生候选（未连接 / 无片源）', () {
      expect(playbackCandidates(streamUrl: '', enabled: true), isEmpty);
    });
  });

  group('鉴权头作用域', () {
    test('同源才算同源：协议 / 主机 / 端口任一不同都不注入', () {
      expect(sameOrigin('$kRoot/Videos/1/stream', kRoot), isTrue);
      // strm 指向第三方 CDN —— 不能把 Emby 令牌递过去
      expect(sameOrigin('https://cdn.example.com/a.mkv', kRoot), isFalse);
      // 同主机不同协议
      expect(sameOrigin('http://192.168.5.29:9443/x', kRoot), isFalse);
      // 同主机不同端口
      expect(sameOrigin('https://192.168.5.29:8096/x', kRoot), isFalse);
      // 非法输入
      expect(sameOrigin('not a url', kRoot), isFalse);
      expect(sameOrigin('$kRoot/x', 'also bad'), isFalse);
    });

    test('默认端口补齐后仍判定同源', () {
      expect(
        sameOrigin('https://nas.local/Videos/1/stream', 'https://nas.local'),
        isTrue,
      );
    });
  });

  group('源码守卫', () {
    test('Exo 把鉴权头交给 VideoPlayerController，不再空手起播', () {
      final s = src('lib/player/playback.dart');
      expect(s.contains('VideoPlayerController.networkUrl('), isTrue);
      expect(s.contains('httpHeaders: h'), isTrue);
      expect(s.contains('Map<String, String>? headers'), isTrue);
    });

    test('MPV 走 Media(httpHeaders:) 且自签证书下发 tls-verify=no', () {
      final s = src('lib/player/playback.dart');
      expect(s.contains('Media(url, httpHeaders: h)'), isTrue);
      // 之前的实现是 const {...} 只有 UA，等于空手要片源
      expect(s.contains("Media(url, httpHeaders: const {'User-Agent'"), isFalse);
      expect(s.contains("setProperty('tls-verify', 'no')"), isTrue);
      expect(s.contains('bool ignoreSsl = false'), isTrue);
    });

    test('播放内核暴露真实错误，供失败角标与诊断面板使用', () {
      final s = src('lib/player/playback.dart');
      expect(s.contains('String get lastError'), isTrue);
      expect(s.contains('errorDescription'), isTrue);
      expect(s.contains('_player.stream.error.listen'), isTrue);
    });

    test('播放页：按 url 取头、绿联走候选、失败后自动切 MPV', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains('headersFor(url)'), isTrue);
      expect(s.contains('playbackCandidates('), isTrue);
      expect(s.contains('_triedMpvOnFailure'), isTrue);
      expect(s.contains('probeStream('), isTrue);
      expect(s.contains('_showAttempts'), isTrue);
      // 取流鉴权状态直接展示在播放信息里，避免再靠猜
      expect(s.contains("'取流鉴权'"), isTrue);
    });

    test('emby_client：鉴权头收口到 streamHeaders + headersFor', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains('Map<String, String> get streamHeaders'), isTrue);
      expect(s.contains('Map<String, String> headersFor(String url)'), isTrue);
      expect(s.contains('sameOrigin(url, rootUrl)'), isTrue);
      expect(s.contains('Future<ResourceProbeResult> probeStream('), isTrue);
      // 浏览器直开是 403 这件事必须写在诊断里，否则用户会误判
      expect(s.contains('必须带请求头'), isTrue);
    });

    test('版本号只有一处来源：kClientVersion', () {
      expect(src('lib/models.dart').contains("kClientVersion = '2.0.90'"),
          isTrue);
      // 图片鉴权头里不该再出现硬编码版本
      expect(src('lib/ugreen_resource.dart').contains('Version="2.0.'), isFalse);
    });
  });

  group('版本与文档', () {
    test('版本与文档同步到 v2.0.90', () {
      expect(src('pubspec.yaml').contains('version: 2.0.90+290'), isTrue);
      expect(src('README.md').contains('v2.0.90 (290)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.90 (290)'), isTrue);
      expect(src('VERIFICATION.md').contains('§104'), isTrue);
      expect(src('lib/dlna/dlna_protocol.dart').contains('Camby/2.0.90'),
          isTrue);
    });
  });
}
