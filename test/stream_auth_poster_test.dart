import 'dart:io';

import 'package:camby/ugreen_resource.dart';
import 'package:camby/watch_history.dart';
import 'package:camby/widgets/cached_image.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.0.101：三处回归守卫
/// ① 播放信息的「取流鉴权」必须按本次实际取流地址判定；
/// ② 海报墙不能再把海报压成 120px，且角标要算「本月这部片的总时长」；
/// ③ 投屏两个转码开关必须有通用 HLS 风险提示，默认仍关闭。
String src(String path) => File(path).readAsStringSync();

void main() {
  group('播放信息 · 取流鉴权文案', () {
    test('标准 Emby（含 strm 条目）：第一跳同源，必须显示已注入', () {
      expect(
        describeStreamAuth(
          connected: true,
          hasUrl: true,
          sameOrigin: true,
          hasToken: true,
        ),
        'X-Emby-Token 已注入',
      );
    });

    test('探测/回退到第三方直链：不注入，且不再谎报已注入', () {
      expect(
        describeStreamAuth(
          connected: true,
          hasUrl: true,
          sameOrigin: false,
          hasToken: true,
        ),
        '外部直链 · 不注入令牌',
      );
    });

    test('同源但服务器没配令牌', () {
      expect(
        describeStreamAuth(
          connected: true,
          hasUrl: true,
          sameOrigin: true,
          hasToken: false,
        ),
        '未注入（服务器未配置令牌）',
      );
    });

    test('未连接 / 尚未取流优先于其它判定', () {
      expect(
        describeStreamAuth(
          connected: false,
          hasUrl: true,
          sameOrigin: true,
          hasToken: true,
        ),
        '未连接服务器',
      );
      expect(
        describeStreamAuth(
          connected: true,
          hasUrl: false,
          sameOrigin: false,
          hasToken: true,
        ),
        '尚未取流',
      );
    });
  });

  group('海报墙 · 时长聚合与文案', () {
    test('同一部片本月多次观看累加，且不被「只取 6 张」截断', () {
      final events = <WatchEvent>[
        for (var i = 1; i <= 8; i++)
          WatchEvent(
            itemId: 'm$i',
            name: '片$i',
            date: '2026-11-0$i',
            minutes: 30,
          ),
        // 第 9 条才是 m1 的第二次观看：旧写法取满 6 张就 break 会漏掉它
        const WatchEvent(
          itemId: 'm1',
          name: '片1',
          date: '2026-11-20',
          minutes: 72,
        ),
      ];
      final r = aggregateMonthWatchMinutes(events, '2026-11-');
      expect(r.minutes['m1'], 102);
      expect(r.minutes['m8'], 30);
      expect(formatWatchMinutes(r.minutes['m1']!), '1 小时 42 分');
    });

    test('跨月事件不计入；混入估算时整片标估算', () {
      final r = aggregateMonthWatchMinutes(const [
        WatchEvent(itemId: 'a', name: 'A', date: '2026-11-02', minutes: 40),
        WatchEvent(
          itemId: 'a',
          name: 'A',
          date: '2026-11-08',
          minutes: 20,
          source: WatchSource.imported,
        ),
        WatchEvent(itemId: 'b', name: 'B', date: '2026-10-31', minutes: 300),
      ], '2026-11-');
      expect(r.minutes['a'], 60);
      expect(r.minutes.containsKey('b'), isFalse);
      expect(r.estimated['a'], isTrue);
      expect(formatWatchMinutes(60, estimated: true), '~1 小时');
    });

    test('formatWatchMinutes 边界：0 / 负 / NaN 不显示假时长', () {
      expect(formatWatchMinutes(0), '');
      expect(formatWatchMinutes(-5), '');
      expect(formatWatchMinutes(double.nan), '');
      expect(formatWatchMinutes(42), '42 分钟');
      expect(formatWatchMinutes(120), '2 小时');
      expect(formatWatchMinutes(59.4), '59 分钟');
      // 四舍五入跨过 60 分界后按整点显示，不写「60 分钟」
      expect(formatWatchMinutes(59.6), '1 小时');
    });
  });

  group('海报墙 · 图片地址宽度', () {
    const url =
        'https://nas:8920/emby/Items/42/Images/Primary?maxWidth=400&tag=abc&api_key=tok';

    test('替换 maxWidth 并保留 tag / api_key', () {
      final out = posterUrlAtWidth(url, 800)!;
      final q = Uri.parse(out).queryParameters;
      expect(q['maxWidth'], '800');
      expect(q['tag'], 'abc');
      expect(q['api_key'], 'tok');
    });

    test('换宽度会换 cacheKey，不会被列表里的 120px 小图污染', () {
      final big = posterUrlAtWidth(url, 800)!;
      expect(imageCacheKey(big), isNot(imageCacheKey(url)));
    });

    test('原本没有 maxWidth 的第三方图不改写一个对方不认的参数', () {
      const cdn = 'https://cdn.example.com/p.jpg';
      expect(posterUrlAtWidth(cdn, 800), cdn);
    });

    test('null / 空 / 非法地址原样返回', () {
      expect(posterUrlAtWidth(null, 800), isNull);
      expect(posterUrlAtWidth('', 800), '');
      expect(posterUrlAtWidth('not a url', 800), 'not a url');
    });
  });

  group('源码守卫', () {
    test('播放信息按实际取流地址判定，不再只看服务器配置', () {
      final s = src('lib/pages/player_page.dart');
      expect(s.contains('_streamAuthLabel()'), isTrue);
      expect(s.contains('describeStreamAuth('), isTrue);
      expect(s.contains('sameOrigin(url, srv.rootUrl)'), isTrue);
      expect(
        s.contains('widget.state.server?.streamHeaders.isNotEmpty ?? false'),
        isFalse,
      );
    });

    test('海报墙用大图缓存 + 时长角标 + 全月聚合', () {
      final s = src('lib/pages/watch_calendar_page.dart');
      // v2.0.102：memWidth 会同时压 memCacheWidth 与 maxWidthDiskCache，
      // 给 480 等于把大图二次降采样编码。改成 1200 解码 + 磁盘豁免。
      expect(s.contains('posterUrlAtWidth(e.posterUrl, 1200)'), isTrue);
      expect(s.contains('FilterQuality.high'), isTrue);
      expect(s.contains('memWidth: 1200'), isTrue);
      expect(s.contains('fullResDiskCache: true'), isTrue);
      expect(s.contains('memWidth: 480'), isFalse);
      // 注意子串陷阱：'memWidth: 120' 会被 'memWidth: 1200' 命中，
      // 必须带上逗号才是「旧的 120px 降采样」这一行。
      expect(s.contains('memWidth: 120,'), isFalse);
      expect(s.contains('aggregateMonthWatchMinutes(events, prefix)'), isTrue);
      expect(s.contains('durationLabel'), isTrue);
      // 角标无条件出现：0 分钟的记录显示「时长未记」，别让角标整片消失
      expect(
        s.contains("durationLabel.isEmpty ? '时长未记' : durationLabel"),
        isTrue,
      );
      expect(s.contains('toImage(pixelRatio: 3.0)'), isTrue);
    });

    test('投屏两个开关有通用 HLS 风险提示，默认仍关闭', () {
      final sheet = src('lib/dlna/dlna_sheet.dart');
      expect(sheet.contains('多数电视的 DLNA '), isTrue);
      expect(sheet.contains('if (widget.transcodeAvailable) ...['), isTrue);
      expect(sheet.contains('会一直缓冲'), isTrue);
      final ctrl = src('lib/dlna/dlna_controller.dart');
      expect(ctrl.contains('bool compatibleMode = false;'), isTrue);
      expect(ctrl.contains('bool burnSubtitle = false;'), isTrue);
    });

    test('版本与验证文档同步到 v2.0.102', () {
      expect(src('pubspec.yaml').contains('version: 2.0.102+302'), isTrue);
      expect(src('README.md').contains('v2.0.102 (302)'), isTrue);
      expect(src('CHANGELOG.md').contains('v2.0.102 (302)'), isTrue);
      expect(src('VERIFICATION.md').contains('§112'), isTrue);
    });
  });
}
