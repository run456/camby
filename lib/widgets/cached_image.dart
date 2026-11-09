import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../theme.dart';
import 'skeleton.dart';

/// 生成稳定的图片缓存 key：去掉会随登录变化的 `api_key`，
/// 保留 `tag` / `maxWidth`，这样换一次 token 也能命中同一份磁盘缓存。
String imageCacheKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final q = Map<String, String>.from(uri.queryParameters)..remove('api_key');
  final keys = q.keys.toList()..sort();
  final query = keys.map((k) => '$k=${q[k]}').join('&');
  return '${uri.scheme}://${uri.host}:${uri.port}${uri.path}?$query';
}

/// 带磁盘缓存的网络图片（v2.0.64 质感包改造）。
///
/// 断网 / 服务器不可达时，只要之前加载过，就会直接从本地缓存读取，
/// 不会变成空白。相比旧版四处变化：
///  · 占位从 `SizedBox.shrink()` 换成低饱和渐变骨架，看得出「正在加载」；
///  · 网络图 180ms 淡入（`Anim.curve`），不再「啪」地硬切；
///  · 磁盘缓存命中时 `fadeInDuration = 0`，二次进入瞬间出图、看不到骨架；
///  · 404 / 加载失败保留骨架 + [fallbackLabel] 片名，卡片仍可点开详情。
///
/// 缓存探测放在渲染图片之前（一次内存 / 磁盘索引查询），是为了让
/// `fadeInDuration` 在 CachedNetworkImage 的整个生命周期里保持稳定，
/// 不会中途重建把已开始的淡入打断。
class CachedImage extends StatefulWidget {
  const CachedImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.memWidth,
    this.filterQuality = FilterQuality.low,
    this.errorWidget,
    this.fallbackLabel,
    this.radius = 0,
  });

  final String? url;
  final BoxFit fit;
  final Alignment alignment;
  final int? memWidth;
  final FilterQuality filterQuality;
  final Widget? errorWidget;

  /// 失败保底时叠在骨架上的片名，避免出现一个没有上下文的黑洞。
  final String? fallbackLabel;

  /// 骨架圆角。多数调用方外层已 ClipRRect / ClipOval，默认 0 不重复裁剪。
  final double radius;

  @override
  State<CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> {
  Future<FileInfo?>? _probe;

  @override
  void initState() {
    super.initState();
    _probe = _probeCache();
  }

  @override
  void didUpdateWidget(CachedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _probe = _probeCache();
  }

  Future<FileInfo?> _probeCache() async {
    final u = widget.url;
    if (u == null || u.isEmpty) return null;
    try {
      return await DefaultCacheManager().getFileFromCache(imageCacheKey(u));
    } catch (_) {
      // 缓存管理器不可用时按「未命中」处理，走 180ms 淡入，不影响加载。
      return null;
    }
  }

  Widget _placeholder() => SizedBox.expand(
        child: SkeletonBox(
          radius: widget.radius,
          label: widget.fallbackLabel,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final u = widget.url;
    if (u == null || u.isEmpty) {
      return widget.errorWidget ?? const SizedBox.shrink();
    }
    // 每张图独立成层：列表滚动 / 详情页滑动时，未变化的图不再重绘，
    // 大幅降低 GPU 重绘开销（详情页卡顿的主要来源之一）。
    return RepaintBoundary(
      child: FutureBuilder<FileInfo?>(
        future: _probe,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _placeholder();
          }
          final instant = snap.data != null;
          return CachedNetworkImage(
            imageUrl: u,
            cacheKey: imageCacheKey(u),
            fit: widget.fit,
            alignment: widget.alignment,
            memCacheWidth: widget.memWidth,
            maxWidthDiskCache: widget.memWidth,
            filterQuality: widget.filterQuality,
            fadeInDuration: instant ? Duration.zero : AppMotion.imageFade,
            fadeInCurve: Anim.curve,
            fadeOutDuration: Duration.zero,
            placeholder: (_, __) => _placeholder(),
            errorWidget: (_, __, ___) => widget.errorWidget ?? _placeholder(),
          );
        },
      ),
    );
  }
}
