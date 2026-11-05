import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camby/lara/lara_client.dart';

void main() {
  group('LaraSigning · HMAC/MD5 原语（对齐官方 SDK client.js）', () {
    test('HMAC-SHA256 + Base64 命中 RFC 测试向量', () {
      // RFC 4231 风格向量：HMAC-SHA256(key="Jefe", data=...) 的十六进制为
      // 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843
      const expected = 'W9zBRr9gdU5qBCQmCJV1x1oAPwidJzmDnexYuWTsOEM=';
      expect(LaraSigning('Jefe').sign('what do ya want for nothing?'), expected);
    });

    test('MD5 + Base64 命中空串向量（d41d8cd98f00b204e9800998ecf8427e）', () {
      const expected = '1B2M2Y8AsgTpgAmY7PhCfg==';
      expect(LaraSigning('irrelevant').md5Base64(''), expected);
    });

    test('签名挑战串严格为 METHOD\\nPATH\\nMD5\\nTYPE\\nDATE', () {
      final s = LaraSigning('secret');
      expect(
        s.challenge('POST', '/v2/auth', 'md5val', 'application/json', 'DATE'),
        'POST\n/v2/auth\nmd5val\napplication/json\nDATE',
      );
    });
  });

  group('LaraClient.parseTranslation · 响应解析（兼容多种格式）', () {
    test('单个 JSON', () {
      final r = LaraClient.parseTranslation(
        '{"translation":"你好世界","source_language":"en"}',
      );
      expect(r.translation, '你好世界');
      expect(r.sourceLanguage, 'en');
    });

    test('NDJSON 流式：取最后一个含 translation 的片段', () {
      final r = LaraClient.parseTranslation(
        '{"translation":"你"}\n{"translation":"你好"}\n{"translation":"你好世界","source_language":"en"}\n',
      );
      expect(r.translation, '你好世界');
      expect(r.sourceLanguage, 'en');
    });

    test('SSE（data: 前缀）也能解析', () {
      final r = LaraClient.parseTranslation(
        'data: {"translation":"已译","source_language":"ja"}\n\n',
      );
      expect(r.translation, '已译');
      expect(r.sourceLanguage, 'ja');
    });

    test('无 translation 时抛 LaraApiError', () {
      expect(
        () => LaraClient.parseTranslation('{"status":500}'),
        throwsA(isA<LaraApiError>()),
      );
    });
  });

  group('LaraCredentials · 本地存取（shared_preferences mock）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('保存后能读回，isValid 反映完整性', () async {
      const c = LaraCredentials(id: 'ak_123', secret: 'sk_456');
      await LaraCredentials.save(c);
      final loaded = await LaraCredentials.load();
      expect(loaded?.id, 'ak_123');
      expect(loaded?.secret, 'sk_456');
      expect(loaded?.isValid, isTrue);
    });

    test('缺任一项返回 null 且 isValid=false', () async {
      await LaraCredentials.save(const LaraCredentials(id: '', secret: 'sk'));
      final loaded = await LaraCredentials.load();
      expect(loaded, isNull);
      expect(const LaraCredentials(id: '', secret: 'sk').isValid, isFalse);
    });

    test('clear 后读不到', () async {
      await LaraCredentials.save(const LaraCredentials(id: 'a', secret: 'b'));
      await LaraCredentials.clear();
      expect(await LaraCredentials.load(), isNull);
    });
  });

  group('LaraClient.translate · 无凭证/无效凭证的失败路径', () {
    test('credentials 为空时 isValid=false（调用方据此提示去设置页）', () {
      expect(const LaraCredentials(id: '', secret: '').isValid, isFalse);
    });
  });
}
