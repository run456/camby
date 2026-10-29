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
