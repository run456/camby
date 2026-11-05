import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Lara Translate 官方 REST 客户端。
///
/// 协议严格对齐官方 SDK（`@translated/lara` v1.18.2，自 `lib/net/lara/client.js`
/// 移植）：base `https://api.laratranslate.com`，鉴权为 **Access Key 签名换 JWT**，
/// 而非简单的 API Key header。翻译走 `POST /v2/translate`，请求体含 `q` / `source`
/// （省略则自动检测）/ `target` / `style` / `instructions` 等，响应含 `translation`
/// 与 `source_language`。
///
/// 鉴权流程：
/// 1. `POST /v2/auth`，body `{"id": <accessKeyId>}`；请求头带 `X-Lara-Date`
///    （RFC1123 / GMT）、`Content-MD5`（body 的 MD5 经 Base64）、`Authorization:
///    Lara:<签名>`；签名为 `HMAC-SHA256(secret, "METHOD\nPATH\nCONTENT-MD5\n
///    CONTENT-TYPE\nDATE")` 的 Base64。
/// 2. 响应 `token` 即 Bearer；刷新令牌在响应头 `x-lara-refresh-token`。
/// 3. 后续请求 `Authorization: Bearer <token>`；token 过期（JWT `exp` 或 401）
///    用 `POST /v2/auth/refresh` + refresh token 续期。
class LaraClient {
  LaraClient(this.credentials, {this.baseUrl = 'https://api.laratranslate.com'});

  final LaraCredentials credentials;
  final String baseUrl;

  String? _token;
  String? _refreshToken;
  DateTime? _expiry;

  /// 翻译风格（对齐官方 SDK 的 `style` 取值）。
  static const Map<LaraStyle, String> styleParam = {
    LaraStyle.faithful: 'faithful',
    LaraStyle.fluid: 'fluid',
    LaraStyle.creative: 'creative',
  };

  static const Map<LaraStyle, String> styleLabel = {
    LaraStyle.faithful: '忠实',
    LaraStyle.fluid: '流畅',
    LaraStyle.creative: '创意',
  };

  /// 确保持有有效 token：本地有未过期 token 直接复用；否则用 refresh token 续期，
  /// 再不行就用 access key 重新签名登录。三者都失败才抛错。
  Future<String> _ensureToken() async {
    if (_token != null && !_isExpired(_token!, _expiry)) return _token!;
    _token = null;
    if (_refreshToken != null) {
      try {
        await _refresh();
        if (_token != null) return _token!;
      } on LaraApiError {
        _refreshToken = null;
      }
    }
    await _login();
    if (_token == null) {
      throw const LaraAuthError('无法获取 Lara 访问令牌，请检查 Access Key');
    }
    return _token!;
  }

  bool _isExpired(String token, DateTime? expiry) {
    if (expiry != null) {
      return expiry.difference(DateTime.now()).inMilliseconds <= 5000;
    }
    // 兜底：解析 JWT 中段拿 exp（秒）
    final parts = token.split('.');
    if (parts.length != 3) return true;
    var b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    while (b64.length % 4 != 0) b64 += '=';
    try {
      final json = utf8.decode(base64.decode(b64));
      final exp = (jsonDecode(json)['exp'] as int?) ?? 0;
      return exp * 1000 <= DateTime.now().millisecondsSinceEpoch + 5000;
    } catch (_) {
      return true;
    }
  }

  Future<void> _login() async {
    final body = jsonEncode({'id': credentials.id});
    final contentMd5 = _md5Base64(body);
    final date = HttpDate.format(DateTime.now().toUtc());
    final challenge =
        'POST\n/v2/auth\n$contentMd5\napplication/json\n$date';
    final sig = _hmacBase64(credentials.secret, challenge);
    final res = await http.post(
      Uri.parse('$baseUrl/v2/auth'),
      headers: {
        'Content-Type': 'application/json',
        'X-Lara-Date': date,
        'Content-MD5': contentMd5,
        'Authorization': 'Lara:$sig',
      },
      body: body,
    );
    _handleAuth(res);
  }

  Future<void> _refresh() async {
    final date = HttpDate.format(DateTime.now().toUtc());
    final res = await http.post(
      Uri.parse('$baseUrl/v2/auth/refresh'),
      headers: {
        'Authorization': 'Bearer $_refreshToken',
        'X-Lara-Date': date,
      },
    );
    _handleAuth(res);
  }

  void _handleAuth(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw LaraApiError(res.statusCode, _errMessage(res));
    }
    final body = _decodeJson(res.body);
    final token = body['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const LaraAuthError('Lara 鉴权响应缺少 token');
    }
    _token = token;
    _refreshToken = res.headers['x-lara-refresh-token'];
    // 从 JWT 解析 exp 做本地过期判断（可选，失败则靠 401 兜底刷新）
    final parts = token.split('.');
    if (parts.length == 3) {
      var b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (b64.length % 4 != 0) b64 += '=';
      try {
        final exp = (jsonDecode(utf8.decode(base64.decode(b64)))['exp']
            as int?) ?? 0;
        _expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      } catch (_) {
        _expiry = null;
      }
    }
  }

  /// 翻译一段文本。
  ///
  /// [source] 省略时由 Lara 自动检测源语言（与需求「自动检测文字语言」一致）。
  /// [target] 默认中文 `zh-CN`；[style] 见 [LaraStyle]；[instructions] 为自由
  /// 指令（如「用口语化表达」）。[noTrace] 开启隐身模式（内容不被用于模型改进）。
  Future<LaraTranslation> translate(
    String text, {
    String? source,
    String target = 'zh-CN',
    LaraStyle? style,
    List<String>? instructions,
    bool noTrace = true,
  }) async {
    if (text.trim().isEmpty) {
      return const LaraTranslation(translation: '', sourceLanguage: '');
    }
    final token = await _ensureToken();
    final bodyMap = <String, Object>{
      'q': text,
      'target': target,
      if (source != null && source.isNotEmpty) 'source': source,
      if (style != null) 'style': styleParam[style]!,
      if (instructions != null && instructions.isNotEmpty)
        'instructions': instructions,
    };
    final body = jsonEncode(bodyMap);
    final date = HttpDate.format(DateTime.now().toUtc());
    final res = await http.post(
      Uri.parse('$baseUrl/v2/translate'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
        'X-Lara-Date': date,
        if (noTrace) 'X-No-Trace': 'true',
      },
      body: body,
    );
    if (res.statusCode == 401) {
      // token 失效，清掉后让下次调用重新鉴权
      _token = null;
      _refreshToken = null;
      throw const LaraAuthError('Lara 令牌已失效，请重试');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw LaraApiError(res.statusCode, _errMessage(res));
    }
    return LaraClient.parseTranslation(res.body);
  }

  /// 测试连通性（设置页「测试连接」用）：能拿到 token 即视为凭证有效。
  Future<void> testConnection() async {
    await _ensureToken();
  }

  // ── 响应解析 ──────────────────────────────────────────────────────────────

  /// `/v2/translate` 可能以 NDJSON / SSE（`data: {...}`）逐行流式返回，也可能返回
  /// 单个 JSON。统一按行解析，取最后一个含 `translation` 的对象（流式时末段即完整译文）。
  /// 抽出为 public static 以便单测，不依赖网络。
  static LaraTranslation parseTranslation(String raw) {
    String? translation;
    String? sourceLanguage;
    for (final line in raw.split('\n')) {
      var s = line.trim();
      if (s.isEmpty) continue;
      if (s.startsWith('data:')) s = s.substring(5).trim();
      if (!s.startsWith('{')) continue;
      Map<String, dynamic>? obj;
      try {
        obj = _decodeJsonStatic(s);
      } catch (_) {
        continue;
      }
      final t = obj['translation'];
      if (t is String && t.isNotEmpty) translation = t;
      final sl = obj['source_language'] ?? obj['sourceLanguage'];
      if (sl is String && sl.isNotEmpty) sourceLanguage = sl;
    }
    if (translation == null) {
      throw LaraApiError(0, 'Lara 未返回译文：${raw.trim().length > 200 ? raw.trim().substring(0, 200) : raw.trim()}');
    }
    return LaraTranslation(
      translation: translation,
      sourceLanguage: sourceLanguage ?? '',
    );
  }

  Map<String, dynamic> _decodeJson(String s) => _decodeJsonStatic(s);

  static Map<String, dynamic> _decodeJsonStatic(String s) =>
      jsonDecode(s) as Map<String, dynamic>;

  String _errMessage(http.Response res) {
    try {
      final obj = _decodeJson(res.body);
      return (obj['message'] as String?) ??
          (obj['error'] as String?) ??
          'HTTP ${res.statusCode}';
    } catch (_) {
      return 'HTTP ${res.statusCode}';
    }
  }

  // ── 签名原语 ──────────────────────────────────────────────────────────────

  static String _hmacBase64(String secret, String challenge) {
    final h = crypto.Hmac(crypto.sha256, utf8.encode(secret));
    final sig = h.convert(utf8.encode(challenge)).bytes;
    return base64.encode(sig);
  }

  static String _md5Base64(String body) {
    final d = crypto.md5.convert(utf8.encode(body)).bytes;
    return base64.encode(d);
  }
}

/// 翻译风格。
enum LaraStyle { faithful, fluid, creative }

/// 单次翻译结果。
class LaraTranslation {
  const LaraTranslation({
    required this.translation,
    required this.sourceLanguage,
  });

  final String translation;
  final String sourceLanguage;
}

/// Lara 凭证（Access Key ID + Secret）。
class LaraCredentials {
  const LaraCredentials({required this.id, required this.secret});

  final String id;
  final String secret;

  /// 是否完整可用（设置页据此启用翻译按钮）。
  bool get isValid => id.trim().isNotEmpty && secret.trim().isNotEmpty;

  static const _kId = 'lara_access_key_id';
  static const _kSecret = 'lara_access_key_secret';

  static Future<LaraCredentials?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kId) ?? '';
    final secret = prefs.getString(_kSecret) ?? '';
    if (id.isEmpty || secret.isEmpty) return null;
    return LaraCredentials(id: id, secret: secret);
  }

  static Future<void> save(LaraCredentials creds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kId, creds.id);
    await prefs.setString(_kSecret, creds.secret);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kId);
    await prefs.remove(_kSecret);
  }
}

/// Lara 鉴权失败（凭证错误或令牌失效）。
class LaraAuthError implements Exception {
  const LaraAuthError(this.message);
  final String message;
  @override
  String toString() => 'LaraAuthError: $message';
}

/// Lara API 业务错误（含 HTTP 状态码）。
class LaraApiError implements Exception {
  const LaraApiError(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'LaraApiError($statusCode): $message';
}

/// HMAC/MD5 原语的纯函数封装，便于单元测试（不依赖网络）。
class LaraSigning {
  LaraSigning(this.secret);
  final String secret;

  /// 构造 `/v2/auth` 的签名挑战串（与 SDK `client.js#sign` 完全一致）。
  String challenge(String method, String path, String contentMd5,
      String contentType, String date) {
    return '$method\n$path\n$contentMd5\n$contentType\n$date';
  }

  String sign(String challenge) => LaraClient._hmacBase64(secret, challenge);

  String md5Base64(String body) => LaraClient._md5Base64(body);
}
