// 守卫测试（v1.7.66）：
// 1. Emby 播放列表 API 的 `Ids` 必须是逗号分隔字符串（v1.7.65 传 JSON 数组被
//    服务端 400 拒绝且静默吞掉，导致收藏夹映射到播放列表全部失败）；
// 2. 收藏页标题行必须有「与服务器同步」按钮；
// 3. 封面堆叠必须贴底对齐（收紧标题与封面间距）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final clientSrc = File('lib/emby_client.dart').readAsStringSync();
  final pageSrc = File('lib/pages/favorites_page.dart').readAsStringSync();

  group('Playlist Ids 序列化（v1.7.66 回归守卫）', () {
    final createIdx = clientSrc.indexOf('Future<String?> createPlaylist');
    final addIdx = clientSrc.indexOf('Future<bool> addToPlaylist');

    test('createPlaylist 必须用 join(\',\') 序列化 Ids', () {
      expect(createIdx, greaterThanOrEqualTo(0));
      final seg = clientSrc.substring(createIdx, createIdx + 1600);
      expect(seg.contains("'Ids'] = itemIds.join(',')"), isTrue,
          reason: "Ids 应为逗号分隔字符串：body['Ids'] = itemIds.join(',')");
      expect(seg.contains("'Ids': itemIds,"), isFalse,
          reason: '禁止把 Ids 作为 JSON 数组发送（Emby 400）');
    });

    test('addToPlaylist 必须用 join(\',\') 序列化 Ids', () {
      expect(addIdx, greaterThan(createIdx));
      final seg = clientSrc.substring(addIdx, addIdx + 900);
      expect(seg.contains("itemIds.join(',')"), isTrue);
      expect(seg.contains("'Ids': itemIds}"), isFalse);
    });

    test('空列表时不得发送 Ids 字段', () {
      final seg = clientSrc.substring(createIdx, createIdx + 1600);
      expect(seg.contains('if (itemIds.isNotEmpty)'), isTrue);
    });
  });

  group('收藏页同步入口与布局（v1.7.66）', () {
    test('标题行必须有 _SyncButton（与服务器同步）', () {
      expect(pageSrc.contains('class _SyncButton'), isTrue);
      expect(pageSrc.contains('_SyncButton(state: state)'), isTrue);
    });

    test('同步按钮必须调用 syncFoldersFromServer 并汇报结果', () {
      final idx = pageSrc.indexOf('class _SyncButton');
      final seg = pageSrc.substring(idx);
      expect(seg.contains('syncFoldersFromServer()'), isTrue);
      expect(seg.contains('showToast'), isTrue);
    });

    test('封面堆叠必须贴底对齐（bottomCenter）', () {
      final stackIdx = pageSrc.indexOf('clipBehavior: Clip.none,');
      expect(stackIdx, greaterThanOrEqualTo(0));
      final seg = pageSrc.substring(stackIdx, stackIdx + 220);
      expect(seg.contains('Alignment.bottomCenter'), isTrue,
          reason: '海报堆叠应贴底，避免标题与封面间距过宽');
    });

    test('新建收藏夹卡图标不得小于 54', () {
      final newIdx = pageSrc.indexOf('class _NewFolderTile');
      final seg = pageSrc.substring(newIdx);
      final m = RegExp(r'width: (\d+),\s*\n\s*height: \d+,').firstMatch(seg);
      expect(m, isNotNull);
      expect(int.parse(m!.group(1)!), greaterThanOrEqualTo(54));
    });
  });
}
