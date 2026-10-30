# Camby v1.7.38 源码重建 · 验证记录

> 生成环境：Flutter **3.47.8** / Dart **3.13.7**（与 `pubspec.yaml` 的 `sdk: ^3.13.0` 一致）
> 验证日期：见文末命令输出时间戳

---

## 1. 静态分析

```
$ flutter analyze
Analyzing camby...
299 issues found. (ran in 10.2s)
```

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| error | **0** |  |
| warning | **0** |  |
| info | 299 | 235 条 `withOpacity` 弃用提示 + 35 条 `unnecessary_underscores` + 风格建议，**全部继承自 v1.7.21 基线代码**，非本次重建引入 |

修复过程：初版有 7 个 error / 1 个 warning，全部来自新增代码——

| 位置 | 问题 | 修法 |
| --- | --- | --- |
| `settings_page.dart:112` | `const Map<Color, String>` 键类型不允许覆写 `==` | 改成对 `color.toARGB32()` 做 `switch` |
| `player_page.dart:583` | `p.hardwareDecode`，`p` 可空且在闭包内无法提升 | 在 `setState` 外先取出局部变量 |
| `player_page.dart:359` | 跨 await 使用 `BuildContext` | 补 `if (!mounted) return` |
| `person_page.dart` | `_FilmTab` 被 `_Seg` 取代后成为死代码 | 删除（46 行） |
| `widgets/subtitle_style_sheet.dart` | `Color.value` 已废弃 | 统一改回 `toARGB32()`（与 `models.dart:466` 的原写法一致） |

---

## 2. 单元测试

```
$ flutter test
00:01 +25: All tests passed!
```

**25/25 通过**，含新增的 `test/camby_1738_test.dart`（12 组）：

- `SubtitleStyle`：默认值 / `copyWith` 不改原对象 / JSON 往返无损 / 残缺 JSON 回落 / `bottomRatio` 双向夹取 / `textStyle` 描边开关
- `EmbyServer.streamUrl`：不带码率不追加 `MaxStreamingBitrate`、携带时参数正确、`0` 与负数视为「不限」
- `EmbyServer.heightFromNameForTest`：`Np` 显式标记、`4K/UHD/HDRip` 隐含标记、无法判断时返回 `null`（含 `2170p` 这类非标准写法不能误判）

---

## 3. Release 构建

```
$ flutter build apk --release --target-platform=android-arm64
✓ Built build/app/outputs/flutter-apk/app-release.apk (34.4MB)
```

构建过程中的环境阻碍与解法：

| 阻碍 | 解法 |
| --- | --- |
| `github.com` 443 不通，media_kit 的 libmpv 依赖下载超时 | 用 GH 镜像取回 4 个 ABI 的 jar，校验 MD5 后放入 `build/media_kit_libs_android_video/v1.1.7/` |
| Gradle 9.3.1 报 "prefer settings repositories over project repositories" | `/root/.gradle/init.gradle` 里遗留的 `mavelCentral()` 拼错 + 仓库注入方式过时，改写为正确的 beforeSettings 语法（必要时可整体移开） |
| Gradle daemon 反复 "disappeared unexpectedly" | 容器 cgroup 内存上限 8 GiB，而 Gradle 默认 `-Xmx4G` + 并行 worker 会顶爆。在全局 gradle.properties 降到 `-Xmx3g`、`workers.max=4`、`parallel=false` 后一次通过（第二次起 55 秒出包） |

---

## 4. 与原始 APK 的逐项对拍

### 4.1 包级一致性

| 项目 | 原始 APK | 重建 APK |
| --- | --- | --- |
| 文件名 | `Camby-v1.7.38-arm64-release(1).apk` · 33 MB | `app-release.apk` · 34.4 MB |
| package | `cn.camby.camby` | `cn.camby.camby` ✓ |
| versionName / versionCode | `1.7.38` / **78** | `1.7.38` / **78** ✓ |
| minSdk / targetSdk | 28 / 36 | 28 / 36 ✓ |
| 权限 | INTERNET, ACCESS_NETWORK_STATE, WAKE_LOCK (+DYNAMIC_RECEIVER…) | 完全一致 ✓ |
| ABI | 仅 `arm64-v8a` | 仅 `arm64-v8a` ✓ |
| `.so` 清单 | app / flutter / dartjni / mpv / mediakitandroidhelper / datastore_shared_counter | 同一套 6 个 ✓ |
| `libapp.so` 大小 | 7,078,792 B | 7,078,792 B（md5 不同，大小巧合一致） |

### 4.2 新增符号逐个核对（26/26 命中，库哈希一致）

| 源文件 | 符号 | 原始 APK | 重建 APK |
| --- | --- | --- | --- |
| `lib/pages/player_page.dart` @**28472116** | `_GlassPanel` `_InfoHeader` `_SpeedChip` `_changeBitrate` `_loadSubStyle` `_lockScreen` `_reportProgress` `_reportProgressNow` `_shortSubUrl` `_showGlassPanel` `_showSubtitleStyle` `_toggleHardware` `_unlockScreen` | ✓ | ✓ |
| `lib/pages/home_page.dart` @**559049366** | `_commitShown` `_persistReco` `_pickRecommendations` `_rebuildHeroPool` `_recoWeight` `_restoreRecoState` `_scheduleMidnightRefresh` `_shuffleReco` | ✓ | ✓ |
| `lib/pages/person_page.dart` @**596023365** | `_Seg` `_showFilterSheet` | ✓ | ✓ |
| `lib/emby_client.dart` @**555127961** | `_heightFromName` | ✓ | ✓ |
| `SubtitleStyleSheet` 相关 | `_SubtitleStyleSheetState` `_ColorSwatch` | ✓ @605399474 | ✓ @604383483（拆成独立文件，见 README 差异 1） |

### 4.3 配置键 / 字符串证据

| 字符串 | 原始 | 重建 |
| --- | --- | --- |
| `camby_sub_size` / `_pos` / `_opa` / `_stroke` / `_offset` / `_color` | ✓ | ✓ |
| `home_reco_at` / `_seed` / `_recent` | ✓ | ✓ |
| `&MaxStreamingBitrate=` | ✓ | ✓ |
| `/Users/` + `/Items/` + `/UserData`（进度写回路线） | ✓ | ✓ |
| `Sessions` / `Playing/Stopped` / `IsPaused` | — | —（两边都不存在，说明原始并未走 Sessions 三件套） |
| `hwdec` / `hwdec-codecs` / `getDefaultHwdec` | ✓ | ✓ |
| `PlaybackPositionTicks` / `PlaybackStartDateTime` | ✓ | ✓ |

字符串集合整体重合率 **91.5%**（差异主要来自 Dart/Flutter 版本号、构建路径与重写过的 UI 文案）。

---

## 5. 结论

重建产物满足三条硬指标：

1. **能编译**：`flutter analyze` 零错误零警告；
2. **能出包**：与原始同 ABI、同包名、同 versionCode 的 release APK 构建成功，产物大小相差 1.4 MB；
3. **改对了地方**：26 个新增符号全部对齐且落在同一编译单元，新增/修改了 6 个 lib 文件、新增 2 个文件——其余 8 个 lib 文件零新增符号，判定为相对 v1.7.21 未改动，直接沿用。

改动清单（`lib/`）：

| 文件 | 状态 |
| --- | --- |
| `lib/emby_client.dart` | 改：`_heightFromName`、`streamUrl(maxBitrate)`、`reportProgress` |
| `lib/player/playback.dart` | 改：`PlaybackController.hardwareDecode` / `setHardwareDecode` |
| `lib/pages/player_page.dart` | 改：硬解热切换、码率上限、字幕样式、锁定/解锁、倍速胶囊、进度写回 |
| `lib/pages/home_page.dart` | 改：每日推荐引擎（权重 + 种子 + 冷却 + 跨天/手动换一批） |
| `lib/pages/person_page.dart` | 改：`_Seg` 分段 + `_showFilterSheet` 年代/排序筛选 |
| `lib/pages/settings_page.dart` | 改：字幕样式入口、硬解开关联动、版本号 |
| `lib/widgets/subtitle_style_sheet.dart` | **新增**（518 行） |
| `test/camby_1738_test.dart` | **新增** |

---

## 6. v1.7.40 (80) 补齐验收（第二轮回补）

> 触发：原始会话的分享存档已拿到（`04-原会话履历复原与差距清单.md`），据此把 v1.7.23 之后遗漏的 7 项逐条补齐。

| 项 | 来源版本 | 落点 | 验证方式 |
|---|---|---|---|
| 字幕响应 8MB 上限 + 视频魔数嗅探 + 600ms 重试 | 1.7.28 | `emby_client.dart` `_fetchBytesOnce` / `_videoMagic` | 4 种魔数判定单测 + 代码审查 |
| 字幕第 5 级 `/Items/{id}/File?Path=` | 1.7.25 | `emby_client.dart` 五级候选 + `models.dart` `sourcePath` | `textCandidates` 保序去重单测 |
| 中文字幕判定链（语言→显示名→路径）+ 无标记默认中文 | 1.7.23 / 1.7.27 | `models.dart` `SubtitleTrackInfo.isChinese` | 8 组单测（含 `scene` 不误判、pgs 不兜底） |
| 播放页 ValueNotifier 解耦 | 1.7.38 | `player_page.dart` `_posNv`/`_bufNv`/`_cueNv`/`_styleRev` | `setState` 数量审查 + 真机手感 |
| 底栏缓冲+时长贴右常显 | 1.7.33 / 1.7.40 | `player_page.dart` `_bottomBar` | 布局审查 |
| 四类弹层居中玻璃面板 + 返回手势退场 | 1.7.32 / 1.7.39 | `_GlassPanel` / `_GlassPanelRoute` | 代码审查 + 真机 |
| Anim 常量 / routes.dart 统一转场 / Impeller / 着色器预热 | 1.7.38 / 1.7.39 | `theme.dart` `Anim`、`routes.dart`、`AndroidManifest.xml`、`main.dart` `_ShaderWarmup` | `_ShaderWarmup@21041693` 符号存在；`EnableImpeller` 在 manifest |

**质量门**

- `flutter analyze`：**0 error / 0 warning**
- `flutter test`：**48 / 48 通过**（新增 `test/camby_1740_test.dart` 11 组）
- `flutter build apk --release --target-platform=android-arm64`：成功，34.4MB
- 产物校验：`versionCode=80`、`versionName=1.7.40`；`libapp.so` 中确认存在 `/Items/`、`_ShaderWarmup@21041693`、`_GlassPanelRoute@28472116`、`-- MB/s`、`sub-pos`、`sub-delay`

**仍存在的已知差异**

1. 演员页筛选抽屉未加「共 N 部 · 已选 M 项」计数行（重置/应用栏、分段控件、草稿态均已对齐媒体页）。
2. `_GlassPanelRoute` 的返回手势退场依赖 `PageRouteBuilder` 的反向过渡；本 Flutter 版本无 `transitionOnUserGestures` 参数，效果为系统手势触发反向动画（与 v1.7.39 当时的结论一致）。
3. v1.7.40 的 #4（收藏夹弹窗 v2）、#5（STRM 黑屏加载态 A/B/C/D）在原会话中**只出了设计稿、未实现**，本版本同样未含。

---

## 7. v1.7.41 (81) 重建代码复核

> 触发：拿到完整对话实录（31 轮）后，对重建实现做「符号表 + 规则表」双向复核，修掉 6 处不一致。

| # | 问题 | 证据 | 修复 |
|---|---|---|---|
| 1 | 推荐种子不是「日期+手动偏移」，原版有 `_activeSeed` getter，重建版无 | 原版符号 `get:_activeSeed@559049366`；对话 1.7.30 规则表 | `RecoEngine.activeSeed()`：`天数(自 2025-01-01)×100000 + 手动种子` |
| 2 | 推荐权重表被重写（评分 0~1、无名气项、抖动大于评分） | 对话 1.7.30 权重表 vs `_recoWeight` 实现 | 恢复 3.0/2.0/1.5/0.5/0.5/±0.8 量纲 |
| 3 | 已看完未排除、多样性只看系列不看类型 | 同上 | `isFinished()` 硬排除 + 同系列 1 部 + 同类型 ≤2 部 |
| 4 | 冷启动「已推」表把当前批也排除，导致每次开 App 换一批 | 代码推演 `_shuffleReco` → `_restoreRecoState` | 改为「先记旧批、再挑新批」，种子 `+1` 可复现 |
| 5 | 详情页无 `_onStateChanged`，进度不自动刷新 | 原版符号 `_onStateChanged@DetailPage`；对话 1.7.29 交付项 | `initState` 注册 / `dispose` 注销，按需 `setState` |
| 6 | `AppState.updateProgress` 整个不存在，进度只发服务端 | 对话 1.7.29 交付项；全库 grep 无此符号 | 新增 `updateProgress`，`copyWith` 补齐 4 个字段，尊重 `set_record_history` |
| 7 | `continueWatching` 无排序、信息面板缺文件大小 | 原版符号 `_fmtSize@28472116`；对话 1.7.31 需求 3 | 按 `lastPlayedAt` 倒序；补「大小 / 入库」两行 |

**质量门**

- `flutter analyze`：**0 error / 0 warning**
- `flutter test`：**73 / 73 通过**（新增 `test/reco_engine_test.dart` 18 组、`test/progress_test.dart` 7 组）
- 产物：`Camby-v1.7.41-TEST-arm64.apk`（`cn.camby.camby.test` / 81 / 1.7.41）、`camby-1.7.41-rebuilt-release-arm64.apk`（`cn.camby.camby` / 81）
- 符号复核：新包已含 `_fmtSize`、`_onStateChanged`、`updateProgress`、`activeSeed`、`RecoEngine`

**仍未处理**

1. ASS 特效字幕仍会套用叠加层样式（原版 `_isTextSubtitle` 语义不同，需真机比对后再定）。
2. 演员页 `_sortLabel` / `_typeLabel` 两个纯文案函数未补（行为无差异）。
3. 项目资产打包（`Camby-1.7.38-源码与对话存档.zip`）仍是 v1.7.38 时的快照，未含 v1.7.39~41 的改动。

---

## 8. v1.7.42 (82) 设置项与隐性优化复查

| 问题 | 现状（v1.7.41） | 修复 |
|---|---|---|
| 「默认播放内核」设置不生效（**1.7.29 修过又复发**） | `_engine` 硬写 `PlaybackEngine.exo` | `_applySavedPreferences()` 在 `_open()` 前读 `set_play_engine` |
| 「最大码率」设置不生效 | 播放器不读，只有胶囊能改 | 起播即读 `set_max_bitrate` |
| 「缓存大小」设置不生效 | `MpvController` 无 cache 参数 | `cacheMb` → `demuxer-max-bytes` / `demuxer-max-back-bytes` / `cache-secs` |
| 「自动连播下一集」只有 UI | 无实现 | `_checkAutoNext()`：播到 95% 跳下一集并先上报进度 |
| `_load()` 残留 12 个死键 | 每次进设置页白读 | 全部移除，仅留 5 个有效键 + 2 个推荐口味 |
| 设置页缺「推荐」分栏 | 无 | 每日推荐（只读说明）/ 优先没看过 / 排除已看完 |
| 首页 CAMBY 字距（1.7.29 优化过又复发） | `letterSpacing: 3` | 改回 1，与下方间距 3→1 |
| 演员页筛选抽屉缺计数行（1.7.40 已知差异） | 无 | 「共 N 部 · 已选 X」，按草稿态实时算 |
| 播放信息面板缺文件大小/入库 | 无 | `_fmtSize` / `_fmtDate` 两行 |

**质量门**：`flutter analyze` 0 error / 0 warning；`flutter test` **76/76**；产物 `1.7.42 (82)` 双包。

**一个重复出现的问题值得记一笔**：「设置项不生效」已经复发两次（1.7.29 的播放内核、1.7.29 的 CAMBY 字距），根因是重建/回滚时把旧实现又贴了回来。此后改设置相关代码，一律先 grep 键名确认有读取点。
