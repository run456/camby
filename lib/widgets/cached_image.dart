import 'package:cached_network_image/cached_network_image.dart';
import 'package:camby/ugreen_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../theme.dart';
import 'image_ssl.dart';
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
    this.fullResDiskCache = false,
    this.filterQuality = FilterQuality.low,
    this.errorWidget,
    this.fallbackLabel,
    this.radius = 0,
  });

  final String? url;
  final BoxFit fit;
  final Alignment alignment;
  final int? memWidth;

  /// v2.0.102：为 true 时**磁盘缓存保留服务端返回的原始分辨率**。
  ///
  /// 默认把 `memWidth` 同时传给 `maxWidthDiskCache`，等于把大图重新降采样
  /// 再编码一次存盘，之后无论怎么提高请求宽度都拿不回细节 —— 月报海报墙
  /// 被反复报告「压缩」就是这里。`memWidth` 仍控制内存解码宽度（不爆内存），
  /// 只是磁盘那份不再二次有损压缩。仅用于会被放大光栅化的场景（分享图）。
  final bool fullResDiskCache;
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
  List<String> _candidates = const <String>[];
  int _index = 0;
  bool _advanceScheduled = false;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(CachedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _reset();
  }

  void _reset() {
    final u = widget.url;
    final policy = ResourcePolicy.instance;
    _candidates = (u == null || u.isEmpty)
        ? const <String>[]
        : imageUrlCandidates(u, enabled: policy.ugreenMode);
    final preferred = policy.preferredImageIndex ?? 0;
    _index = _candidates.isEmpty
        ? 0
        : preferred.clamp(0, _candidates.length - 1);
    _advanceScheduled = false;
    _probe = _probeCache();
  }

  String? get _current => _candidates.isEmpty ? null : _candidates[_index];

  Future<FileInfo?> _probeCache() async {
    final u = widget.url;
    if (u == null || u.isEmpty) return null;
    try {
      // 所有候选共用同一个 key：任一候选成功后，下次进页面直接命中缓存，
      // 不必再把失败的组合重试一遍（缓存 key 里已剔除会变的 api_key）。
      return await ImageSsl.manager.getFileFromCache(imageCacheKey(u));
    } catch (_) {
      // 缓存管理器不可用时按「未命中」处理，走 180ms 淡入，不影响加载。
      return null;
    }
  }

  /// v2.0.89：绿联兼容层的图片端点/鉴权方式因固件而异，第一个候选失败
  /// 就自动切下一个；全部失败才落回骨架。切候选放在 postFrame，避免在
  /// build 阶段 setState。
  void _onImageError() {
    if (!mounted || _advanceScheduled || _index + 1 >= _candidates.length) {
      return;
    }
    _advanceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _advanceScheduled = false;
      if (!mounted || _index + 1 >= _candidates.length) return;
      setState(() => _index++);
    });
  }

  Widget _placeholder() => SizedBox.expand(
    child: SkeletonBox(radius: widget.radius, label: widget.fallbackLabel),
  );

  @override
  Widget build(BuildContext context) {
    final u = _current;
    if (u == null) {
      return widget.errorWidget ?? const SizedBox.shrink();
    }
    final policy = ResourcePolicy.instance;
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
            // 切候选时强制重建内部 state，避免复用上一次失败的加载状态。
            key: ValueKey<int>(_index),
            imageUrl: u,
            cacheManager: ImageSsl.manager,
            cacheKey: imageCacheKey(widget.url!),
            httpHeaders: embyAuthHeaders(u, enabled: policy.ugreenMode),
            fit: widget.fit,
            alignment: widget.alignment,
            memCacheWidth: widget.memWidth,
            maxWidthDiskCache: widget.fullResDiskCache ? null : widget.memWidth,
            filterQuality: widget.filterQuality,
            fadeInDuration: instant ? Duration.zero : AppMotion.imageFade,
            fadeInCurve: Anim.curve,
            fadeOutDuration: Duration.zero,
            placeholder: (_, __) => _placeholder(),
            errorWidget: (_, __, ___) {
              _onImageError();
              return widget.errorWidget ?? _placeholder();
            },
          );
        },
      ),
    );
  }
}
