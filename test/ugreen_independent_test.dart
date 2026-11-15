import 'dart:io';

import 'package:camby/emby_client.dart';
import 'package:camby/models.dart';
import 'package:camby/widgets/image_ssl.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.88：绿联影视中心「独立服务器类型 + 资源地址修复 + 继续观看虚拟库」
/// 的回归守卫。
///
/// 真机 UGOS Pro 无法在 CI 里复现，这里把能从代码直接验证的部分钉死：
/// ① `ServerKind.ugreen` 的独立类型与旧配置迁移；
/// ② API 基址与资源基址分离后，图片 / 播放 URL 必须落在站点根路径且带 api_key；
/// ③ 图片网络层的证书策略确实被 `CachedNetworkImage` 用上；
/// ④ 继续观看「查看全部」落到虚拟媒体库，而不是「全部」。
String src(String path) => File(path).readAsStringSync();

EmbyServer ugreen() => EmbyServer(
  host: '10.0.0.7',
  port: 9443,
  secure: true,
  username: 'media',
  kind: ServerKind.ugreen,
  ignoreSsl: true,
);

void main() {
  group('独立服务器类型', () {
    test('kindLabel 与 JSON 往返', () {
      const p = ServerProfile(
        id: 'u1',
        name: '客厅 NAS',
        host: '10.0.0.7',
        port: 9443,
        secure: true,
        username: 'media',
        kind: ServerKind.ugreen,
        ignoreSsl: true,
      );
      expect(p.kindLabel, '绿联影视中心');
      expect(p.address, 'https://10.0.0.7:9443');
      final q = ServerProfile.fromJson(p.toJson());
      expect(q.kind, ServerKind.ugreen);
      expect(q.ignoreSsl, isTrue);
    });

    test('v2.0.87 旧形态自动迁移，条件必须同时满足', () {
      Map<String, dynamic> base() => {
        'id': 'old',
        'name': 'old',
        'host': '10.0.0.7',
        'username': 'media',
        'kind': 'emby',
        'ignore_ssl': true,
        'secure': true,
        'port': 9443,
      };
      expect(ServerProfile.fromJson(base()).kind, ServerKind.ugreen);
      expect(
        ServerProfile.fromJson(base()..['port'] = 8096).kind,
        ServerKind.emby,
        reason: '标准 Emby 端口不能被误判',
      );
      expect(
        ServerProfile.fromJson(base()..['secure'] = false).kind,
        ServerKind.emby,
      );
      expect(
        ServerProfile.fromJson(base()..['ignore_ssl'] = false).kind,
        ServerKind.emby,
      );
    });

    test('已有 kind=ugreen 的配置不受端口影响', () {
      final q = ServerProfile.fromJson({
        'id': 'u',
        'name': 'u',
        'host': 'nas.local',
        'port': 9443,
        'secure': true,
        'username': 'm',
        'kind': 'ugreen',
        'ignore_ssl': true,
      });
      expect(q.kind, ServerKind.ugreen);
    });
  });

  group('资源 URL 与 API 前缀分离（文档第五节）', () {
    test('绿联：API 与资源都落根路径', () {
      final s = ugreen();
      expect(s.isUgreen, isTrue);
      expect(s.rootUrl, 'https://10.0.0.7:9443');
      expect(s.baseUrl, 'https://10.0.0.7:9443');
      expect(s.assetUrl, s.rootUrl);
    });

    test('绿联图片地址：无 /emby 前缀、带 api_key、无 null 字面量', () {
      final u = ugreen().imageUrl('it42');
      expect(u, 'https://10.0.0.7:9443/Items/it42/Images/Primary'
          '?maxWidth=400&api_key=');
      expect(u.contains('/emby'), isFalse);
      expect(u.contains('api_key=null'), isFalse);
      expect(u.contains('api_key='), isTrue);
    });

    test('绿联播放地址：最简直链，忽略 MediaSourceId / HLS 参数', () {
      final s = ugreen();
      const expected = 'https://10.0.0.7:9443/Videos/it42/stream?api_key=';
      expect(s.streamUrl('it42'), expected);
      expect(s.streamUrl('it42', direct: false), expected);
      expect(s.streamUrl('it42', mediaSourceId: 'ms-9'), expected);
      final u = s.streamUrl('it42');
      expect(u.contains('/emby'), isFalse);
      expect(u.contains('Static=true'), isFalse);
      expect(u.contains('PlaySessionId'), isFalse);
      expect(u.contains('MediaSourceId'), isFalse);
      expect(u.contains('api_key='), isTrue);
    });

    test('标准 Emby 行为不变：仍走 /emby 前缀', () {
      final s = EmbyServer(
        host: 'emby.local',
        port: 8096,
        secure: false,
        username: 'u',
      );
      expect(s.isUgreen, isFalse);
      expect(s.baseUrl, 'http://emby.local:8096/emby');
      expect(s.assetUrl, s.baseUrl);
      expect(s.imageUrl('a').startsWith('http://emby.local:8096/emby/Items/a/'),
          isTrue);
      expect(s.streamUrl('a').contains('/emby/Videos/a/stream?Static=true'),
          isTrue);
      expect(s.streamUrl('a', direct: false).contains('master.m3u8'), isTrue);
    });

    test('Jellyfin 走根路径，且未把资源地址误绑到 API 前缀', () {
      final s = EmbyServer(
        host: 'jf.local',
        port: 8096,
        secure: false,
        username: 'u',
        kind: ServerKind.jellyfin,
      );
      expect(s.baseUrl, 'http://jf.local:8096');
      expect(s.assetUrl, s.rootUrl);
      expect(s.imageUrl('a').contains('/emby'), isFalse);
    });

    test('诊断面板展示真实 URL、播放候选与令牌提醒', () {
      final s = ugreen();
      final d = s.diagnostics(sampleItemId: 'it42');
      expect(d.contains('服务器类型：ugreen'), isTrue);
      expect(d.contains('绿联影视中心'), isTrue);
      expect(d.contains('资源基址：https://10.0.0.7:9443'), isTrue);
      expect(d.contains('证书校验：已跳过（仅限局域网）'), isTrue);
      expect(d.contains('① 图片自检'), isTrue);
      expect(d.contains('② 播放自检'), isTrue);
      expect(d.contains('/Items/it42/Images/Primary'), isTrue);
      expect(d.contains('/Videos/it42/stream'), isTrue);
      // 实际生成的资源地址仍不带 /emby；诊断里出现 /emby 只是候选清单。
      expect(s.imageUrl('it42').contains('/emby'), isFalse);
      expect(s.streamUrl('it42').contains('/emby'), isFalse);
      expect(d.contains('X-Emby-Token'), isTrue);
      expect(d.contains('允许第三方软件访问'), isTrue);
      expect(d.contains('请勿外传'), isTrue);
    });

    test('诊断面板优先展示 App 真实使用的海报 URL（含 tag）', () {
      const realPoster = 'https://10.0.0.7:9443/Items/it42/Images/Primary'
          '?maxWidth=800&api_key=TOKEN&tag=abc123';
      final d = ugreen().diagnostics(
        sampleItemId: 'it42',
        samplePosterUrl: realPoster,
      );
      expect(d.contains(realPoster), isTrue);
      expect(d.contains('tag={ImageTag}'), isFalse);
    });
  });

  group('图片网络层证书策略', () {
    test('默认严格校验，开关键可切换且可复位', () {
      expect(ImageSsl.ignoreCertificateErrors, isFalse);
      ImageSsl.setIgnoreCertificateErrors(true);
      expect(ImageSsl.ignoreCertificateErrors, isTrue);
      ImageSsl.setIgnoreCertificateErrors(false);
      expect(ImageSsl.ignoreCertificateErrors, isFalse);
    });

    test('image_ssl.dart 用自定义 CacheManager 且回调动态读取开关', () {
      final s = src('lib/widgets/image_ssl.dart');
      expect(s.contains('DefaultCacheManager.key'), isTrue);
      expect(s.contains('HttpFileService(httpClient:'), isTrue);
      expect(s.contains('badCertificateCallback'), isTrue);
      expect(s.contains('ignoreCertificateErrors'), isTrue);
      // 不能把 true 写死在回调里，否则切换服务器后仍信任任意证书。
      expect(RegExp(r'badCertificateCallback[^\n]*=>\s*true').hasMatch(s),
          isFalse);
    });

    test('cached_image.dart 探测缓存与图片组件都改用 ImageSsl.manager', () {
      final s = src('lib/widgets/cached_image.dart');
      expect('ImageSsl.manager'.allMatches(s).length, greaterThanOrEqualTo(2));
      expect(s.contains('cacheManager: ImageSsl.manager'), isTrue);
      expect(s.contains('ImageSsl.manager.getFileFromCache'), isTrue);
    });

    test('app_state 连接 / 切换 / 断开时同步图片层策略', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('ImageSsl.setIgnoreCertificateErrors(ignoreSsl)'),
          isTrue);
      expect('ImageSsl.setIgnoreCertificateErrors(false)'.allMatches(s).length,
          greaterThanOrEqualTo(2));
      expect(s.contains('kind != ServerKind.ugreen'), isTrue);
    });
  });

  group('继续观看虚拟媒体库', () {
    test('哨兵 ID 与判定函数', () {
      expect(kContinueViewId, '__camby_continue__');
      expect(kContinueView.id, kContinueViewId);
      expect(isContinueViewId(kContinueViewId), isTrue);
      expect(isVirtualViewId(kContinueViewId), isTrue);
      expect(isContinueViewId(kRecentViewId), isFalse);
      expect(isContinueViewId(null), isFalse);
      expect(isVirtualViewId(kRecentViewId), isTrue);
    });

    test('首页显示「查看全部」并走独立回调', () {
      final s = src('lib/pages/home_page.dart');
      expect(s.contains("action: '查看全部'"), isTrue);
      expect(s.contains('onAction: widget.onOpenContinue'), isTrue);
      expect(s.contains('required this.onOpenContinue'), isTrue);
      expect(s.contains('onOpenAll'), isFalse);
    });

    test('main 落到继续观看虚拟库，且删除旧的跳「全部」链路', () {
      final s = src('lib/main.dart');
      expect(s.contains('void _openContinueLibrary()'), isTrue);
      expect(s.contains('_state.selectedViewId = kContinueViewId'), isTrue);
      expect(s.contains('onOpenContinue: _openContinueLibrary'), isTrue);
      expect(s.contains('void _openAllLibrary()'), isFalse);
      expect(s.contains('onOpenAll:'), isFalse);
    });

    test('library 零网络请求取本地 continueWatching，chip 行扩到 +3', () {
      final s = src('lib/pages/library_page.dart');
      expect(s.contains('if (isContinueViewId(vid)) return widget.state.continueWatching;'),
          isTrue);
      // v2.0.98：chip 行改成「全部 + 常用 + ⊞ 全部媒体库」，其余收进弹窗
      expect(s.contains("'全部媒体库'"), isTrue);
      expect(s.contains('showLibraryPickerSheet('), isTrue);
      expect(s.contains('_selectView(kContinueViewId)'), isTrue);
    });
  });

  group('设置页独立入口与诊断', () {
    test('绿联并入「添加服务器」表单：三段切换、强制 HTTPS、自动忽略证书', () {
      final s = src('lib/pages/settings_page.dart');
      // v2.0.92：不再是设置页上一张独立的绿联卡片，而是表单里的第三种类型
      expect(s.contains("items: const ['Emby', 'Jellyfin', '绿联']"), isTrue);
      expect(s.contains('void _switchKind(int i)'), isTrue);
      expect(s.contains('presetKind: ServerKind.ugreen'), isFalse);
      expect(s.contains('_ignoreSsl = true;'), isTrue);
      expect(s.contains("'_port.text = '9443'"), isFalse);
      expect(s.contains("_port.text = '9443'"), isTrue);
      expect(s.contains("'HTTPS · 强制'"), isTrue);
      expect(s.contains('连接绿联影视中心'), isTrue);
      expect(s.contains('影视中心媒体服务器账号'), isTrue);
      expect(s.contains('已自动勾选'), isTrue);
      // 设置页只留一个添加入口
      expect(s.contains('Emby / Jellyfin / 绿联影视中心，同一个入口'), isTrue);
    });

    test('诊断入口读取 AppState.serverDiagnostics 且可选中复制', () {
      final s = src('lib/pages/settings_page.dart');
      expect(s.contains("title: '连接诊断'"), isTrue);
      expect(s.contains('state.serverDiagnostics'), isTrue);
      expect(s.contains('SelectableText'), isTrue);
      expect(s.contains('连接诊断 · 图片与播放地址'), isTrue);
    });

    test('app_state 暴露诊断与绿联判定', () {
      final s = src('lib/app_state.dart');
      expect(s.contains('String get serverDiagnostics'), isTrue);
      expect(s.contains('bool get isUgreenServer'), isTrue);
    });
  });

  group('版本与文档同步', () {
    test('版本、UA、文档均为 v2.0.98', () {
      expect(src('pubspec.yaml').contains('version: 2.0.98+298'), isTrue);
      expect(src('README.md').contains('v2.0.98 (298)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.98 (298)'), isTrue);
      expect(src('VERIFICATION.md').contains('§108'), isTrue);
      expect(src('lib/dlna/dlna_protocol.dart').contains('Camby/2.0.98'),
          isTrue);
    });
  });
}
