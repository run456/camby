# 性能验证（Camby · 手机 / 平板）

双端改造后性能风险集中在三处：**平板大网格滚动**、**整页背景模糊（BackdropFilter）**、**图片解码尺寸**。
沙箱/CI 无法跑真机帧率，因此采用「静态红线门禁 + profile 真机测量」两层，缺一不可。

## 1. 静态红线（自动化，每版必跑）

`tools/perf_audit.py`（已接入 `tools/verify_release.sh` 第 4 步）扫 `lib/` 命中即失败：

| 红线 | 为什么 | 典型症状 |
|---|---|---|
| 模糊/滤镜外层必须有 `RepaintBoundary` | `BackdropFilter` 每帧对下层重采样 | 滚动掉帧、GPU 占用高 |
| `CachedImage` 必须给 `memWidth` | 按显示尺寸解码，避免 4K 原图进内存 | 内存暴涨、OOM |
| 列表 `itemBuilder` 内不得 `setState` | 滚动期整页重建 | 滚动卡顿 |
| 长列表不得 `shrinkWrap` | 一次性构建全部子项 | 首屏/切页卡死 |
| 网格列数必须走断点判断 | 平板沿用手机 3 列 → 超大卡片 | 平板卡片巨大、图片解码量翻 4 倍 |

豁免项写在脚本 `ALLOW` 里，逐条注明理由（静态浮层 / 弹窗短列表），新增豁免必须评审。

## 2. 真机测量（手工，每版固定执行）

```bash
# ① 构建 profile 包（与 release 同优化，但保留性能追踪）
flutter build apk --profile --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-profile.apk

# ② 采集时间线（DevTools → Performance / Timeline）
flutter pub global activate devtools && flutter pub global run devtools
```

**阈值（60Hz 屏，16.67ms/帧）**

| 场景 | 指标 | 阈值 |
|---|---|---|
| 媒体库 6 列网格滚动（平板） | UI 线程帧耗时 | 平均 < 8ms，> 16ms 的帧 < 3% |
| 同上 | Raster 线程 | 平均 < 10ms（大网格图片解码是主要开销） |
| 首页切换 Tab（保活页） | 切页耗时 | < 120ms，无重建导致的图片重解码 |
| 详情页进出（含整页模糊） | 首帧耗时 | < 200ms |
| 播放起播 | 黑幕揭开 | < 1.5s（含 900ms 兜底） |
| 内存（平板 6 列滚 200 项） | RSS 增量 | < 120MB，滚回顶部后应回落 |

**重点看什么**
- Raster 线程出现 `ImageShader`/`drawPicture` 长条 → 图片太大：核对 `memWidth` 是否随列宽收敛（平板 6 列卡片更窄，`memWidth` 应更小）。
- UI 线程出现 `build` 长条且集中在滚动 → 列表项缺 `RepaintBoundary` 或 `itemBuilder` 里做了状态回写。
- 平板比手机明显更卡 → 先看是否触发了「手机列数」分支（断点没走到）。

## 3. 本轮已做的性能相关改动

| 项 | 处理 |
|---|---|
| 平板 6 列网格 | 复用媒体库已有 `RepaintBoundary` 卡片（每张卡独立栅格化） |
| 平板大图 | Hero / 详情头部 `memWidth: 1200`，人物头像 600，避免按原图解码 |
| 整页背景模糊 | 详情页/首页/人物页背景模糊继续保持 `RepaintBoundary` 包一层 |
| 统计页双栏 | 平板把卡片两两并排，减少单页滚动长度与同屏重绘面积 |
| 页面保活 | 切 Tab 用 `Offstage`+`TickerMode`，不重建、不重解码 |

## 4. 每版固定验证顺序

```bash
bash tools/verify_release.sh --build   # 分析 + 全量测试 + 性能静态审计 + 构建
```
再按 §2 在真机（手机 + 平板各一台）跑一遍阈值表，结果记入 `VERIFICATION.md` 对应版本章节。
