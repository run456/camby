import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'dlna_protocol.dart';

/// Android 的 Wi-Fi 驱动默认会**丢弃组播包**（省电）。不持 MulticastLock 时
/// SSDP M-SEARCH 常常一个响应都收不到，表现就是「一直搜索不到设备」。
/// Dart 侧拿不到 WifiManager，所以由 MainActivity 提供这个开关：
/// 只在发现阶段短暂持有，发现结束立刻释放，避免常驻耗电。
class MulticastLock {
  static const MethodChannel _channel = MethodChannel('cn.camby.camby/network');

  static Future<bool> set(bool enabled) async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'setMulticastLock',
        <String, dynamic>{'enabled': enabled},
      );
      return res?['held'] == true;
    } catch (_) {
      // 平台通道不存在（老包 / 桌面端）时静默降级，不影响后续单播 SOAP。
      return false;
    }
  }
}

/// SSDP 主动发现：发 M-SEARCH 组播，收设备的**单播**响应。
///
/// 刻意不调用 `joinMulticast`：设备对 M-SEARCH 的应答是定向发回源端口的
/// 单播包，接收它不需要加入组播组；而 Android 上 joinMulticast 必须显式
/// 指定 NetworkInterface，不指定会直接抛 SocketException，反而让整个发现
/// 流程失败。组播锁只用于保证**发出的** M-SEARCH 不被驱动过滤。
class SsdpDiscovery {
  const SsdpDiscovery();

  static const Duration defaultTimeout = Duration(seconds: 4);

  /// 返回去重后的设备描述 LOCATION 列表。
  Future<List<String>> search({
    Duration timeout = defaultTimeout,
    List<String> targets = ssdpSearchTargets,
  }) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    final seen = <String>{};
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket = sock;
      sub = sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        // 一次 read 事件可能积压多个数据报，循环取空。
        while (true) {
          final dg = sock.receive();
          if (dg == null) break;
          final raw = utf8.decode(dg.data, allowMalformed: true);
          final headers = parseSsdpHeaders(raw);
          final loc = ssdpLocation(headers);
          if (loc == null || !isRendererCandidate(headers)) continue;
          seen.add(loc);
        }
      });

      for (final st in targets) {
        _send(sock, st);
      }
      // UDP 没有重传；700ms 后补发一轮，明显提升国产电视 / 盒子的命中率。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      for (final st in targets) {
        _send(sock, st);
      }
      await Future<void>.delayed(timeout);
    } catch (_) {
      // 无网络 / Wi-Fi 未连接 / 不支持组播：交上层显示「未找到设备」。
    } finally {
      await sub?.cancel();
      socket?.close();
    }
    return seen.toList(growable: false);
  }

  void _send(RawDatagramSocket socket, String st) {
    try {
      socket.send(
        utf8.encode(buildMSearch(st)),
        InternetAddress(ssdpMulticastIp),
        ssdpPort,
      );
    } catch (_) {}
  }
}

/// 并行拉取各 LOCATION 的描述 XML，过滤出真正带 AVTransport 的 DMR 并去重。
class DeviceDescriptionFetcher {
  const DeviceDescriptionFetcher();

  Future<List<DlnaDevice>> fetch(
    List<String> locations, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final results = await Future.wait<DlnaDevice?>(
      locations.map((loc) => _one(loc, timeout)),
    );
    final byId = <String, DlnaDevice>{};
    for (final d in results) {
      if (d != null) byId.putIfAbsent(d.id, () => d);
    }
    final list = byId.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return list;
  }

  Future<DlnaDevice?> _one(String location, Duration timeout) async {
    try {
      final res = await http
          .get(
            Uri.parse(location),
            headers: const <String, String>{
              'USER-AGENT': dlnaUserAgent,
            },
          )
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      final xml = utf8.decode(res.bodyBytes, allowMalformed: true);
      return parseDeviceDescription(xml, location);
    } catch (_) {
      return null;
    }
  }
}
