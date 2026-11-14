import 'package:flutter/services.dart';

/// 设备 HDR 能力诊断（v2.0.83）。
///
/// 只读一次 `Display.getHdrCapabilities()`，用于播放信息面板说明「这块屏
/// 到底支不支持 HDR / DV」。**不用于开启 HDR 直通**：Flutter texture 不
/// 具备该能力，HDR 内容一律 tone-map 到 SDR，这是渲染管线的硬限制。
///
/// 平台通道不可用时（桌面、单元测试、旧系统）静默降级，绝不影响播放。
class DisplayCaps {
  static const MethodChannel _channel = MethodChannel('cn.camby.camby/display');

  static bool _loaded = false;
  static bool isHdr = false;
  static List<String> types = const <String>[];
  static String error = '';

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'hdrCapabilities',
      );
      if (res == null) return;
      isHdr = res['isHdr'] == true;
      types =
          (res['types'] as List?)?.map((e) => '$e').toList() ??
          const <String>[];
      error = res['error'] as String? ?? '';
    } catch (_) {
      // 测试环境 / 桌面端没有这个通道，读不到就算了
      error = '不可用';
    }
  }

  /// 播放信息面板的一行摘要
  static String get label {
    if (error.isNotEmpty) return '未知（$error）';
    if (!isHdr || types.isEmpty) return 'SDR 屏';
    return 'HDR 屏 · ${types.join(' / ')}';
  }

  static bool get supportsDolbyVision =>
      types.any((e) => e.toLowerCase().contains('dolby'));
}
