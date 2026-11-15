import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v2.0.103：收藏夹封面从「扇形堆叠」改成「单张完整海报」的守卫。
///
/// 背景：旧实现三张小图倾斜叠放 + 0.85 缩放 + BoxFit.cover，封面互相遮挡
/// 又被二次裁切，真机上「收藏影片封面显示不完整」。现在一张海报按 2:3
/// 原生比例铺满卡片宽度，contain 保证整张都在。顺带把无限横滑条换成 2 列
/// 网格，「管理」弹窗整行可点进对应收藏夹。
void main() {
  final src = File('lib/pages/favorites_page.dart').readAsStringSync();

  String stackSegment() {
    final idx = src.indexOf('class _StackTile');
    expect(idx, greaterThanOrEqualTo(0), reason: '找不到 _StackTile');
    final end = src.indexOf('Widget get _placeholder', idx);
    expect(end, greaterThan(idx), reason: '找不到 _StackTile 结束位置');
    return src.substring(idx, end);
  }

  test('封面不再扇形叠放：_layer / Transform.rotate / maxDepth 全部移除', () {
    expect(
      src.contains('Widget _layer(int depth'),
      isFalse,
      reason: '扇形叠放会遮挡并裁切封面，v2.0.103 起整段移除',
    );
    expect(src.contains('Transform.rotate('), isFalse);
    expect(src.contains('maxDepth'), isFalse);
    // _NewFolderTile 仍用 bottomCenter 对齐虚线框，只约束海报卡本身
    expect(stackSegment().contains('Alignment.bottomCenter'), isFalse);
  });

  test('单张完整海报：contain + 2:3 比例 + 大图缓存', () {
    final seg = stackSegment();
    expect(seg.contains('covers.first'), isTrue, reason: '只取夹内最新一部做封面');
    expect(seg.contains('w * 1.5'), isTrue, reason: '2:3 原生比例');
    expect(seg.contains('BoxFit.contain'), isTrue, reason: '非标准比例海报也要整张可见');
    expect(seg.contains('memWidth: 600'), isTrue);
    expect(seg.contains('filterQuality: FilterQuality.high'), isTrue);
  });

  test('收藏夹改 2 列网格，不再无限横滑', () {
    expect(src.contains("ValueKey('folder-grid')"), isTrue);
    expect(src.contains("ValueKey('folder-rail')"), isFalse);
    expect(src.contains('_kMaxFolderTiles'), isTrue);
    expect(src.contains('final cols = context.isTablet ? 3 : 2;'), isTrue);
    expect(src.contains('folders.take(_kMaxFolderTiles - 2)'), isTrue);
    expect(src.contains('查看全部收藏夹'), isTrue);
  });

  test('「管理」弹窗整行点进收藏夹，… 才进重命名 / 删除', () {
    final idx = src.indexOf('void _folderMenu(');
    expect(idx, greaterThan(0));
    final end = src.indexOf('Widget _folderLeading(', idx);
    expect(end, greaterThan(idx));
    final seg = src.substring(idx, end);
    expect(seg.contains('isScrollControlled: true'), isTrue);
    expect(seg.contains('点开即进入'), isTrue);
    expect(seg.contains("_openFolder(f.id, f.name)"), isTrue);
    expect(seg.contains("_openFolder(null, '全部收藏')"), isTrue);
    expect(seg.contains('IconButton('), isTrue, reason: '… 独立成按钮');
    expect(seg.contains('_manageFolder(f)'), isTrue);
    expect(seg.contains('ListView('), isTrue, reason: '夹子多时弹窗可滚动');
  });
}
