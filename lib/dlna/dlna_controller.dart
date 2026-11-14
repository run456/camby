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

/// 一条可随投屏发送的字幕轨（v2.0.85）。
///
/// [url] 统一指向 Emby 的 `Stream.srt`：DLNA 电视端基本只认 SubRip，
/// `SubtitleTrackInfo.textCandidates` 会把 ASS / VTT / SMI 的扩展名换成
/// srt，由服务端按扩展名转出文本流。[streamIndex] 是烧录模式要用的
/// `SubtitleStreamIndex`。
class CastSubtitle {
  const CastSubtitle({
    required this.label,
    required this.url,
    required this.streamIndex,
    this.isTextFriendly = true,
  });

  final String label;
  final String url;
  final int streamIndex;

  /// PGS / SUP 等图形字幕即便换成 SRT 扩展名也拿不到文本，电视端外挂
  /// 大概率无效，面板给「建议烧录」提示；不硬禁止，交由用户试。
  final bool isTextFriendly;
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
    this.subtitleUrl,
    this.subtitleLabel,
  });

  final String url;
  final String title;
  final String id;
  final Duration startAt;
  final Duration? duration;
  final String mimeType;

  /// 外挂字幕的绝对 SRT 地址。**烧录模式传 null** —— 字幕已经在画面里，
  /// 再外挂一次会让电视叠加出双份字幕。
  final String? subtitleUrl;

  /// 面板展示用，controller 只透传不解析。
  final String? subtitleLabel;
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

  // ── 字幕（v2.0.85）────────────────────────────────────────────────────
  List<CastSubtitle> subtitles = const <CastSubtitle>[];
  CastSubtitle? selectedSubtitle;

  /// 把外挂字幕地址写进 DIDL-Lite（默认开，无损、不转码）。
  bool sendSubtitle = true;

  /// 让 Emby 把字幕烧进画面（默认关：实时转码、画质有损，但任何电视都认）。
  bool burnSubtitle = false;

  String castSubtitleLabel = '';

  /// 实际生效的字幕：关闭「随投屏发送」时为 null。
  CastSubtitle? get effectiveSubtitle =>
      sendSubtitle ? selectedSubtitle : null;

  /// 面板 chip 的高亮判定：[s] 为 null 代表「不带字幕」那一枚。
  /// 关掉「随片发送」后就应该高亮它，而不是继续高亮某条字幕轨。
  bool isSubtitleSelected(CastSubtitle? s) {
    if (s == null) return !sendSubtitle;
    return sendSubtitle && selectedSubtitle?.streamIndex == s.streamIndex;
  }

  /// 上一次配置字幕时所属的片源。字幕的 `streamIndex` 在不同影片间会重复
  /// （基本都是 2、3、4…），只按 index 保留选择会把上一部片选的轨错带到
  /// 下一部，所以换个 itemId 就必须重置。
  String _subtitleScope = '';

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

  // ── 字幕选择 ────────────────────────────────────────────────────────────

  /// 打开面板时由详情页注入候选。同一片源内保留用户此前的选择；换片
  /// （[scope] 一般是 itemId）则重置，并跟随详情页手选的轨；详情页没选
  /// 就取第一条（通常是默认中文字幕）——用户要求「有字幕的也投过去」。
  void configureSubtitles({
    required List<CastSubtitle> available,
    int? preferredIndex,
    String scope = '',
  }) {
    final sameScope = scope.isNotEmpty && scope == _subtitleScope;
    _subtitleScope = scope;
    subtitles = available;

    final keep = sameScope ? selectedSubtitle : null;
    if (keep != null &&
        available.any((e) => e.streamIndex == keep.streamIndex)) {
      notifyListeners();
      return;
    }
    CastSubtitle? pick;
    for (final s in available) {
      if (s.streamIndex == preferredIndex) {
        pick = s;
        break;
      }
    }
    selectedSubtitle = available.isEmpty ? null : (pick ?? available.first);
    if (!sameScope) sendSubtitle = true;
    notifyListeners();
  }

  /// [value] 为 null 即面板里的「不带字幕」chip。
  void selectSubtitle(CastSubtitle? value) {
    if (value == null) {
      setSendSubtitle(false);
      return;
    }
    if (selectedSubtitle?.streamIndex == value.streamIndex && sendSubtitle) {
      return;
    }
    selectedSubtitle = value;
    sendSubtitle = true;
    notifyListeners();
  }

  void setSendSubtitle(bool value) {
    if (sendSubtitle == value) return;
    sendSubtitle = value;
    notifyListeners();
  }

  void setBurnSubtitle(bool value) {
    if (burnSubtitle == value) return;
    burnSubtitle = value;
    notifyListeners();
  }

  // ── 投屏 ────────────────────────────────────────────────────────────────

  Future<bool> cast(DlnaDevice device, CastRequest request) async {
    _stopPoll();
    current = device;
    castTitle = request.title;
    castSubtitleLabel = request.subtitleLabel ?? '';
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
      subtitleUrl: request.subtitleUrl,
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
              'USER-AGENT': dlnaUserAgent,
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
