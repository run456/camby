#include <flutter/runtime_effect.glsl>

// L2 液态玻璃 fragment shader（ImageFilter.shader 专用）
//
// ImageFilter.shader 契约（Flutter 官方）：
//   1) 首个 uniform 必须是 vec2 —— 引擎会把它设为「绑定纹理」的尺寸（物理像素）；
//   2) 至少一个 sampler2D —— 第一个会被引擎设为「滤镜输入」（即背后内容）。
//   因此这里 u0_size 由引擎注入，无需（也不应）在 Dart 侧依赖它做几何换算。
//
// 效果：圆角矩形 SDF → 表面法线 → 边缘采样坐标偏移（真实折射）
//       → R/G/B 不同折射率（色散）→ 固定光源 Fresnel 镜面高光。

precision highp float;

uniform vec2 u0_size;        // 引擎注入：滤镜输入纹理尺寸（物理像素）
uniform float u1_dispersion; // 色散强度（0~0.5）
uniform vec2 u2_light;       // 固定光源方向（已归一化）
uniform float u3_radius;     // 圆角半径（物理像素）
uniform float u4_refract;    // 折射偏移强度（物理像素）
uniform float u5_spec;       // 镜面高光强度
uniform sampler2D u6_tex;    // 引擎注入：背后内容
uniform float u7_full;        // 整面折射模式：1.0=整面透镜，0.0=仅边缘带

out vec4 fragColor;

// 圆角矩形有符号距离场：内部 < 0，外部 > 0
float sdRoundRect(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
  vec2 size = u0_size;
  vec2 coord = FlutterFragCoord().xy;

  // 采样坐标（0~1）。GLES 后端 Y 轴翻转，否则内容上下颠倒。
  vec2 uv = coord / size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  // SDF 与法线在本地像素空间计算（与输出像素对齐，不做 Y 翻转）
  vec2 p = coord - size * 0.5;
  vec2 b = size * 0.5 - 1.0;
  float d = sdRoundRect(p, b, u3_radius);

  float e = 1.0;
  float dx = sdRoundRect(p + vec2(e, 0.0), b, u3_radius)
           - sdRoundRect(p - vec2(e, 0.0), b, u3_radius);
  float dy = sdRoundRect(p + vec2(0.0, e), b, u3_radius)
           - sdRoundRect(p - vec2(0.0, e), b, u3_radius);
  vec2 n = normalize(vec2(dx, dy) + vec2(1e-6));

  // 折射带宽度（仅「边缘带模式」生效）。
  float ew = max(6.0, min(size.x, size.y) * 0.14);
  // 整面折射模式（u7_full>0.5）：中心 edge→0、边缘 edge→1，覆盖整块卡面。
  // 背景在玻璃内被放大/弯曲，形成真实透镜感，而非单纯磨砂。
  float edge = u7_full > 0.5
      ? clamp(1.0 + d / (min(size.x, size.y) * 0.5), 0.0, 1.0)
      : 1.0 - smoothstep(0.0, ew, -d); // 边缘带模式：贴近内边缘 → 1，内部 → 0

  // 沿法线偏移采样坐标：边缘处背景被「弯折」，形成玻璃透镜感
  vec2 off = n * u4_refract * edge / size;
#ifdef IMPELLER_TARGET_OPENGLES
  off.y = -off.y; // 与 uv 的翻转保持一致，避免折射方向反了
#endif

  // RGB 三通道用不同折射率采样 → 青/品红色散细边
  float rc = texture(u6_tex, clamp(uv + off * (1.0 + u1_dispersion), 0.0, 1.0)).r;
  float gc = texture(u6_tex, clamp(uv + off, 0.0, 1.0)).g;
  float bc = texture(u6_tex, clamp(uv + off * (1.0 - u1_dispersion), 0.0, 1.0)).b;
  vec3 col = vec3(rc, gc, bc);

  // Fresnel + 固定光源镜面，集中在边缘强化玻璃厚度与体积。
  // v2.0.76：fres 0.32 → 0.18。原来边缘能叠到 0.8 的白，在深色卡面上
  // 会显出一圈发灰的亮边，像积了水垢；收一档只留冷光。
  float ny = clamp(abs(n.y), 0.0, 1.0);
  float fres = pow(1.0 - ny, 3.0);
  float spec = max(0.0, dot(n, normalize(u2_light)));
  col += vec3(1.0) * (fres * 0.18 + spec * u5_spec * 0.8) * edge;

  fragColor = vec4(col, 1.0);
}
