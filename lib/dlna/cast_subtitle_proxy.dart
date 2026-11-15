import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// v2.0.100：DLNA 投屏的**本机字幕代理**。
///
/// 为什么需要它：投屏是 DMR 模式，电视自己发 HTTP GET 拉字幕。原来塞进
/// DIDL-Lite 的 `Stream.srt?api_key=...` 有两个硬伤 ——
///  1. 绿联兼容层只认 `X-Emby-Token` 请求头，电视不会带，字幕请求直接 401；
///  2. 带 `?api_key=…` 的 URL 不以 `.srt` 结尾，不少电视按扩展名认字幕，
///     直接忽略掉这条外挂资源。
///
/// 这里在手机上起一个极轻量的 HTTP 服务：App 用自己的完整鉴权把 SRT
/// 拉成字节，对外暴露 `http://<局域网IP>:<端口>/sub/<id>.srt` —— 无鉴权、
/// 无 query、以 `.srt` 结尾、内容是纯 UTF-8 文本。电视只要肯读 DIDL-Lite
/// 里的字幕地址，就一定拿得到内容，且完全不需要服务端实时转码。
///
/// 只转发几十 KB 的文本，视频仍由电视直连服务器，手机不当中转。
class CastSubtitleProxy {
  CastSubtitleProxy({this.hostOverride});

  static final CastSubtitleProxy instance = CastSubtitleProxy();

  /// 测试可注入；生产恒为 null，由 [_localIPv4] 自动探测。
  final String? hostOverride;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _sub;
  Future<HttpServer>? _starting;
  String? _host;
  int _seq = 0;
  final Map<String, Uint8List> _files = <String, Uint8List>{};

  static final RegExp _subPath = RegExp(r'^/sub/([0-9]+)\.srt$');

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// 发布一份字幕，返回给电视用的绝对 URL。
  ///
  /// 抛异常时调用方应回退到原始 URL —— 拿不到局域网 IP（例如只用蜂窝数据）
  /// 不该让原本能投的片变得不能投。
  Future<Uri> publish(List<int> raw) async {
    final server = await _ensureServer();
    final host = _host;
    if (host == null || host.isEmpty) {
      throw const SocketException('找不到可用的局域网 IPv4 地址');
    }
    final id = (++_seq).toString();
    _files[id] = _normalize(raw);
    return Uri(
      scheme: 'http',
      host: host,
      port: server.port,
      path: '/sub/$id.srt',
    );
  }

  Future<HttpServer> _ensureServer() {
    final running = _server;
    if (running != null) return Future<HttpServer>.value(running);
    final pending = _starting;
    if (pending != null) return pending;
    final f = _start();
    _starting = f;
    return f;
  }

  Future<HttpServer> _start() async {
    final host = hostOverride ?? await _localIPv4();
    if (host == null || host.isEmpty) {
      _starting = null;
      throw const SocketException('找不到可用的局域网 IPv4 地址');
    }
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _host = host;
    _starting = null;
    _sub = server.listen(
      (HttpRequest req) {
        unawaited(_handle(req));
      },
      onError: (Object _) {},
    );
    return server;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      _commonHeaders(res);
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.ok;
        await res.close();
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        await res.close();
        return;
      }
      final m = _subPath.firstMatch(req.uri.path);
      final bytes = m == null ? null : _files[m.group(1)!];
      if (bytes == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }

      var start = 0;
      var end = bytes.length - 1;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final rm = RegExp(r'bytes=([0-9]*)-([0-9]*)')
            .firstMatch(range.trim());
        if (rm != null) {
          final a = rm.group(1)!;
          final b = rm.group(2)!;
          if (a.isNotEmpty) start = int.tryParse(a) ?? 0;
          if (b.isNotEmpty) {
            end = int.tryParse(b) ?? end;
          }
          if (start >= bytes.length || start > end) {
            res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            res.headers.set('Content-Range', 'bytes */${bytes.length}');
            await res.close();
            return;
          }
          if (end >= bytes.length || end < start) end = bytes.length - 1;
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            'Content-Range',
            'bytes $start-$end/${bytes.length}',
          );
        }
      }

      final slice = bytes.sublist(start, end + 1);
      res.headers.set(HttpHeaders.contentLengthHeader, slice.length);
      if (req.method != 'HEAD') res.add(slice);
      await res.close();
    } catch (_) {
      // 电视可能在拿到字幕前就断开连接；一次失败不能拖垮整个服务。
      try {
        await res.close();
      } catch (_) {}
    }
  }

  void _commonHeaders(HttpResponse res) {
    res.headers.set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8');
    res.headers.set('Accept-Ranges', 'bytes');
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.persistentConnection = false;
  }

  /// UTF-8 BOM 会让部分电视把第一行序号吃掉；非法字节替换成 U+FFFD，
  /// 保证回出去的一定是合法 UTF-8。
  Uint8List _normalize(List<int> raw) {
    var b = raw;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      b = b.sublist(3);
    }
    final text = utf8.decode(b, allowMalformed: true);
    return Uint8List.fromList(utf8.encode(text));
  }

  /// Wi-Fi 与蜂窝同时在线时会列出多个地址，优先 WLAN / 以太网，
  /// 排除环回与 169.254 自动私有地址。
  static Future<String?> _localIPv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final sorted = <NetworkInterface>[...ifaces]
        ..sort((a, b) => _ifaceScore(a.name).compareTo(_ifaceScore(b.name)));
      for (final i in sorted) {
        for (final a in i.addresses) {
          if (a.isLoopback || a.address.startsWith('169.254.')) continue;
          return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  static int _ifaceScore(String name) {
    final n = name.toLowerCase();
    if (n.contains('wlan') || n.contains('eth') || n.startsWith('en')) {
      return 0;
    }
    if (n.contains('rmnet') ||
        n.contains('cellular') ||
        n.contains('pdp') ||
        n.contains('wwan')) {
      return 20;
    }
    return 10;
  }

  /// 仅供测试释放端口；生产环境单例常驻到进程结束（电视可能在播放中途
  /// 重新请求字幕，断开投屏时关掉服务反而会让它取不到）。
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _server?.close(force: true);
    _server = null;
    _starting = null;
    _host = null;
    _files.clear();
  }
}
