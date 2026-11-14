/// 服务器地址解析与「非标准 Emby 源」识别（v2.0.87）。
///
/// 绿联 NAS（UGOS Pro）影视中心对外是 Emby 兼容接口，但有三条与标准 Emby
/// 不同的硬约束，社区帖子（club.ugnas.com tid=6281 / tid=6256）已实测：
///   1. 只开 HTTPS、固定 9443 端口，自签证书，HTTP / 8096 一律不通；
///   2. 不广播 Emby 发现包，只能手动填地址（Camby 本来就没有 Emby 自动发现）；
///   3. `/Sessions/*` 与进度上报在多数 UGOS Pro 版本不生效。
///
/// 这里只放**纯函数**：不碰网络、不碰 UI，方便 `flutter test` 直接验证粘贴
/// `https://nasip:9443` 这种完整地址时的拆分结果。

/// 从一段原始输入里拆出的服务器三元组。
class ServerAddress {
  const ServerAddress({
    required this.host,
    required this.port,
    required this.secure,
  });

  /// 纯主机名 / IP，不含协议、端口、路径。IPv6 保留方括号。
  final String host;

  /// 1..65535；解析不出来时用调用方给的兜底端口。
  final int port;

  /// 是否 HTTPS。
  final bool secure;

  String get origin => '${secure ? 'https' : 'http'}://$host:$port';

  @override
  String toString() => origin;
}

/// 解析用户粘贴的地址。
///
/// 支持这几种写法（都返回干净的 host / port / secure）：
/// ```text
/// 192.168.1.24
/// 192.168.1.24:9443
/// https://192.168.1.24:9443
/// https://nas.local:9443/emby/
/// http://[::1]:8096
/// ```
///
/// [fallbackPort] / [fallbackSecure] 用于输入里没写协议或端口时；
/// [portOverride] / [secureOverride] 优先级最高，供表单里独立的
/// 「端口」「协议」控件覆盖（用户手动改过就不该被粘贴内容再改回去，
/// 调用方决定是否传）。
ServerAddress parseServerAddress(
  String raw, {
  int fallbackPort = 8096,
  bool fallbackSecure = false,
  int? portOverride,
  bool? secureOverride,
}) {
  var s = raw.trim();
  var secure = fallbackSecure;

  // 1) 剥协议
  final schemeAt = s.indexOf('://');
  if (schemeAt >= 0) {
    final scheme = s.substring(0, schemeAt).toLowerCase();
    if (scheme == 'https') secure = true;
    if (scheme == 'http') secure = false;
    s = s.substring(schemeAt + 3);
  }

  // 2) 剥路径 / 查询 / 片段
  for (final sep in ['/', '?', '#']) {
    final i = s.indexOf(sep);
    if (i >= 0) s = s.substring(0, i);
  }
  s = s.trim();

  // 3) 剥端口。IPv6 的 `[::1]:8096` 要先判方括号，别把里面的冒号当端口分隔。
  var port = fallbackPort;
  String host = s;
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close >= 0) {
      host = s.substring(0, close + 1);
      final rest = s.substring(close + 1);
      if (rest.startsWith(':')) {
        final p = int.tryParse(rest.substring(1));
        if (p != null && p > 0 && p <= 65535) port = p;
      }
    }
  } else {
    final colon = s.lastIndexOf(':');
    // 裸 IPv6（`fe80::1`）里有多个冒号，不能当 host:port 拆
    final colonCount = ':'.allMatches(s).length;
    if (colon > 0 && colonCount == 1) {
      // 只要是 host:port 形态就先把端口从 host 里剥掉；端口非法时用兜底值，
      // 别把 `ip:99999` 整串留进 host，否则又会拼出 `ip:99999:8096`。
      host = s.substring(0, colon);
      final p = int.tryParse(s.substring(colon + 1));
      if (p != null && p > 0 && p <= 65535) port = p;
    }
  }

  // 4) 去掉用户名前缀与尾随点（user@host、host.）
  final at = host.lastIndexOf('@');
  if (at >= 0) host = host.substring(at + 1);
  host = host.trim().replaceAll(RegExp(r'\.$'), '');

  return ServerAddress(
    host: host,
    port: portOverride ?? port,
    secure: secureOverride ?? secure,
  );
}

/// 是否「绿联影视中心兼容源」。
///
/// 判据刻意保守：只有 **HTTPS + 9443** 同时成立才认。9443 是 UGOS Pro 影视中心
/// 的固定对外端口，标准 Emby / Jellyfin 默认 8096 / 8920 / 443，不会误伤。
/// 判成兼容源后 App 会关掉会话型进度上报并给出说明，见
/// `AppState.progressSyncSupported`。
bool isUgreenCompatSource({required int port, required bool secure}) =>
    secure && port == 9443;

/// 绿联兼容源不支持的能力说明（设置页 / 连接成功提示共用一份文案）。
const String kUgreenProgressHint =
    '当前服务器不支持进度同步：绿联影视中心未开放会话与进度接口，'
    '观看记录仅保存在本机的观影日历中。';

/// 只建议对局域网地址关闭证书校验。公网 / 域名穿透场景要显式提醒中间人风险。
bool isLanHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;
  if (h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.internal')) {
    return true;
  }
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
      .firstMatch(h);
  if (m == null) return false;
  final a = int.tryParse(m.group(1)!);
  final b = int.tryParse(m.group(2)!);
  if (a == null || b == null) return false;
  return a == 10 ||
      (a == 192 && b == 168) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 169 && b == 254);
}
