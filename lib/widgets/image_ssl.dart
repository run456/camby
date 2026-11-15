import 'dart:async';
import 'dart:io';

import 'package:camby/ugreen_resource.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/io_client.dart';

/// 图片网络层的证书策略（v2.0.88）。
///
/// 这是绿联兼容方案文档 5.1 第 3 条点名的坑：**图片请求走的是另一套
/// HttpClient**。`CachedNetworkImage` → `flutter_cache_manager` →
/// `package:http`，与 `EmbyServer._newClient()` 里那 8 处 API 请求完全
/// 不是一个实例；v2.0.87 只收口了 API 层，自签 HTTPS 的海报依旧会在
/// TLS 握手阶段被拒。Kotlin 的 `setIgnoreSsl` 改的是 Java
/// `HttpsURLConnection` 默认值（给 ExoPlayer 用），同样管不到 Dart 的
/// BoringSSL 栈，所以必须在这里单独给图片 client 装回调。
///
/// 回调**动态读取** [ignoreCertificateErrors]，切换服务器无需重建
/// CacheManager，也不会把「信任任意证书」永久留在进程里。
class ImageSsl {
  const ImageSsl._();

  /// 由 AppState 在连接 / 切换 / 断开服务器时同步。默认严格校验。
  static bool ignoreCertificateErrors = false;

  static void setIgnoreCertificateErrors(bool value) {
    ignoreCertificateErrors = value;
  }

  static CacheManager? _manager;

  /// 用默认缓存 key，升级后已缓存的海报不会全部失效。
  static CacheManager get manager => _manager ??= CacheManager(
    Config(
      DefaultCacheManager.key,
      fileService: HttpFileService(httpClient: _newHttpClient()),
    ),
  );

  static IOClient _newHttpClient() {
    final io = HttpClient();
    io.badCertificateCallback = (X509Certificate cert, String host, int port) =>
        ignoreCertificateErrors;
    return IOClient(io);
  }

  /// v2.0.89：用**与图片组件完全相同**的证书策略与鉴权头，真实发一次
  /// GET，把状态码 / content-type / 握手错误带回来。
  ///
  /// 只要 `req.close()` 返回就拿到了响应头，立刻取消 body 订阅，
  /// 不会把整张海报（更不会把一个视频）下载下来。
  static Future<ResourceProbeResult> probe(
    String url, {
    required String label,
  }) async {
    final io = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) =>
              ignoreCertificateErrors;
    StreamSubscription<List<int>>? sub;
    try {
      final req = await io
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      for (final e in embyAuthHeaders(url, enabled: true).entries) {
        req.headers.set(e.key, e.value);
      }
      final res = await req.close().timeout(const Duration(seconds: 8));
      final code = res.statusCode;
      final ct = res.headers.contentType?.toString();
      sub = res.listen(null, cancelOnError: true);
      await sub.cancel();
      sub = null;
      return ResourceProbeResult(
        label: label,
        url: url,
        statusCode: code,
        contentType: ct,
      );
    } catch (e) {
      return ResourceProbeResult(
        label: label,
        url: url,
        error: _shortError(e),
      );
    } finally {
      await sub?.cancel();
      io.close(force: true);
    }
  }

  static String _shortError(Object e) {
    final s = e.toString();
    if (s.contains('HandshakeException') ||
        s.contains('CERTIFICATE') ||
        s.contains('certificate')) {
      return 'TLS 证书被拒（HandshakeException）';
    }
    if (s.contains('SocketException')) {
      return '网络不可达 / 连接被拒（SocketException）';
    }
    if (s.contains('TimeoutException')) return '请求超时（8s）';
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }
}
