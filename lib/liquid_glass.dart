import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 玻璃材质档位开关与 L2 液态 shader 持有器。
///
/// 设计原则：
/// - **真的生效**：L2 走自定义 fragment shader（真折射），叠加在模糊之上；
///   同时 [Glass] 里还有一层不依赖 shader 的分层光学（色散细边 / 菲涅尔高光）
///   作为保底——即使个别机型回退 Skia，也能看到明显区别于 L1 的液态质感。
/// - **可一键回滚**：[GlassConfig.liquidEnabled] 关闭即整站退回 L1 凝态。
/// - **近景优先**：播放页 [Glass.blurEnabled] 为 false 时天然不进模糊管线，
///   但仍可走纯 shader 折射（背后是逐帧视频，折射随视频流动）。
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
  /// → `u4_refract` → `u5_spec` → `u6_tex`(sampler) → `u7_full`。
  /// 尺寸 u0_size 由引擎在 flush 时覆盖为「绑定纹理尺寸」，这里仅给非零兜底
  /// 防除零；几何量（radius / refraction）用**物理像素**，与纹理同尺度。
  ///
  /// - [full]：整面折射模式。true 时 shader 把折射带扩展到整块卡面（透镜弯曲），
  ///   false 时仅在边缘 14% 带内做色散/高光（经典毛玻璃描边）。
  /// - [light]：镜面高光方向（单位向量）。动态镜面由调用方每帧传入公转角度。
  static FragmentShader shader({
    required double radius,
    double refraction = 10,
    double dispersion = 0.22,
    double specular = 0.35,
    bool full = false,
    Offset light = const Offset(0.45, -1.0),
  }) {
    final s = _program!.fragmentShader();
    s.setFloat(0, 1.0); // u0_size.x（引擎会覆盖）
    s.setFloat(1, 1.0); // u0_size.y（引擎会覆盖）
    s.setFloat(2, dispersion); // u1_dispersion
    s.setFloat(3, light.dx); // u2_light.x
    s.setFloat(4, light.dy); // u2_light.y
    s.setFloat(5, radius); // u3_radius
    s.setFloat(6, refraction); // u4_refract
    s.setFloat(7, specular); // u5_spec
    s.setFloat(8, full ? 1.0 : 0.0); // u7_full
    return s;
  }
}

/// 动态镜面光源。
///
/// 用全局 [Ticker]（来自 scheduler，无需 State 的 vsync）让光源角度匀速公转，
/// 周期约 9 秒。所有 `fullRefraction` 玻璃订阅 [angle]，每帧用新角度重建
/// shader 的镜面高光方向，得到「光线在玻璃上游走」的液态流动感。
///
/// 性能红线由调用方承担：**只有大玻璃（导航条 / 播放控制条）订阅**，
/// 小卡片保持静态光源（见 [Glass]）。App 启动时调用一次 [start]。
class LiquidLightSource {
  LiquidLightSource._();

  /// 当前光源角度（弧度），0~2π 循环。
  static final ValueNotifier<double> angle = ValueNotifier<double>(0);
  static Ticker? _ticker;

  /// App 启动时调用一次；重复调用安全（已启动则跳过）。
  static void start() {
    if (_ticker != null) return;
    _ticker = Ticker((elapsed) {
      // 9 秒一圈，光源在玻璃表面匀速公转
      angle.value = (elapsed.inMilliseconds % 9000) / 9000 * 2.0 * pi;
    });
    _ticker!.start();
  }
}
