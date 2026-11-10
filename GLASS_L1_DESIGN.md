# 液态玻璃 · L1 阶段设计稿（凝态玻璃）

> 配套文档：[玻璃材质升级可行性研究](https://github.com/run456/camby) 的落地延伸。
> 本报告只覆盖 **L1（凝态 Frozen）** 这一级；L2（液态，自定义 shader）与 L3（原生路径）仅作关系说明，不在本次实现范围。
> 状态：**已落地（v2.0.70）**。配方已按本稿实现于 `lib/theme.dart` 的 `Glass`，see `CHANGELOG.md` 的 v2.0.70 条目。

---

## 0. TL;DR

- 当前 `Glass` 实质处于报告定义的 **霜态（Frost）**：只有高斯模糊 + 灰白 tint + 静态高光，**没有色彩矩阵、没有厚度感**，背景被灰白稀释、卡片与背景「两张皮」。
- L1 目标让同一套组件从「霜」跳到 **凝态（Frozen）**：背景色块被「冻住」、边缘有明亮厚度。改动集中在 `lib/theme.dart` 的 `Glass` 一处，**零新增依赖、约半天投入、可独立回滚**。
- 三件事：① `ColorFiltered` 叠加 saturate+contrast 色彩矩阵；② 内发光（inner glow）；③ 亮边（bright edge）+ 现有高光提一档。
- 复用现有 `blurEnabled` 与滚动降级机制，**不引入新掉帧**；播放页 `blurEnabled:false` 保持不变。

---

## 1. 研究结论：现状实现效果评估

### 1.1 实现盘点（真实参数，取自代码）

| 组件 | 文件 | 现状做法 | 关键参数 |
|---|---|---|---|
| `Glass`（主组件） | `lib/theme.dart:262` | `BackdropFilter` 高斯模糊 + 白色 tint 渐变 + 静态对角高光 + 静态顶部弧光 + 1px 边 | `blur=26`、`radius=24`、`tint=0.10`、`border=white.18/1px`；高光 `white.26→0→0→.12`、弧光 `white.14→0` |
| `GlassPanel`（弹层卡片） | `lib/widgets/glass_sheet.dart:21` | 默认 `blur=false`：高不透明深色底 `0xF2141A28` + 细边 + 投影；`blur=true` 才做 `BackdropFilter(24)` + 深色渐变 tint | 卡宽 470/620；边 `white.10/.18`；外阴影 `blur40 offset(0,18) alpha.5` |
| `LiquidPress`（按下态） | `lib/widgets/liquid_press.dart:12` | 缩放 0.955 + 整片提亮 + 手指处径向光晕 + 边缘加亮 | `glow=.30`、`tint=.20`；时长 90ms |
| 组合件 | `GlassIconButton` / `LiquidIconButton` / `LiquidPill` / `GlassPanelRoute` | 基于上述封装 | — |

> 全仓 `Glass(` 调用约 26 处；`blurEnabled:false` 共 10 处，**全部在 `player_page.dart`**（压在逐帧视频上，开启实时模糊会拖垮 GPU，故关模糊、仅留半透明质感）。其余弹窗均走真实模糊。

### 1.2 光学评估（对照报告三态模型）

| 光学维度 | 现状（霜态 Frost） | 本报告目标（凝态 Frozen） |
|---|---|---|
| 色彩透传 | 低饱和 + 灰白 tint，**发闷发灰** | `saturate 1.5–1.8` + `contrast 1.1`，颜色「冻」在玻璃里 |
| 边缘光学 | 无，背景与卡片是两张皮 | 轻微：内发光 + 亮边，**制造厚度** |
| 镜面高光 | 静态对角渐变（已有） | 亮边 + 顶部弧光，可随内容亮度自适应 |
| 体积 / 厚度 | 一层平面 | 内发光 + 外阴影，**两层** |
| 像素采样 | 1（模糊，引擎优化） | 1 + 色彩矩阵（CPU 参数，GPU 成本几乎不变） |

### 1.3 关键缺陷（这是「霜」而非「液态」的原因）

1. **没有色彩矩阵**：背景被灰白 tint 稀释 → 整体发闷发灰，对应参考图最下层。
2. **没有厚度/内发光/亮边**：卡片边缘是「切」出来的，不是「折射」出来的，缺乏玻璃厚度感。
3. **注释误导**：`Glass` 中写着 `// 折射高光层：对角镜面光……（液态玻璃）`，但**没有真正的坐标重映射/折射**，只是静态渐变。代码自称「液态玻璃」是不准确的。

---

## 2. L1 凝态玻璃设计稿

### 2.1 设计原则

- **零新增依赖**：只动 `Glass` 一处，全部用现成 `BackdropFilter` / `ColorFiltered` / `BoxDecoration`。
- **复用降级**：`blurEnabled`、滚动掉帧时的降级开关原样保留；播放页 `blurEnabled:false` 不动。
- **可独立回滚**：单组件改动，出问题回退一个 commit 即可，不影响 L2 预留的 shader 路径。
- **性能中性**：色彩矩阵是 CPU 参数（经 `ColorFiltered`），不增加 GPU 采样次数；内发光/亮边是装饰层，开销可忽略。

### 2.2 三项改造（基于现有 `Glass.build`）

**① 色彩矩阵（核心）**——模糊后过一遍 `ColorFiltered(matrix)`：
```dart
// 近似 saturate 1.6 + contrast 1.1（矩阵可微调）
// 先 saturate，再 contrast，亮度居中不变
static const List<double> _vibrancy = [
//  R          G          B   A  bias
   1.46,  0.36,  0.18,  0, 0,
   0.36,  1.46,  0.18,  0, 0,
   0.18,  0.36,  1.46,  0, 0,
   0,     0,     0,     1, 0,
];
// 叠 contrast 1.1 ≈ 乘 1.1、bias (1-1.1)*0.5=-0.05，可合并进上面矩阵或
// 用 ColorFiltered 两次（仍零依赖）。实践中用一份合并矩阵即可。
```

**② 内发光（inner glow）**——Flutter 的 `BoxShadow` **不支持 `inset`**，故用「边缘内渐变」近似：
```dart
// 软白环：边缘 24px 内发亮、向内淡出，读作玻璃厚度
DecoratedBox(
  decoration: BoxDecoration(
    borderRadius: r,
    gradient: RadialGradient(
      center: Alignment.center, radius: 0.92,
      colors: [Colors.white.withOpacity(0.0), Colors.white.withOpacity(0.10)],
      stops: const [0.72, 1.0],
    ),
  ),
)
// 若要更紧的折射感，改用 _InnerGlowPainter(CustomPainter) 画四边渐变。
```

**③ 亮边（bright edge）+ 高光提档**：
```dart
border: Border.all(color: Colors.white.withOpacity(0.22), width: 0.9), // 原 0.18/1px → 提亮收细
// 现有对角高光 alpha .26 → 提至 .30~.34；弧光 .14 → .18
```

### 2.3 改造后的 `Glass.build`（参考配方）

```dart
Widget build(BuildContext context) {
  final r = BorderRadius.circular(radius);
  // tint 让出一档给色彩矩阵，避免叠加后过曝
  final tintNow = tint * 0.7;

  Widget content = Container(
    width: width, height: height, padding: padding,
    decoration: BoxDecoration(
      borderRadius: r,
      gradient: gradient ?? _tintGradient(tintNow, soft),
      // ③ 亮边：更亮更细
      border: border ? Border.all(color: Colors.white.withOpacity(0.22), width: 0.9) : null,
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 30, offset: const Offset(0, 12)),
      ],
    ),
    child: child,
  );

  if (blurEnabled) {
    // ① 关键：模糊 + 色彩矩阵（纯 CPU 参数）
    content = ColorFiltered(
      colorFilter: ColorFilter.matrix(_vibrancy),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: content,
        ),
      ),
    );
  } else {
    content = ClipRRect(borderRadius: r, child: content);
  }

  // ② 内发光（无 inset，用边缘内渐变近似厚度）
  content = Stack(children: [content, _innerGlow(r, 0.10)]);
  // ③ 折射高光层（现有，alpha 提档；L2 才做真折射）
  content = Stack(children: [content, _specular(r, top: 0.32, diag: 0.34)]);

  if (onTap != null) content = LiquidPress(onTap: onTap, radius: radius, child: content);
  if (margin != null) content = Padding(padding: margin!, child: content);
  return content;
}
```

### 2.4 参数建议表（评审用，灰度可调）

| 项 | 现状值 | L1 建议值 | 说明 |
|---|---|---|---|
| tint | 0.10（全量） | 0.07（×0.7） | 让位给色彩矩阵，防过曝 |
| 色彩矩阵 saturate | — | 1.5–1.8（建议 1.6） | 报告给定区间 |
| 色彩矩阵 contrast | — | 1.1 | 报告给定 |
| 亮边 | white .18 / 1px | white .22 / 0.9px | 更亮更细 |
| 内发光 | 无 | white .10，边缘 24px | 制造厚度 |
| 对角高光 | white .26 | white .32–.34 | 提一档 |
| 顶部弧光 | white .14 | white .18 | 提一档 |
| 外阴影 | 原样 | blur30 / offset(0,12) / .35 | 略加深，托起体积 |

> 灰度策略：先以 `saturate 1.6 / contrast 1.1 / innerGlow .10` 起评，按真机截图在 `1.4–1.8` 间微调；若发现文字清晰度下降，优先降 tint 而非降 saturate。

---

## 3. 与现状对比

### 3.1 光学维度（霜 → 凝）

| 维度 | 现状（霜态） | L1（凝态） | 用户可感知变化 |
|---|---|---|---|
| 背景色彩 | 被灰白稀释、发闷 | 高饱和「冻」住 | 卡片后面的海报/视频颜色更鲜活 |
| 边缘 | 平切、无厚度 | 亮边 + 内发光 | 玻璃「有厚度」，不再像贴纸 |
| 高光 | 静态、偏弱 | 提档、可自适应 | 顶光更立挺 |
| 体积 | 一层 | 内发光 + 外阴影 | 浮起感更强 |
| 性能 | 1 采样 | 1 + 色彩矩阵(CPU) | 无感知差异 |

### 3.2 结构 / 代码对比

| | 现状 | L1 |
|---|---|---|
| 模糊 | `BackdropFilter(blur)` | `BackdropFilter(blur)`（不变） |
| 色彩 | 无 | `ColorFiltered(matrix)` 新增一层 |
| 厚度 | 仅 1px 边 | 1px 边 + 内发光环 + 外阴影 |
| 改动面 | — | 仅 `Glass.build` 一处；`GlassPanel`/`LiquidPress` 自动受益 |
| 降级 | `blurEnabled` | 复用（播放页仍 `false`） |
| 注释 | 「液态玻璃」不实 | 改为「凝态（L1）」，真折射交给 L2 |

### 3.3 可视化对比

见 `glass_l1_mockup.html`：同一张彩色背景上，左卡「现状·霜态」、右卡「L1·凝态」，可直观看到色彩鲜活度与边缘厚度的差异。

---

## 4. 风险 / 性能 / 回滚

- **性能**：色彩矩阵走 `ColorFiltered`（CPU 参数），不增加 GPU 纹理采样；内发光/亮边为装饰层，开销可忽略。`perf_audit.py` 关注点（模糊须配 `RepaintBoundary`、列表禁 `setState`）均不受影响。
- **文字可读**：saturate 抬太高 + tint 残留可能压暗文字。对策：tint ×0.7 让位，灰度上限 1.8。
- **低端 / 非 Impeller**：`blurEnabled:false` 分支仍是「半透明质感 + 厚重底」，L1 的 `ColorFiltered` 在此分支也照常生效（纯 CPU），无新增风险。
- **回滚**：单 commit 改动 `theme.dart`，`git revert` 即回霜态；不影响后续 L2 shader 的 `isShaderFilterSupported` 降级预留。

---

## 5. 与 L2 / L3 的关系（路线图定位）

```
L1 凝态（本次）  ──独立上线/回滚──▶  零依赖，色彩矩阵+内发光+亮边
   │
   ▼ （详情页/弹窗优先，不铺播放页）
L2 液态  ──自定义 fragment shader──▶  SDF 法线偏移采样，边缘背景弯曲放大；关折射即退回 L1
   │
   ▼ （技术储备）
L3 原生 37.2 路径  ──暂不实施──▶  仅储备，不强依赖新系统 API
```

L1 是 L2 的「安全兜底」：L2 在 `ImageFilter.isShaderFilterSupported == false`（低端 / GLES fallback）时自动退化到 L1 的凝态表现。

---

## 6. 待确认

1. saturate/contrast 起评档位（建议 1.6 / 1.1）是否接受，还是先更保守（1.4 / 1.05）灰度？
2. 内发光用「边缘内渐变」近似（零成本）即可，还是上 `CustomPainter` 做更紧的折射环？
3. 是否顺带把 `Glass` 里「液态玻璃」的误导性注释改为「凝态（L1）」？
4. 落地时是否新建 `v2.0.70` 小版本，还是并入下个大版本？
