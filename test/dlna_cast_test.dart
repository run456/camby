import 'dart:io';

import 'package:camby/dlna/dlna_controller.dart';
import 'package:camby/dlna/dlna_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.84：DLNA 投屏链路的回归守卫。
///
/// DLNA 最阴的 bug 都在「看不见」的地方：XML 转义漏一层、相对 controlURL
/// 拼错、`<serviceList>` 被正则当成 `<service>`、Android 没持组播锁 ——
/// 真机表现一律是「点投屏电视没反应」，所以这里把协议层钉成纯函数逐条测。
String src(String path) => File(path).readAsStringSync();

const String _desc = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <URLBase>http://192.168.1.42:8200/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅 &amp; 电视</friendlyName>
    <manufacturer>Sony</manufacturer>
    <modelName>BRAVIA 4K</modelName>
    <UDN>uuid:abc-123</UDN>
    <iconList><icon><mimetype>image/png</mimetype><url>/icons/48.png</url></icon></iconList>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/org_tv_ctrl</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/RenderingControl/ctrl</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/ConnectionManager/ctrl</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

void main() {
  group('SSDP 发现报文与响应', () {
    test('M-SEARCH 报文格式完整（HOST/MAN/MX/ST + CRLF + 空行）', () {
      final m = buildMSearch('urn:schemas-upnp-org:device:MediaRenderer:1');
      expect(m, contains('M-SEARCH * HTTP/1.1\r\n'));
      expect(m, contains('HOST: 239.255.255.250:1900\r\n'));
      expect(m, contains('MAN: "ssdp:discover"\r\n'));
      expect(m, contains('MX: 3\r\n'));
      expect(
        m,
        contains('ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'),
      );
      expect(m.endsWith('\r\n\r\n'), isTrue);
    });

    test('默认搜三类目标，避免漏掉只回 ssdp:all 的国产电视', () {
      expect(ssdpSearchTargets.length, 3);
      expect(ssdpSearchTargets.any((e) => e.contains('MediaRenderer')), isTrue);
      expect(ssdpSearchTargets.any((e) => e.contains('AVTransport')), isTrue);
      expect(ssdpSearchTargets.contains('ssdp:all'), isTrue);
    });

    test('响应头解析：大小写无关、状态行跳过、URL 里的冒号不截断', () {
      final h = parseSsdpHeaders(
        'HTTP/1.1 200 OK\r\n'
        'cache-control: max-age=1800\r\n'
        'location: http://192.168.1.42:8200/rootDesc.xml\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        'USN: uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n',
      );
      expect(h['LOCATION'], 'http://192.168.1.42:8200/rootDesc.xml');
      expect(h['CACHE-CONTROL'], 'max-age=1800');
      expect(h['USN'], contains('uuid:abc-123'));
      expect(ssdpLocation(h), h['LOCATION']);
      expect(ssdpLocation(const <String, String>{}), isNull);
    });

    test('媒体服务器 / 网关被粗筛掉，renderer 与 ssdp:all 放行', () {
      expect(
        isRendererCandidate(const <String, String>{
          'ST': 'urn:schemas-upnp-org:device:MediaServer:1',
        }),
        isFalse,
      );
      expect(
        isRendererCandidate(const <String, String>{
          'ST': 'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
        }),
        isFalse,
      );
      expect(
        isRendererCandidate(const <String, String>{
          'ST': 'urn:schemas-upnp-org:device:MediaRenderer:1',
        }),
        isTrue,
      );
      expect(
        isRendererCandidate(const <String, String>{'ST': 'ssdp:all'}),
        isTrue,
      );
    });
  });

  group('XML 工具与转义', () {
    test('标签边界：serviceList 不被当成 service，URLBase 不被当成 url', () {
      expect(xmlBlocks(_desc, 'service').length, 3);
      expect(xmlBlocks(_desc, 'icon').length, 1);
      expect(
        xmlTagValue('<root><URLBase>http://x/</URLBase></root>', 'url'),
        '',
      );
    });

    test('命名空间前缀与实体解码', () {
      expect(
        xmlTagValue(
          '<upnp:friendlyName>A &amp; B</upnp:friendlyName>',
          'friendlyName',
        ),
        'A & B',
      );
      expect(xmlTagValue('<title>&#65;&#x42;</title>', 'title'), 'AB');
    });

    test('xmlEscape 顺序正确：&amp;lt; 不会被二次解码成 <', () {
      expect(xmlEscape('a&b<c>d"e\'f'), 'a&amp;b&lt;c&gt;d&quot;e&apos;f');
      expect(xmlUnescape(xmlEscape('&lt;')), '&lt;');
      expect(xmlUnescape('A &amp; B'), 'A & B');
    });
  });

  group('设备描述与 controlURL', () {
    test('三种 URL 形态都能拼成绝对地址', () {
      const loc = 'http://192.168.1.42:8200/rootDesc.xml';
      expect(
        resolveControlUrl(loc, '', 'http://10.0.0.9:1234/ctl'),
        'http://10.0.0.9:1234/ctl',
      );
      expect(
        resolveControlUrl(loc, '', '/AVTransport/ctrl'),
        'http://192.168.1.42:8200/AVTransport/ctrl',
      );
      expect(
        resolveControlUrl(loc, '', 'ctl/AVTransport'),
        'http://192.168.1.42:8200/ctl/AVTransport',
      );
      expect(
        resolveControlUrl(loc, 'http://192.168.1.42:9999/', 'rel/ctrl'),
        'http://192.168.1.42:9999/rel/ctrl',
      );
      expect(resolveControlUrl(loc, '', ''), '');
    });

    test('解析出 DMR 的 AVTransport / RenderingControl / 图标', () {
      final d = parseDeviceDescription(
        _desc,
        'http://192.168.1.42:8200/rootDesc.xml',
      );
      expect(d, isNotNull);
      expect(d!.title, '客厅 & 电视');
      expect(d.id, 'uuid:abc-123');
      expect(d.manufacturer, 'Sony');
      expect(d.modelName, 'BRAVIA 4K');
      expect(d.subtitle, 'Sony · BRAVIA 4K');
      expect(
        d.avTransportUrl,
        'http://192.168.1.42:8200/AVTransport/org_tv_ctrl',
      );
      expect(
        d.renderingControlUrl,
        'http://192.168.1.42:8200/RenderingControl/ctrl',
      );
      expect(d.iconUrl, 'http://192.168.1.42:8200/icons/48.png');
      expect(d.hasVolume, isTrue);
    });

    test('没有 AVTransport 的设备（媒体服务器 / 网关）必须被过滤', () {
      const xml =
          '<root><device><friendlyName>NAS</friendlyName>'
          '<serviceList><service>'
          '<serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>'
          '<controlURL>/cds/ctrl</controlURL>'
          '</service></serviceList></device></root>';
      expect(
        parseDeviceDescription(xml, 'http://192.168.1.9:5000/desc.xml'),
        isNull,
      );
    });

    test('serviceType 缺失时用 serviceId 兜底', () {
      const xml =
          '<root><device><friendlyName>盒子</friendlyName>'
          '<serviceList><service>'
          '<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>'
          '<controlURL>AVTransport/ctrl</controlURL>'
          '</service></serviceList></device></root>';
      final d = parseDeviceDescription(xml, 'http://192.168.1.8:8080/desc.xml');
      expect(d, isNotNull);
      expect(d!.avTransportUrl, 'http://192.168.1.8:8080/AVTransport/ctrl');
      expect(d.hasVolume, isFalse);
    });
  });

  group('SOAP 与 DIDL-Lite', () {
    test('SOAPACTION 头与 envelope 由同一 service/action 生成', () {
      final c = playCall();
      expect(
        c.actionHeader,
        '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
      );
      expect(
        c.envelope,
        contains(
          '<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">',
        ),
      );
      expect(c.envelope, contains('<Speed>1</Speed>'));
      expect(c.envelope, contains('<?xml version="1.0" encoding="utf-8"?>'));
    });

    test('Emby 流地址里的 & 与 metadata 整段都要转义一次', () {
      const url =
          'http://192.168.1.5:8096/emby/Videos/1/stream?Static=true&api_key=abc';
      final c = setAvTransportUriCall(url: url, metadata: '<DIDL-Lite/>');
      expect(c.envelope, contains('Static=true&amp;api_key=abc'));
      expect(c.envelope, isNot(contains('Static=true&api_key')));
      expect(c.envelope, contains('&lt;DIDL-Lite/&gt;'));
      expect(c.envelope, contains('<InstanceID>0</InstanceID>'));
    });

    test('DIDL-Lite 内部字段各自转义，时长走 UPnP 格式', () {
      final didl = buildDidlLite(
        id: 'm1',
        title: 'A & B',
        url: 'http://x/y?a=1&b=2',
        duration: const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(didl, contains('A &amp; B'));
      expect(didl, contains('a=1&amp;b=2'));
      expect(didl, contains('duration="01:02:03"'));
      expect(
        didl,
        contains(
          'protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0"',
        ),
      );
      expect(didl, contains('<upnp:class>object.item.videoItem</upnp:class>'));
    });

    test('其余 SOAP 动作参数完整', () {
      expect(
        seekCall(const Duration(minutes: 5)).envelope,
        contains('<Target>00:05:00</Target>'),
      );
      expect(
        seekCall(const Duration(minutes: 5)).envelope,
        contains('<Unit>REL_TIME</Unit>'),
      );
      expect(
        setVolumeCall(42).envelope,
        contains('<DesiredVolume>42</DesiredVolume>'),
      );
      expect(
        setVolumeCall(999).envelope,
        contains('<DesiredVolume>100</DesiredVolume>'),
      );
      expect(setVolumeCall(999).service, renderingControlService);
      expect(getPositionInfoCall().action, 'GetPositionInfo');
      expect(getTransportInfoCall().action, 'GetTransportInfo');
      expect(pauseCall().action, 'Pause');
      expect(stopCall().action, 'Stop');
    });
  });

  group('时长 / 状态 / 错误解析', () {
    test('UPnP 时长往返与坏数据降级', () {
      expect(
        formatUpnpDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '01:02:03',
      );
      expect(formatUpnpDuration(const Duration(seconds: 7)), '00:00:07');
      expect(formatUpnpDuration(const Duration(seconds: -5)), '00:00:00');
      expect(
        parseUpnpDuration('01:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(
        parseUpnpDuration('00:00:07.500'),
        const Duration(seconds: 7, milliseconds: 500),
      );
      expect(parseUpnpDuration('NOT:A:DURATION'), Duration.zero);
      expect(parseUpnpDuration(null), Duration.zero);
    });

    test('SOAP Fault 能读出设备给的原因', () {
      expect(
        soapFault(
          '<s:Fault><faultstring>Invalid Action</faultstring></s:Fault>',
        ),
        'Invalid Action',
      );
      expect(
        soapFault(
          '<UPnPError><errorDescription>712</errorDescription></UPnPError>',
        ),
        '712',
      );
      expect(soapFault('<s:Fault/>'), '设备返回错误');
      expect(soapFault('<s:Envelope><s:Body/></s:Envelope>'), isNull);
    });

    test('进度 / 传输状态 / 音量解析', () {
      const body =
          '<u:GetPositionInfoResponse>'
          '<TrackDuration>01:42:10</TrackDuration><RelTime>00:12:34</RelTime>'
          '</u:GetPositionInfoResponse>';
      final p = parsePositionInfo(body);
      expect(p.relTime, const Duration(minutes: 12, seconds: 34));
      expect(
        p.trackDuration,
        const Duration(hours: 1, minutes: 42, seconds: 10),
      );
      expect(
        parseTransportState(
          '<CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState>',
        ),
        'PAUSED_PLAYBACK',
      );
      expect(parseVolume('<CurrentVolume>37</CurrentVolume>'), 37);
      expect(parseVolume('<CurrentVolume>bad</CurrentVolume>'), isNull);
    });
  });

  group('投屏地址可达性', () {
    test('局域网 IP 可用，回环 / 非法地址必须告警', () {
      expect(
        isLanReachableUrl('http://192.168.1.5:8096/emby/Videos/1/stream'),
        isTrue,
      );
      expect(isLanReachableUrl('https://nas.local:8920/emby/x'), isTrue);
      expect(isLanReachableUrl('http://127.0.0.1:8096/emby/x'), isFalse);
      expect(isLanReachableUrl('http://localhost:8096/emby/x'), isFalse);
      expect(isLanReachableUrl('http://0.0.0.0:8096/emby/x'), isFalse);
      expect(isLanReachableUrl('not a url'), isFalse);
    });
  });

  group('控制器与状态常量', () {
    test('初始状态是 idle，且默认直连原片', () {
      final c = DlnaController();
      expect(c.phase, DlnaPhase.idle);
      expect(c.devices, isEmpty);
      expect(c.current, isNull);
      expect(c.isActive, isFalse);
      expect(c.compatibleMode, isFalse);
      c.dispose();
    });

    test('兼容模式切换会通知监听者', () {
      final c = DlnaController();
      var notified = 0;
      c.addListener(() => notified++);
      c.setCompatibleMode(true);
      expect(c.compatibleMode, isTrue);
      expect(notified, 1);
      c.setCompatibleMode(true);
      expect(notified, 1);
      c.dispose();
    });
  });

  group('源码守卫（真机难以复现的结构性错误）', () {
    test('Android 组播锁与权限都在，否则一台设备都搜不到', () {
      final kt = src(
        'android/app/src/main/kotlin/cn/camby/camby/MainActivity.kt',
      );
      expect(kt.contains('setMulticastLock'), isTrue);
      expect(kt.contains('createMulticastLock("camby.dlna")'), isTrue);
      expect(kt.contains('cn.camby.camby/network'), isTrue);
      // v2.0.83 的 HDR 诊断通道不能被这次改动误删
      expect(kt.contains('hdrCapabilities'), isTrue);
      final mf = src('android/app/src/main/AndroidManifest.xml');
      expect(mf.contains('CHANGE_WIFI_MULTICAST_STATE'), isTrue);
      expect(mf.contains('ACCESS_WIFI_STATE'), isTrue);
      expect(mf.contains('android.permission.INTERNET'), isTrue);
    });

    test('发现阶段必定获取并释放组播锁，且释放写在 finally', () {
      final c = src('lib/dlna/dlna_controller.dart');
      expect(c.contains('await MulticastLock.set(true)'), isTrue);
      expect(c.contains('await MulticastLock.set(false)'), isTrue);
      expect(
        c.indexOf('MulticastLock.set(false)'),
        greaterThan(c.indexOf('MulticastLock.set(true)')),
      );
      expect(c.contains('finally'), isTrue);
      expect(c.contains('_stopPoll()'), isTrue);
    });

    test('SSDP 不 joinMulticast（Android 不指定网卡会抛 SocketException）', () {
      final d = src('lib/dlna/dlna_discovery.dart');
      expect(d.contains('joinMulticast('), isFalse);
      expect(d.contains('RawDatagramSocket.bind'), isTrue);
      expect(d.contains('ssdpMulticastIp'), isTrue);
    });

    test('详情页两处投屏入口接了共享控制器，URL 带选中版本的 MediaSourceId', () {
      final p = src('lib/pages/detail_page.dart');
      expect(p.contains('DlnaController.shared'), isTrue);
      expect(p.contains('showCastingSheet('), isTrue);
      expect(p.contains('icon: Icons.cast_rounded'), isTrue);
      expect(p.contains('_CastSquareButton'), isTrue);
      expect(p.contains('mediaSourceId: msId'), isTrue);
      expect(p.contains('v.id'), isTrue);
      expect(p.contains('ListenableBuilder'), isTrue);
    });

    test('投屏面板复用 Glass 抽屉，动作文字统一蓝字', () {
      final s = src('lib/dlna/dlna_sheet.dart');
      expect(s.contains('showModalBottomSheet<void>'), isTrue);
      expect(s.contains('Glass('), isTrue);
      expect(s.contains('color: AppColors.accent'), isTrue);
      expect(s.contains('AppColors.cyan'), isFalse);
      expect(s.contains('setState('), isFalse);
    });

    test('版本号与协议层 UA 已同步到 87，且三处共用同一常量', () {
      expect(src('pubspec.yaml').contains('version: 2.0.97+297'), isTrue);
      final proto = src('lib/dlna/dlna_protocol.dart');
      expect(proto.contains("dlnaUserAgent = 'Camby/2.0.97"), isTrue);
      expect(proto.contains(r'USER-AGENT: $dlnaUserAgent'), isTrue);
      for (final f in <String>[
        'lib/dlna/dlna_discovery.dart',
        'lib/dlna/dlna_controller.dart',
      ]) {
        final s = src(f);
        expect(s.contains("'USER-AGENT': dlnaUserAgent"), isTrue, reason: f);
        expect(s.contains('Camby/2.0.'), isFalse, reason: f);
      }
    });
  });
}
