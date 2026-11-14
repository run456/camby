import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'dlna_discovery.dart';
import 'dlna_protocol.dart';

enum DlnaPhase {
  idle,
  discovering,
  ready,
  connecting,
  playing,
  paused,
  stopped,
  error,
}

/// 一次投屏的内容描述。URL 由详情页按当前选中版本 / 兼容模式**现算**，
/// 控制器不依赖 Emby 客户端，也不缓存 URL（鉴权 token 可能会变）。
class CastRequest {
  const CastRequest({
    required this.url,
    required this.title,
    this.id = '0',
    this.startAt = Duration.zero,
    this.duration,
    this.mimeType = 'video/mp4',
  });

  final String url;
  final String title;
  final String id;
  final Duration startAt;
  final Duration? duration;
  final String mimeType;
}

class SoapResult {
  const SoapResult({this.body = '', this.error});

  final String body;
  final String? error;

  bool get ok => error == null;
}

/// DLNA 控制点（DMC）状态机。
///
/// 职责：发现 DMR → SetAVTransportURI + Play → 播放 / 暂停 / 停止 / 跳转 /
/// 音量 → 定时轮询进度与传输状态。手机**不解码、不转发视频**：投出去的是
/// Emby 的 stream URL，由电视自己拉取，因此断开 App 不影响电视播放。
class DlnaController extends ChangeNotifier {
  DlnaController({SsdpDiscovery? discovery, DeviceDescriptionFetcher? fetcher})
    : _discovery = discovery ?? const SsdpDiscovery(),
      _fetcher = fetcher ?? const DeviceDescriptionFetcher();

  /// 进程级共享实例：详情页退出再进入，投屏状态与已发现设备都还在。
  static final DlnaController shared = DlnaController();

  final SsdpDiscovery _discovery;
  final DeviceDescriptionFetcher _fetcher;

  List<DlnaDevice> devices = const <DlnaDevice>[];
  DlnaDevice? current;
  DlnaPhase phase = DlnaPhase.idle;
  String message = '';
  String castTitle = '';
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  int volume = 50;

  /// 兼容模式：改用 Emby 的 HLS 转码流（兼容性好、画质有损）。
  /// 默认直连原片，电视不支持容器 / 编码时再打开。
  bool compatibleMode = false;

  bool _discovering = false;
  Timer? _poll;

  bool get isBusy =>
      phase == DlnaPhase.discovering || phase == DlnaPhase.connecting;

  bool get isActive =>
      current != null &&
      (phase == DlnaPhase.playing ||
          phase == DlnaPhase.paused ||
          phase == DlnaPhase.connecting);

  bool get isPlaying => phase == DlnaPhase.playing;

  @override
  void dispose() {
    _stopPoll();
    super.dispose();
  }

  // ── 发现 ────────────────────────────────────────────────────────────────

  Future<void> discover() async {
    if (_discovering) return;
    _discovering = true;
    phase = DlnaPhase.discovering;
    message = '正在搜索同一 Wi-Fi 下的投屏设备…';
    notifyListeners();

    // 组播锁只在发现期间持有；finally 里必定释放，避免常驻耗电。
    await MulticastLock.set(true);
    try {
      final locations = await _discovery.search();
      devices = await _fetcher.fetch(locations);
      phase = DlnaPhase.ready;
      message = devices.isEmpty ? '没有找到投屏设备' : '找到 ${devices.length} 台设备';
    } catch (e) {
      phase = DlnaPhase.error;
      message = '搜索失败：$e';
    } finally {
      await MulticastLock.set(false);
      _discovering = false;
      notifyListeners();
    }
  }

  void setCompatibleMode(bool value) {
    if (compatibleMode == value) return;
    compatibleMode = value;
    notifyListeners();
  }

  // ── 投屏 ────────────────────────────────────────────────────────────────

  Future<bool> cast(DlnaDevice device, CastRequest request) async {
    _stopPoll();
    current = device;
    castTitle = request.title;
    phase = DlnaPhase.connecting;
    message = '正在连接 ${device.title}…';
    position = Duration.zero;
    duration = request.duration ?? Duration.zero;
    notifyListeners();

    final metadata = buildDidlLite(
      id: request.id,
      title: request.title,
      url: request.url,
      duration: request.duration,
      mimeType: request.mimeType,
    );

    final ok = await _call(
      device.avTransportUrl,
      setAvTransportUriCall(url: request.url, metadata: metadata),
    );
    if (!ok) return false;
    if (!await play()) return false;

    if (request.startAt > Duration.zero) {
      await seek(request.startAt);
    }
    await _refreshVolume(device);
    return true;
  }

  Future<bool> play() async {
    final d = current;
    if (d == null) return false;
    if (!await _call(d.avTransportUrl, playCall())) return false;
    phase = DlnaPhase.playing;
    message = '';
    notifyListeners();
    _startPoll();
    return true;
  }

  Future<void> pause() async {
    final d = current;
    if (d == null) return;
    if (!await _call(d.avTransportUrl, pauseCall())) return;
    phase = DlnaPhase.paused;
    message = '';
    notifyListeners();
  }

  Future<void> stop() async {
    final d = current;
    _stopPoll();
    if (d != null) {
      await _call(d.avTransportUrl, stopCall());
    }
    phase = DlnaPhase.stopped;
    position = Duration.zero;
    message = '';
    notifyListeners();
  }

  Future<void> disconnect() async {
    await stop();
    await MulticastLock.set(false);
    current = null;
    castTitle = '';
    phase = DlnaPhase.idle;
    message = '';
    notifyListeners();
  }

  Future<void> seek(Duration at) async {
    final d = current;
    if (d == null) return;
    if (!await _call(d.avTransportUrl, seekCall(at))) return;
    position = at;
    notifyListeners();
  }

  Future<void> setVolume(int value) async {
    final d = current;
    final url = d?.renderingControlUrl;
    if (url == null) return;
    final v = value.clamp(0, 100).toInt();
    if (!await _call(url, setVolumeCall(v))) return;
    volume = v;
    notifyListeners();
  }

  // ── SOAP ────────────────────────────────────────────────────────────────

  Future<SoapResult> _post(String controlUrl, SoapCall call) async {
    try {
      final res = await http
          .post(
            Uri.parse(controlUrl),
            headers: <String, String>{
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': call.actionHeader,
              'USER-AGENT': 'Camby/2.0.84 UPnP/1.1 DLNADOC/1.50',
            },
            body: utf8.encode(call.envelope),
          )
          .timeout(const Duration(seconds: 6));
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      final fault = soapFault(body);
      if (fault != null) return SoapResult(body: body, error: fault);
      if (res.statusCode >= 400) {
        return SoapResult(body: body, error: '设备返回 HTTP ${res.statusCode}');
      }
      return SoapResult(body: body);
    } on TimeoutException catch (_) {
      return const SoapResult(error: '设备响应超时');
    } catch (e) {
      return SoapResult(error: '$e');
    }
  }

  Future<bool> _call(String controlUrl, SoapCall call) async {
    final r = await _post(controlUrl, call);
    if (r.ok) return true;
    phase = DlnaPhase.error;
    message = r.error ?? '设备无响应';
    notifyListeners();
    return false;
  }

  Future<void> _refreshVolume(DlnaDevice device) async {
    final url = device.renderingControlUrl;
    if (url == null) return;
    final r = await _post(url, getVolumeCall());
    if (!r.ok) return;
    final v = parseVolume(r.body);
    if (v == null) return;
    volume = v;
    notifyListeners();
  }

  // ── 轮询 ────────────────────────────────────────────────────────────────

  void _startPoll() {
    _stopPoll();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _pollOnce());
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _pollOnce() async {
    final d = current;
    if (d == null ||
        (phase != DlnaPhase.playing && phase != DlnaPhase.paused)) {
      return;
    }
    final results = await Future.wait<SoapResult>(<Future<SoapResult>>[
      _post(d.avTransportUrl, getPositionInfoCall()),
      _post(d.avTransportUrl, getTransportInfoCall()),
    ]);
    final pos = results[0];
    if (pos.ok) {
      final p = parsePositionInfo(pos.body);
      position = p.relTime;
      if (p.trackDuration > Duration.zero) duration = p.trackDuration;
    }
    final info = results[1];
    if (info.ok) {
      final state = parseTransportState(info.body).toUpperCase();
      if (state == 'PLAYING') {
        phase = DlnaPhase.playing;
      } else if (state == 'PAUSED_PLAYBACK' || state == 'PAUSED') {
        phase = DlnaPhase.paused;
      } else if (state == 'STOPPED' || state == 'NO_MEDIA_PRESENT') {
        phase = DlnaPhase.stopped;
        _stopPoll();
      }
    }
    notifyListeners();
  }
}
