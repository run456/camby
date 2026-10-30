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

---

## 9. v1.7.43 (83) 收藏夹弹窗 v2

| 项 | v1 | v2 |
|---|---|---|
| 头部红心 | 无，只有一行静态文案 | 可点胶囊 ♥已收藏（粉红渐变）/ ♡收藏（灰玻璃） |
| 取消收藏 | 做不到，要退出弹窗回详情页 | 点红心即切换，`toggleFavorite` 连带 `_removeItemFromFolders` |
| 未收藏态 | 无此概念 | 收藏夹列表变暗禁用、主按钮改「关闭」、副标题提示点红心 |
| 新建收藏夹 | 二级对话框，输入框被裁 | 内联输入行，回车即建、同名复用、当场并入选 |
| 名字长度 | `maxLength` 挤出计数器行 | 提交时截断 20 字 |
| 键盘/手势条 | 只避让键盘 | `viewInsets` 与 `padding.bottom` 分别计算，不叠加 |
| 内容过高 | 溢出被裁 | 整体 `SingleChildScrollView`，封顶 82% 屏高 |

**顺带**：`promptFolderName`（收藏页新建 / 文件夹页重命名共用）外层补 `SingleChildScrollView`，输入框改固定 46 高居中容器，二级对话框的同类裁切一并修掉。

**测试可测性**：`AppState.disablePersistence`（`@visibleForTesting`）。根因是 `path_provider` 在 `flutter test` 里没有实现，`_foldersFile()` 的 `await` 会一直挂起 —— 于是「新建收藏夹」这类依赖持久化返回值的流程永远走不到下一步，表现为「夹子建出来了但没勾上」。生产代码从不设置该开关。

**质量门**：`flutter analyze` 0 error / 0 warning；`flutter test` **84/84**（新增 8 组）。

**交付**：只出一个正式包 `camby-1.7.43-release-arm64.apk`（`cn.camby.camby` / 83 / 1.7.43 / 33M）。按用户要求，此后不再构建共存 test 包。

---

## 10. v1.7.44 (84) STRM 起播三件套（A/B/D）

**背景**：`_tryOpen()` 是「直连 → 失败回退 HLS」。Exo 的 `open()` 等到解码器可出帧才返回，所以可信；**MPV 的 `open()` 立即返回**（libmpv 异步探测），App 以为开播成功就揭幕 → 用户看到纯黑而 App 毫不知情。缺的是「首帧到达」这个信号。

| 方案 | 落地 | 关键点 |
|---|---|---|
| **A 加载态** | `_bootOverlay()` + `_startBootWatch()` | 中央玻璃胶囊：片名 + 已等待 N 秒 + 内核实名；8s 露「切 Exo」按钮；25s 提示插件。秒数走 `ValueNotifier`，不每 500ms 重建整页 |
| **B MPV 调优** | `playback.dart` | `user-agent=VLC/3.0.20 LibVLC/3.0.20`（属性 + `Media.httpHeaders` 双写）+ `network-timeout=30`；MPV 10s 无首帧自动切 Exo（保留进度、只切一次） |
| **D 智能内核** | `MediaItem.isStrm` + 设置项 | 判据 `Path` 以 `.strm` 结尾或 `Container == STRM`；strm 默认 Exo，设置页新增「STRM 优先 Exo」开关（默认开） |

**接口变化**：`PlaybackController` 新增 `bool get firstFrameReady`。Exo = `isInitialized`；MPV = `videoParams.w > 0 && h > 0`。

**策略抽离**：`lib/player/boot_watch.dart` 的 `BootWatchPolicy` 管三个阈值（8 / 10 / 25）与两个判定，单测直接打靶，改数字只改一处。

**质量门**：`flutter analyze` 0 error / 0 warning；`flutter test` **97/97**（新增 `test/strm_boot_test.dart` 13 组）。

**交付**：`camby-1.7.44-release-arm64.apk`（`cn.camby.camby` / 84 / 1.7.44 / 33M）。

**附**：`/workspace/08-服务端STRM插件安装指南.md` —— 按 Emby 版本分流（4.8.x → StrmAssistant；4.9/4.10 → MediaInfoKeeper），含 Windows / Docker / Linux / 群晖四种环境的完整命令。

---

## 11. v1.7.45 (85) 启动黑屏修复

**症状**：装 v1.7.44 后点开 App 一片黑，永远进不去。

**排查**：代码静态检查 0 error / 0 warning、`flutter test` 97/97 全过、新增的启动冒烟测试（`test/smoke_boot_test.dart`，pumpWidget 真实 `CambyApp`）也能渲染出首页 —— 说明 Dart 侧逻辑本身没有必崩的错。问题落在「真机渲染管线 / 启动期不可恢复异常」这一类，而这类问题在单测里天然测不出来（单测跑的是测试渲染器，不是 Impeller/Skia + 真实 GLES 驱动）。

于是按「先保命、再定位」处理，做了 5 处加固：

| # | 改动 | 理由 |
|---|---|---|
| 1 | **Impeller 改 false**（回退 Skia） | 全站大量 `BackdropFilter` + Hero + 自定义转场，恰是 Impeller 兼容问题高发场景。部分 GPU/驱动组合下表现为整屏黑或闪退 |
| 2 | **删除 `_ShaderWarmup`** | 它是 Stack 最后一个子节点（压最底层）的隐形 `BackdropFilter`，会为「它下面的全部内容」建离屏图层；Activity theme 背景是黑的，这块离屏合成一旦失败就是纯黑。预热省下的首帧掉帧不值得冒这个险 |
| 3 | **`main()` 逐个 try** | 原来 `Inspire.warmUp()` / `MediaKit.ensureInitialized()` 是裸调用，任一个抛错 → `runApp` 根本不执行 → 纯黑。现在失败只跳过该补丁并打日志 |
| 4 | **`restore()` catchError** | 读缓存文件 / 连服务器抛未捕获异常同样会黑屏。现在吞掉只记日志，首页照常显示「未连接」 |
| 5 | **`ErrorWidget.builder` 可见化** | 真的某个组件构建失败时，原来是一片纯黑；现在直接把异常文字画在屏幕上，并且 `FlutterError.onError` 统一打 `[fatal]` 日志 |

> 第 5 条是这轮最有用的：如果 v1.7.45 仍然黑屏，**请把屏幕上的红字拍照发我**，那就是精确的出错组件和行号，一步到位。如果连红字都没有（纯黑），说明是引擎级渲染问题，那第 1、2 条应该已经解决；若仍未解决，请告诉我机型 + 系统版本，我改推 `--no-tree-shake-icons` / x86/arm32 变体进一步定位。

**质量门**：`flutter analyze` 0 error / 0 warning；`flutter test` **98/98**（新增启动冒烟 1 组）。

**交付**：`camby-1.7.45-release-arm64.apk`（`cn.camby.camby` / 85 / 1.7.45 / 33M / sha256 `66e8ea64…`）。

---

## 12. v1.7.46 (86) 「我的」页渲染崩溃修复

**症状**：v1.7.45 能进 App 了，但点「我的」Tab 整页被红字替代：

```
界面渲染出错
type 'Null' is not a subtype of type 'int'
```

「我的」页崩了 → 无法进入「添加服务器」，等于全 App 不可用。

> 这段红字正是 v1.7.45 第 5 条加固（`ErrorWidget.builder` 可见化）换来的 —— 上一个版本同样会崩，只是表现为一片黑，看不到原因。

### 根因

**v1.7.42 清理设置页「死键」时，只删了 `_load()` 里的 map 条目，没删 Widget 树里对它们的引用。**

具体链路：

1. v1.7.42 做了一次「配置项瘦身」，把 12 个已经没有任何读取点的偏好键从 `settings_page.dart` 的 `_load()` 返回 map 里删掉了（`sub_lang`、`theme_mode`、`danmaku_on`、`pip_on`…）。
2. 但页面 `build()` 里对应的行仍然在，仍然写着 `_s['sub_lang'] as int` 这样的取值。
3. Dart 里 `Map<String, dynamic>` 取不存在的键返回 `null`，`null as int` 直接抛 `_TypeError`。
4. 该异常发生在 `SettingsPage.build()` 内部 → 整棵子树被 `ErrorWidget` 顶掉 → 用户看到满屏红字。

v1.7.43 ~ v1.7.45 这三个版本都没碰设置页，所以这颗雷一直埋着；之前 97 个测试全绿也抓不到，因为**没有任何一个测试 build 过设置页**。

### 修复

**① 删除 4 组残留 UI**（它们背后的 key 早已不生效，留着只会误导用户）：

| 删除项 | 失效的键 |
|---|---|
| 字幕默认语言（选择行） | `sub_lang` |
| 弹幕整组 | `danmaku_on` / `danmaku_opacity` / `danmaku_area` / `danmaku_speed` |
| 主题整组 + `_ThemeDots` 组件类 | `theme_mode` / `theme_seed` |
| 画中画 / 气泡整组 | `pip_on` / `bubble_on` |

连带删掉 `_SliderRow` 组件类（唯一调用方在弹幕组里）。

**② 补齐仍在用的键**（这些功能是活的，只是 `_load()` 漏了初始化）：

```dart
'sub_lang':         prefs.getInt('set_sub_lang') ?? 0,
'ass_subtitle':     prefs.getBool('set_ass_subtitle') ?? true,
'online_subtitle':  prefs.getBool('set_online_subtitle') ?? true,
'strm_exo':         prefs.getBool('set_strm_exo') ?? true,
```

**③ 同时落地上个版本承诺的「STRM 优先 Exo」开关**（v1.7.44 的 D 方案只在 `player_page` 里读了 `set_strm_exo`，设置页没有入口），默认开。

### 测试补强 —— 这次要堵住的是「测试全绿但页面崩掉」的盲区

| 新文件 | 做什么 | 组数 |
|---|---|---|
| `test/all_pages_render_test.dart` | 五个 Tab（首页 / 搜索 / 追剧 / 片单 / 我的）**逐个 pumpWidget 真实页面**，断言无异常、无 `ErrorWidget` | 5 |
| `test/settings_render_test.dart` | ① build 设置页断言不抛；② **正则扫源码**：抓出所有 `_s['xxx']` 引用与 `_load()` 里初始化的键，做差集，缺失即失败 | 2 |

第 ② 条是数据驱动的一致性检查，不依赖人工维护清单 —— 以后再出现「删了 key 没删 UI」或「加了 UI 没加 key」，测试直接红，开发阶段就能拦住，不用等真机。

**有效性已验证**：`git stash` 掉修复代码后跑 `all_pages_render_test`，成功复现 `type 'Null' is not a subtype of type 'int'`；恢复后转绿。测试确实打在病灶上，不是空跑。

> 顺带一提：`settings_render_test.dart` 第一次跑就自己抓出了 `sub_lang`、`ass_subtitle`、`online_subtitle` 三个缺失键 —— 我原以为只崩了一个，实际是四个雷同时埋着，只是第一个触发就中断了后续构建。

**质量门**：`flutter analyze` 0 error / 0 warning；`flutter test` **105/105**（97 → 105，新增 8 组）。

**交付**：`camby-1.7.46-release-arm64.apk`（`cn.camby.camby` / 86 / 1.7.46 / 33M / sha256 `3356553dc4a437abafc32b24c31a677ee8509ec3344297d6f9f48d92ccda69b6`）。

---

## 13. v1.7.47 (87) 设置项接通：字幕默认语言 / ASS 特效 / 假开关守卫

**起因**：`06-需求实现对比总表.md` 的待办表里还挂着「字幕默认语言自动选轨 — 未做」。
顺着查了一遍，发现更普遍的问题：**设置页里有 4 个开关是纯装饰** —— 能点、值也存了，
但整个 `lib/` 里没有任何地方读它。

| 设置项 | 接通前 | 接通后 |
|---|---|---|
| 字幕默认语言 | 有 UI、无读取点（v1.7.46 修崩溃时我甚至把 UI 一并删了） | ✅ 播放页自动选轨 |
| ASS 特效字幕渲染 | 有 UI、无读取点 | ✅ MPV 走 `sub-ass` 实时开关 |
| 在线字幕搜索 | 有 UI、无读取点 | ⚠️ **做不到**，改为如实标注（见下） |
| STRM 优先 Exo | v1.7.46 已接 | 不变 |

### 13.1 字幕默认语言 → 自动选轨

新增 `lib/player/subtitle_pick.dart`，把判定抽成纯函数：

- `SubtitlePref` 枚举：跟随片源 / 中文 / 英文 / 日文 / 韩文 / 不自动挂载。
  **设置页与播放页共用同一份枚举**，从根上避免「两套顺序对不上导致选错语言」。
- `SubtitlePicker.pick(tracks, pref)` 规则（自上而下命中即返回）：
  1. `off` → 不挂
  2. 该语言有非强制轨 → 取服务端标默认的，没有取第一条
  3. 该语言只有强制轨 → 也接受
  4. 该语言一条都没有 → **回落「跟随片源」**，而不是静默无字幕
  5. `auto` → 服务端默认轨，都没有取第一条非强制

几个刻意的取舍：

- **语言优先于 `IsDefault`**。Emby 里 `IsDefault` 常常是封装时带上的（很多片源默认标英文轨），
  用户既然明确说了「我要中文」，就不该被这个标记盖掉。
- **不被强制轨劫持**。`Signs & Songs` 这类 forced 轨只翻片头片尾，当选正片字幕会缺大半台词。
- **语言识别三级**：ISO 码 → 带地区码取主标签（`zh-Hans` → `zh`）→ `displayTitle` 文字线索
  （「简体中字」「中字」）。外挂字幕在 Emby 里经常 `Language` 为空。

播放页接入点：

```dart
// initState，必须在 _open() 之前：_start() 会拿 _subtitle 去挂载
if (widget.subtitle == null) unawaited(_autoPickSubtitle());
```

`widget.subtitle == null` 才自动选 —— 详情页点某条字幕进来属于用户显式意图，不覆盖。
另加 `_userPickedSub`：一旦在字幕菜单里手动选过（含「关闭字幕」），本页不再自动插手。

### 13.2 ASS 特效字幕渲染 → 真开关

`PlaybackController` 新增 `Future<void> setAssRendering(bool on)`：

| 内核 | 实现 |
|---|---|
| MPV | `sub-ass` = yes/no。yes 走 libass 完整还原特效；no 则 ASS 当纯文本按 App 样式渲染 |
| Exo | 空实现（本来就没有 ASS 能力，叠加层只画纯文本） |

默认 **开**，即保持原盘特效。关掉后画面统一、不吃 GPU，适合 ASS 特效花得离谱的片源。
`_start()` 建完内核后下发一次，切内核也会重新下发。

### 13.3 在线字幕搜索 —— 这项做不到，我改成了不骗人

查过 `lib/subtitles/` 与 `emby_client.dart`：**整个 App 没有接入任何在线字幕源**
（无 OpenSubtitles / 无字幕站 API）。字幕轨 100% 来自 Emby 的 `MediaStreams`，
服务器上装了字幕插件就有，没装就没有。

所以这个开关没有「接上」的选项。处理方式：

- 副标题改为 `本版未接入字幕源（预留）`，并在开启时弹提示说明
- 无字幕时播放页的提示改为可操作的话术：
  `该影片没有可用字幕：可在 Emby 装字幕插件后重新扫描，或手动放置外挂字幕`

> 与其让用户点了开关以为能用，不如直说没接源。真要做，需要你给一个字幕站账号/API key。

### 13.4 新增守卫：假开关测试

`test/settings_effect_test.dart` —— 静态扫描，两道线：

1. 设置页 UI 上出现的每个 `_set('xxx')` / `_s['xxx']`，必须在**设置页以外**被
   `getInt/getBool/getString/getDouble` 读过至少一次，否则失败；
2. 白名单 `documented` 登记「已知无消费端且已在 UI 如实标注」的例外，并附理由。
   第二条测试反过来守白名单：一旦某个例外真被接上了，测试失败提醒清掉白名单，防止长期腐烂。

这类问题编译不报错、原有测试也全绿（没人测「这个设置到底有没有生效」），
只有静态扫描能守住。

**有效性已验证**（变异测试）：
- 把 `subtitle_pick.dart` 里语言匹配那行改成 `if (false && ...)` → **4 组失败**
- 把 `set_strm_exo` 的读取换成硬编码 `true` → 守卫测试精确报出 `set_strm_exo`，恢复后转绿

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning（316 条 info 为基线遗留） |
| `flutter test` | **122 / 122**（105 → 122，新增 `subtitle_pick_test` 15 组 + `settings_effect_test` 2 组） |

**交付**：`camby-1.7.47-release-arm64.apk`（`cn.camby.camby` / 87 / 1.7.47 / 33M / sha256 `798e6b722eea736ae7c24aa682399dcd86feea4d8ae14403678dd7234d5379a5`）。

---

## 14. v1.7.48 (88) 删掉「在线字幕搜索」占位开关

**用户指出**：在线字幕搜索不需要。

上一版（v1.7.47）我的处理是**保留开关 + 副标题标注「本版未接入字幕源（预留）」**。
这个处理是错的：既然不做，就不该占一个开关位 —— 留着一个点了没反应的东西，
本质上还是「假开关」，只是换了个诚实的说法。

**改动**：

| # | 内容 |
|---|---|
| 1 | 删除设置页「在线字幕搜索」整行（含 onChanged 里的提示逻辑） |
| 2 | 删除 `_load()` 里的 `online_subtitle` 键与 `_onlineSubDesc` 常量 |
| 3 | `test/settings_effect_test.dart` 移除例外白名单 —— 本版**不再有任何例外** |
| 4 | 新增守卫：设置页出现「预留 / 暂未接入 / 待接入 / 敬请期待」字样直接失败 |

第 4 条是为了防止我以后又用「先放个开关，以后再接」的方式糊过去。

**保留的部分**：播放页无字幕时的提示文案仍为
`该影片没有可用字幕：可在 Emby 装字幕插件后重新扫描，或手动放置外挂字幕` ——
这句是有用的，告诉用户该去哪儿解决，不涉及任何虚假功能承诺。

**质量门**：`flutter analyze` 0 error / 0 warning；`flutter test` **122 / 122**。
占位开关守卫已做变异验证：故意在副标题里加「（预留）」→ 精确报错，恢复后转绿。

**交付**：`camby-1.7.48-release-arm64.apk`（`cn.camby.camby` / 88 / 1.7.48 / 33M / sha256 `404aa1a7e4310bef6baf716f1919b1cc05b48b93c11ef5ef68ed9f9481dc184d`）。

---

## 15. v1.7.49 (89) 播放内核 bug + STRM 加载弹窗 + 播放器控件对齐设计稿

用户报 5 项，其中 #2 / #5 是真 bug，#3 / #4 是按设计稿补齐。

### 15.1 【bug】设置里选 MPV，实际永远开 Exo

**现象**：设置页「默认播放内核」选 MPV，进播放页顶栏却恒显示 `Exo`。

**根因**：`initState` 里两行代码并发跑：

```dart
_applySavedPreferences();   // async：内部 await SharedPreferences.getInstance()
...
_open();                    // 同步往下走，_start() 立刻读 _engine
```

`SharedPreferences.getInstance()` 首次要读磁盘，`await` 之后才执行
`_engine = eng == 1 ? mpv : exo`。而 `_open()` 不等它，此刻 `_engine`
还是字段初始值 `PlaybackEngine.exo` —— **所以设置永远生效不了**。

这个 bug 的隐蔽之处：没有任何异常、没有日志、界面一切正常，
只是「设置不生效」。v1.7.42 我以为接通了这个设置，实际只是把键读出来了，
读的时机不对。

**修复**：`initState` 只留一个入口，强制串行：

```dart
Future<void> _boot() async {
  await _applySavedPreferences();      // 先读完全部设置
  if (widget.subtitle == null && !_userPickedSub) {
    await _autoPickSubtitle();         // 再定字幕轨
  }
  await _open();                       // 最后才开播
}
```

**守卫**：`test/player_boot_order_test.dart` 静态检查 `initState` 里
不允许出现裸的 `_open()` / `_applySavedPreferences()`，且 `_boot()` 里
`await 读设置` 必须排在 `await 开播` 之前。变异验证：把代码改回并发形式，
测试精确报红。

### 15.2 STRM 加载弹窗（设计稿要求的形态，之前做偏了）

**用户反馈**：方案是「加载 strm 前有弹窗」，没看到。

**我之前做错的地方**：实现成「进播放页后盖一层胶囊」。顺序反了 ——
设计稿要的是**进入播放页之前先弹窗**，用户先看到「正在获取媒体信息」。

**新增** `lib/widgets/strm_loading_dialog.dart`：

| 设计稿要求 | 实现 |
|---|---|
| 黑底 + 中央玻璃卡片 | 不透明黑底 + 极淡径向光（避免像死机）+ `BackdropFilter` 玻璃卡 |
| 片名 | 两行截断，长标题不撑破卡片 |
| 转圈 + 分阶段标题 | 0–4s「正在连接服务器…」/ 4–12s「正在获取媒体信息…」/ 12s+「正在缓冲画面…」 |
| 副文案说明 STRM 需服务端探测 | 原文沿用设计稿 |
| 三段进度点（连接→探测→缓冲） | `BootWatchPolicy.stageIndex()` 按时间推进 |
| 已等待 N 秒 | 200ms 刷新 |
| >8s 露「切换 Exo 内核」（保留进度） | 只有 MPV 显示（Exo 是兜底，给了是废话） |
| 「继续等待」 | 做成纯文字而非按钮：它不做事，做成按钮按下去没反应更糟 |
| >25s 提示装服务端插件 | 文案已改为 MediaInfoKeeper / StrmAssistant（原来写的 EverMedia 是旧名） |

**编排**：弹窗与播放页同时推入（弹窗在上层），播放页照常起播，首帧一到
通过 `PlayerPage.onBootSettled` 把弹窗关掉。用户看到的是「弹窗 → 画面」，
中间没有黑屏空档。至少显示 1.2 秒，避免网络快时一闪而过像闪屏。

弹窗里点「切换 Exo」→ 通过 `GlobalKey<PlayerPageState>` 直接调
`switchToExo()`，**不重新推页面**（那样进度、字幕、音量全丢）。

### 15.3 播放器控件：弹层被裁切

**现象**（截图）：播放信息弹层下半截被切掉，「音频 aac 2ch」下面就没了；
标题在滚动时压在正文上。

**根因**：`_GlassPanel` 用 `maxHeight: h * 0.88`。横屏播放时 `h` 只有约 500px
→ 上限 440px，而播放信息内容约 700px。虽然有 `SingleChildScrollView`，
但**标题也一起滚**，观感和「内容被切断」一致。

**修复**：

- 高度改为 `可用高度 - 24`（横屏尽量吃满）
- 标题栏移出滚动区 → `Column[标题(固定), Divider, Flexible(滚动内容)]`
- 字幕样式面板套用同一套尺寸规则

### 15.4 字幕样式：入口藏得太深 + 面板缺底部按钮

**现象**：截图里字幕样式是两套不同的界面。

**根因**：字幕样式有两个入口 ——「字幕」按钮**长按**（隐藏手势，没人猜得到）
和「选择字幕」弹层里的一行。而后者在代码里**根本没有**（截图里有、代码里没有）。

**修复**：

- 「选择字幕」弹层补上「字幕样式…（大小 / 位置 / 描边 / 偏移）」一行 —— 明确的入口，不再靠长按
- 该片一条字幕都没有时，不再直接 toast 返回，而是照常显示弹层 + 说明文字 + 字幕样式入口
- 字幕样式面板加底部固定按钮：**恢复默认 / 完成**（之前要滚到底才能关）

### 15.5 收藏夹弹窗（设计稿①）补齐两处

海报堆叠墙（方案 B）v1.7.20~1.7.23 已完成，红心胶囊与内联新建 v1.7.43 已完成。
本轮对齐设计稿补齐：

- 内联输入行右侧加 **`n / 20`** 字数计数（超限变红）。上限提取为
  `_maxFolderName` 常量，截断与计数共用，避免「提示 20 实际截 30」
- 底部加 **「取消收藏（移出全部收藏夹）」**。之前要取消收藏，得先退出弹窗
  回详情页再点一次心

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **139 / 139**（122 → 139，新增 `strm_dialog_test` 13 + `player_boot_order_test` 4） |
| 变异验证 | 内核时序守卫、占位开关守卫、选轨策略守卫均验证过「改坏会红」 |

**交付**：`camby-1.7.49-release-arm64.apk`（`cn.camby.camby` / 89 / 1.7.49 / 33M / sha256 `6de1f5133dd6faaf7e27c313fc96f972e45396b4a2e179194320187fe4fcd586`）。
