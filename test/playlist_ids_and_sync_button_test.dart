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
      expect(
        seg.contains("'Ids'] = itemIds.join(',')"),
        isTrue,
        reason: "Ids 应为逗号分隔字符串：body['Ids'] = itemIds.join(',')",
      );
      expect(
        seg.contains("'Ids': itemIds,"),
        isFalse,
        reason: '禁止把 Ids 作为 JSON 数组发送（Emby 400）',
      );
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
    test('v2.0.106：标题行必须有上传/下载双按钮（取代旧的单向同步按钮）', () {
      expect(pageSrc.contains('class _SyncButtons'), isTrue);
      expect(pageSrc.contains('_SyncButtons(state: state)'), isTrue);
      expect(pageSrc.contains("ValueKey('fav-upload')"), isTrue);
      expect(pageSrc.contains("ValueKey('fav-download')"), isTrue);
      expect(pageSrc.contains('class _SyncButton '), isFalse);
    });

    test('上传/下载各自调用对应入口，且先问覆盖/合并', () {
      final idx = pageSrc.indexOf('class _SyncButtons');
      final seg = pageSrc.substring(idx);
      expect(seg.contains('uploadFoldersToServer('), isTrue);
      expect(seg.contains('downloadFoldersFromServer('), isTrue);
      expect(seg.contains("'覆盖'"), isTrue);
      expect(seg.contains("'合并'"), isTrue);
      expect(seg.contains('showToast'), isTrue);
    });

    test('v2.0.103：封面改单张完整海报（原 _layer 堆叠已移除）', () {
      expect(
        pageSrc.contains('Widget _layer(int depth'),
        isFalse,
        reason: '扇形叠放会互相遮挡并二次裁切封面',
      );
      final idx = pageSrc.indexOf('class _StackTile');
      expect(idx, greaterThanOrEqualTo(0));
      final end = pageSrc.indexOf('Widget get _placeholder', idx);
      final seg = pageSrc.substring(idx, end);
      expect(seg.contains('BoxFit.contain'), isTrue);
      expect(
        seg.contains('Alignment.bottomCenter'),
        isFalse,
        reason: '海报按 2:3 铺满卡片，不再贴底缩放堆叠',
      );
      // v1.7.66 的教训：内部 Center 会把海报再次居中，仍禁止
      expect(seg.contains('Center('), isFalse);
    });

    test('新建收藏夹卡图标还原为 40（外框由 FractionallySizedBox 缩小）', () {
      final newIdx = pageSrc.indexOf('class _NewFolderTile');
      final seg = pageSrc.substring(newIdx);
      final m = RegExp(r'width: (\d+),\s*\n\s*height: \d+,').firstMatch(seg);
      expect(m, isNotNull);
      expect(int.parse(m!.group(1)!), 40, reason: '内部按钮还原 v1.7.63 尺寸');
      expect(
        seg.contains('FractionallySizedBox'),
        isTrue,
        reason: '虚线外框必须缩到 0.85 与海报卡一致',
      );
      expect(seg.contains('heightFactor: 0.85'), isTrue);
    });
  });
}
