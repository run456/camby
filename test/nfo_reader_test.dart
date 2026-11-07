import 'package:camby/metadata/nfo_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nfoPathFromMediaPath', () {
    test('http 直链换扩展名（中文由 Uri 编码）', () {
      final u = nfoPathFromMediaPath('http://h/片库/IPZZ-077-C.mp4');
      expect(u, isNotNull);
      expect(Uri.decodeFull(Uri.parse(u!).path), '/片库/IPZZ-077-C.nfo');
    });

    test('本地路径也能换扩展名（供 Emby 代理 Path 参数）', () {
      expect(
        nfoPathFromMediaPath('/volume1/media/ABC.mp4'),
        '/volume1/media/ABC.nfo',
      );
    });

    test('.strm / 无扩展名 / 目录', () {
      expect(
        nfoPathFromMediaPath('https://h/x/ABC.strm'),
        'https://h/x/ABC.nfo',
      );
      expect(nfoPathFromMediaPath('https://h/x/ABC'), 'https://h/x/ABC.nfo');
      expect(nfoPathFromMediaPath('https://h/x/'), isNull);
    });
  });

  group('buildNfoUrls', () {
    const fp = 'http://192.168.5.29:5445/d/库/影片.mp4';

    test('带 emby 凭据：代理优先 + 直链兜底', () {
      final urls = buildNfoUrls(
        fp,
        embyBase: 'http://h:8096/emby',
        embyToken: 'TK',
        itemId: '123',
      );
      expect(urls.length, 2);
      expect(
        urls[0],
        startsWith('http://h:8096/emby/Items/123/File?Path='),
      );
      expect(urls[0], contains('api_key=TK'));
      expect(
        urls[1],
        'http://192.168.5.29:5445/d/%E5%BA%93/%E5%BD%B1%E7%89%87.nfo',
      );
    });

    test('缺 emby 凭据：只产直链', () {
      final urls = buildNfoUrls(fp);
      expect(urls.length, 1);
      expect(urls[0], startsWith('http://192.168.5.29:5445/'));
    });

    test('本地路径无直链：只产 Emby 代理', () {
      final urls = buildNfoUrls(
        '/volume1/media/x.mp4',
        embyBase: 'http://h:8096/emby',
        embyToken: 'TK',
        itemId: '9',
      );
      expect(urls.length, 1);
      expect(urls[0], startsWith('http://h:8096/emby/Items/9/File?Path='));
      expect(urls[0], contains('Path=%2Fvolume1%2Fmedia%2Fx.nfo'));
    });
  });

  group('parseNfoSeries 回归', () {
    test('<series> 优先', () {
      expect(
        parseNfoSeries('<movie><series>S1</series></movie>'),
        'S1',
      );
    });

    test('无 <series> 时回退 <set><name>', () {
      expect(
        parseNfoSeries('<movie><set><name>S2</name></set></movie>'),
        'S2',
      );
    });

    test('无系列字段返回 null', () {
      expect(parseNfoSeries('<movie><title>x</title></movie>'), isNull);
    });
  });
}
