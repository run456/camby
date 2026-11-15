import 'dart:io';

import 'package:camby/dlna/dlna_controller.dart';
import 'package:camby/dlna/dlna_protocol.dart';
import 'package:camby/emby_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.85：DLNA 投屏字幕的回归守卫。
///
/// 这里最要紧的两件事：① 不带字幕时 DIDL-Lite 必须与 v2.0.84 逐字节一致
/// （不能给已经能投屏的电视换 metadata）；② 字幕 URL 里的 `&` 要转义两次
/// —— 字段内一次、整段 metadata 作为 SOAP 参数再一次，漏一层电视就静默失败。
String src(String path) => File(path).readAsStringSync();

const String _video =
    'http://192.168.1.9:8096/emby/Videos/42/stream?Static=true&api_key=tok';
const String _sub =
    'http://192.168.1.9:8096/emby/Videos/42/42/Subtitles/2/'
    '0/Stream.srt?api_key=tok&X-Emby-Token=abc';

void main() {
  group('DIDL-Lite · 外挂字幕', () {
    test('不带字幕时输出与 v2.0.84 逐字节一致', () {
      final xml = buildDidlLite(id: '42', title: '电影', url: _video);
      const expected =
          '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" '
          'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
          '<item id="42" parentID="-1" restricted="1">'
          '<dc:title>电影</dc:title>'
          '<upnp:class>object.item.videoItem</upnp:class>'
          '<res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0">'
          'http://192.168.1.9:8096/emby/Videos/42/stream?Static=true&amp;api_key=tok'
          '</res></item></DIDL-Lite>';
      expect(xml, expected);
      expect(xml.contains('sec:'), isFalse);
      expect(xml.contains('pv:'), isFalse);
      expect(xml.contains('CaptionInfo'), isFalse);
    });

    test('空字符串字幕 URL 等同于不带字幕', () {
      expect(
        buildDidlLite(id: '42', title: '电影', url: _video, subtitleUrl: ''),
        buildDidlLite(id: '42', title: '电影', url: _video),
      );
    });

    test('三星 + LG/松下系字段一次全塞，命名空间齐全', () {
      final xml = buildDidlLite(
        id: '42',
        title: '电影',
        url: _video,
        subtitleUrl: _sub,
      );
      // 三星系
      expect(xml.contains('<sec:CaptionInfoEx sec:type="srt">'), isTrue);
      expect(xml.contains('<sec:CaptionInfo sec:type="srt">'), isTrue);
      expect(xml.contains('</sec:CaptionInfoEx>'), isTrue);
      // LG / 松下 / 部分安卓电视
      expect(xml.contains('pv:subtitleFileUri="'), isTrue);
      expect(xml.contains('pv:subtitleFileType="srt"'), isTrue);
      expect(
        xml.contains(
          '<res protocolInfo="http-get:*:text/srt:'
          'DLNA.ORG_OP=01;DLNA.ORG_CI=0"',
        ),
        isTrue,
      );
      // 三个私有命名空间必须声明，否则严格解析器会判 metadata 非法
      expect(xml.contains('xmlns:sec="http://www.sec.co.kr/"'), isTrue);
      expect(xml.contains('xmlns:pv="http://www.pv.com/pvns/"'), isTrue);
      expect(
        xml.contains('xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/"'),
        isTrue,
      );
      // 主视频 res 仍在，且只有一个 video/mp4
      expect(xml.contains('http-get:*:video/mp4:'), isTrue);
      expect('video/mp4'.allMatches(xml).length, 1);
    });

    test('字幕 URL 与视频 URL 的 & 都在字段级转义', () {
      final xml = buildDidlLite(
        id: '42',
        title: 'A & B',
        url: _video,
        subtitleUrl: _sub,
      );
      expect(xml.contains('&amp;api_key=tok'), isTrue);
      // 字幕 URL 共 4 处：CaptionInfoEx 文本、CaptionInfo 文本、
      // 第二个 res 的 pv:subtitleFileUri 属性、以及该 res 的文本内容。
      expect('&amp;X-Emby-Token=abc'.allMatches(xml).length, 4);
      expect(xml.contains('Stream.srt?api_key=tok&X-Emby-Token'), isFalse);
      expect(xml.contains('<dc:title>A &amp; B</dc:title>'), isTrue);
      expect(xml.contains('&amp;amp;'), isFalse, reason: '字段级只转义一次');
    });

    test('整段 metadata 进 SOAP 参数时再转义一次（双层）', () {
      final xml = buildDidlLite(
        id: '42',
        title: '电影',
        url: _video,
        subtitleUrl: _sub,
      );
      final envelope = setAvTransportUriCall(
        url: _video,
        metadata: xml,
      ).envelope;
      expect(envelope.contains('&amp;amp;'), isTrue);
      expect(envelope.contains('&lt;sec:CaptionInfoEx'), isTrue);
      expect(envelope.contains('<u:SetAVTransportURI'), isTrue);
      expect(
        envelope.contains('SOAPACTION'),
        isFalse,
        reason: 'SOAPACTION 在 HTTP header 里，不在 envelope',
      );
    });

    test('subtitleType 可覆盖，且做 XML 转义', () {
      final xml = buildDidlLite(
        id: '1',
        title: 't',
        url: _video,
        subtitleUrl: _sub,
        subtitleType: 'vtt',
      );
      expect(xml.contains('sec:type="vtt"'), isTrue);
      expect(xml.contains('http-get:*:text/vtt:'), isTrue);
      expect(xml.contains('pv:subtitleFileType="vtt"'), isTrue);
    });
  });

  group('Emby · 字幕烧录 URL', () {
    test('必须同时带 SubtitleStreamIndex 与 SubtitleMethod=Encode', () {
      final u = buildBurnSubtitleUrl(
        baseUrl: 'http://192.168.1.9:8096/emby',
        itemId: '42',
        apiKey: 'tok',
        subtitleStreamIndex: 3,
        playSessionId: 'ps-1',
        mediaSourceId: 'src-9',
      );
      final uri = Uri.parse(u);
      expect(uri.path, '/emby/Videos/42/master.m3u8');
      expect(uri.queryParameters['SubtitleStreamIndex'], '3');
      expect(uri.queryParameters['SubtitleMethod'], 'Encode');
      expect(uri.queryParameters['MediaSourceId'], 'src-9');
      expect(uri.queryParameters['PlaySessionId'], 'ps-1');
      expect(uri.queryParameters['api_key'], 'tok');
    });

    test('无 mediaSourceId 时不带该参数；特殊字符正确百分号转义', () {
      final u = buildBurnSubtitleUrl(
        baseUrl: 'http://192.168.1.9:8096/emby',
        itemId: '42',
        apiKey: 'a b&c',
        subtitleStreamIndex: 2,
        playSessionId: 'ps/1',
      );
      final uri = Uri.parse(u);
      expect(uri.queryParameters.containsKey('MediaSourceId'), isFalse);
      expect(uri.queryParameters['api_key'], 'a b&c');
      expect(uri.queryParameters['PlaySessionId'], 'ps/1');
      expect(
        u.contains('api_key=a+b%26c') || u.contains('api_key=a%20b%26c'),
        isTrue,
        reason: '& 必须百分号转义，不能裸奔进 query',
      );
    });

    test('烧录地址不是 Static 直连，也不能带外挂字幕字段', () {
      final u = buildBurnSubtitleUrl(
        baseUrl: 'http://192.168.1.9:8096/emby',
        itemId: '42',
        apiKey: 'tok',
        subtitleStreamIndex: 2,
        playSessionId: 'ps-1',
      );
      expect(u.contains('Static=true'), isFalse);
      expect(u.contains('master.m3u8'), isTrue);
    });
  });

  group('控制器 · 字幕选择语义', () {
    const a = CastSubtitle(label: '中文 · SRT', url: _sub, streamIndex: 2);
    const b = CastSubtitle(label: 'English · ASS', url: _sub, streamIndex: 3);
    const graphic = CastSubtitle(
      label: '中文 · PGS',
      url: _sub,
      streamIndex: 4,
      isTextFriendly: false,
    );

    DlnaController fresh() => DlnaController();

    test('默认选第一条；preferredIndex 优先', () {
      final c = fresh();
      c.configureSubtitles(available: const <CastSubtitle>[a, b], scope: 'm1');
      expect(c.effectiveSubtitle?.streamIndex, 2);
      expect(c.isSubtitleSelected(a), isTrue);
      expect(c.isSubtitleSelected(b), isFalse);
      expect(c.isSubtitleSelected(null), isFalse);

      final d = fresh();
      d.configureSubtitles(
        available: const <CastSubtitle>[a, b],
        preferredIndex: 3,
        scope: 'm1',
      );
      expect(d.effectiveSubtitle?.streamIndex, 3);
    });

    test('没有字幕轨时 effectiveSubtitle 为 null', () {
      final c = fresh();
      c.configureSubtitles(available: const <CastSubtitle>[], scope: 'empty');
      expect(c.subtitles, isEmpty);
      expect(c.effectiveSubtitle, isNull);
    });

    test('换片源（scope 变化）必须重置，不能按重复的 index 串轨', () {
      final c = fresh();
      c.configureSubtitles(available: const <CastSubtitle>[a, b], scope: 'm1');
      c.selectSubtitle(b);
      expect(c.effectiveSubtitle?.streamIndex, 3);

      // 第二部片也有 index=3 的字幕，但用户没选过它 → 应回到默认第一条
      c.configureSubtitles(available: const <CastSubtitle>[a, b], scope: 'm2');
      expect(c.effectiveSubtitle?.streamIndex, 2);

      // 同一片重复打开面板 → 保留用户选择
      c.selectSubtitle(b);
      c.configureSubtitles(available: const <CastSubtitle>[a, b], scope: 'm2');
      expect(c.effectiveSubtitle?.streamIndex, 3);
    });

    test('「不带字幕」chip 关掉发送，再选轨会自动恢复', () {
      final c = fresh();
      c.configureSubtitles(available: const <CastSubtitle>[a, b], scope: 'm1');
      c.selectSubtitle(null);
      expect(c.sendSubtitle, isFalse);
      expect(c.effectiveSubtitle, isNull);
      expect(c.isSubtitleSelected(null), isTrue);
      expect(c.isSubtitleSelected(a), isFalse);

      c.selectSubtitle(b);
      expect(c.sendSubtitle, isTrue);
      expect(c.effectiveSubtitle?.streamIndex, 3);
      expect(c.isSubtitleSelected(null), isFalse);
    });

    test('setSendSubtitle / setBurnSubtitle 会通知监听器且不重复通知', () {
      final c = fresh();
      var n = 0;
      c.addListener(() => n++);
      c.setSendSubtitle(false);
      expect(n, 1);
      c.setSendSubtitle(false);
      expect(n, 1);
      c.setBurnSubtitle(true);
      expect(n, 2);
      c.setBurnSubtitle(true);
      expect(n, 2);
      c.dispose();
    });

    test('图形字幕带 isTextFriendly=false，普通轨为 true', () {
      expect(graphic.isTextFriendly, isFalse);
      expect(a.isTextFriendly, isTrue);
    });

    test('CastRequest 字幕字段按调用方透传', () {
      const r = CastRequest(
        url: _video,
        title: '电影',
        subtitleUrl: _sub,
        subtitleLabel: '中文 · SRT',
      );
      expect(r.subtitleUrl, _sub);
      expect(r.subtitleLabel, '中文 · SRT');
      const burn = CastRequest(url: _video, title: '电影');
      expect(burn.subtitleUrl, isNull);
      expect(burn.subtitleLabel, isNull);
    });

    test('v2.0.100：绿联（无转码）两个开关失活，MIME 保持在原片直投', () {
      // 用户把两个开关都打开也不行 —— 服务器没有 HLS 转码能力
      final t = resolveCastTranscode(
        available: false,
        compatibleMode: true,
        burnSubtitle: true,
        hasSubtitle: true,
      );
      expect(t.compatible, isFalse);
      expect(t.burn, isFalse);
      expect(
        castMimeType(compatible: t.compatible, burn: t.burn),
        'video/mp4',
      );

      // 标准 Emby：开关照常生效，走 HLS
      final std = resolveCastTranscode(
        available: true,
        compatibleMode: true,
        burnSubtitle: true,
        hasSubtitle: true,
      );
      expect(std.compatible, isTrue);
      expect(std.burn, isTrue);
      expect(
        castMimeType(compatible: std.compatible, burn: std.burn),
        'application/vnd.apple.mpegurl',
      );

      // 没有选中字幕时，烧录不该被打开
      expect(
        resolveCastTranscode(
          available: true,
          compatibleMode: false,
          burnSubtitle: true,
          hasSubtitle: false,
        ).burn,
        isFalse,
      );
    });
  });

  group('源码守卫', () {
    test('协议层同时写全三星与 LG/松下系字段', () {
      final s = src('lib/dlna/dlna_protocol.dart');
      expect(s.contains('sec:CaptionInfoEx'), isTrue);
      expect(s.contains('sec:CaptionInfo'), isTrue);
      expect(s.contains('pv:subtitleFileUri'), isTrue);
      expect(s.contains('subtitleUrl: request.subtitleUrl'), isFalse);
      expect(s.contains("'USER-AGENT': dlnaUserAgent"), isFalse);
      expect(s.contains('final ns = sub.isEmpty'), isTrue,
          reason: '无字幕时必须退回 v2.0.84 的根节点');
    });

    test('控制器把字幕 URL 传进 SetAVTransportURI 的 metadata', () {
      final s = src('lib/dlna/dlna_controller.dart');
      expect(s.contains('subtitleUrl: request.subtitleUrl'), isTrue);
      expect(s.contains('scope == _subtitleScope'), isTrue);
      expect(s.contains("'USER-AGENT': dlnaUserAgent"), isTrue);
      expect(s.contains('Camby/2.0.'), isFalse);
    });

    test('Emby 烧录 URL 显式带 Encode，且实例方法已接入', () {
      final s = src('lib/emby_client.dart');
      expect(s.contains("'SubtitleMethod': 'Encode'"), isTrue);
      expect(s.contains("'SubtitleStreamIndex'"), isTrue);
      expect(s.contains('String burnSubtitleUrl('), isTrue);
      expect(s.contains('buildBurnSubtitleUrl('), isTrue);
      expect(s.contains('Future<Uint8List?> fetchSubtitleBytes('), isTrue);
      expect(s.contains('sameOrigin(url, rootUrl)'), isTrue);
    });

    test('详情页拼装候选并用默认轨兜底', () {
      final s = src('lib/pages/detail_page.dart');
      expect(
        s.contains('Future<List<CastSubtitle>> _castSubtitles()'),
        isTrue,
      );
      expect(s.contains('s.textCandidates'), isTrue);
      expect(s.contains('isTextFriendly: !graphic'), isTrue);
      expect(s.contains('srv.burnSubtitleUrl('), isTrue);
      expect(s.contains('_defaultSubtitle(_item)?.index'), isTrue);
      expect(s.contains('subtitles: subtitles'), isTrue);
      expect(s.contains('preferredSubtitleIndex: preferred'), isTrue);
      // v2.0.100：字幕走本机代理，绿联禁用两个必然失败的转码开关
      expect(s.contains('srv.fetchSubtitleBytes('), isTrue);
      expect(s.contains('CastSubtitleProxy.instance.publish(bytes)'), isTrue);
      expect(s.contains('transcodeAvailable: !widget.state.isUgreenServer'), isTrue);
    });

    test('面板：烧录时不外挂、改动自动重投、字幕区与 scope 注入', () {
      final s = src('lib/dlna/dlna_sheet.dart');
      expect(s.contains('subtitleUrl: burn ? null : sub?.url'), isTrue);
      expect(s.contains('_recastIfActive(c)'), isTrue);
      expect(s.contains("scope: widget.itemId"), isTrue);
      expect(s.contains("'不带字幕'"), isTrue);
      expect(s.contains('字幕烧录（服务端转码）'), isTrue);
      expect(s.contains('isTextFriendly'), isTrue);
      expect(s.contains('hasSubtitle: sub != null'), isTrue);
      expect(s.contains('widget.buildUrl(c.compatibleMode)'), isFalse);
      // MIME 常量已抽到控制器，由纯函数按实际生效维度决定
      expect(
        src('lib/dlna/dlna_controller.dart')
            .contains("'application/vnd.apple.mpegurl'"),
        isTrue,
      );
      // v2.0.100：服务器不支持转码时两个开关失活，且不再把 HLS MIME
      // 套在直连原片上
      expect(s.contains('final canTranscode = widget.transcodeAvailable;'), isTrue);
      expect(s.contains('resolveCastTranscode('), isTrue);
      expect(s.contains('castMimeType(compatible: compatible, burn: burn)'), isTrue);
      expect(s.contains('onChanged: canTranscode ? _onCompatibleChanged : null'), isTrue);
    });

    test('版本与文档同步到 v2.0.105', () {
      expect(src('pubspec.yaml').contains('version: 2.0.105+305'), isTrue);
      expect(src('README.md').contains('v2.0.105 (305)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.105 (305)'), isTrue);
      expect(src('VERIFICATION.md').contains('§99'), isTrue);
      expect(src('VERIFICATION.md').contains('§110'), isTrue);
      expect(
        src('lib/dlna/dlna_protocol.dart').contains("'Camby/2.0.105 "),
        isTrue,
      );
    });
  });
}
