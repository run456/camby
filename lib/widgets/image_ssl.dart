import 'dart:io';

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
}
