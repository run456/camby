import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 播放器原生网络栈的证书开关（v2.0.87）。
///
/// 为什么需要它：Dart 层 `HttpClient.badCertificateCallback` 只管得住
/// `dart:io` 自己发起的请求（登录、拉库、海报、字幕）。视频播放走
/// `video_player` / ExoPlayer，底层是 Android 的 `HttpsURLConnection`，
/// 完全不走 Dart 的 SSL 栈 —— 自签证书的 HTTPS 片源在 Exo 内核下会直接
/// `SSLHandshakeException`，现象是「列表和海报都正常，点播放一直转圈/黑屏」。
/// MPV（libmpv + FFmpeg）默认 `tls-verify=no`，本来就能播，不需要这里处理。
///
/// 实现是 MainActivity 里给 `HttpsURLConnection` 换默认 SSLSocketFactory。
/// 这是**进程级**开关，所以只在用户对该服务器显式勾选「忽略 SSL 证书校验」
/// 时打开；切到不勾选的服务器、断开连接或 App 重启都会恢复系统默认。
class NativeSsl {
  static const MethodChannel _channel = MethodChannel(
    'cn.camby.camby/security',
  );

  static bool _current = false;

  /// 当前原生栈是否处于「信任任意证书」状态。仅用于诊断展示。
  static bool get ignoreCertificateErrors => _current;

  /// 同步开关。非 Android 平台 / 通道不可用时静默返回 false，不影响播放链。
  static Future<bool> setIgnoreCertificateErrors(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      _current = false;
      return false;
    }
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'setIgnoreSsl',
        <String, Object?>{'enabled': enabled},
      );
      _current = res?['enabled'] == true;
    } catch (_) {
      // 单元测试 / 桌面端没有这个通道；失败时保持系统默认（不信任自签）
      _current = false;
    }
    return _current;
  }
}
