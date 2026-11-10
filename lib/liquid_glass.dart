import 'dart:ui';

import 'package:flutter/foundation.dart';

/// 玻璃材质档位开关与 L2 液态 shader 持有器。
///
/// 设计原则：
/// - **真的生效**：L2 走自定义 fragment shader（真折射），叠加在模糊之上；
///   同时 [Glass] 里还有一层不依赖 shader 的分层光学（色散细边 / 菲涅尔高光）
///   作为保底——即使个别机型回退 Skia，也能看到明显区别于 L1 的液态质感。
/// - **可一键回滚**：[GlassConfig.liquidEnabled] 关闭即整站退回 L1 凝态。
/// - **近景优先**：播放页 [Glass.blurEnabled] 为 false 时天然不进滤镜管线。
/// - **无并发串扰**：[shader] 每次返回独立的 [FragmentShader]，多实例同帧 paint
///   时参数不会串味。
class GlassConfig {
  /// v2.0.76 修复：以前是裸 static bool，设置页 setState 只重建设置页自身，
  /// 已被 IndexedStack / 路由缓存的其它页面不会 rebuild，于是「开关点了没反应」。
  /// 现在改成 ValueNotifier：每个 [Glass] 自己监听，切换瞬间全场玻璃重绘。
  static final ValueNotifier<bool> liquid = ValueNotifier<bool>(true);

  /// 用户开关：true = 液态玻璃(L2)，false = 凝态玻璃(L1)。默认开。
  /// 由设置页「液态玻璃」持久化为 `set_liquid_glass`；启动时从 SharedPreferences 读入。
  static bool get liquidEnabled => liquid.value;
  static set liquidEnabled(bool v) {
    if (liquid.value != v) liquid.value = v;
  }
}

/// L2 液态玻璃的 shader 资源加载与实例工厂。
class LiquidGlass {
  LiquidGlass._();

  static FragmentProgram? _program;
  static bool _tried = false;

  /// 是否可用：shader 已成功加载，且运行后端支持 [ImageFilter.shader]
  /// （仅 Impeller；非 Impeller 下该 getter 为 false，必须降级）。
  static bool get supported =>
      _program != null && ImageFilter.isShaderFilterSupported;

  /// 应用启动时调用一次。资源缺失 / 编译失败均静默吞掉，整体退回 L1。
  static Future<void> ensureLoaded() async {
    if (_tried) return;
    _tried = true;
    try {
      _program = await FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    } catch (_) {
      _program = null;
    }
  }

  /// 生成一枚独立的 [FragmentShader] 实例。
  ///
  /// uniform 顺序须与 `shaders/liquid_glass.frag` 的声明（=字母序）一致：
  /// `u0_size`(vec2) → `u1_dispersion` → `u2_light`(vec2) → `u3_radius`
  /// → `u4_refract` → `u5_spec` → `u6_tex`(sampler)。
  ///
  /// 尺寸 u0_size 由引擎在 flush 时覆盖为「绑定纹理尺寸」，这里仅给非零兜底
  /// 防除零；几何量（radius / refraction）用**物理像素**，与纹理同尺度。
  static FragmentShader shader({
    required double radius,
    double refraction = 10,
    double dispersion = 0.22,
    double specular = 0.5,
  }) {
    final s = _program!.fragmentShader();
    s.setFloat(0, 1.0); // u0_size.x（引擎会覆盖）
    s.setFloat(1, 1.0); // u0_size.y（引擎会覆盖）
    s.setFloat(2, dispersion); // u1_dispersion
    s.setFloat(3, 0.45); // u2_light.x（固定光源：右上）
    s.setFloat(4, -1.0); // u2_light.y
    s.setFloat(5, radius); // u3_radius
    s.setFloat(6, refraction); // u4_refract
    s.setFloat(7, specular); // u5_spec
    return s;
  }
}
