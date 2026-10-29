import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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

/// 带磁盘缓存的网络图片。
///
/// 断网 / 服务器不可达时，只要之前加载过，就会直接从本地缓存读取，
/// 不会变成空白。
class CachedImage extends StatelessWidget {
  const CachedImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.memWidth,
    this.filterQuality = FilterQuality.low,
    this.errorWidget,
  });

  final String? url;
  final BoxFit fit;
  final Alignment alignment;
  final int? memWidth;
  final FilterQuality filterQuality;
  final Widget? errorWidget;

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || u.isEmpty) return const SizedBox.shrink();
    return CachedNetworkImage(
      imageUrl: u,
      cacheKey: imageCacheKey(u),
      fit: fit,
      alignment: alignment,
      memCacheWidth: memWidth,
      maxWidthDiskCache: memWidth,
      filterQuality: filterQuality,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => const SizedBox.shrink(),
      errorWidget: (_, __, ___) => errorWidget ?? const SizedBox.shrink(),
    );
  }
}
