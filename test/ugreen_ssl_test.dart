import 'dart:convert';
import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:camby/server_address.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.87：绿联 NAS 影视中心接入（方案 A）的回归守卫。
///
/// 真机 / 真绿联 NAS 无法在 CI 里复现，所以这里覆盖三部分：
/// ① 地址解析纯函数（用户按建议粘贴 `https://ip:9443` 必须被正确拆开）；
/// ② 证书开关的序列化与「默认关闭」语义；
/// ③ 用本地 HttpServer 实测 `/emby` 前缀探测（兼容实现只认根路径时不能 404 死）。
String src(String path) => File(path).readAsStringSync();

void main() {
  group('地址解析 · 完整 URL 粘贴', () {
    test('纯 IP 用兜底协议与端口', () {
      final a = parseServerAddress('192.168.1.24');
      expect(a.host, '192.168.1.24');
      expect(a.port, 8096);
      expect(a.secure, isFalse);
      expect(a.origin, 'http://192.168.1.24:8096');
    });

    test('ip:port 只拆一个冒号', () {
      final a = parseServerAddress('192.168.1.24:9443');
      expect(a.host, '192.168.1.24');
      expect(a.port, 9443);
    });

    test('绿联标准写法 https://ip:9443 全拆对', () {
      final a = parseServerAddress('https://192.168.1.24:9443');
      expect(a.host, '192.168.1.24');
      expect(a.port, 9443);
      expect(a.secure, isTrue);
      expect(a.origin, 'https://192.168.1.24:9443');
    });

    test('带路径 / 查询 / 用户名也能剥干净', () {
      final a = parseServerAddress('https://nas.local:9443/emby/?a=1#x');
      expect(a.host, 'nas.local');
      expect(a.port, 9443);
      expect(a.secure, isTrue);
      final b = parseServerAddress('http://admin@10.0.0.5:8096/web');
      expect(b.host, '10.0.0.5');
      expect(b.port, 8096);
      expect(b.secure, isFalse);
    });

    test('显式 http 会覆盖兜底 https', () {
      final a = parseServerAddress(
        'http://192.168.1.24:8920',
        fallbackSecure: true,
      );
      expect(a.secure, isFalse);
      expect(a.port, 8920);
    });

    test('IPv6 方括号写法', () {
      final a = parseServerAddress('https://[::1]:9443');
      expect(a.host, '[::1]');
      expect(a.port, 9443);
      expect(a.secure, isTrue);
    });

    test('裸 IPv6 不被当成 host:port', () {
      final a = parseServerAddress('fe80::1');
      expect(a.host, 'fe80::1');
      expect(a.port, 8096);
    });

    test('非法端口回退，且不会把冒号留在 host 里', () {
      final a = parseServerAddress('https://nas.local:99999');
      expect(a.host, 'nas.local');
      expect(a.port, 8096);
      expect(a.secure, isTrue);
    });

    test('override 优先级高于文本（表单手动改过就别被粘贴覆盖）', () {
      final a = parseServerAddress(
        'https://nas.local:9443',
        portOverride: 8920,
        secureOverride: false,
      );
      expect(a.port, 8920);
      expect(a.secure, isFalse);
    });
  });

  group('绿联兼容源判据', () {
    test('只有 HTTPS + 9443 命中', () {
      expect(isUgreenCompatSource(port: 9443, secure: true), isTrue);
      expect(isUgreenCompatSource(port: 9443, secure: false), isFalse);
      expect(isUgreenCompatSource(port: 8096, secure: true), isFalse);
      expect(isUgreenCompatSource(port: 8920, secure: true), isFalse);
      expect(isUgreenCompatSource(port: 443, secure: true), isFalse);
    });

    test('提示文案明确说明进度不同步且记录在本机', () {
      expect(kUgreenProgressHint, contains('不支持进度同步'));
      expect(kUgreenProgressHint, contains('观影日历'));
    });
  });

  group('局域网判据（风险提示用）', () {
    test('常见内网地址都认', () {
      for (final h in [
        '192.168.1.24',
        '10.0.0.5',
        '172.16.0.9',
        '172.31.255.1',
        '169.254.3.4',
        'localhost',
        '127.0.0.1',
        '[::1]',
        'nas.local',
        'box.lan',
      ]) {
        expect(isLanHost(h), isTrue, reason: h);
      }
    });

    test('公网地址与域名不认（要显示中间人风险）', () {
      for (final h in [
        '8.8.8.8',
        '1.1.1.1',
        '172.32.0.1',
        'my-nas.example.com',
        'ddns.ugnas.com',
      ]) {
        expect(isLanHost(h), isFalse, reason: h);
      }
    });
  });

  group('ServerProfile · 证书开关默认关闭', () {
    test('新建配置默认 false', () {
      final p = ServerProfile(
        id: 's1',
        name: 'NAS',
        host: '192.168.1.24',
        port: 9443,
        secure: true,
        username: 'admin',
      );
      expect(p.ignoreSsl, isFalse);
      expect(p.address, 'https://192.168.1.24:9443');
    });

    test('JSON 往返保留开关', () {
      final p = ServerProfile(
        id: 's1',
        name: '绿联',
        host: '192.168.1.24',
        port: 9443,
        secure: true,
        username: 'admin',
        ignoreSsl: true,
      );
      final q = ServerProfile.fromJson(p.toJson());
      expect(q.ignoreSsl, isTrue);
      expect(q.port, 9443);
      expect(q.secure, isTrue);
      // v2.0.88：这条配置正是 v2.0.87 保存的绿联形态，反序列化时自动
      // 升级成独立类型，旧配置才能拿到「资源地址走根路径」的修复。
      expect(q.kind, ServerKind.ugreen);
    });

    test('v2.0.88 旧配置迁移：只有 HTTPS 9443 + 忽略证书才升级', () {
      Map<String, dynamic> base() => {
        'id': 'old',
        'name': 'old',
        'host': '10.0.0.2',
        'port': 9443,
        'secure': true,
        'username': 'u',
        'password': 'p',
        'kind': 'emby',
        'ignore_ssl': true,
      };
      expect(ServerProfile.fromJson(base()).kind, ServerKind.ugreen);
      expect(
        ServerProfile.fromJson({...base(), 'port': 8096}).kind,
        ServerKind.emby,
      );
      expect(
        ServerProfile.fromJson({...base(), 'secure': false}).kind,
        ServerKind.emby,
      );
      expect(
        ServerProfile.fromJson({...base(), 'ignore_ssl': false}).kind,
        ServerKind.emby,
      );
      expect(
        ServerProfile.fromJson({...base(), 'kind': 'jellyfin'}).kind,
        ServerKind.jellyfin,
      );
      expect(
        ServerProfile.fromJson({...base(), 'kind': 'ugreen'}).kind,
        ServerKind.ugreen,
      );
    });

    test('旧配置没有 ignore_ssl 键 → 默认关闭，不继承旧版隐式全开', () {
      final q = ServerProfile.fromJson({
        'id': 'old',
        'name': 'old',
        'host': '10.0.0.2',
        'port': 8096,
        'secure': false,
        'username': 'u',
        'password': 'p',
        'kind': 'emby',
      });
      expect(q.ignoreSsl, isFalse);
    });

    test('copyWith 能单独改开关', () {
      final p = ServerProfile(
        id: 's1',
        name: 'n',
        host: 'h',
        port: 9443,
        secure: true,
        username: 'u',
      );
      expect(p.copyWith(ignoreSsl: true).ignoreSsl, isTrue);
      expect(p.ignoreSsl, isFalse);
    });
  });

  group('EmbyServer · 基础路径与前缀探测', () {
    test('标准 Emby 默认 /emby；Jellyfin 走根路径', () {
      final e = EmbyServer(
        host: 'nas',
        port: 9443,
        secure: true,
        username: 'u',
      );
      expect(e.baseUrl, 'https://nas:9443/emby');
      expect(e.rootUrl, 'https://nas:9443');
      expect(e.ignoreSsl, isFalse);
      final j = EmbyServer(
        host: 'nas',
        port: 8096,
        secure: false,
        username: 'u',
        kind: ServerKind.jellyfin,
      );
      expect(j.baseUrl, 'http://nas:8096');
    });

    test('ignoreSsl 可显式打开', () {
      final e = EmbyServer(
        host: 'nas',
        port: 9443,
        secure: true,
        username: 'u',
        ignoreSsl: true,
      );
      expect(e.ignoreSsl, isTrue);
    });

    test('/emby 返回 404 时自动回退根路径，后续 baseUrl 跟随', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var embyHits = 0;
      var rootHits = 0;
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        if (req.uri.path.startsWith('/emby/')) {
          embyHits++;
          req.response.statusCode = 404;
          req.response.write('not found');
        } else if (req.uri.path == '/Users/AuthenticateByName') {
          rootHits++;
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'AccessToken': 'tok',
              'User': {'Id': 'uid'},
            }),
          );
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      try {
        final e = EmbyServer(
          host: '127.0.0.1',
          port: server.port,
          secure: false,
          username: 'u',
          password: 'p',
        );
        await e.authenticate();
        expect(embyHits, 1);
        expect(rootHits, 1);
        expect(e.baseUrl, 'http://127.0.0.1:${server.port}');
        expect(e.isConnected, isTrue);
      } finally {
        await server.close(force: true);
      }
    });

    test('/emby 可用时不回退；401 不被误判成路径问题', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        hits++;
        if (req.uri.path == '/emby/Users/AuthenticateByName') {
          req.response.statusCode = 401;
          req.response.write('bad password');
        } else {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'AccessToken': 'tok',
              'User': {'Id': 'uid'},
            }),
          );
        }
        await req.response.close();
      });
      try {
        final e = EmbyServer(
          host: '127.0.0.1',
          port: server.port,
          secure: false,
          username: 'u',
        );
        await expectLater(e.authenticate(), throwsA(isA<EmbyException>()));
        // 401 是账号问题，不该拿根路径再试一次
        expect(hits, 1);
        expect(e.baseUrl, 'http://127.0.0.1:${server.port}/emby');
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('源码守卫（真机/服务端难以稳定复现的结构性错误）', () {
    test('emby_client：证书忽略只留一处且受开关约束', () {
      final s = src('lib/emby_client.dart');
      // 注释里会提到旧写法的 `HttpClient()`，所以只数真正的调用行
      expect('final c = HttpClient();'.allMatches(s).length, 1);
      expect(s.contains('if (ignoreSsl) c.badCertificateCallback'), isTrue);
      expect(s.contains('HttpClient _newClient('), isTrue);
      // 8 处调用点全部走工厂
      expect('_newClient('.allMatches(s).length, greaterThanOrEqualTo(9));
      expect(s.contains("_basePath = prefix"), isTrue);
      expect(s.contains('on _PathMiss catch'), isTrue);
    });

    test('字幕兜底通道默认不再无条件信任任意证书', () {
      final s = src('lib/subtitles/subtitles.dart');
      expect(s.contains('bool ignoreSsl = false'), isTrue);
      expect(s.contains('if (ignoreSsl) {'), isTrue);
      final p = src('lib/pages/player_page.dart');
      expect(p.contains('ignoreSsl: widget.state.ignoreSslErrors'), isTrue);
    });

    test('原生层：SSL 通道、trust-all 工厂、恢复系统默认都在', () {
      final k = src(
        'android/app/src/main/kotlin/cn/camby/camby/MainActivity.kt',
      );
      expect(k.contains('SECURITY_CHANNEL'), isTrue);
      expect(k.contains('setIgnoreSsl'), isTrue);
      expect(k.contains('createTrustAllFactory'), isTrue);
      expect(k.contains('setDefaultSSLSocketFactory'), isTrue);
      expect(k.contains('defaultSocketFactory'), isTrue);
      expect(k.contains('defaultHostnameVerifier'), isTrue);
      final d = src('lib/player/native_ssl.dart');
      expect(d.contains("'cn.camby.camby/security'"), isTrue);
      expect(d.contains('setIgnoreCertificateErrors'), isTrue);
    });

    test('app_state：连接同步原生 + 图片证书开关、绿联按类型关进度、断开恢复', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('NativeSsl.setIgnoreCertificateErrors(ignoreSsl)'), isTrue);
      expect(s.contains('ImageSsl.setIgnoreCertificateErrors(ignoreSsl)'), isTrue);
      expect(s.contains('ImageSsl.setIgnoreCertificateErrors(false)'), isTrue);
      // v2.0.88：进度能力按独立类型判定，不再靠 9443 猜来源
      expect(s.contains('kind != ServerKind.ugreen'), isTrue);
      expect(s.contains('isUgreenCompatSource('), isFalse);
      // 4 个上报入口各一处早退：进度直写 / 队列冲刷 / 起播 / 退出
      expect('!_progressSyncSupported'.allMatches(s).length, 4);
      expect(s.contains('ignoreSsl: profile.ignoreSsl'), isTrue);
      expect(s.contains('ignoreSsl: ignoreSsl'), isTrue);
      expect(
        s.contains('unawaited(NativeSsl.setIgnoreCertificateErrors(false))'),
        isTrue,
      );
    });

    test('设置页：绿联并入统一表单、证书开关、风险提示、完整地址粘贴', () {
      final s = src('lib/pages/settings_page.dart');
      expect(s.contains('late bool _ignoreSsl;'), isTrue);
      expect(s.contains('_ignoreSsl = p?.ignoreSsl ?? isUgreenPreset;'), isTrue);
      expect(s.contains('忽略 SSL 证书校验'), isTrue);
      expect(s.contains('中间人风险'), isTrue);
      expect(s.contains('parseServerAddress('), isTrue);
      expect(s.contains('_onHostChanged'), isTrue);
      expect(s.contains('kUgreenProgressHint'), isTrue);
      expect(s.contains('证书校验失败'), isTrue);
      // v2.0.92：绿联收回到同一个表单当第三种类型，不再是设置页上的独立入口
      expect(s.contains("items: const ['Emby', 'Jellyfin', '绿联']"), isTrue);
      expect(s.contains('void _switchKind(int i)'), isTrue);
      // 切到绿联时协议/端口/证书一键带好
      expect(s.contains("_port.text = '9443'"), isTrue);
      expect(s.contains("'连接绿联影视中心'"), isTrue);
      expect(s.contains("'HTTPS · 强制'"), isTrue);
      expect(s.contains('state.serverDiagnostics'), isTrue);
      expect(
        src('lib/models.dart').contains('enum ServerKind { emby, jellyfin, ugreen }'),
        isTrue,
      );
    });

    test('图片网络层：证书开关对 CachedNetworkImage 生效', () {
      final s = src('lib/widgets/image_ssl.dart');
      expect(s.contains('badCertificateCallback'), isTrue);
      expect(s.contains('ignoreCertificateErrors'), isTrue);
      expect(s.contains('HttpFileService(httpClient:'), isTrue);
      expect(s.contains('DefaultCacheManager.key'), isTrue);
      final c = src('lib/widgets/cached_image.dart');
      expect(c.contains('cacheManager: ImageSsl.manager'), isTrue);
      expect(c.contains('ImageSsl.manager.getFileFromCache'), isTrue);
    });

    test('版本与文档同步到 v2.0.94', () {
      expect(src('pubspec.yaml').contains('version: 2.0.94+294'), isTrue);
      expect(src('README.md').contains('v2.0.94 (294)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.94 (294)'), isTrue);
      expect(src('VERIFICATION.md').contains('§108'), isTrue);
      expect(src('lib/dlna/dlna_protocol.dart').contains('Camby/2.0.94'), isTrue);
    });
  });
}
