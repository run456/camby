/// DLNA / UPnP 协议层（v2.0.84，v2.0.85 补外挂字幕 metadata）。
///
/// 这里只放**纯函数与不可变模型**：SSDP 报文、设备描述 XML、SOAP envelope、
/// DIDL-Lite metadata、响应解析。刻意不引用 `dart:io` / Flutter，因而可以在
/// `flutter test` 里逐条验证 —— DLNA 最容易出错的恰恰是转义与相对 URL，
/// 这两类 bug 在真机上只会表现为「电视毫无反应」，很难定位。
library;

// ───────────────────────────────────────────────────────────────────────────
// SSDP（简单服务发现协议）
// ───────────────────────────────────────────────────────────────────────────

const String ssdpMulticastIp = '239.255.255.250';
const int ssdpPort = 1900;

/// 发版号只在这里维护：SSDP M-SEARCH、描述 XML GET、SOAP POST 三处共用，
/// 以前散在三个文件里，升版本时漏改就会出现「同一会话两种 UA」的怪现象。
const String dlnaUserAgent = 'Camby/2.0.106 UPnP/1.1 DLNADOC/1.50';

/// 同时搜三类目标：只发 MediaRenderer 会漏掉部分国产电视 / 盒子（它们只回
/// `ssdp:all` 或 AVTransport 服务类型）。多播三个包代价可忽略。
const List<String> ssdpSearchTargets = <String>[
  'urn:schemas-upnp-org:device:MediaRenderer:1',
  'urn:schemas-upnp-org:service:AVTransport:1',
  'ssdp:all',
];

String buildMSearch(String st, {int mx = 3}) =>
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: $ssdpMulticastIp:$ssdpPort\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: $mx\r\n'
    'ST: $st\r\n'
    'USER-AGENT: $dlnaUserAgent\r\n'
    '\r\n';

/// 解析 SSDP 响应头。首行是状态行（`HTTP/1.1 200 OK` / `NOTIFY * HTTP/1.1`），
/// 没有冒号会被自然跳过；header 名统一大写，兼容设备里五花八门的大小写。
Map<String, String> parseSsdpHeaders(String raw) {
  final out = <String, String>{};
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    final key = line.substring(0, i).trim().toUpperCase();
    if (key.isEmpty || key.contains(' ')) continue;
    out[key] = line.substring(i + 1).trim();
  }
  return out;
}

/// SSDP 报文里的设备描述地址。LOCATION 是唯一能继续往下走的信息。
String? ssdpLocation(Map<String, String> headers) {
  final v = headers['LOCATION'];
  return (v == null || v.isEmpty) ? null : v;
}

/// 粗筛：明确的媒体服务器 / 网关直接丢掉，其余都放行。
/// 是否为可投屏设备最终由描述 XML 里有没有 AVTransport 决定（见
/// [parseDeviceDescription]），这里宁可多 GET 一次也不要漏掉只回 `ssdp:all`
/// 的电视。
bool isRendererCandidate(Map<String, String> headers) {
  final s =
      '${headers['ST'] ?? ''} ${headers['US'] ?? ''} '
              '${headers['NT'] ?? ''} ${headers['SERVER'] ?? ''}'
          .toLowerCase();
  const excluded = <String>[
    'mediaserver',
    'contentdirectory',
    'internetgateway',
    'wanipconnection',
    'wanpppconnection',
    'mediareceiverregistrar',
    'connectionmanager:',
  ];
  for (final e in excluded) {
    if (s.contains(e)) return false;
  }
  return true;
}

// ───────────────────────────────────────────────────────────────────────────
// XML 小工具（UPnP 描述与 SOAP 响应结构都很扁，不值得引入 xml 包）
// ───────────────────────────────────────────────────────────────────────────

/// 取第一个同名标签的文本，容忍命名空间前缀（`<upnp:friendlyName>`）。
/// XML 派生类里标签名不会被转义，直接用插值拼进正则即可。
String xmlTagValue(String src, String name) {
  if (src.isEmpty || name.isEmpty) return '';
  // \\b 不可省：否则 name='service' 会把 <serviceList> 也当成开始标签，
  // name='url' 会误匹配 <URLBase>，解析结果直接串位。
  final re = RegExp(
    '<(?:[A-Za-z0-9_.-]+:)?$name\\b\\s*[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?$name\\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  final m = re.firstMatch(src);
  if (m == null) return '';
  return xmlUnescape(m.group(1)!.trim());
}

/// 取所有 `<service>` / `<icon>` 块，供调用方逐块取字段。
List<String> xmlBlocks(String src, String name) {
  if (src.isEmpty) return const <String>[];
  final re = RegExp(
    '<(?:[A-Za-z0-9_.-]+:)?$name\\b\\s*[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?$name\\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  return re.allMatches(src).map((m) => m.group(1) ?? '').toList();
}

String xmlUnescape(String s) => s
    .replaceAllMapped(RegExp(r'&#(x[0-9A-Fa-f]+|[0-9]+);'), (m) {
      final g = m.group(1)!;
      final v = g.startsWith('x')
          ? int.tryParse(g.substring(1), radix: 16)
          : int.tryParse(g);
      return v == null ? m.group(0)! : String.fromCharCode(v);
    })
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    // &amp; 必须最后替换，否则 `&amp;lt;` 会被二次解码成 `<`。
    .replaceAll('&amp;', '&');

String xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

// ───────────────────────────────────────────────────────────────────────────
// 设备描述（GET LOCATION 得到的 XML）
// ───────────────────────────────────────────────────────────────────────────

/// 把描述 XML 里的相对 controlURL 拼成绝对 URL。
///
/// 三种形态都要处理：完整 `http://...`、根相对 `/AVTransport/control`、
/// 以及文档相对 `ctl/AVTransport`（相对于 LOCATION 所在目录）。URLBase 存在时
/// 优先用它的 scheme/host/port，否则退回 LOCATION。
String resolveControlUrl(String location, String urlBase, String controlUrl) {
  final raw = controlUrl.trim();
  if (raw.isEmpty) return '';
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;

  final loc = Uri.tryParse(location) ?? Uri.parse('http://127.0.0.1/');
  final base = Uri.tryParse(urlBase.isNotEmpty ? urlBase : location) ?? loc;

  final path = raw.startsWith('/')
      ? raw
      : '${loc.path.contains('/') ? loc.path.substring(0, loc.path.lastIndexOf('/') + 1) : '/'}$raw';

  final scheme = base.hasScheme ? base.scheme : 'http';
  final host = base.host.isNotEmpty ? base.host : loc.host;
  final port = base.hasPort ? base.port : (loc.hasPort ? loc.port : 0);
  final authority = port > 0 ? '$host:$port' : host;
  return '$scheme://$authority$path';
}

/// 一台可被投屏的 DMR（Digital Media Renderer）。
class DlnaDevice {
  const DlnaDevice({
    required this.id,
    required this.friendlyName,
    required this.location,
    required this.avTransportUrl,
    this.renderingControlUrl,
    this.manufacturer = '',
    this.modelName = '',
    this.iconUrl,
  });

  /// UDN（一般是 `uuid:...`）；缺失时退化为 LOCATION，用于去重。
  final String id;
  final String friendlyName;
  final String location;

  /// AVTransport 的绝对 controlURL，SOAP 动作都往这里 POST。
  final String avTransportUrl;

  /// RenderingControl 的绝对 controlURL；没有就隐藏音量控制。
  final String? renderingControlUrl;
  final String manufacturer;
  final String modelName;
  final String? iconUrl;

  String get title => friendlyName.isNotEmpty
      ? friendlyName
      : (modelName.isNotEmpty ? modelName : '未命名设备');

  String get subtitle =>
      [manufacturer, modelName].where((e) => e.isNotEmpty).toSet().join(' · ');

  bool get hasVolume => renderingControlUrl != null;
}

/// 解析设备描述 XML。**只有含 AVTransport 服务的设备才是可投屏 DMR**，
/// 其余（媒体服务器、网关、机顶盒的其它服务）返回 null 直接过滤掉。
DlnaDevice? parseDeviceDescription(String xml, String location) {
  if (xml.isEmpty) return null;
  final urlBase = xmlTagValue(xml, 'URLBase');
  String? av;
  String? rc;
  for (final block in xmlBlocks(xml, 'service')) {
    final type = xmlTagValue(block, 'serviceType').toLowerCase();
    final control = xmlTagValue(block, 'controlURL');
    if (control.isEmpty) continue;
    final abs = resolveControlUrl(location, urlBase, control);
    if (type.contains('avtransport') && av == null) av = abs;
    if (type.contains('renderingcontrol') && rc == null) rc = abs;
  }
  // 少数设备把 serviceType 写在 serviceId 里，补一次兜底。
  if (av == null) {
    for (final block in xmlBlocks(xml, 'service')) {
      final id = xmlTagValue(block, 'serviceId').toLowerCase();
      final control = xmlTagValue(block, 'controlURL');
      if (id.contains('avtransport') && control.isNotEmpty) {
        av = resolveControlUrl(location, urlBase, control);
        break;
      }
    }
  }
  if (av == null) return null;

  final udn = xmlTagValue(xml, 'UDN');
  final icons = xmlBlocks(xml, 'icon');
  final iconPath = icons.isEmpty ? '' : xmlTagValue(icons.first, 'url');

  return DlnaDevice(
    id: udn.isNotEmpty ? udn : location,
    friendlyName: xmlTagValue(xml, 'friendlyName'),
    location: location,
    avTransportUrl: av,
    renderingControlUrl: rc,
    manufacturer: xmlTagValue(xml, 'manufacturer'),
    modelName: xmlTagValue(xml, 'modelName'),
    iconUrl: iconPath.isEmpty
        ? null
        : resolveControlUrl(location, urlBase, iconPath),
  );
}

// ───────────────────────────────────────────────────────────────────────────
// SOAP / AVTransport / RenderingControl
// ───────────────────────────────────────────────────────────────────────────

const String avTransportService = 'urn:schemas-upnp-org:service:AVTransport:1';
const String renderingControlService =
    'urn:schemas-upnp-org:service:RenderingControl:1';

/// 一次 SOAP 动作。envelope 与 SOAPACTION 头必须由同一个 service/action 生成，
/// 否则设备会回 401 Invalid Action。
class SoapCall {
  const SoapCall(
    this.service,
    this.action, [
    this.args = const <String, String>{},
  ]);

  final String service;
  final String action;
  final Map<String, String> args;

  String get actionHeader => '"$service#$action"';

  String get envelope {
    final body = args.entries
        .map((e) => '<${e.key}>${xmlEscape(e.value)}</${e.key}>')
        .join();
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$service">$body</u:$action></s:Body>'
        '</s:Envelope>';
  }
}

SoapCall setAvTransportUriCall({
  required String url,
  required String metadata,
}) => SoapCall(avTransportService, 'SetAVTransportURI', <String, String>{
  'InstanceID': '0',
  'CurrentURI': url,
  'CurrentURIMetaData': metadata,
});

SoapCall playCall([String speed = '1']) => SoapCall(
  avTransportService,
  'Play',
  <String, String>{'InstanceID': '0', 'Speed': speed},
);

SoapCall pauseCall() =>
    SoapCall(avTransportService, 'Pause', <String, String>{'InstanceID': '0'});

SoapCall stopCall() =>
    SoapCall(avTransportService, 'Stop', <String, String>{'InstanceID': '0'});

SoapCall seekCall(Duration at) =>
    SoapCall(avTransportService, 'Seek', <String, String>{
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': formatUpnpDuration(at),
    });

SoapCall getPositionInfoCall() => const SoapCall(
  avTransportService,
  'GetPositionInfo',
  <String, String>{'InstanceID': '0'},
);

SoapCall getTransportInfoCall() => const SoapCall(
  avTransportService,
  'GetTransportInfo',
  <String, String>{'InstanceID': '0'},
);

SoapCall setVolumeCall(int volume) =>
    SoapCall(renderingControlService, 'SetVolume', <String, String>{
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${volume.clamp(0, 100).toInt()}',
    });

SoapCall getVolumeCall() => const SoapCall(
  renderingControlService,
  'GetVolume',
  <String, String>{'InstanceID': '0', 'Channel': 'Master'},
);

/// DIDL-Lite：SetAVTransportURI 的 CurrentURIMetaData。
///
/// 关键是**整段 XML 会作为 SOAP 参数再被 [xmlEscape] 转义一次**，所以这里
/// 内部的 URL / 标题必须先各自转义，否则含 `&` 的 Emby 流地址会让设备
/// 解析 XML 失败，表现是「点了投屏电视没反应」。
String buildDidlLite({
  required String id,
  required String title,
  required String url,
  Duration? duration,
  String mimeType = 'video/mp4',
  String? subtitleUrl,
  String subtitleType = 'srt',
}) {
  final dur = duration == null
      ? ''
      : ' duration="${formatUpnpDuration(duration)}"';

  // v2.0.85：外挂字幕必须在**起播的 metadata** 里声明。DLNA 没有标准的
  // 「选字幕」动作，电视只看得到 SetAVTransportURI 带过来的这份 DIDL-Lite。
  // 各厂商用各自的私有字段，互相不认，所以一次全塞：
  //   · sec:CaptionInfoEx / CaptionInfo —— 三星（Ex 是必须的 hint）
  //   · pv:subtitleFileUri + 第二个 text/srt res —— LG / 松下 / 部分安卓电视
  // 字幕 URL 里带 api_key（有 &），这里先转义一次，整段 metadata 作为 SOAP
  // 参数时还会再转义一次，两层都不能省。
  var sub = '';
  if (subtitleUrl != null && subtitleUrl.isNotEmpty) {
    final u = xmlEscape(subtitleUrl);
    final t = xmlEscape(subtitleType);
    sub = '<sec:CaptionInfoEx sec:type="$t">$u</sec:CaptionInfoEx>'
        '<sec:CaptionInfo sec:type="$t">$u</sec:CaptionInfo>'
        '<res protocolInfo="http-get:*:text/$t:DLNA.ORG_OP=01;DLNA.ORG_CI=0" '
        'pv:subtitleFileUri="$u" pv:subtitleFileType="$t">$u</res>';
  }

  // 命名空间只在真的带字幕时追加：不带字幕的输出必须与 v2.0.84 逐字节
  // 一致，否则等于给所有已能正常投屏的电视换了一份 metadata，纯属自找风险。
  final ns = sub.isEmpty
      ? ''
      : ' xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" '
          'xmlns:sec="http://www.sec.co.kr/" '
          'xmlns:pv="http://www.pv.com/pvns/"';
  return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"$ns>'
      '<item id="${xmlEscape(id)}" parentID="-1" restricted="1">'
      '<dc:title>${xmlEscape(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="http-get:*:$mimeType:DLNA.ORG_OP=01;DLNA.ORG_CI=0"$dur>'
      '${xmlEscape(url)}</res>'
      '$sub'
      '</item></DIDL-Lite>';
}

/// UPnP 时间格式 `HH:MM:SS`（小时不截断，超过 99 也照写）。
String formatUpnpDuration(Duration d) {
  final neg = d.isNegative ? Duration.zero : d;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(neg.inHours)}:${two(neg.inMinutes % 60)}:'
      '${two(neg.inSeconds % 60)}';
}

/// 解析 `00:12:34` / `00:12:34.500`，坏数据一律退化为 0 而不是抛异常。
Duration parseUpnpDuration(String? raw) {
  if (raw == null || raw.isEmpty) return Duration.zero;
  final parts = raw.trim().split(':');
  if (parts.length < 3) return Duration.zero;
  final h = int.tryParse(parts[0]) ?? 0;
  final m = int.tryParse(parts[1]) ?? 0;
  final sec = double.tryParse(parts[2]) ?? 0;
  final whole = sec.floor();
  final ms = ((sec - whole) * 1000).round();
  return Duration(hours: h, minutes: m, seconds: whole, milliseconds: ms);
}

/// SOAP Fault：UPnP 设备出错时 HTTP 状态是 500，body 里才有可读原因。
String? soapFault(String body) {
  final f = xmlTagValue(body, 'faultstring');
  if (f.isNotEmpty) return f;
  final d = xmlTagValue(body, 'errorDescription');
  if (d.isNotEmpty) return d;
  // SOAP Fault 常带命名空间前缀（<s:Fault>），单看 "<fault" 会漏。
  final lower = body.toLowerCase();
  if (lower.contains('<fault') || lower.contains(':fault')) {
    return '设备返回错误';
  }
  return null;
}

class TransportPosition {
  const TransportPosition({required this.relTime, required this.trackDuration});

  final Duration relTime;
  final Duration trackDuration;
}

TransportPosition parsePositionInfo(String body) => TransportPosition(
  relTime: parseUpnpDuration(xmlTagValue(body, 'RelTime')),
  trackDuration: parseUpnpDuration(xmlTagValue(body, 'TrackDuration')),
);

String parseTransportState(String body) =>
    xmlTagValue(body, 'CurrentTransportState');

int? parseVolume(String body) =>
    int.tryParse(xmlTagValue(body, 'CurrentVolume'));

/// 投屏是「把 URL 交给电视，电视自己去拉流」，手机不解码不转发。
/// 因此 Emby 地址必须是电视能访问到的局域网地址；`localhost` / `127.0.0.1`
/// 这类回环地址在电视上指向电视自己，必然失败。
bool isLanReachableUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !u.hasScheme || u.host.isEmpty) return false;
  final h = u.host.toLowerCase();
  const loopback = <String>['localhost', '127.0.0.1', '::1', '0.0.0.0'];
  if (loopback.contains(h)) return false;
  return u.scheme == 'http' || u.scheme == 'https';
}
