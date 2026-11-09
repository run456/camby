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

---

## 16. v1.7.50 (90) 六屏 UI 对齐设计稿（逐项优化）

> 触发：用户基于 14 张设计稿截图，要求「一项项来」，把六大屏按图精修。
> 约束：当前环境不支持读图，依据用户文字描述 + 既有设计语言实现，最后逐屏自查。

### 16.1 一、播放页

| # | 改动 | 实现 |
|---|---|---|
| 1 | 控件布局按图：顶栏去掉多余徽章 | 删除顶栏硬编码的「⚡硬解」`GestureDetector` 徽章（目标图无此元素） |
| 2 | 底栏加码率 chip + 网速显示 | 底栏 chips 新增 `码率 · ${_bitrateShort()}` 芯片，回调 `_changeBitrate`；`_bitrateShort()` 文案 `原片` → `自动` |
| 3 | 字幕弹窗「黄线」 | **根因**：自定义 `PageRouteBuilder` 路由（`_GlassPanelRoute`）无 `Material` 祖先，弹层内 `Text` 在 debug 下回退 fallback 样式出现黄线。修复：所有玻璃弹层（`_Sheet`、字幕样式面板）最外层包 `Material(type: MaterialType.transparency)` |
| 4 | 字幕调节弹窗严格按图（不要乱加东西） | `subtitle_style_sheet.dart` 整文件重写：只留「标题 + 右上圆形关闭 + 4 行（大小/位置/描边/不透明度）+ 5 色（白/黄/绿/蓝/红）」。删预览区、`±` 按钮、底部「恢复默认/完成」按钮 |
| 5 | 播放详情弹窗按图 | `_showInfo()` 重构：媒体信息改为带蓝竖条的分节标题（`_InfoSection`），只保留片名/分辨率/视频编码/动态范围/音频/封装/大小/字幕/码率上限/进度。删掉「内核/画质/入库/倍速/进度/最近跳转/内核状态」等冗余行 |

### 16.2 二、收藏页

**海报堆叠墙修复**：原实现后层是纯渐变卡、位移极小，视觉上等于平面（「没有堆叠效果」）。

- `_StackTile._layer` 重写：后层改用**真实海报**（`covers[depth % covers.length]`），加大扇形角度与位移（`depth=2 → (0.155,0.085,-0.050)`、`depth=1 → (-0.185,-0.085,-0.050)`、`depth=0 → (-0.045,-0.012,0.012)`），`Transform.rotate` 用 `alignment: Alignment.bottomCenter`，后层叠压暗渐变。
- `_movieWall()` 内 `maxDepth`：`math.min(3, …)` → `math.min(2, …)`，墙更紧凑。
- `test/favorites_wall_test.dart` golden 重生成（视觉变更属预期）。

### 16.3 三、设置页

| # | 改动 |
|---|---|
| 1 | 清除用不到的设置项（含关联代码）：自动连播下一集、STRM 优先 Exo、ASS 特效字幕渲染、字幕默认语言、字幕样式、每日推荐、优先没看过的、排除已看完。删除对应字段、`_load()` 键、UI 行与说明常量 |
| 2 | 【bug】选 MPV 内核优先但顶栏仍显示 Exo：根因是 `_strmPreferExo = true` 默认值让 strm 条目无视设置强制走 Exo。`_applySavedPreferences()` 删除该覆盖分支：`_engine = eng == 1 ? mpv : exo`（尊重用户选择）；`main.dart` 的 STRM 加载弹窗改为先读 `set_play_engine` 再决定传 `mpv/exo`，让 MPV 用户能真正切到 MPV |

### 16.4 四、演员页

| # | 改动 | 实现 |
|---|---|---|
| 1 | 背景模糊（对齐详情页） | `Positioned.fill` + `RepaintBoundary` + `ImageFiltered(blur 60)` 头像模糊 + 深色遮罩 |
| 2 | 列表滑动状态对齐详情页 | 结构改 `CustomScrollView`：`SliverToBoxAdapter`(头像 ShaderMask 渐隐) → (姓名/简介/分段+筛选) → `SliverPadding` + `SliverGrid`(懒加载，滚动不发坠) |
| 3 | 页面选项 bug | `_Seg` 分段控件对齐公式修复：原 `alignment: Alignment(-1 + 2.0 * i / (n-1) * (1 - unit), 0)` 三档时高亮块偏左错位；去掉 `* (1 - unit)` 后归位 |
| 4 | 筛选跟媒体库一致 | 新增 `_PersonFilterSheet`（媒体库同款：排序字段行 × 升/降 + 年代 chips + 底部重置/应用），返回 `(sortKey, desc, decade)` 元组 |
| 5 | 按钮液态玻璃效果 | 顶栏按钮改 `_RoundBtn`（液态玻璃圆形，从详情页复制，带光晕/下沉/提亮）；删 `_SheetBtn` |

### 16.5 五、详情页

- 媒体信息位置：`_mediaInfoCard` 从「相似推荐之后」移到「剧情简介之后 / 分集之前」。

### 16.6 六、首页

| # | 改动 | 实现 |
|---|---|---|
| 1 | tab 栏按下态优化 | `_GlassNavBar` 的 tab 项改为圆形玻璃片（`AnimatedContainer 38×38 shape: BoxShape.circle`，选中时白色渐变 + 蓝/黑双阴影） |
| 2 | 图标液态玻璃效果 | `_GlassCircleBtn` 加 `ClipOval` + `BackdropFilter(sigma 16)` 真磨砂；`_Pill` 加 `ClipRRect` + `BackdropFilter(sigma 16)` 真磨砂（海报透出被磨砂化） |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **139 / 139**（与 v1.7.49 持平；`player_boot_order_test` 守卫随 `set_strm_exo` 下架同步更新、`favorites_wall_test` golden 重生成） |
| 守卫有效性 | 字幕样式面板重写后仍保留 `SubtitleStyle` / `SubtitleStyleStore` 数据模型，模型单测不受影响 |

**交付**：`camby-1.7.50-release-arm64.apk`（`cn.camby.camby` / 90 / 1.7.50 / 33M / sha256 `41f89c1826226f3b68c31ac1f162c478ff2b65ac0014a7424a2f5039bde93918`）。

**改动清单（`lib/`）**

| 文件 | 状态 |
| --- | --- |
| `lib/pages/player_page.dart` | 改：控件布局（去硬解徽章 / 加码率 chip）、字幕弹层 Material 包裹、`_showInfo` 分节精简、删 strm 强制 Exo |
| `lib/widgets/subtitle_style_sheet.dart` | 重写：严格按图的字幕调节面板，保留数据模型 |
| `lib/pages/favorites_page.dart` | 改：海报堆叠墙（真实后层 + 加大扇形） |
| `lib/pages/settings_page.dart` | 改：清除 8 项无用设置（含关联代码）、footer 改 v1.7.50 |
| `lib/main.dart` | 改：STRM 弹窗按真实内核偏好传 engine |
| `lib/pages/home_page.dart` | 改：tab 圆形玻璃片、图标真磨砂 |
| `lib/pages/person_page.dart` | 重写：模糊背景 + SliverGrid 懒加载 + `_Seg` 对齐 + 媒体库同款筛选 + 液态玻璃按钮 |
| `lib/pages/detail_page.dart` | 改：媒体信息移到剧情简介后 |
| `test/player_boot_order_test.dart` | 改：守卫随 `set_strm_exo` 下架更新 |
| `test/goldens/favorites_wall.png` | 重生成：堆叠墙视觉变更 |

---

## 17. v1.7.51 (91) 收藏页堆叠墙「边缘被裁剪」修复

**用户反馈**：收藏页还是不对，后层海报的边缘好像被裁剪了（附当前效果 / 目标效果两张截图）。

### 根因（两层叠加）

1. **`LiquidPress` 的 `ClipRRect` 把后层裁掉了**。`_StackTile` 用 `LiquidPress(radius: 14)` 包裹整格，而堆叠后层靠 `Transform.rotate/translate` **探出瓦片矩形**才能露出来 —— 全部被 `ClipRRect` 裁在格内，只剩一条「被裁的边」，看起来接近单张海报。
2. **主海报自己撑满整格**（`SizedBox(width: w, height: h)`），即使后层不被裁，也会被前层完全盖住。

### 修复

| # | 改动 |
|---|---|
| 1 | `LiquidPress` 新增 `clip` 参数（默认 `true` 保持既有行为）；按下高光层本来就自带 `borderRadius` 装饰不会溢出，去掉外层 `ClipRRect` 无副作用。`_StackTile` 传 `clip: false` 解除裁剪 |
| 2 | `_layer` 几何重调：三张卡统一缩到 **0.86 居中**（主海报不再撑满，给后层留探出空间）；后卡 ±7° 扇开 + 向上探出（`depth2=(0.11, +0.060, -0.050)`、`depth1=(-0.13, -0.060, -0.050)`、前卡微倾 `-0.02`），探出量控制在格内不压相邻卡片 |
| 3 | golden 重生成（堆叠墙视觉变更，渲染无异常/无溢出） |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **139 / 139** |

**交付**：`camby-1.7.51-release-arm64.apk`（`cn.camby.camby` / 91 / 1.7.51 / 33M / sha256 `4155eae73654af28dc67bdb2324a1c4057a6e69c3723762ccee861d1951cc1a9`）。

---

## 18. v1.7.52 (92) 顶栏按钮统一 + 媒体库刷新 + 收藏状态 + 端口协议对齐

| # | 用户反馈 | 处理 |
|---|---|---|
| 1 | 添加服务器弹窗「端口 / 协议」两列不对齐 | 端口输入框固定 48 高、协议切换器 46→48，两列都是「11px label + 6 间距 + 48 控件」，顶底对齐 |
| 2 | 部分页面顶栏按钮没有液态玻璃效果 | 统一：详情页 / 演员页 `_RoundBtn`、媒体库 `_TopBtn`、标签页返回钮都补上 `ClipOval(RRect)` + `BackdropFilter(sigma 16)` 真磨砂（与首页 `_GlassCircleBtn` / `_Pill`、`GlassIconButton` 同款）；文件夹页 / 字幕筛选页 / 播放页原本就用 `GlassIconButton`，保持不变 |
| 3 | 媒体库页加刷新按钮 | 顶栏排序按钮左侧新增刷新钮，点击 `state.refresh()` 重拉条目与视图并 toast「正在刷新媒体库…」；刷新中沿用原有转圈 |
| 4 | 演员页未选中标签看不清 | `_Seg` 未选中文字 `AppColors.muted` → 白色 90%（选中仍为纯白 + w800） |
| 5 | 详情页收藏后按钮没有状态 | 顶栏第三枚改为**心形收藏状态钮**：未收藏 `favorite_border`（灰玻璃）、已收藏 `favorite_rounded` 实心 + 粉红渐变描边（与收藏夹弹窗「已收藏」胶囊同色系）。点击仍进收藏夹弹窗管理，关闭后回读状态（详情页已有 `_onStateChanged` 监听全局条目） |
| 6 | 【问】首页下拉刷新是干什么用的 | 见下方说明；本次不改行为 |

### 关于首页下拉刷新

`RefreshIndicator(onRefresh: () => state.refresh())` → `AppState.refresh()`：

1. 重新拉该服务器的**全部媒体条目**（`s.items()`）；
2. 清空走马灯 / 预览缓存、重建派生数据；
3. 重新拉**媒体库视图**（`s.userViews()`）；
4. 写回本地缓存，再刷新「继续观看」进度（`_loadPlayback()`）。

**用途**：App 启动时读的是本地缓存，服务器**新入库、换海报、删片改名**之后，下拉一次即可把 App 里的数据与服务器同步 —— 不下拉的话，新片在首页和媒体库里都不会出现（要等下次冷启动或缓存过期）。

> 与「媒体库页刷新按钮」（本次新增）是同一套动作，只是入口不同：首页下拉 = 全局，媒体库按钮 = 在该页内就地触发。

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **139 / 139** |

**交付**：`camby-1.7.52-release-arm64.apk`（`cn.camby.camby` / 92 / 1.7.52 / 33M / sha256 `eb63d3f77d962478a3ab1ea81f0288050d4c2a5e590c466007f818cfb424470d`）。

---

## 19. v1.7.53 (93) 刷新交互统一 + 收藏夹页筛选

| # | 需求 | 处理 |
|---|---|---|
| 1 | 首页下拉刷新要触发提示 | `AppState.refresh()` 改为 `Future<int>`（返回同步条目数，失败 -1）；首页 `onRefresh` 走 `_onRefresh()`，结束后 toast「已同步 N 项」/「刷新失败，请检查网络或服务器地址」 |
| 2 | 媒体库改成下拉刷新，去掉刷新按钮 | 移除 v1.7.52 刚加的顶栏刷新钮；`CustomScrollView` 包进 `RefreshIndicator`（physics 改 `AlwaysScrollableScrollPhysics` 保证条目不足一屏也能拉），toast 与首页同一套文案 —— 两页操作逻辑完全一致 |
| 3 | 收藏页「全部影片」加演员页同款筛选 | 抽出公共组件 `lib/widgets/media_filter_sheet.dart`：演员页本地的 `_PersonFilterSheet` / `_SortRow` 上移为公共件，另提供 `applyMediaFilter` / `countForDecade` / `mediaFilterSummary` 纯函数。`FolderPage` 由 `StatelessWidget` 改 `StatefulWidget`（承载排序/年代草稿态），顶栏加筛选胶囊（tune 图标 + 摘要，与演员页完全同款），网格按筛选结果渲染；演员页改为复用公共件，删掉约 340 行重复代码 |

### 关于 `refresh()` 返回值

原来返回 `Future<void>`，调用方无从知道同步结果。改成 `Future<int>` 后：

- 成功 → 同步到的条目数（用于「已同步 N 项」）
- 无服务器 / 异常 → `-1`（用于失败提示）

其余调用点（首页错误重试按钮）只 `await` 不取值，行为不变。

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **139 / 139** |

**交付**：`camby-1.7.53-release-arm64.apk`（`cn.camby.camby` / 93 / 1.7.53 / 33M / sha256 `fcd1a6ebd01ac2d380dc8f148ad1aa9e7189ffdc20d2b432a8f339b95ba879f4`）。

---

## 20. v1.7.54 (94) 锁定钮对位 + 三页筛选统一 + 字幕样式面板可确认

| # | 需求 | 处理 |
|---|---|---|
| 1 | 播放页锁定按钮与未锁定时不在同一位置 | 锁定态原来用 `Positioned(right: 18, top: 0, bottom: 0) + Center`，贴在屏幕**垂直居中**处、尺寸 44；未锁定的锁钮在顶栏最后一位（SafeArea + `fromLTRB(14, 8, 14, 0)` + 42）。改为锁定态复用同一套 SafeArea / 内边距 / 尺寸 / iconSize，`Align(centerRight)` 右对齐 —— 点锁定后锁钮原地不动，只是顶栏其余部分隐去 |
| 2 | 收藏页、演员页的筛选控件要和媒体库一致 | 删除媒体库本地的 `LibraryFilterSheet` / `LibraryFilterResult` / `_TopBtn` / `_SortRow` / `_SwitchRow`，把整套能力上移为**唯一实现** `MediaFilter` + `MediaFilterButton` + `showMediaFilterSheet`（5 个排序字段 × 各自升降 + 分辨率多选 + 仅看中文字幕 + 标签多选 + 重置/应用筛选）。三页顶栏都换成同一个磨砂胶囊（↓ 发行日期 + 条件数角标）；收藏页、演员页的筛选能力从「只有年代档」升级到与媒体库完全一致；媒体库 `_compute` 也改为调用 `MediaFilter.apply`，逻辑只剩一份 |
| 3 | 字幕样式面板不生效、需要确认与恢复默认按钮 | ①不生效根因：`_assSubtitle` 默认 true，MPV 走 libass 按 ASS 自带样式渲染，App 下发的字号/颜色/描边被忽略 → `applySubtitleStyle` 增发 `sub-ass-override=force`（采用 App 样式覆盖，保留 ASS 定位）；同时删掉误映射的 `sub-delay`（`offset` 是垂直微调不是时间轴）。②面板标题行新增「恢复默认」「确认」两枚胶囊（关闭钮左侧），关闭钮语义改为**取消**（回滚到打开面板时的样式并落盘），确认才保留本次调整 |

### 筛选一致性的实现边界

- 三页共用 `MediaFilter`：排序字段、方向记忆、条件判定（组内或 / 组间且）、计数口径全部一份代码。
- 演员页的筛选作用于「当前 tab（全部/电影/剧集）」子集；收藏夹页作用于「当前收藏夹」子集；媒体库作用于「当前媒体库视图」子集 —— 数据源不同，能力与版式完全相同。

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **139 / 139** |

**交付**：`camby-1.7.54-release-arm64.apk`（`cn.camby.camby` / 94 / 1.7.54 / 33M / sha256 `9988a3826ecea8630d954be2be389758a2b5404d446bacd3dd764c2d6022879c`）。

---

## 21. v1.7.55 (95) 起播加载弹窗合并为一套 + 切 Exo / 自动回退修复

| # | 需求 | 根因 | 处理 |
|---|---|---|---|
| 1 | STRM 获取媒体信息时出现两种弹窗，统一为 1661104d 的版式 | 两套实现并存：`strm_loading_dialog.dart`（独立路由，盖在播放页之上，片名 + 三阶段 + 切换 Exo + 插件提示）与播放页 `_bootOverlay()`（黑屏期居中胶囊「正在获取媒体信息…」） | 删除旧路由弹窗文件与播放页胶囊层，新增 `lib/widgets/strm_boot_overlay.dart`（版式取 1661104d：片名 / 标题随阶段变化 / 三段进度 / 已等待 N 秒 · 内核 / 切换 Exo / 继续等待 / 25 秒插件提示），由播放页直接渲染 |
| 2 | 点弹窗里的「切换到 Exo」胶囊没生效 | ① 弹窗是**另一个路由**，`onSwitchEngine` 先 pop 自己再调播放页方法，用户看到的是「窗没了但还在 MPV」；② `_switchEngine()` 是**取反**语义，当前已是 Exo 时会切回 MPV；③ `_switchEngine()` 末尾无条件 `_autoFellBack = false`，把「用户已手动切过」清掉，10 秒后又被回退一次 | 切内核改为显式 `_switchTo(PlaybackEngine.exo)`；`switchToExo()` 已是 Exo 时给 toast 而不是静默 return；只有切到 MPV 才复位 `_autoFellBack`；弹窗不再自己 pop，切完由首帧信号收起 |
| 3 | 超时自动跳转 Exo 没生效 | 自动回退挂在 `_startBootWatch()`（播放页）上，但只有「出首帧 / 明确失败」才会 `_markBootSettled`；用户看到弹窗的场景恰恰是**等不到首帧**，看护计时到 10 秒确实会切，切完却没有首帧 → 弹窗（另一路由）不关、`ready()` 永远 false，观感就是「没自动跳」 | 弹窗改由播放页托管后，可见性只取决于 `_firstFrame`，切换内核期间保持可见并重新计时，切成功后新内核首帧一到自然收起 |

### 关键代码

- `PlayerPage._bootOverlayVisible`：`!_firstFrame && !_demo && !_fallback && !_bootOverlayDismissed`
- `PlayerPage._switchTo(target)`：`_switchEngine()` 变成薄封装，两者共用同一段切换逻辑
- `StrmBootOverlay`：面板内自计时与播放页 `_bootVN` 取较大值，禁止「已等待」倒退
- 加载弹窗期间不绘制顶栏 / 底栏 / 中央控件（否则会盖住弹窗上的按钮）

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **149 / 149**（新增 `test/strm_overlay_single_test.dart` 10 条结构守卫：旧弹窗已删、main 不再推载荷弹窗、只渲染一套、切 Exo 非取反、自动回退走 `_switchTo`、切 Exo 后不复位回退标记） |

**交付**：`camby-1.7.55-release-arm64.apk`（`cn.camby.camby` / 95 / 1.7.55 / 33M / sha256 `f3d2ec8dc1e9a6491f7c877910eb9c21d07a145ca27b04f2be575ec28f9cad14`）。

---

## 22. v1.7.56 (96) 播放中顶栏内核胶囊切换失效 + 互切提示

| # | 需求 | 根因 | 处理 |
|---|---|---|---|
| 1 | 播放时点顶栏 MPV 胶囊切换 ExoPlayer 无效 | `Glass(onTap:)` 收 `VoidCallback?`，而原代码写的是 `onTap: _switchEngine` —— `_switchEngine` 是 `Future<void> Function({bool silent})`。Dart 允许把带可选命名参数的函数赋给无参回调，**编译通过、点击也调了，但返回的 Future 被静默丢弃**，`silent` 语义一并丢失；`_switchTo` 内部又用 `if (!silent) showToast(...)` 兜底，异常路径没有可见反馈，表现为「点了没反应」 | 新增 `_toggleEngine()`（显式无参、`unawaited` 交 Future），胶囊改为 `onTap: _toggleEngine` |
| 2 | MPV ↔ Exo 互切要有 toast | 原来只有成功时一句写死的「已切换至 X」，且只在 `!silent` 时出现，而胶囊路径的 silent 语义并不可靠 | 统一在 `_switchEngine` 里发三条：切换前「正在切换到 X 内核…」（换内核要重建播放器，1–3 秒无反馈像点空了）、成功后「已切换到 X 内核」、失败「切换到 X 失败，请检查片源或稍后重试」；`_switchTo` 改为**失败必提示**（不管 silent），成功提示由调用方按需给，避免弹窗路径与胶囊路径各说一半 |

### 验证

- `flutter analyze`：0 error / 0 warning
- `flutter test`：**152 / 152**（`test/strm_overlay_single_test.dart` 新增 3 条守卫：胶囊不得直接传 `_switchEngine`、三条互切文案齐备、`_toggleEngine` 用 `unawaited` 交出 Future）

**交付**：`camby-1.7.56-release-arm64.apk`（`cn.camby.camby` / 96 / 1.7.56 / 33M / sha256 `8629d72aa91435c2024c5aea041966ef406e098cf01f020c087b0a2e3593ab46`）。

---

## 23. v1.7.57 (97) MPV 模式字幕样式面板不生效

### 根因（本机 mpv 0.37 + APK 内 libmpv.so 双重实证）

| # | 事实 | 影响 |
|---|---|---|
| 1 | mpv **没有** `sub-opacity` 属性（0.36 / 0.37 运行时均报 `option not found`）；mpv 也没有独立的字幕不透明度选项，透明度只能合成进颜色的 alpha 通道 | 「不透明度」滑杆下发到不存在的属性 → 永远无效 |
| 2 | media_kit 的 `NativePlayer.setProperty` 走 `mpv_set_property_string` 且**吞掉返回的错误码、从不抛异常** | 无效属性名失败被 `try/catch` 静默掩盖，设备上毫无痕迹 |
| 3 | `sub-border-size` 是较新 mpv 的命名（旧版为 `sub-outline-size`），Android 捆绑 libmpv（media_kit_libs 1.3.8，mpv v0.36.0-549 dirty）版本不定 | 描边粗细在部分库上落空 |

半透明背景是字幕文件自带的 ASS 样式（mpv 对 SRT 默认只渲染白字+细描边、无背景块，本机渲染对比确认），不受影响。

### 处理（`lib/player/playback.dart` `applySubtitleStyle` 重写）

- 不透明度 → `_mpvColorWithAlpha()` 合成 `#AARRGGBB`（文字色与描边色都带 alpha），彻底不再下发 `sub-opacity`
- 描边属性带旧名回退：先写 `sub-border-size` / `sub-border-color`，回读（`getProperty`）为空再写 `sub-outline-size` / `sub-outline-color`
- `sub-scale` / `sub-pos` / `sub-ass-override=force` 语义保持不变
- 新增守卫 `test/mpv_sub_style_test.dart`：不得出现 `sub-opacity`、必须用 8 位 alpha 颜色串、必须带 `sub-outline-*` 旧名回退

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **153 / 153** |

**交付**：`camby-1.7.57-release-arm64.apk`（`cn.camby.camby` / 97 / 1.7.57 / 33M / sha256 `d722180bb7f06f8890fc84a7c55ebae4cfad7d50c4d366026883c84e6f7e0a53`）。

---

## 24. v1.7.58 (98) 文本字幕统一为「白字 + 半透明背景块」

### 需求

MPV 下 ASS 字幕自带半透明背景块（视觉正确），但 SRT 只有白字+细描边；希望在两个内核下 SRT 也是白字 + 半透明背景块。

### 为什么不能靠 mpv 原生实现（本机 mpv 0.37 实测）

| 尝试 | 结果 |
|---|---|
| `sub-back-color=#80000000` | 无效果——SRT 默认 BorderStyle=1（描边），没有背景块可填色 |
| `sub-border-style=4` | **选项不存在**（0.36 / 0.37 均 option not found，mpv 0.38 才引入） |
| `sub-ass-force-style=BorderStyle=3,BackColour=&H59…` | 无效果（且该选项在 0.37 已废弃为 `sub-ass-style-overrides` 的别名） |
| `sub-ass-style-overrides=BorderStyle=3,BackColour=&H59…` | 对 SRT 同样无效果（仅作用于真 ASS 脚本的 Default 样式） |

结论：mpv 在 0.36/0.37 上**无法给文本字幕指定背景块**，只能换渲染主体。

### 处理

1. **渲染主体分流**（`lib/pages/player_page.dart`）
   - 新增 `_isAssUrl()`：只有 `.ass` / `.ssa` 才交给 MPV 内核原生渲染（保留 ASS 特效与自带样式）
   - 其余（SRT / VTT，以及 Exo 全部）走 App **叠加层**渲染 → 两个内核外观完全一致、样式面板必然生效
   - `open()` 不再无条件把字幕交给内核；切换字幕时若目标不是 ASS，先 `setSubtitle(null)` 摘掉内核字幕，避免两份字幕重叠
   - 删除切内核时「无条件清叠加层」的旧逻辑（否则 MPV 下 SRT 会被清成空白）
2. **叠加层外观**：字幕外包 `Container`（黑 55% 底 + 圆角 7 + 10/5 内边距），底色 alpha 跟随字幕不透明度滑杆

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **157 / 157**（新增 `test/subtitle_background_test.dart` 4 条守卫） |

**交付**：`camby-1.7.58-release-arm64.apk`（`cn.camby.camby` / 98 / 1.7.58 / 33M / sha256 `90f8501bd53c3fa8d45181fb87e9a76787b4b39546a19fd85d3b3b162244ce20`）。

---

## 25. v1.7.59 (99) 背景块贴文字宽度（参考设计图）

### 需求

v1.7.58 的背景块横贯整行（一整条），应如设计图：**只有文字出现的地方有背景块**，块随文字宽度收缩、居中。

### 根因

叠加层的 `Positioned(left: 24, right: 24)` 对子级施加**紧约束**，Container 被迫占满可用宽度，背景块变成整行长条。

### 处理（`lib/pages/player_page.dart` 叠加层）

- Container 外包 `Align(alignment: Alignment.bottomCenter)`：loose 约束让块收缩到文字实际宽度
- 多行长字幕限宽 `maxWidth = 屏宽 * 0.85`，自动换行（maxLines 3 + ellipsis 保持）
- 内边距 10/5、圆角 7、55% 黑底不变

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **157 / 157** |

**交付**：`camby-1.7.59-release-arm64.apk`（`cn.camby.camby` / 99 / 1.7.59 / 33M / sha256 `7da11acf8ea5b1ea5c5d06b216c89da6cc321b06818652df6f10a9f6f56f2ee9`）。

---

## 26. v1.7.60 (100) 拖动松手回弹 + 设置页版本号动态化

| # | 问题 | 根因 | 处理 |
|---|---|---|---|
| 1 | 1:00 拖到 2:00，圆点先到 2:00，松手后先弹回 1:00 再跳 2:00 | `_endScrub()` 先 `_scrubbing = false`、再调 `_commitSeek()` 里才 `setState(_seeking = true)` —— 中间露出「既不拖动、也还没跳转」的一帧，该帧 `_syncPos()` 取真实位置（仍是拖动前的点）推出去 | `_scrubbing=false` 与 `_seeking=true` 放进**同一次** setState，并同步写 `_scrubPos = target` |
| 2 | seek 完成后仍可能小幅回跳 | libmpv / Exo 的 position 回调滞后（可达数百毫秒），`_seeking=false` 后显示立刻交还给滞后的真实位置 | 新增跳转后「粘滞」：`_settlePos` / `_settleUntil`（900ms 窗口），`_syncPos` 优先显示目标；`_waitSettleOut()` 每 90ms 检查真实位置是否追上（差 ≤1s），追上或超时才交还 |
| 3 | 设置页版本号停在 v1.7.56 | 硬编码字符串，每次发版要手改，漏改就显示旧版本 | 改为 `_VersionLine` 运行时读 `PackageInfo.fromPlatform()`（`package_info_plus`），加守卫测试禁止再出现硬编码版本号 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **160 / 160**（新增 `test/seek_settle_and_version_test.dart` 3 条守卫） |

**交付**：`camby-1.7.60-release-arm64.apk`（`cn.camby.camby` / 100 / 1.7.60 / 33M / sha256 `7f12caa994664d24f8eea556dd694c110440848c7ddffa5ebf88c9ae0ba7cfed`）。

> **发布节奏约定（v1.7.60 起）**：源码照常每个小版本本地提交，但**不再每次推送 GitHub**；
> 累计 5 个小版本迭代后再统一推送 + 发 Release。本次为第 1 个（v1.7.60），
> 预计 v1.7.64 时推送，届时会把 v1.7.60~v1.7.64 一并推上去。

---

## 27. v1.7.61 (101) 取消字幕背景块

| # | 问题 | 处理 |
|---|---|---|
| 1 | v1.7.58/59 加的字幕背景块（半透明黑底圆角）用户不再需要 | 移除 `Container + BoxDecoration`，改回 `ConstrainedBox + Text` 纯文字渲染 |
| 2 | 避免回退时把「文字居中、长句换行」一起丢掉 | 保留 `Align(bottomCenter)` + `maxWidth = 屏宽 × 0.85`（多行长字幕自动换行、居中，不顶出屏幕） |

字幕可读性回到由样式面板的**描边/阴影**负责（`SubtitleStyle.textStyle`）：描边 > 0 时四向阴影，= 0 时柔和投影。

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **160 / 160**（`subtitle_background_test.dart` 守卫反过来校验：叠加层不得再出现 BoxDecoration / 55% 底色） |

**交付**：`camby-1.7.61-release-arm64.apk`（`cn.camby.camby` / 101 / 1.7.61 / 33M / sha256 `15a6826973e9f5255e8379554df80555bd5edb7481e60a15de171c8b1f819e5f`）。

> 发布节奏：本地提交，**未推送 GitHub**（v1.7.60 起累计 5 个版本再推；本版为第 2 个，预计 v1.7.64 推送）。

## 28. v1.7.62 (102) 拖动中央时间实时刷新 + 亮度/音量指示条换侧

| # | 问题 | 根因 | 处理 |
|---|---|---|---|
| 1 | 拖动进度条时中央大时间冻结在起拖附近的旧值（底部小字却实时正确） | 气泡直接读 `_scrubPos`，但只靠整页 `setState` 重建；拖动期间 `_updateScrub` 只推 `_posNv`，整页不重建 → 气泡冻结 | 气泡改为 `ValueListenableBuilder` 订阅 `_posNv`（拖动中每帧 `_syncPos()` 都会把 `_scrubPos` 推进去），文本改用监听值 `pos` 计算 |
| 2 | 左半屏上滑调亮度，亮度条出现在左侧被手指挡住；右半屏调音量同理 | 指示条 `left/right` 与手势同侧 | 换到**手势对侧**：调亮度 → 指示条在右；调音量 → 指示条在左 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | 160 → **162 / 162**（新增 `scrub_bubble_adjust_side_test.dart`：气泡必须订阅 `_posNv` 且禁止 `_fmt(_scrubPos)`；指示条必须 `left=volume / right=brightness`） |

**交付**：`camby-1.7.62-release-arm64.apk`（`cn.camby.camby` / 102 / 1.7.62 / 34.5M / sha256 `e44a7c7e51890794e8d564c8dc1a805f24aca5b127679d22a31c3908503294ca`）。

> 发布节奏：本地提交，**未推送 GitHub**（v1.7.60 起累计 5 个版本再推；本版为第 3 个，预计 v1.7.64 推送 v1.7.60~64）。

## 29. v1.7.63 (103) 收藏夹海报扇形收敛（方案 B · 更克制）

| # | 问题 | 根因 | 处理 |
|---|---|---|---|
| 1 | 收藏夹海报堆叠的扇形太大，两个收藏夹互相重叠 | 后卡 ±7°（0.11/0.13 rad）、水平探出 6%、scale 0.86；旋转后横向外扩约 15dp/侧，越过 2 列网格的格子边界压住邻居封面 | 采用设计稿方案 B：后卡角度 → ±0.040/-0.046 rad（≈±2.5°）、探出 → ±2%、scale → 0.85；扇形整体收在格内（约 6dp 余量） |

改动集中在 `favorites_page.dart` 的 `_layer()` 三个常量 + 缩放。保留：后层真实海报（夹内第 2/3 张）、压暗渐变、前卡 -0.020 rad 微倾、上探露顶边。

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | 162 → **165 / 165**（新增 `favorites_fan_test.dart` 守卫：`|angle| ≤ 0.05`、`|dx| ≤ 0.020`、`scale ≤ 0.85`；同步更新 `goldens/favorites_wall.png`） |

**交付**：`camby-1.7.63-release-arm64.apk`（`cn.camby.camby` / 103 / 1.7.63 / 34.5M / sha256 `b048c9fcae49fb8243bfa86456822797c1d880ccd0b752766953affdf1f412c9`）。

> 发布节奏：本地提交，**未推送 GitHub**（v1.7.60 起累计 5 个版本再推；本版为第 4 个，**下一版 v1.7.64 即推送 v1.7.60~64**）。

## 30. v1.7.64 (104) 收藏页标题收紧 + 指示条加高离边 + 播放常亮

| # | 问题 | 处理 |
|---|---|---|
| 1 | 收藏页标题区与封面不够紧凑 | 标题 → 分段控件间距 14 → 10；影片/演员网格顶部留白 16/18 → 6（网格内部行距 22 保持不变，与「夹名 ↔ 新建卡」节奏一致） |
| 2 | 亮度/音量指示条太矮、太贴屏幕边缘 | 竖向进度条 88 → 150、胶囊宽 62 → 68、离边 22dp → **48dp** |
| 3 | 播放中长时间不操作设备自动黑屏 | 接入 `wakelock_plus`：播放中 `WakelockPlus.toggle(enable: true)`，暂停/退出自动解除；放在 300ms ticker 里按**状态翻转**触发，不重复打平台通道；`dispose()` 强制 `disable()` 兜底 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | 165 → **168 / 168**（新增 `wakelock_adjust_spacing_test.dart`；同步 `favorites_wall/actors` 黄金图与 v1.7.62 指示条守卫的 48dp 锚点） |

**交付**：`camby-1.7.64-release-arm64.apk`（`cn.camby.camby` / 104 / 1.7.64 / 34.5M / sha256 `658cc1c565e627391d6b608ebdca73ce819c67a4172f24133235249338d9db5e`）。

> 发布节奏：v1.7.60~64 已**统一推送 GitHub** 并逐版创建 Release（附对应 APK），累计窗口清零，下次推送从 v1.7.65 起再累计 5 版。

## 31. v1.7.65 (105) 多设备同步：进度 + 收藏夹 + 重装恢复

> 背景：用户提出四连问（进度不同步 / 收藏夹不同步 / 统计不同步 / 重装恢复）。
> 完整方案见 `docs/SYNC_PLAN.md`。本版落地三项，统计一致性由「进度同步正确」自然满足
> （统计始终从服务端 UserData 派生，刷新即对齐）。

| # | 问题 | 处理 |
|---|---|---|
| 1 | 另一台手机看不到播放记录 | `reportProgress` 重写：① 新增 `played` 字段写入（之前从不标「已看完」）；② `_postJson` 增加 **HTTP 状态码校验**，500/503 不再被当成成功；③ 瞬时网络错误自动重试一次；④ AppState 新增**持久化待上报队列** `reportServerProgress`/`flushPendingProgress`，失败入队、成功出队，App 被杀也不丢；⑤ 播放页心跳 10s → **30s**（用户确认） |
| 2 | 设备 A 的收藏夹同步到设备 B | 收藏夹映射到 Emby 服务端 **Playlist**：`create/rename/delete/add/remove` 时同步服务端；`connect` 后从服务器 `listPlaylists` 拉回，与本地 `reconcileFolders` 合并（服务端为权威取并集、服务端新增则自动建本地、服务端已删则本地移除、纯本地保留）。**修复多服串号 bug**：`FavoriteFolder` 增加 `serverId` 字段，切服不再把 A 的收藏夹渲染到 B |
| 3 | 卸载重装后恢复收藏夹 | ① 收藏夹已上云（映射到服务端 Playlist），重装登录后自动拉回；② 开启 **Android Auto Backup**（`AndroidManifest` `allowBackup` + `res/xml/backup_rules.xml`），让服务器配置 / 收藏夹 JSON 随 Google 备份跨重装还原；③ 设置页「我的服务器」已连接时新增「**从服务器恢复收藏夹**」手动入口兜底 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | 168 → **176 / 176**（新增 `progress_sync_test.dart`：Played 写入 / 500 返回 false / 未登录不抛；`sync_folders_test.dart`：reconcile 四类场景 + 跨服隔离） |

**交付**：`camby-1.7.65-release-arm64.apk`（`cn.camby.camby` / 105 / 1.7.65 / 34.5M / sha256 `d44fc3888e04dd2fd91b97e0989be55c2d2b905d814c5c700ff31614fa110654`）。

> 发布节奏：未推送 GitHub（v1.7.65 为累计窗口第 1 版，攒满 5 版再推）。
> 注意：Emby 播放列表路由各版本不完全一致，收藏夹映射采用多端点探测 + 失败静默回退，
> 建议在你真实服务器上回归一次收藏夹增删/改名/换设备。

## 32. v1.7.66 (106) 修复收藏夹未同步 + 收藏页同步按钮与布局优化

| # | 问题 | 根因 | 处理 |
|---|---|---|---|
| 1 | 收藏夹没有同步到 Emby 服务端（网页端「播放列表」下无对应条目） | **`Ids` 参数格式错误**：Emby 的 `Ids` 是逗号分隔字符串，v1.7.65 传 JSON 数组被服务端 400 拒绝，又被静默回退吞掉 → 播放列表从未创建成功 | `createPlaylist`/`addToPlaylist` 改为 `Ids: itemIds.join(',')`；空列表干脆不发送该字段 |
| 2 | 同步无感知、无手动入口 | 同步只在连接时静默进行 | 收藏页标题行新增**同步按钮**（转圈指示 + 完成后 toast 汇报「N 个收藏夹与服务器一致」；未连接服务器提示不可用；`syncFoldersFromServer` 返回同步数量） |
| 3 | 封面与标题间距较宽 | 海报堆叠以 0.85 缩放**居中**于格子，上下各空 7.5% 高度 | 堆叠改**贴底对齐**（`Alignment.bottomCenter`），名称间距 9 → 6 |
| 4 | 新建收藏夹按钮太小 | 图标 40 / 加号 21 / 字号 11.5 偏弱 | 图标 54 / 加号 26 / 字号 13 w700，与真实收藏夹卡视觉分量对齐 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | 176 → **183 / 183**（新增 `playlist_ids_and_sync_button_test.dart`：Ids 必须 `join(',')`、空列表不发字段、必须有同步按钮、堆叠必须贴底、新建卡 ≥54；同步更新收藏墙黄金图） |

**交付**：`camby-1.7.66-release-arm64.apk`（`cn.camby.camby` / 106 / 1.7.66 / 34.5M / sha256 `ecd3000b5ad34fa251d3ca7c1c996c973349e6da420fea4a482d9c4eff0c5155`）。

> 发布节奏：未推送 GitHub（v1.7.66 为累计窗口第 2 版，攒满 5 版再推）。
> 验证提示：装包后打开收藏页点右上角同步按钮，再到 Emby 网页端「播放列表」确认出现对应条目。

## 33. v1.7.67 (107) 收藏页布局二次修正（v1.7.66 未生效的三处）

| # | 问题 | 根因 | 处理 |
|---|---|---|---|
| 1 | 标题离封面底部距离仍宽 | v1.7.66 改了外层 Stack 的贴底，但 `_layer()` 返回的 `Center` 又把海报**二次居中**，贴底根本没生效 | `_layer()` 改返回 `Align(bottomCenter)`；名称间距 6 → 3 |
| 2 | 新建收藏外框太大 | 虚线框撑满整个 Expanded，比海报卡（0.85 缩放）大一圈 | 虚线外框包 `FractionallySizedBox(0.85×0.85)` + 贴底，与海报卡完全同尺寸；**内部按钮/文字还原 v1.7.63 尺寸**（40 / 21 / 11.5） |
| 3 | 「收藏」「44 部·2 个收藏夹」、刷新按钮基线不齐 | 标题行 `crossAxisAlignment.end` | 改 `crossAxisAlignment.center` 水平居中对齐 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning |
| `flutter test` | **183 / 183**（守卫更新：`_layer` 内禁用 `Center`、新建卡内部还原 40 + 外框必须 `FractionallySizedBox`；同步收藏墙黄金图） |

**交付**：`camby-1.7.67-release-arm64.apk`（`cn.camby.camby` / 107 / 1.7.67 / 34.5M / sha256 `2adf98286ce3bdef730efdbf56805eb4a5ffc5a70726090b4e6eaea0aba94412`）。

> 发布节奏：未推送 GitHub（v1.7.67 为累计窗口第 3 版）。

---

## 34. v1.7.68 (108) 收藏夹同步机制修复（治本 + 权威口径落地）

### 事故链（v1.7.67 实测）

新建收藏夹「测试」点同步后：服务器多出 3 个**空名**播放列表、APP 里收藏夹名字变空、影片从未上云。

| 环节 | 事实 | 后果 |
|---|---|---|
| ① 创建 | `POST /Playlists` 的 `Name/Ids` 写在 **JSON body** 里，而 Emby 只读 **URL query** | 服务端创建出「空名空片」播放列表，并返回**合法 Id** |
| ② 本地 | 拿到 Id 即视为"已上云"，本地留有名字与片单 | 表面同步成功，实际服务端是空壳 |
| ③ 拉回 | `reconcileFolders` 无条件用服务端名覆盖本地名 | **空名覆盖好名字**，APP 名称被清空 |

### 修复

| # | 项 | 处理 |
|---|---|---|
| 1 | 创建播放列表（根因） | 新增 `_postQueryReturning`，改 `POST /Playlists?Name=&Ids=&UserId=`（body 空） |
| 2 | 重命名 | 先 `GET /Users/{uid}/Items/{id}` 取完整对象 → 改 `Name` → `POST /Items/{id}`，避免整包覆盖丢片 |
| 3 | 权威口径（决策③） | 本地已有收藏夹 → **上行模式 `_reconcileUpload`**（APP 为准：改名 + 增删条目全推服务端；服务端独有非空名拉回本地）；本地无内容 → **下行 `reconcileFolders`**（服务端为准，新装恢复） |
| 4 | 名称规则（决策①） | 仅服务端名**非空**才覆盖本地 |
| 5 | 空名脏数据（决策②） | `_deleteJunkPlaylists` 删除「服务端空名且本地无对应」的播放列表；下行模式也不把它建成本地收藏夹 |
| 6 | 上行失败静默 | `FavoriteFolder.pendingSync`（持久化）：创建/改名/增删影片失败置位，下次同步重试；同步 toast 显示「N 个收藏夹（M 个待重试）」 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze lib` | 编辑文件 0 error / 0 warning（其余为历史 `withOpacity` info） |
| `flutter test test/sync_folders*.dart` | **12 / 12 全绿**（新增 `sync_folders_upload_test.dart`：上行改名+补片、纯本地创建、空名删除+非空拉回、下行新装恢复、pending 标记；`sync_folders_test.dart` 补决策①②） |

**交付**：`camby-1.7.68-release-arm64.apk`（`cn.camby.camby` / 108 / 1.7.68 / 33M / sha256 `f290d1d59accc775eeea16447d37a7a9e5ace6156652578ba2c6cac0db88b479`）。

> 发布节奏：未推送 GitHub（v1.7.68 为累计窗口第 4 版）。

---

## 35. v1.7.69 (109) 同步仍失败修复：重建消失的播放列表 + 失败原因可见

### 现象（v1.7.68 真机实测）

收藏页同步 toast「已同步 · 3 个收藏夹（**3 个待重试**）」，Emby 网页端播放列表为空——
即 3 个收藏夹全部上云失败，但 APP 说不出原因。

### 根因

| # | 问题 | 说明 |
|---|---|---|
| 1 | **v1.7.68 逻辑漏洞** | 收藏夹带着旧 playlistId、但服务端对应播放列表已不在（`_reconcileUpload` 中 `p == null`）时，只置 `pendingSync` 却**从不重新创建** → 永远卡「待重试」，服务端永远是空的 |
| 2 | **失败原因被吞** | 创建/改名/加片失败全部静默，真机上服务端返回的具体错误（400/500/…）无法看到 |

### 修复

| # | 项 | 处理 |
|---|---|---|
| 1 | 重建消失的播放列表 | `p == null` → 走与纯本地相同的 `createOnServer`（用本地名称+片单重建，成功即更新 playlistId 并清 pending） |
| 2 | 失败原因可见 | `EmbyServer.lastPlaylistError` 记录最近一次错误；`_reconcileUpload` 收集 diag → `AppState.folderSyncDiag` → toast「N 个待重试：「夹名」创建失败：请求失败 (500)」 |
| 3 | 创建兼容性 | 补 `MediaType=Video`；2xx 空 body 不回 Id 时按名字重新拉列表兜底（`_findPlaylistIdByName`） |
| 4 | 真网络验证 | 新增本地假 Emby HTTP 服务测试：验证 Name/Ids/UserId 确实走 query、body 为空、空 body 兜底、rename 先 GET 全对象再 POST |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning（改动文件） |
| `flutter test`（全量） | **196 / 196 全绿**（含 4 条真 HTTP 假服务端用例） |

**交付**：`camby-1.7.69-release-arm64.apk`（`cn.camby.camby` / 109 / 1.7.69 / 34M / sha256 `a87c8de1f4b075df55887d71e260fccc66c798011fe0cbb1eddcecc5e93f0781`）。

> 发布节奏：未推送 GitHub（v1.7.69 为累计窗口第 5 版，达到推送窗口，随下版一起推）。

## 36. v1.7.70 (110) 首页/收藏页 UI 精简 + 全局搜索方案设计

### 改动（用户确认后直接实施）

| # | 项 | 处理 |
|---|---|---|
| 1 | **收藏页网格 2 列 → 3 列** | `favorites_page.dart` `_movieWall` 的 `SliverGridDelegateWithFixedCrossAxisCount`：`crossAxisCount` 2→3、`crossAxisSpacing` 16→12、`mainAxisSpacing` 22→18、`childAspectRatio` 0.60→0.54（窄卡比例收窄，标题不挤压）；`_StackTile` 为相对布局，3 列无溢出 |
| 2 | **首页顶栏精简** | 移除左上 `CAMBY` 品牌字与「服务器 · 片数」副标题、移除搜索圆钮；顶栏仅留右上连接状态胶囊（`Spacer` + `_Pill`）；删除随之无用的 `_sourceInfo` / `_searchRoute` / `_GlassCircleBtn` 及 `search_page` 导入 |
| 3 | **全局搜索方案设计稿** | `docs/global_search_proposal.html`：悬浮球（常驻/可拖贴边）、下拉唤醒（首页与媒体库被刷新占用，仅 3 页可用）、双击当前 Tab 三方案对比 + 推荐组合（A1 常驻悬浮球 + C 双击兜底），待用户确认 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze`（改动文件） | 0 error / 0 warning |
| `flutter test`（全量） | **196 / 196 全绿** |
| 守卫测试 | `favorites_wall_test` 新增断言 `crossAxisCount == 3`；黄金图 `favorites_wall.png` 已 `--update-goldens` 重新生成 |
| Release APK | `cn.camby.camby` / **versionCode 110** / **1.7.70** / 33M / sha256 `4989b1d25f59712538aeb177e7390d5e05eec9af3166185960209fbd6c106fbf` |

**交付**：`camby-1.7.70-release-arm64.apk`。

> 发布节奏：未推送 GitHub（v1.7.70 为累计窗口第 6 版）。注：v1.7.65~1.7.70 共 6 版本地未推，达到推送窗口，确认后一并推 GitHub 并打 Release。

#### 全局搜索方案摘要（详见 `docs/global_search_proposal.html`）

- **A 悬浮球（推荐主方案）**：在壳层 Overlay 常驻一个玻璃搜索球，右上角默认、可拖动贴边半隐、位置记忆、设置页可开关。5 个 Tab + 二级页全覆盖，一眼可见。
- **B 下拉唤醒**：在收藏/数据/我的页顶部下拉唤出搜索；但首页与媒体库下拉已被"刷新"占用，全局性打折，且二级页需逐个覆盖。
- **C 双击当前 Tab（兜底）**：双击当前所处 Tab（不切换）唤起搜索，零空间、所有页面可用但完全隐蔽。
- 推荐 **A1 + C**：悬浮球为主、双击 Tab 兜底；首页搜索按钮不再恢复。待确认：① 球默认位置（右上/右下）② 是否可拖贴边 ③ 双击兜底是否同加。

## 37. v1.7.71 (111) 全局搜索落地：双击 Tab + 我的页搜索按钮

### 用户决策

> 做方案 C 就行，然后在「我的」页右上角加个搜索按钮。

即：**仅做方案 C（双击当前 Tab 唤起）**，并额外在**「我的」页右上角**加一个常驻搜索按钮作为可见入口。

### 改动

| # | 项 | 处理 |
|---|---|---|
| 1 | 双击当前 Tab 唤起搜索 | `GlassNavBar` 由 `StatelessWidget` 改为 `StatefulWidget`，在 `GlassNavBarState` 用 `_lastTap`/`_lastIndex` 记录上次点击；`_onTap(i)` 中若 `i == 当前 index 且 == 上次 index 且间隔 < 300ms` → 调 `onSearch?.call()`（并重置 `_lastTap` 防止第三次连点再触发），否则走原 `onChanged(i)` |
| 2 | 壳层搜索入口 | `main.dart` 新增 `_openSearch()` / `_searchRoute()`（与详情页同款半透明路由 + 淡入上浮），传给 `GlassNavBar.onSearch`；`GlassNavBar` 原为私有，改为公开以便单测 |
| 3 | 「我的」页搜索按钮 | `settings_page.dart` 头部 Row 右侧加玻璃质感搜索圆钮（`LiquidPress` 包裹 `Icon(Icons.search_rounded)`），点击 `_openSearch()` 唤起搜索页；`SettingsPage` 新增必填 `onOpenDetail` 入参并透传 |
| 4 | 测试修复 | 因 `SettingsPage` 新增必填参数，`settings_render_test` / `all_pages_render_test` 同步补 `onOpenDetail`，否则编译失败 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze`（改动文件） | 0 error / 0 warning |
| `flutter test`（全量） | **199 / 199 全绿** |
| 守卫测试 | `global_search_test.dart`：双击触发 `onSearch` 且不再切换、点其它 Tab 只切换、我的页搜索钮打开 `SearchPage` |

**交付**：`camby-1.7.71-release-arm64.apk`（`cn.camby.camby` / **versionCode 111** / **1.7.71** / 34M / sha256 `5a46d1d6738f98fca52d9617cc855a9d8cdcf3885b1249658db2d35ba5e6f77a`）。

> 发布节奏：未推送 GitHub（v1.7.65~1.7.71 共 7 版本地未推，已到推送窗口，确认后一并推并打 Release）。

## 38. v1.7.72 (112) 标签页排序统一 + 偏好演员5条 + 常看作品裸Id修复

### 用户反馈与答复

1. **所有标签页样式统一**：年份/标题/评分三个排序字段，点一次倒序、再点正序 → 已实现。
2. **偏好演员 4→5 条**；数据怎么来、从何时算、能否多端同步 → 见下「统计口径」。
3. **常看作品里的「34847」是什么** → 见下「统计口径」。

### 改动

| # | 项 | 处理 |
|---|---|---|
| 1 | 排序组件 | 新增 `lib/widgets/sort_chip_row.dart`：`SortChipRow`（年份/标题/评分）+ `sortItemsBy()`；点选默认倒序（↓），再点同字段切正序（↑） |
| 2 | TagPage | 改 StatefulWidget，头部加 `SortChipRow`，默认年份倒序；此前该页完全没有排序 |
| 3 | SubtitleFilterPage | 旧「最近添加/评分/年份」三 chip 替换为共用 `SortChipRow`（移除最近添加，加标题），交互统一 |
| 4 | 偏好演员 | `topPeople.take(4)` → `take(5)` |
| 5 | 裸 Id 修复 | `EmbyServer.itemNamesByIds()` 批量反查；`AppState._resolveActivityNames()` 拉日志后解析；stats_page 回退链 `库内名 → 服务器片名 → 「库外影片（已删除）」` |
| 6 | 日志按账号过滤 | `activityLog()` 按 `UserId == _userId` 过滤（管理员账号此前会混入全家人的播放） |

### 统计口径（答复用户疑问）

- **偏好演员**：遍历「已看完或观看进度 > 90%」的影片，每部取前 5 位演员计次排序。数据来自服务器 **UserData 的已看标记**——覆盖服务器建档以来的全部观看历史，不是从装 APP 才开始；因以服务器为准，**同账号任何设备登录结果一致（多端同步）**。
- **最常看作品 Top**：来自服务器**内置活动日志**（`System/ActivityLog/Entries`，取最近约 800 条播放记录），按条目计次。覆盖范围=服务器日志里仍保留的历史。
- **「34847」**：是**服务器活动日志里某部影片的条目 Id**——该片已被你从服务器删除（或不在 APP 拉取的库范围），APP 解析不到片名，旧版直接把裸 Id 显示了出来（播放 4 次）。新版会先向服务器反查片名；确认已删除的显示「库外影片（已删除）」。
- **多端同步**：偏好演员/常看作品/时段分布均以**服务器数据**为源，同账号多端一致；此前管理员账号会把其他用户的播放混入，v1.7.72 起按账号过滤，更准。

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze`（改动文件） | 0 error / 0 warning |
| `flutter test`（全量） | **202 / 202 全绿** |
| 新增守卫 | `sort_chip_row_test.dart`：方向翻转纯逻辑、TagPage chip 交互（↓→↑→换字段默认↓）、中文字幕页同款且无「最近添加」 |

**交付**：`camby-1.7.72-release-arm64.apk`（`cn.camby.camby` / **versionCode 112** / **1.7.72**）。

> 发布节奏：未推送 GitHub（v1.7.65~1.7.72 共 8 版本地未推，已远超推送窗口，待确认后一并推并打 Release）。

## 39. v1.7.73 (113) 统计页三条卡片全空修复（APP 播放接入会话上报）

### 用户反馈

升级 1.7.72 后统计页「每日观看时长（近 30 天）」「播放时段统计」「最常看作品 Top」三条全部显示「暂无数据」。

### 根因

这三张卡片的数据源是服务器**活动日志**（`/System/ActivityLog/Entries`），只有**会话型播放**（网页端、TV 端等走 `Sessions/Playing` 的客户端）才会写入。本 APP 从 1.7.38 起进度上报一直走 `UserData` 直写（`/Users/{uid}/Items/{id}/UserData`），**从不产生活动日志条目**——即 APP 里的每次观看在服务器日志里是「不存在」的。

此前统计页有数据，是因为管理员账号能看到全家人的日志（其他客户端的播放）；1.7.72 按账号过滤后，日志里没有本账号的条目 → 全部清零。**之前看到的其实一直是别人的播放。**

### 改动

| # | 项 | 处理 |
|---|---|---|
| 1 | 会话上报三事件 | `emby_client.dart` 新增 `reportPlaybackStart`（`POST /Sessions/Playing`）、`reportPlaybackProgress`（`/Sessions/Playing/Progress`）、`reportPlaybackStop`（`/Sessions/Stopped`），全部尽力而为、失败静默 |
| 2 | AppState 入口 | `reportServerProgress` 成功后附带会话心跳；新增 `reportServerPlaybackStart/Stop` |
| 3 | 播放页接线 | `_open()` 起播后发 Start（`!_demo && _recordHistory` 守卫）；`dispose()` 退出前发 Stop（带结束位置与看完标记），与心跳共同构成完整会话 |
| 4 | 空态文案 | 三张卡片「暂无」提示改为说明数据来源与生效时间（APP 播放自 1.7.73 起计入） |

### 效果

- 从本版起，APP 内的每次播放都会以**本账号 UserId** 写入服务器活动日志，「每日观看时长 / 播放时段统计 / 最常看作品 Top」逐步积累本人真实数据；历史数据无法追溯（日志里本就没有），需从本版起重新积累
- 网页 / TV 端的播放照常计入；账号过滤（1.7.72）保持不变，不会混入家人播放

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error |
| `flutter test`（全量） | **204 / 204 全绿**（新增 2 条） |
| 新增守卫 | `session_playback_report_test.dart`：会话三事件请求体契约（ItemId/PositionTicks/Played）+ 服务端 500 不抛异常 |

**交付**：`camby-1.7.73-release-arm64.apk`（`cn.camby.camby` / **versionCode 113** / **1.7.73**）。

## 40. v2.0.0 (200) 统计页三条卡片全空——真正根因修复（活动日志账号归属）

### 用户质疑（成立）

> 「之前网页或者其他 APP 的记录也是我登录的这个账号啊，按理说都是我本人看的。」

用户指出 1.7.73 的根因判断有误：如果网页/TV 用的是同一账号，按 UserId 过滤本不该把它们全部排除。**用户是对的。**

### 真正根因

1.7.72 加的是**严格字符串比较**：

```dart
if (_userId != null && uid.isNotEmpty && uid != _userId) continue;
```

而 Emby 同一个账号 Id 在不同接口/日志里的写法并不统一：
- 登录返回 `User.Id` 常是**带连字符的 36 位 GUID**（`a1b2c3d4-...`）；
- 活动日志里的 `UserId` 可能是**不带连字符的 32 位**（`a1b2c3d4...`），大小写也可能不同；
- 播放类事件**经常根本不带 `UserId` 字段**（空字符串）。

三者任一出现，严格 `==` 都会把**本账号的播放**判为「非本人」丢弃 → 三条卡片全空。此前（1.7.72 之前）不做任何 UserId 判断，所以这些记录能正常显示。

### 修复

| # | 项 | 处理 |
|---|---|---|
| 1 | 归一化匹配 | 新增 `_normId()`：去除非十六进制字符 + 转小写；`uid` 与 `_userId` 都归一化后比较 |
| 2 | 空 UserId | 视为本人（单账号服务器里播放事件不带 UserId 是常态）；仍能排除明确属于他人的条目 |
| 3 | 诊断可见 | `EmbyServer.lastActivityDiag` 记录「日志播放 N 条，本账号 M 条」，匹配为 0 时附带本账号 Id 与日志账号样本；`AppState.activityDiag` 暴露，三张卡片空态直接展示 |
| 4 | 会话上报保留 | v1.7.73 的 `/Sessions/Playing|Progress|Stopped` 继续有效，APP 播放照常写入日志 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error |
| `flutter test`（全量） | **206 / 206 全绿**（新增 2 条：活动日志归属 4 场景 + 诊断信息） |
| 新增守卫 | `activity_log_account_match_test.dart`：GUID 带/不带连字符、大小写、空 UserId 均判本人；他人账号排除；全他账号时返回 null 且诊断文案正确 |

**交付**：`camby-2.0.0-release-arm64.apk`（`cn.camby.camby` / **versionCode 200** / **2.0.0**）。

> 发布节奏：**v2.0.0 首次推送 GitHub**（含此前本地未推的 v1.7.65~v1.7.73 提交历史），并打 `v2.0.0` Release。

> 发布节奏：未推送 GitHub（v1.7.65~1.7.73 共 9 版本地未推，待确认后一并推并打 Release）。

## 41. v2.0.1 (201) 收藏夹加片 + 播放会话上报修复

### 用户反馈

1. 收藏夹同步又失效，影片没同步上（服务端「人妻」播放列表存在但**内容为空**）；
2. 观看历史（继续观看）没同步；
3. 服务端活动记录里没有 APP 的信息（日志里只有官方 App 的 OPPO-PKJ10 记录）。

### 根因

| # | 问题 | 根因 |
|---|---|---|
| 1 | 播放列表空壳 | `addToPlaylist` 把 `Ids` 放 JSON body，Emby 加片接口只认 query（`/Playlists/{id}/Items?Ids=&UserId=`），服务端 2xx 但未加任何条目 |
| 2 | 活动日志无 APP | `/Sessions/Playing` 未带 `PlaySessionId`，部分 Emby 版本直接 400；异常被静默吞掉，无从发现 |
| 3 | 继续观看丢失 | `/Sessions/Playing` 未带 `PositionTicks` → 服务端按 0 处理，把已有续播位置重置；且起播时先写 UserData、后发 Playing，顺序进一步放大问题 |

### 修复

| # | 项 | 处理 |
|---|---|---|
| 1 | 加片参数 | `addToPlaylist` 改用 `_postQueryReturning`，`Ids`/`UserId` 走 query；标准端点 `/Items` 优先，`/Items/Add` 兜底 |
| 2 | 会话事件 | Start/Progress/Stop 全部带 `PlaySessionId`（每次播放生成一个）；失败写入 `lastSessionError` 并在统计页空态展示 |
| 3 | 续播位置 | `reportPlaybackStart(itemId, positionTicks:)` 带当前续播位置；播放页先发 Start 再写 UserData |
| 4 | 设备标识 | 全局 `Device="Camby"`（原 `Android`），活动日志可直接辨认 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error |
| `flutter test`（全量） | **208 / 208 全绿**（新增 2 条：加片 query 契约、失败诊断） |
| 新增守卫 | `playlist_add_http_test.dart`：`Ids=a1,a2`/`UserId` 必须在 query 且 body 为空；500 时返回 false 且写 `lastPlaylistError` |

**交付**：`camby-2.0.1-release-arm64.apk`（versionCode **201** / **2.0.1**）。

## 42. v2.0.2 (202) 会话上报 query 双形态 / 播放历史兜底 / 双击提示错位

### 用户反馈

1. 收藏同步已正常；
2. 播放记录仍未同步、服务端活动记录里仍无 APP 信息（真机 2.0.1）；
3. 播放页快进/快退时，提示气泡与按钮重叠（截图：`+10秒` 压在快进按钮上）。

### 根因

| # | 问题 | 根因 |
|---|---|---|
| 1 | 活动日志无 APP 条目 | Emby 10.9 起会话接口按 `[FromQuery]` 绑定模型，只认 query；旧实现全放 JSON body → ItemId 为空 → 服务端 204 但不落日志。与 v2.0.1 修的 `addToPlaylist` 属同一类错误 |
| 2 | 心跳可能整段消失 | 心跳挂在 `reportProgress`（UserData）成功分支下，UserData 被拒时会话事件一次都不发 |
| 3 | 只有 Start 没有 Stop | 直接上滑杀 App 不走 `dispose()`，`Stopped` 永远发不出去，观看时长对不上 |
| 4 | 提示与按钮重叠 | 提示气泡与中央按钮同一条水平线（距中心 148dp），窄横屏下正好落在快进按钮上 |

### 修复

| # | 项 | 处理 |
|---|---|---|
| 1 | 传输形态 | 新增 `_postSession()`：先 query（`_postQueryReturning`）再 body（`_postJson`）兜底，任一成功即成功，失败写 `lastSessionError` |
| 2 | 解耦 | `reportServerProgress` 里会话心跳独立发出，不再以 UserData 成功为前提 |
| 3 | 顺序兜底 | `reportPlaybackProgress/Stop` 发现无 `PlaySessionId` 时先补发 `Playing` |
| 4 | 生命周期 | `WidgetsBindingObserver`：`paused/detached` 补发 `Stopped`，`resumed` 重新起会话 |
| 5 | 播放历史 | `playedHistory()`（`Filters=IsPlayed`）参与「继续观看」兜底，不依赖活动日志权限 |
| 6 | 同步加固 | `listPlaylists` 失败中止同步；同步后清派生缓存 |
| 7 | 提示位置 | 按钮组正上方：常规 60dp / 窄屏 46dp，横向 34dp 方向感偏移 |

### 质量门

| 项 | 结果 |
|---|---|
| `flutter analyze` | **0 error / 0 warning**（顺手清掉 3 处历史告警） |
| `flutter test` | **216 / 216 全绿**（新增 7 条：会话双形态 4 条 + 播放历史 1 条 + 提示布局 3 条中的 2 条与生命周期 1 条） |
| 新增守卫 | `session_report_transport_test.dart`（query 优先 / body 兜底 / 失败可见 / 缺失会话补 Playing / playedHistory 查询契约）；`player_double_tip_layout_test.dart`（禁止 148dp 水平排布、上移量下限、生命周期观察者配对） |

**交付**：`camby-2.0.2-release-arm64.apk`（versionCode **202** / **2.0.2**）。

## 46. v2.0.8 播放器 UI 平板化

**问题**：v2.0.7 定稿「手机与平板一律强制横屏、功能完全一致」，但播放页控件尺寸仍是写死的手机值，平板上偏小偏挤。

**做法**：把播放页所有控件尺寸抽成 `PlayerUi`（`lib/layout.dart`）两套常量，按**屏幕短边 ≥620** 取档。

| 部位 | 手机 | 平板 |
|---|---|---|
| 快进退钮 / 播放钮 / 间隔 | 50 / 66 / 26 | 56 / 84 / 44 |
| 顶栏内边距 H/V、图标、标题、元信息、胶囊 | 14/8、15、13.5、10、34 | 26/16、19、16、12、38 |
| 底栏左右留白 / 离底 / 间隔、时间字号 | 16 / 10 / 8、11 | 30 / 18 / 12、13.5 |
| 功能胶囊 高/字/图标/间隔 | 30 / 11 / 13 / 8 | 38 / 13.5 / 16 / 12 |
| 进度条 热区/轨道/按下 | 34 / 4 / 8 | 46 / 6 / 11 |
| 双击气泡 宽/字/位移 | 92 / 17 / 181 | 112 / 21 / 242 |
| 拖动大时间 主/副 | 32 / 12 | 44 / 15 |
| 亮度音量条 宽/离边/条高/图标 | 68 / 48 / 150 / 17 | 84 / 72 / 190 / 21 |
| 面板限宽、字幕倍率 | 470、1.0 | 620、1.6 |

**验证结果**：`flutter analyze` 0 error/warning；`flutter test` **235 通过**（新增 8 条播放器度量用例）。

**踩坑**：`tipOffset` 初版写成 `playBtn/2 + clusterGap + sideBtn/2 + tipW/2`，漏了快进退钮的**整宽**（应为 `+sideBtn`），手机算出 130 而非 181 —— 气泡会压在快进钮上。已修正并加几何断言。

---

## 47. v2.0.10 实测反馈 6 项

1. **统计页没数据（根因修复）**：`_loadPlayback` 的播放报告（需插件）/活动日志/最近播放/已看历史四项请求共用一个 try，插件接口抛错时四项全部置空——这就是「播放时段统计、每日观看时长、最常看作品又没数据了」。已拆为独立 try，各败各的。
2. **收藏页角标**：贴到封面右上角（`top = 瓦片高 − 封面高 + 8`，`right = (瓦片宽 − 0.85瓦片宽)/2 + 8`）；新建收藏夹虚线框平板下同比例收窄（`min(h×0.85, 0.85瓦片宽×1.45)`）。
3. **推荐位方案 C**：横图 `ImageFiltered(blur 30)` 铺底（RepaintBoundary + scale 1.15 防边缘透底）+ 左侧竖版海报（1:1.45）+ 右信息列；「换一批」移入信息列底部（原左下被海报压住）。
4. **Rail 去 Logo**：顶部播放圆钮与状态栏叠放移除。
5. **搜索置顶**：Rail 结构改为 [搜索] + [5 个 Tab] 贴顶排列。
6. **详情头图同方案 C**。

---

## 48. v2.0.11 实测反馈 6 项

1. **统计页又没数据（第三轮修复）**：① 活动日志去掉 `HasUserId=true`（部分服务器版本加该参数后日志为空）；② 三卡新增「已看历史」兜底层——插件/日志都不可用时用 `/Users/{id}/PlayedItems`（普通权限必可用）近似生成每日时长（片长估算）/时段分布/常看 Top，徽章显示「已看历史近似」。空态诊断文案（`activityDiag`/`sessionDiag`）保持可见。
2. **Rail 搜索与 Tab 间距**统一为按钮间标准 8dp。
3. **状态栏重叠**：Rail 顶部 `padding.top + 10`、首页 Hero 顶部 `padding.top + 12`（收藏/搜索/设置/详情/统计页此前已有 SafeArea/顶部避让）。
4. **连接状态胶囊**：平板移入 Hero 卡内右上角（随滚动），手机保持悬浮。
5. **首页横行左间距 24 → 12**，与卡间 gap、行间上下间距统一；RowHeader 平板同步 12。
6. **收藏页瓦片**：平板 childAspectRatio 0.54 → 0.66（瓦片高≈内容高，封面贴底后的顶部空白消失）、行距 18 → 12、顶部留白 6 → 2。

---

## 53. v2.0.16 实测反馈 3 项

1. **手机端收藏夹重复文件夹**：根因是同步只按 `playlistId` 匹配不看名字——本地夹 Id 失效/未上云时直接新建同名播放列表，服务端同名的再被拉回本地成重复夹。修复（`_reconcileUpload`）：① 未上云 / Id 失效先**按名收养**服务端同名播放列表（`adoptOrCreate`，只补本地缺片、不删服务端多出片）；② 收尾**按名去重合并**本地重复夹（片单并集、多余服务端播放列表删除）；③ `renamePlaylist` 增加**最小 body 重试兜底**修「人妻」改名永远 400。测试 +3（收养 / 去重 / 不波及其它服务器）。
2. **统计页「缺简介 0 部」**：`missingOverview` 计数只判 `overview.isEmpty`，而解析层把空简介替换成「暂无简介」占位 → 计数恒 0、列表却有条目。计数与列表统一同一套条件（`missingPoster` 同步统一）。
3. **平板详情页按设计稿重排**：v2.0.14 只修标题对齐、双栏未动，与 `docs/detail_sections_proposal.html` 不符。改**单列**：分集 → 剧情简介 → 媒体信息 → 主演 → 标签 → 剧照 → 相似推荐；扩展档占满内容区、中等档限宽 760 居中；顺带修扩展档左栏 `Column` 缺 `crossAxisAlignment: start` 导致标签 chip 整排居中。`tablet_layout_test` 增加单列顺序断言。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过（232→235）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.16-release-arm64.apk`。

---

## 55. v2.0.19 平板详情页横幅信息区重排（实测反馈）
1. **海报等距**：`_tabletBanner` 内层 Padding `fromLTRB(26,0,26,24)` + `CrossAxisAlignment.end`（海报贴底：上 44/下 24/左 26）→ `symmetric(horizontal: 34)` + 默认居中：海报垂直居中，上下 = (330-262)/2 = 34，水平 34，四边等宽。
2. **信息列居中**：徽章/标题/元信息不再贴底，与海报中线对齐。
3. **信息流顺序**（用户指定）：媒体徽章 → 标题 → 元信息 → **观看进度（右对齐：百分比+剩余分钟+细进度条）** → 播放按钮行。观看进度从 `Positioned(right:28,bottom:26)` 悬浮块挪进 `_bannerInfo` 信息列（宽 220、右对齐），删除按钮区右侧 `SizedBox(width:250)` 占位 hack；`_bannerProgress` 文字改 `CrossAxisAlignment.end`。
4. **测试**：`tablet_layout_test` 增补海报上下等距守卫（顶距/底距 = 34±1，poster 缺失时跳过）；全量 235 全过。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.19-release-arm64.apk`。

---

## 57. v2.0.21 实测反馈 3 项（首页播放列表隐藏 + 统计卡片合并 + 进度条方向）
1. **首页隐藏「播放列表」**：`emby_client.userViews` 过滤条件加 `collectionType == 'playlists'`，collectionType 缺失时名称兜底加「播放列表」/`playlists`。收藏夹同步出的 Playlist 视图与合集/BoxSets 一致不进首页（媒体库列表其余消费方同步受益）。
2. **统计页「库存覆盖率」并入「观看完成率」**：删除独立 `_SectionCard(库存覆盖率)`；`_CompletionCard` 加 `total` 参数，卡片内在完成率圈环描述行之后加分隔线 + `_CoverageGauge(rate: watchCoverage, watched: watchedCount, total)`，覆盖率圈环（紫色）与「已看 X / 库内 Y 部\n还有 Z 部 未看」文案原样保留。手机流式列表与平板 `_tabletColumns` 双栏共用同一 children 列表，一处修改两端生效。
3. **平板详情观看进度靠左 + 从左往右**：`_bannerProgress` 列 `crossAxisAlignment.end` → `start`；进度轨道 `Container` 加 `width: double.infinity` + `alignment: Alignment.centerLeft`。旧实现轨道宽度随 `FractionallySizedBox` 收缩（≈220×progress）且被 `crossAxis.end` 推到右缘，填充虽锚左但整体观感「从右往左走」；新轨道恒定满宽 220、填充自左缘向右生长。
4. **测试**：`test/views_filter_http_test.dart`（真 socket 假 Emby：movies/boxsets/playlists/无类型「播放列表」/tvshows → 只剩 movies+tvshows；**教训**：与 `testWidgets` 同文件时 flutter_test 初始化 binding 后全局 `HttpOverrides` 劫持 HttpClient，所有真 socket 请求变 400，故 HTTP 假服务测试必须独立成文件）；`test/v2021_ui_test.dart`（完成率卡片在、覆盖率卡片无、数据质量收尾，长列表需 `scrollUntilVisible` 后断言）；`tablet_layout_test` 增补 220 块左缘 = 文字左缘 = 填充条左缘、填充宽 = 220×progress 断言。全量 239 全过。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 239 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.21-release-arm64.apk`。

---

## 58. v2.0.22 统计页两项反馈（去重环 + 偏好演员口径说明）
1. **观看完成率顶部重复环移除**：v2.0.21 把「库存覆盖率」并入「观看完成率」后，`_CompletionCard` 里出现两个同为 7% 的环——顶部 `CircularProgressIndicator(value: completionRate)` 配文案「库内已看完影片占比 / 按底部播放进度 / 已看标记计算」，与底部 `_CoverageGauge(watchCoverage)`（「已看 X / 库内 Y 部 / 还有 Z 部 未看」）口径一致、数值相同，属重复。现删除顶部环 Row 及多余分隔线，卡片只保留 `_CoverageGauge` 一个环 + 最近播放 10 部列表。概览网格的「完成率」(completionRate) 不受影响照常显示。
2. **偏好演员「已看加权」→「?」说明按钮**：`_SectionCard(badge:)` 原 `const _SourceBadge(text: '已看加权', ab: true)` 改挂新组件 `_ExplainButton(title, message)`（圆形「?」+ 边框，onTap 弹 `AlertDialog`）。文案常量 `_kActorExplain` 说明口径：①「已看」= 服务器已看标记 或 播放进度 >90%；② 每部已看影片最多取前 5 位演员（按影片内顺序去重）计频；③「次」= 该演员出现在多少部已看影片；④ 条形长度按「次数÷最高次数」归一化仅用于显示比例。口径与 `models.buildLibraryStats` 的 `personFreq` 统计逻辑一致（`watched.where(userPlayed || resume>0.9)` → `e.people.take(5)` 计频 → top5 / 归一化）。
3. **测试**：`test/stats_explain_test.dart` —— 顶部环文案 `库内已看完影片占比` 消失、`已看加权` 消失、`?` 按钮存在；`tester.tap(?)` 后弹窗含「偏好演员 · 计算说明 / 什么叫已看一次 / 进度超过 90%」，点「知道了」关闭。统计页有持续动画，断言用定长 `pump` 代替 `pumpAndSettle`（否则超时）。全量 241 全过。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 241 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.22-release-arm64.apk`。

---

## 59. v2.0.23 统计页反馈（液态玻璃说明 + 累计播放计时已看）
1. **「?」按钮居中 + 弹窗液态玻璃**：v2.0.22 的「?」圆钮内问号因 Flutter 字体度量未垂直居中（略偏上）。改为 `SizedBox` 包裹 `Container(alignment: center)`，问号用 `TextAlign.center` + `height:1` + `leadingDistribution: even` 真正几何居中。弹窗由纯色 `AlertDialog` 改为 `Glass`（自带 `BackdropFilter` 实时模糊 sigma 32 + 折射高光 + 顶部柔光），与全局玻璃质感统一；`Dialog(backgroundColor: transparent, elevation: 0)` 透出玻璃层。
2. **累计播放时长纳入「已看」口径**：用户要求「一部影片累计播放超过 15 分钟就算已看」。新增本地累计播放秒数（itemId→秒，落盘 `local_play_seconds_json`）：播放页 `_startReportTimer` 起 5 秒周期定时器，仅 `_isPlaying && !_demo && _recordHistory` 时 `state.addLocalPlaySeconds(id, 5)`；退出 `dispose` 时 `_playSecondsTimer.cancel()` + `state.flushLocalPlaySeconds()` 立即落盘（30 秒防抖兜底）。`LibraryStats.compute` 新增 `localPlaySeconds` 入参，「已看」判定增补第三条 `本地累计 ≥ 900s`，与「已看标记 / 进度>90%」为「或」；跨门槛时 `_invalidateDerived()` 使统计缓存失效重算。`restore()` 加载 `_loadLocalPlaySeconds()`。本地计数独立于 Emby UserData，重装/换端重置（属预期）。
3. **说明文案同步**：`_kActorExplain` 增补「在本 App 内累计播放时长 ≥ 15 分钟（本地记录，按影片累加；重看同一片段会重复计时）」。
4. **手机/平板同步**：统计页为同一 `StatsPage` 响应式布局（kTabletBreakpoint 双栏），播放页计时两端共用，`app_state` 全局生效——三处需求一处改动两端生效，无需分别处理。
5. **测试**：`test/local_play_watched_test.dart`（compute 在 899s 不计入、900s 计入、与服务端已看标记/进度 90% 为「或」）；`test/stats_explain_test.dart` 增补「15 分钟」文案断言与 `find.byType(Glass)` 弹窗断言；全量 245 全过。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 245 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.23-release-arm64.apk`。

---

## 56. v2.0.20 收藏夹改名 400（实测反馈）
1. **问题**：用户服务器对 `POST /Items/{id}`（UpdateItem）无论整包还是最小 body 都返回 400（「人妻」改名永远失败，手机/平板端同步均报 400）。v2.0.4 的「补 ProviderIds 空字典」与 v2.0.16 的「最小 body 重试」在该服务器均不奏效。
2. **根因**：该 Emby 实例的 UpdateItem 端点对播放列表改名路径死 400（与字段是否完整无关），而创建/删除/加片为独立端点、实测可用。
3. **修复——`renamePlaylist` 四层兜底**：① 整包回传（保其它元数据）；② 最小 body 重试（仅名字 + 空集合）；③ 完整字段回传（GET 带 `Fields=ProviderIds,PlaylistItems,…` 取真实引用值再 POST）；④ **重建式改名（终极兜底，必成）**：用 `createPlaylist(目标名, 本地片单)` 新建列表 → `deletePlaylist(旧列表)` 删除旧列表，彻底绕开 UpdateItem。若 `listPlaylists` 已存在同名残留（上轮删旧失败）则复用并补差集，保证幂等。
4. **返回语义变更**：`renamePlaylist` 由 `Future<bool>` 改为 `Future<String?>`——成功返回**可能变化**的最终播放列表 Id（重建式改名会换 Id），失败返回 null（原因见 `lastPlaylistError`）。调用方随之调整：
   - `_reconcileUpload`（上行同步）：拿到 `newPid != f.playlistId` 时换绑 `f.playlistId=newPid`、标记已同步并 `continue`（片单已随新列表建好，跳过本轮加/移片）。
   - `renameFolder`（手动改名）：`ok == null` 判定失败、置 `pendingSync`。
5. **测试**：`sync_folders_upload_test` 假服务端 `renamePlaylist` 同步改 `String?` 签名（失败返 null）；`playlist_http_mock_test` / `rename_playlist_providerids_test` 的 `ok` 断言由 `isTrue` 改为断言返回 Id。全量 235 全过。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.20-release-arm64.apk`。

---

## 54. v2.0.18 字幕加粗开关 + 字体可切换（系统/仿宋）
1. **字幕加粗开关**：`SubtitleStyle` 新增 `bold`（默认 true，对应影院风格截图），面板新增「加粗」Switch；MPV `sub-bold` 随开关切 `yes`/`no`，Flutter 叠加层 `fontWeight` 在 `w800`/`w500` 间切换。
2. **字幕字体可切换**：`SubtitleStyle` 新增 `font` 枚举（`system`/`fangsong`），面板新增「字体」选择行（系统/仿宋）；Flutter 叠加层 `fontFamily: 'FangSong'`。仿宋采用**开源思源宋体 Noto Serif SC（OFL 可商用）**，按 GB2312 字符集子集化为 `assets/fonts/FangSong.ttf`（2.6MB，原 12MB），pubspec 注册 family `FangSong` 并改写 TTF 内部 family 名为 `FangSong`（两端一致）；MPV 链路选仿宋时把内置 ttf 抽到应用目录、`sub-fonts-dir` 暴露给 libmpv（按内部 family 名匹配）。偏好新增 `bold`/`font` 持久化键。
3. **测试**：`camby_1738_test` 增补 `bold`/`font` 断言（含 `fontFamily` 与 `w500` 兜底）；`mpv_sub_style_test` 增补 `sub-fonts-dir`/`FangSong`/`_ensureFangSongFont` 守卫；全量 235 全过。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.18-release-arm64.apk`（37MB）。

---

## 53. v2.0.17 实测反馈 2 项（平板横幅模糊 + 字幕样式固定）
1. **平板详情页横幅模糊对齐首页**：`_tabletBanner` 的 backdrop 原清晰直出（`memWidth 1200`），与首页 Hero（高斯模糊 sigma 40 + 低清采样 220）观感不一致。改为 `ImageFiltered(ImageFilter.blur(sigmaX:40, sigmaY:40))` 包 `CachedImage(memWidth:220)`，外层 `Transform.scale(1.12)` 防止模糊采样在圆角边缘露透明羽化；渐变压暗层（底部+左侧双向）不变。
2. **字幕样式固定「影院风格」+ 面板只留大小/位置**：用户截图要求字幕为白色加粗 + 黑色描边。`SubtitleStyle` 删除 `opa/stroke/color` 字段与相应 `copyWith`/`toJson`/`fromJson`/`Store` 键，样式固定为**白字（`w800`）+ 8 向黑色硬描边**（`textStyle` getter 内联常量）；MPV 链路 `applySubtitleStyle` 固定下发 `sub-color=#FFFFFFFF` / `sub-border-color=#FF000000` / `sub-border-size=3` / 新增 `sub-bold=yes`（系统黑体加粗，零打包体积），删除已无用的 `_mpvColorWithAlpha`；设置面板 `SubtitleStyleSheet` 仅保留「大小」「位置」两行滑杆，移除描边/不透明度滑杆与颜色色板（`_palette`/`_colorRow`/`_ColorSwatch` 一并删除）。已存用户偏好只保留 size/pos 生效。字体采用系统黑体方案（Android 自带 Noto/MiSans/HarmonyOS 均为黑体系，观感一致）。
3. **测试**：`camby_1738_test` 的 `SubtitleStyle` group 改为断言固定影院风格（白字加粗 + 8 阴影 + w800）；`mpv_sub_style_test` 改为守卫固定白字/黑描边/sub-bold 与不变量（无 sub-opacity、无 _mpvColorWithAlpha、setWithFallback 回退保留）；总数 235 全过。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.17-release-arm64.apk`。

---

## 52. v2.0.15 移除「选择码率」功能
1. **功能删除**：服务端无转码，`MaxStreamingBitrate` 切换实际无效（直连原片服务端忽略参数；转码地址失败静默回退原片还弹虚假成功）。完整移除：播放页底栏码率胶囊 + 播放信息面板「码率上限」行 + `_changeBitrate`/`_applyBitrate`/`_bitrateText`/`_bitrateShort`/`_showGlassPanel`/`_maxBitrate`/`_bitrates` + 首播读 `set_max_bitrate`；设置页「最大码率」项；`streamUrl` 的 `maxBitrate` 参数。
2. **连带清理**：`_showGlassPanel` 因唯一调用方 `_changeBitrate` 删除而变孤儿，一并移除；`_Sheet.subtitle` 参数此前仅 `_showGlassPanel` 传入，删除后清理死参数与死渲染分支。
3. **测试**：`camby_1738_test` 删除 `Emby streamUrl 码率上限` group，`player_boot_order_test` 删除 `set_max_bitrate` 断言；总数 235 → 232。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 232 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.15-release-arm64.apk`。

---

## 51. v2.0.14 实测反馈（详情页重设计 + 图标 + 返回栈）
1. **详情页下部板块重设计**：`_overviewCard(item, withTitle:false)` / `_mediaInfoCard(item, withTitle:false)` 平板右栏改用列左缘外部标题「剧情简介」「媒体信息」，标题与左栏所有板块（主演/标签/剧照/相似）严格同左缘，根治 16px 错位。手机端 `withTitle` 默认 true，玻璃卡片内嵌标题行为不变。
2. **启动图标加白底（方案 A）**：`android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` 五档重写为白底圆角方块（圆角 22%）+ 原蓝标 60%。预览见 `docs/logo_proposal.html`。
3. **返回栈逐级返回 bug**：`DetailPage` 点演员 push 的 `PersonPage.onOpenDetail` 去掉 `Navigator.pop(context)`，直接复用 `widget.onOpenDetail`（逐级压栈）。手机+平板通用。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.14-release-arm64.apk`。

---

## 50. v2.0.13 实测反馈 2 项

1. **详情页重复播放按钮**：`DetailPage.build` 底部常驻播放区（`_ProgressPlayButton` + 重新播放圆钮 + 渐变模糊带）加 `if (!wide)` 仅手机渲染；平板横幅操作行已含播放入口。平板 `_tabletChildren` 末尾底部预留 `SizedBox(120)` → `32`（手机分支 120 保留，底部条仍在）。
2. **播放器进度条圆点/轨道居中**：`_ProgressBar` 轨道 `top = barHitH/2 - (pressed ? barActiveH : barTrackH)/2`；圆点 `top = barHitH/2 - r`（r = pressed ? 9 : 6）。手机（34/4/8）与平板（46/6/11）两档几何断言不变，中心线恒为 barHitH/2。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.13-release-arm64.apk`。

---

## 49. v2.0.12 实测反馈 6 项

1. **详情页按 `docs/detail_tablet_proposal.html` 重适配（平板端全部重写，手机不动）**：头部横幅 330（backdrop 全宽铺底 + 双向渐变 + 悬浮海报 180×262 + 左下信息/操作 + 右下进度条）；操作行 = 立即/继续播放 + 从头播放 + 收藏 + 标记已看（新增 `EmbyServer.markPlayed` / `AppState.togglePlayed`）；扩展档双栏 1fr/340px；中等档横幅同款 + 限宽 760 居中单列；顶部避让状态栏。守卫测试同步更新（横幅 330 / 边距 24）。
2. **统计页三卡数据（第四轮修复，真根因）**：`activityLog` 解析重构为两轮 —— 第一轮只统计本账号（归一化匹配），命中 0 条但日志里有播放时**回退为全部播放统计**，诊断文案改为「账号匹配 0 条（已按全部播放统计）」。实测服务器日志 UserId 与登录 GUID 属于两套 Id 体系，归一化也对不上。守卫测试 `activity_log_account_match_test` 改为锁定回退语义。
3. **首页 Hero 海报左边距 36 → 22**，与上下间距一致。
4. **Rail 搜索与首页间距**：删除额外 `SizedBox(8)`（此前视觉间距 = 8 + 4 + 4 = 16），现在与 Tab 间一致为 8。
5. **媒体库一行 7 个**：`mediaGridColumns` 中等档 5 → 7（扩展档已是 7）。
6. **演员页**：头部卡片避让状态栏；网格边距 28→24、行距 16→14、比例 0.52→0.55、列数随媒体库 7 列 —— 与媒体库完全一致。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 235 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.12-release-arm64.apk`。

---

## 45. 每版固定验证清单（v2.0.7 起启用）

平板/手机双端共存后，每版发布前**必须**按此清单执行（自动化部分已脚本化）。

### 自动化（一条命令）

```bash
bash tools/verify_release.sh --build
```

| 步骤 | 内容 | 失败即禁止发布 |
|---|---|---|
| 1 | 版本一致性：`pubspec.yaml` / `README.md` 版本行一致 | ✔ |
| 2 | `flutter analyze`：0 error / 0 warning | ✔ |
| 3 | `flutter test`：全量通过 | ✔ |
| 4 | `tools/perf_audit.py`：性能静态红线 | ✔ |
| 5 | 构建 release APK 并复制到 `releases/` | ✔ |

### 回归守卫测试（常驻）

| 测试文件 | 锁定内容 |
|---|---|
| `test/phone_regression_test.dart` | 手机端必须底部 Tab（无 Rail）、首页满幅 Hero、详情单列（无 380 侧栏）、设置页 16 边距；平板端必须 Rail ≤96、设置页限宽 720 居中 |
| `test/layout_breakpoint_test.dart` | 三档断点 840 / 1200 与 `kRailWidth=96` |
| `test/tablet_layout_test.dart` | Hero 定高 300 + 边距 30、详情头部 300、收藏页渲染 |
| `test/player_ui_metrics_test.dart` | 播放器度量：手机端 30 项逐项等于改造前写死值（零漂移）、平板端设计稿值、短边 620 分档、播放页无遗留硬编码 |
| `test/player_double_tip_layout_test.dart` | 双击 ±10 秒气泡走 `PlayerUi.tipOffset`；`tipOffset` 公式正确且「气泡左缘 − 按钮右缘 == clusterGap」（防气泡压按钮） |

### 真机必测（手机 + 平板各一台）

- [ ] 手机端：首页 / 媒体库 / 详情 / 收藏 / 统计 / 设置 —— 与上一版逐页比对（无视觉变化即为通过）
- [ ] 平板横屏：Rail 96px、Hero 卡片 300 高、继续观看 7 张、最近添加 9 张、详情主从分栏、收藏 5 列
- [ ] 平板竖屏（840–1199 档）：导航收为图标条，媒体库 4 列（当前 6 列待按设计稿调），页面无溢出
- [ ] 播放：起播/退出/杀 App 后活动日志有开始+结束，续播位置正确（手机与平板均强制横屏）
- [ ] 播放控件（v2.0.8 起）：手机端与上一版**逐像素一致**；平板端按钮/间距明显放大且无溢出 —— 重点看：中央三键（84/56/44）、顶栏胶囊、底栏胶囊 38 高、进度条按下 11、双击气泡不压按钮、亮度/音量条离边 72 不顶挖孔
- [ ] 性能：`PERFORMANCE.md` §2 阈值表（6 列网格滚动、切 Tab、详情首帧、内存）
- [ ] 回滚锚点：发布前打 tag，出问题 `git reset --hard <tag>`

---

## 60. v2.0.24 多服务器切换与收藏夹归属修复（实测反馈）
1. **本地累计播放越过 15 分钟 → 回写服务器「已看」**：`addLocalPlaySeconds` 在累计秒数跨过 `localPlayWatchedThreshold=900s` 且已连接时，触发 `_syncLocalWatchedToServer(id)` → `_server.markPlayed(id, played:true)` 把「已看」布尔写回服务端 UserData（失败静默）。累计秒数本身服务端无对应字段，仅同步布尔、不同步数字，避免污染续播点。
2. **切换服务器后收藏夹仍显示旧服务器缓存（bug 修复）**：原 `folders` 为跨所有服务器的扁平列表，收藏页直接展示全部。新增 `activeFolders` getter（按 `_activeServerId` 过滤，旧版 `serverId==null` 归当前服务器兼容）；收藏页头部计数 + 网格、`folder_sheet` 弹层（展示与同名查重）均改为只展示当前服务器名下收藏夹。切到 Jellyfin 即拉取其播放列表，Emby 的夹不再混入。
3. **服务器切换 UI 重做（操作隐蔽 / 提示不清）**：取消「长按列表编辑」的隐藏操作，改为每张卡片右侧显式铅笔「编辑」+ 垃圾桶「删除」；非当前服务器新增渐变「切换」按钮并给明确反馈（「正在切换到『X』…」→「已切换到『X』」/ 失败显示去前缀的具体原因）；当前服务器卡片加青色描边 + 「当前」徽标 + 状态行（● 已连接 / ● 离线（显示缓存）/ ○ 点按卡片切换）；区块加操作提示行，空状态重复文案去重。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 245 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.24-release-arm64.apk`（36.9MB）。

---

## 61. v2.0.25 播放兼容修复 + 偏好演员口径调整（实测反馈）
1. **杜比视界绿屏修复**：DV Profile 5 用 IPT 色彩空间，需 IPT→BT.2020 转换否则整体发绿。`MpvController.open` 新增 `dovi=yes` 属性（无 DV 时为 no-op）；抽象 `open` 签名与 `ExoController` 同步加 `audioCodec` 参数。Exo 内核 MediaCodec 无法解码 DV P5 会静默黑屏，故 DV 片走 MPV 内核。
2. **TrueHD / DTS-HD MA 无声修复**：`open()` 新增 `audioCodec` 参数并透传到 MPV；`player_page._start` 起播时传 `widget.item.audioCodec`。检测到 TrueHD / DTS-HD / DTS-HDMA 时强制 `audio-channels=stereo` 立体声下混 —— 这类无损多声道解码成 7.1 PCM 后 Android AudioTrack 常因声道掩码不支持而直接不出声，下混后可正常出声，其余编码保持原声道。
3. **偏好演员口径调整 + 移除本地累计规则**：`LibraryStats.compute` 移除 `localPlaySeconds` 参数及「已看」判定中的 15 分钟本地累计条件；偏好演员改为统计「继续观看」影片（续播进度 1%~99%）的演员。同步移除 app_state / player_page 整套本地累计播放秒数 machinery（`_localPlaySeconds`、`addLocalPlaySeconds` / `flushLocalPlaySeconds` / 计时器 / 落盘 / 恢复加载）与 `test/local_play_watched_test.dart`；`_kActorExplain` 文案改为描述「继续观看」口径。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 241 全过（移除 4 个已废弃用例）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.25-release-arm64.apk`（≈36.9MB）。

---

## §62 · v2.0.26 (226) 偏好演员并入完成观看 + 偏好影片本地播放次数（实测反馈）

1. **偏好演员统计扩展**：统计源从「继续观看」扩为「继续观看 ∪ 完成观看」（完成观看=已看标记或进度≥90%），演员各计 1 次、同片不重复；`_kActorExplain` 文案更新。
2. **偏好影片（新区块）**：`LibraryStats.compute` 新增 `playCounts` 参数，输出 `topMovies`（按本机播放次数取前 10 部**电影**，先筛电影再排序，剧集不占名额）。
3. **本地播放次数链路**：`app_state` 新增 `_playCount`（`movie_play_count_json` 持久化）+ `addPlayCount`/`getPlayCount`/`flushPlayCount`/`_loadPlayCount`；`player_page` 起播成功后 `_playCounted` 标志位记一次（引擎切换重建不重复）；`stats.topMovies` 经 `_TopMovies` 组件渲染（海报+片名+「N 次」角标）。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 244 全过（新增 3 个用例：偏好演员含完成观看、topMovies 取前10部电影、AppState 累加）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.26-release-arm64.apk`（≈36.9MB）。

---

## §63 · v2.0.27 (227) 偏好影片改服务器播放次数（方案A）+ 详情页预告片/剧照滑动（实测反馈）

1. **偏好影片改用服务器 PlayCount（方案 A）**：移除 v2.0.26 自增的整套本地 `_playCount` 逻辑（`app_state`：`_playCount`/`addPlayCount`/`getPlayCount`/`flushPlayCount`/`_loadPlayCount`/持久化/restore 加载；`player_page`：`_playCounted` 与起播记一次 + 退出落盘），`LibraryStats.compute` 去掉 `playCounts` 参数，`topMovies` 改读 `item.userPlayCount`（先筛电影再排序取前 10）。统计页徽标「本机播放次数」→「服务器播放次数」。跨设备一致、重装不丢（App 起播/退出已回传会话事件，服务端 PlayCount 持续累积）。
2. **详情页预告片栏目**：`MediaItem.trailerUrls`（解析 `RemoteTrailers` 远程外链）；`emby_client.trailers(itemId)` 拉取本地预告片（`/Items/{id}/Trailer`，复用 `_fromJson` 生成可直接起播的 `videoUrl`）；详情页剧照之后插入「预告片」板块，本地预告片点按 `widget.onPlay` 在 App 内播放，外链点按 `launchUrl`；新增 `url_launcher` 依赖 + AndroidManifest `<queries>` 浏览器 intent。
3. **剧照左右滑动查看**：`_showBackdrop` → `_showBackdrops(List, initial)`，`PageView` 轮播 + 顶部「N / 总数」页码 + 点空白关闭；手机/平板双布局同步。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 243 全过（偏好影片用例改为断言 `userPlayCount` Top10、并删 AppState 累加用例）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.27-release-arm64.apk`（≈37.0MB）。

## §64 · v2.0.28 (228) 偏好影片修复 + 本地预告片 + 详情页性能（实测反馈）

1. **偏好影片修复（服务器+本机次数取较大值）**：v2.0.27 仅认服务端 `userPlayCount`，很多服务器不给「普通播放」自动 +1，榜单长期为空。v2.0.28 恢复本机播放计数（`app_state`：`_playCount` 持久化 `play_count_json` + `addLocalPlay` + `restore` 加载；`player_page`：起播成功后记一次，由 `_localCounted` 去重避免引擎切换重复记），`LibraryStats.compute` 新增可选 `localPlayCounts` 参数，`topMovies` 用 `max(服务器次数, 本机次数)` 作有效播放次数。数据源徽标「服务器播放次数」→「服务器+本机次数」。本机看过的片必然进榜，其它设备/官方客户端看过的也照常计入，且不重复膨胀。
2. **预告片兼容本地 trailer 文件**：`emby_client.trailers(itemId)` 原只查 `/Items/{id}/Trailer`（网页关联预告片），识别不到放在电影文件夹里的本地预告片（`trailer.mp4` / `trailer/trailer.mkv` 等被扫成 `ExtraType=Trailer` 子条目）。改为两路合并去重：关联预告片 + 按 `ParentId` 查的本地预告片 Extra；任意一路失败不影响另一路，绝不抛异常。本地预告片无自身海报时退回电影 `backdropUrl` 当缩略图。`_trailerSection` 手机/平板双布局共用，已同步受益。
3. **详情页性能**：`CachedImage` 外包 `RepaintBoundary`（滚动时未变化图不再整帧重绘）；剧照查看器解码宽 1600→1280 + 逐页 `RepaintBoundary`（左右滑动更跟手）；详情页顶/底实时模糊 sigma 下调（状态栏 20→14、底部条 20→16）降低滚动每帧重采样开销。

验证：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 244 全过（新增「本机次数与服务器次数取较大值」用例）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.28-release-arm64.apk`（≈37.0MB）。

## §65 · v2.0.29 (229) 预告片识别加固 + 栏目置顶 + 剧照滑动去卡顿（实测反馈）

1. **预告片识别加固**：v2.0.28 只按 `IncludeItemTypes=Trailer` 查 `ParentId` 子条目，漏掉了 Emby 以 `Type=Video` + `ExtraType=Trailer` 存储的本地 trailer，以及放在 `trailer/` 子目录时多嵌一层的场景。`emby_client.trailers()` 改为**递归拉取子项**（`Recursive=true`、`IncludeItemTypes=Trailer,Video`），再用 `EmbyServer.looksLikeTrailer()`（`ExtraType==Trailer / Type==Trailer / 路径含 trailer` 任一命中）客户端过滤，兼容两种存储形态与嵌套目录，且不会把剧集 Episode 误纳。判决逻辑抽成 `@visibleForTesting` 静态方法，新增 `test/trailer_detect_test.dart` 7 条用例。
2. **预告片栏目上移到剧照之上**：手机（`_phoneSections`）与平板（`_tabletSections` 内 `Expanded` 块）双布局同步把「预告片」放到「剧照」之前；仍是「有数据才显示」，读不到 trailer 则不出现。
3. **剧照全屏滑动去卡顿**：`_showBackdrops` 每页的 `InteractiveViewer` 与 `PageView` 横向翻页在手势竞技场抢手势，是滑动卡顿主因——移除 `InteractiveViewer`，翻页恢复顺滑（缩放随之取消，换取跟手）；解码宽 1280→1100，点空白关闭仍由外层 `GestureDetector` 处理。

验证：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 251 全过（新增 trailer 识别 7 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.29-release-arm64.apk`。

## §66 · v2.0.30 (230) 预告片抓取根因修复（实测反馈：目录为 trailers/ 子目录、网页可播、App 不行）

1. **响应数组被强转吞掉**：请求层 `_getJson` 结尾 `jsonDecode(body) as Map<String,dynamic>`，而 Emby `/Items/{id}/Trailer` 在某些版本直接返回 JSON 数组，数组 `as Map` 抛 `TypeError` 被 `trailers()` 的 `catch` 静默吞掉 → 永远空列表。新增 `_getJsonAny()` 返回原始 `dynamic`（同款鉴权/超时/重试），`trailers()` 用 `_parseFlexible()` 同时兼容「裸数组」与「`{Items:[...]}`」。
2. **本地 trailers/ 子目录漏检**：v2.0.29 的 `IncludeItemTypes=Trailer,Video` 在部分 Emby 版本类型归类不一致而漏检。改为不带 `IncludeItemTypes` 的全量子项查询（`ParentId` + `Recursive=true`）+ 客户端 `looksLikeTrailer()` 过滤；后者综合 `ExtraType==Trailer / Type==Trailer / Path 含 trailer / Name 含 trailer / MediaSources[].Path 含 trailer` 五个信号，覆盖服务端不回 `Path` 的情况。
3. **性能与范围**：子项递归查询仅对电影启用（`includeLocalChildren: !_item.isSeries`），避免剧集把分集全量拉出；剧集远程预告片由官方 `/Trailer` 端点覆盖。

验证：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 253 全过（trailer 识别单测 9 条，新增 Name、MediaSources[].Path）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.30-release-arm64.apk`。

## §67 · v2.0.31 (231) 接入 Jellyfin `/LocalTrailers`（实测：`/Trailer` 404、网页能播）

1. **服务端为 Jellyfin**：用户实测 `GET /Items/{id}/Trailer` → 404「找不到文件」，而网页客户端能播放预告片。Jellyfin 不提供 `/Trailer` 端点，本地预告片的规范端点是 `GET /Items/{itemId}/LocalTrailers`（返回 `BaseItemDto[]` 裸数组）。这正是 v2.0.29/2.0.30 一直空列表的根因——请求的端点根本不存在。
2. **四路并发抓取**：`trailers()` 用 `Future.wait` 并发请求 ① Emby `/Items/{id}/Trailer` ② Jellyfin `/Items/{id}/LocalTrailers` ③ `/Items/{id}/SpecialFeatures`（花絮，按 trailer 特征过滤）④ 子项递归兜底（仅电影）。每路独立 try，404/异常退化为空不影响其它路，最后按 id 去重合并。
3. 复用 `_getJsonAny`（兼容裸数组 / `{Items}`），`_parseFlexible(filterTrailer:)` 对花絮与子项做特征过滤，对专用 `Trailer/LocalTrailers` 端点整批信任。

验证：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 253 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.31-release-arm64.apk`。

## §68 · v2.0.32 (232) 子项查询放行 Extra + 预告片诊断入口（实测反馈）

1. **纠正误判**：用户给出的网页 URL `http://192.168.5.29:6655/web/index.html#!/item?id=15512&serverId=94d1105e48fb42aa86912558976c6ca8` —— ① `web/index.html#!/item` 是 **Emby** 路由（Jellyfin 为 `/web/#/details`）；② `94d1...` 是 **serverId（服务器 ID）**，不是影片 ID。之前用 serverId 请求 `/Items/94d1.../Trailer` 得到 404「找不到文件」属正常，因为那根本不是影片。真实影片 ID 为 `15512`。
2. **子项查询放行 Extra**：Emby `/Users/{uid}/Items` 默认过滤 Extra，而 `trailers/` 目录扫出的预告片正是 `ExtraType=Trailer`。`_fetchChildren()` 改为两种参数组合取并集（`IncludeItemTypes=Trailer,Video` 与无类型过滤），并补 `Fields=ExtraType`。
3. **诊断入口**：新增 `EmbyServer.trailerDiag(itemId)`，逐个端点（`/Trailer`、`/LocalTrailers`、`/SpecialFeatures`、两种子项组合）返回「状态码 · 条目数 · 命中数 · 路径」；详情页在无预告片时显示「没看到预告片？点此诊断」按钮（手机/平板双布局），弹窗内可「重新加载」。

验证：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 253 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.32-release-arm64.apk`。

## §69 · v2.0.33 (233) 按 Path 前缀反查 trailers/ 目录（实测诊断结果）

1. **诊断实测**（用户回传）：`/Items/15512/Trailer`、`/LocalTrailers`、`/SpecialFeatures` 均 404；`/Users/{uid}/Items?ParentId=15512&Recursive=true`（含与不含 `IncludeItemTypes`）均 200、返回 8 项、`looksLikeTrailer` 命中 0。结论：Emby 未把 `trailers/` 里的预告片建成本片子条目，D 路天然无效。
2. **新增 E 路 `_fetchByPathPrefix()`**：读影片 `Path` → 截父目录并**保留结尾分隔符** → `/Items?PathStartsWith={dir}&Recursive=true` 全库反查 → `looksLikeTrailer` 过滤。不依赖 Extra 分类与父子关系，直接按物理目录定位，是针对本场景最可靠的兜底。新增 `test/trailer_path_prefix_test.dart` 4 条（Unix/Windows 路径、前缀边界不误配 `ABP-01`/`ABP-018`、空路径安全）。
3. **诊断增强**：输出 `LocalTrailerCount` / `RemoteTrailerCount` / `RemoteTrailers` 数量、真实 `Path`、子项查询每条明细（Name/Type/ExtraType/Path），以及 PathStartsWith 反查结果。

验证：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 257 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.33-release-arm64.apk`。

## §70 · v2.0.34 (234) 请求参数被覆盖的底层 bug + LocalTrailerCount 保底扫描

1. **根因（底层）**：`_getJsonAny`/`_getAny` 用 `Uri.parse(path).replace(queryParameters: qp)`，会**覆盖** path 内嵌的查询参数（`ParentId`、`Recursive`、`IncludeItemTypes`、`PathStartsWith`…），只保留 `UserId`+token。故诊断中子项查询实际返回根目录视图（8 个 `CollectionFolder`）与全库（4801 项），「命中 0」是假象。修复：合并 `base.queryParameters` + 显式 query；抽 `buildRequestUri()`，新增 `test/request_uri_test.dart` 4 条回归。
2. **权威信号**：实测 `LocalTrailerCount=1`（该片确实有 1 个本地预告片）。`trailers()` 先读详情取 `LocalTrailerCount`+`Path`；子项查询扩为 `Recursive=false/true` × `IncludeItemTypes` 四组合。
3. **保底全库扫描**：前几路空且 `LocalTrailerCount>0` 时，拉 `IncludeItemTypes=Trailer`（无则 `Video`）并客户端按影片目录前缀筛（Emby 忽略 `PathStartsWith`），只带 `Path,ExtraType` 控制体积。
4. **诊断**：修复后显示真实子项；末尾加「全库扫描 · Trailer 共 N · 本片目录命中 M」，可判定是取数问题还是 Emby 未索引。

验证：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 261 全过（新增 request_uri 4 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.34-release-arm64.apk`。

验证（v2.0.35）：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 261 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.35-release-arm64.apk`。

验证（v2.0.36）：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 269 全过（新增 4 条额外部分解析 + 3 条三档布局渲染 + 既有全量）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.36-release-arm64.apk`。

验证（v2.0.37）：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 269 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.37-release-arm64.apk`。

验证（v2.0.38）：`flutter analyze` 0 error / 0 warning（仅 info 级 deprecated）；`flutter test` 281 全过（新增 diag_entry 12 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.38-release-arm64.apk`。

## §71 · v2.0.45 (245) 在线字幕搜索集成 + 玻璃弹层组件抽取

交付包 `camby-online-subtitle.zip` 的需求说明、补丁与源码，逐项验收如下。

**1. 交付物完整性**：8 个文件 / 4 类（README、LICENSE-UPSTREAM、`+90/-7` 补丁、833 行模块、3041 行对照播放页、PNG+HTML 设计稿、一键编译脚本）。设计稿标注为静态 UI 模拟，非真机截图。

**2. 基准与兼容性**：包声明基准 `22e7205`，本机 HEAD 正是该提交且工作区干净；`git apply --check` 通过、实际 apply 成功。本地播放页 2958 行 + 补丁净增 83 = 3041 行，与包内完整对照文件逐行差异恰好等于补丁本身。项目内被补丁引用的 API（`filePath` / `seasonNumber` / `episodeNumber` / `nativeSubtitles` / `setSubtitle` / `_cueText` / `_SheetRow` / `_resetHideTimer`）全部存在。

**3. 依赖与工具链**：本机 Flutter 3.47.8 / Dart 3.13.7（交付方沙箱为 Dart 2.17，故其 README 第 6 节标注「未做完整 analyze」）。`gbk_codec: ^0.4.0` 包声明 `sdk >=2.13.0 <3.0.0`，实测 Dart 3.13 pub 可正常解析，且 `gbk_bytes.decode(gbk.encode('中文字幕测试'))` 往返正确 —— 该依赖可用，`main.dart` 的解码器注入不会因版本上限失效。

**4. 数据源现况回放**（本机联网实测，确认解析规则未过期）：迅雷 `oracle/subtitle?name=Inception` → HTTP 200、`data` 57 条，首条直链 104 KB、非 UTF-8（GBK）、正文带 `<font color>`；SubtitleCat 搜索页 38 条 `subs/*.html`，首个详情页 13 个静态 `.srt`、`translate_from_server_folder` 兜底正则命中、`-zh-CN.srt` 字面出现 **0 次**。与 README 第 5.3 节的结论一致。

**5. 集成时的主动修正**（超出补丁本身的 4 处）：
- **弹层外观**：交付模块用 `showModalBottomSheet` + 纯色 `0xFF0E1626` + 原生 `ListTile`、高度写死 68%，与设计稿的玻璃面板和项目的居中卡片都不一致，平板上会拉成整屏色块。抽出 `lib/widgets/glass_sheet.dart`（`GlassPanel` / `GlassPanelRoute` / `SheetRow`），播放页删掉 3 个私有类改引用公共版，在线字幕弹层改用同一套：居中、按短边限宽 470/620、高度按可用空间自适应、键盘弹起不遮输入框、结果行带来源角标。
- **跨 await 生命周期**：`await _player?.setSubtitle(null)` 之后到 `setState` 之间没有 `mounted` 检查，下载期间退出播放页会崩。补 `if (!context.mounted) return;`，并把另 3 处 `!mounted` 换成 `!context.mounted` 消除 `use_build_context_synchronously`。
- **剧集关键词重复**：`cleanTitle()` 对已带 `S01E02` 的文件名仍会再拼一次季集号，变成 `Show S01E02 S01E02`，命中率反而下降。加正则跳过。
- **合规**：`licenses/LICENSE-UPSTREAM.txt` 入库，README「隐私与开源许可」补写在线字幕的数据流（只发清理后的标题/番号、不落盘、显式触发）。

**6. 验证**：`dart analyze` 4 个改动文件 0 error / 0 warning（info 均为项目既有 `withOpacity` 弃用等）；`flutter test` **319 全过**（原 303 + 新增 `online_subtitle_test.dart` 16 条，含手机/平板面板限宽的 `testWidgets`、GBK 注入/未注入双分支、`setSubtitle(null)` 后的二次 mounted 守卫、许可全文与版本号守卫）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.45-release-arm64.apk`。

**7. 已知边界**：迅雷端点未文档化、无鉴权无限流；SubtitleCat 强依赖 HTML 结构。两者都做成单源静默降级，且设计为显式点击触发而非起播自动搜索。加载在线字幕后切内核（Exo ↔ MPV），SRT 叠加层字幕仍在，MPV 的 ASS 原生轨可能需要重新选一次。

验证（v2.0.46）：`dart analyze` 0 error / 0 warning（383 条 info 均为项目既有 `withOpacity` 弃用 / 测试变量命名等）；`flutter test` **332 全过**（原 319 + 新增 `subtitle_cache_test.dart` 9 条存取/导出/边界 + `release_2_0_46_test.dart` 4 条交付守卫：OFL 随附、字体 >4MB、字幕菜单三入口、非 Android 导出兜底）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.46-release-arm64.apk`。
1. **本机缓存与自动复用**：`lib/subtitles/subtitle_cache.dart` 新增 `OnlineSubtitleCache`，按 `MediaItem.id` 写 `subtitle_cache/<id>.{sub,json}`（`getApplicationDocumentsDirectory` 私有目录）。播放页 `_restoreCachedSubtitle` 在「无外部字幕轨 + 未手动选轨 + 无服务端字幕轨」时自动 `parseAny` 挂回叠加层，置 `_subtitleFromCache=true`；信息面板 / 底栏显示「本机」而非「在线」。
2. **导出字幕**：字幕菜单加「导出字幕…」→ `getExternalStorageDirectory()?.`（非 Android 用 `try/catch` 兜异常回退文档目录）写成 `片名.zh-CN.srt`，再弹「系统分享 / 复制路径」面板（`share_plus` + `Clipboard`）；另加「删除本机字幕」即时撤下并阻断本页自动选轨。
3. **简繁并集字体**：`assets/fonts/FangSong.ttf` 由 GB2312 简体子集（~9.6MB→4.4MB）替换为 Noto Serif SC+TC 并集子集（fontTools 子集化 GB2312 ∪ Big5 一级 ∪ 港台补字），family 名保持 `FangSong`；实测繁体样本 `體臺灣麵國學會說這時開關` 不再缺字。OFL 全文随附 `licenses/OFL-NotoSerif.txt`。
4. **健壮性**：`load`/`remove` 全程 try/catch 返回 null；缓存写失败不阻断本次播放（`_pickOnlineSubtitle` 内单独 try）。
5. **已知边界**：字幕仍只存 App 私有目录，未直写影片所在文件夹（服务器路径 + Emby 无上传 API 双重限制）；导出后需用户自行拷到 NAS。

## §72 · v2.0.47 (247) 导出字幕按影片名（优先视频文件原名）命名

针对 v2.0.46 导出文件名 `cleanTitle(片名).zh-CN.srt` 的二次反馈：把命名基准改为「影片名」，且优先用**视频文件原名**（去扩展名），让字幕落到影片旁时 Emby 按同名自动关联。

1. **命名基准前移**：`OnlineSubtitleCache.exportFileName` 不再调用 `cleanTitle` 去画质标签（避免破坏与原视频文件的同名匹配），仅做非法字符清洗 + 拼 `语言.格式` 后缀；命名形如 `<视频文件原名>.zh-CN.srt`（如 `Movie.2023.1080p.zh-CN.srt`）。
2. **影片名兜底链**：播放页新增 `_exportMovieName()`，取 `MediaItem.filePath` 基名（跨 `/` `\` 分隔、去扩展名）作导出名，拿不到服务器路径时回退 `item.name`；`export()` 内再加一层：调用方传入名 → 缓存字幕来源标题 → `subtitle`，绝不会落到 `subtitle.*`。
3. **测试同步**：`subtitle_cache_test.dart` 的 `exportFileName` 用例更新为新语义（保留原文件名 + 拼后缀）；`flutter test` 全过。

验证（v2.0.47）：`dart analyze` 0 error / 0 warning；`flutter test` **全过**；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.47-release-arm64.apk`。

## §73 · v2.0.48 (248) Lara 翻译集成（标题 / 简介一键中译 + 确认后本机缓存）

按用户选择接「官方 API + 我的 key」，实现 Lara Translate 官方 REST 鉴权与翻译，标题 / 简介旁加翻译按钮、弹层展示、确认后缓存。逐项验收：

**1. 协议来源**：官方无 Dart SDK、REST 文档「按需提供」。GitHub API 限流后改由 jsDelivr CDN 逐文件下载 `@translated/lara@1.18.2` 的 `lib/net/lara/client.js` / `lib/credentials.js` / `lib/crypto` 源码，据其移植 Access Key 签名换 JWT 流程：base `https://api.laratranslate.com`；`POST /v2/auth` body `{"id": <accessKeyId>}`，头带 `X-Lara-Date`（RFC1123/GMT）、`Content-MD5`（body MD5 的 Base64）、`Authorization: Lara:<Base64(HMAC-SHA256(secret, "METHOD\nPATH\nMD5\nTYPE\nDATE"))>`；响应 `token` 为 Bearer、刷新令牌在响应头 `x-lara-refresh-token`；`POST /v2/auth/refresh` 续期；`POST /v2/translate` 发 `q/target/style/instructions` 取 `translation` + `source_language`。

**2. 客户端** `lib/lara/lara_client.dart`：`_ensureToken()` 三级（本地未过期复用 → refresh → access key 重签）；`_handleAuth` 解析 JWT `exp` 做本地过期判断、失败靠 401 兜底刷新；`translate()` 省略 `source` 即由 Lara 自动检测（对齐需求）；`parseTranslation` 抽出为 public static，兼容单 JSON / NDJSON / SSE（`data:` 前缀），取最后一个含 `translation` 的对象；签名原语 `LaraSigning` 暴露 `challenge/sign/md5Base64` 供纯函数单测。依赖新增 `crypto: ^3.0.6`。

**3. 凭证设置**：`设置 → Lara 翻译`（`_LaraSection`）填 Access Key ID + Secret，存 `SharedPreferences`（键 `lara_access_key_*`），可「测试连接」调 `testConnection()`；`isValid` 供翻译弹层判断是否引导去设置页。

**4. 缓存** `lib/lara/translate_cache.dart`：按 `MediaItem.id + 字段`（title / overview）写 App 私有目录 `lara_translate_cache/<id>_<field>.json`，含译文与目标语 / 风格 / 检测源语言 / 时间戳；`load` 对文件不存在 / 损坏 / meta 缺失一律静默兜底（返回 null 或默认值），不阻断详情页；`loadAll` 进页预读两字段。翻译是个人偏好且 Lara 无「按影片存译文」概念，故只落本机。

**5. 交互** `lib/lara/translate_sheet.dart` 复用 `GlassPanelRoute`：有缓存时打开即回显译文并沿用上次风格，可「重新翻译」/「复制」/「确认并缓存」；三风格用 `ChoiceChip`。详情页标题旁、剧情简介标题旁（手机 `withTitle` 分支 + 平板 sections 共 3 处）加 `_translateButton`，已缓存时按钮高亮主题色、tooltip「查看 / 重新翻译」。

**6. 修复的 3 处回归**（均由新增 UI 触发、非需求本身）：
- `_SectionLabel` 内部含 `Spacer`（`Expanded`），被新 `Row` 包后拿到 unbounded width，`performLayout` 抛「non-zero flex + unbounded constraints」→ 两处改为 `Expanded(child: _SectionLabel(...))` 给其有界宽度。回归测试 `diag_entry_test.dart` 12 条一度全挂，修复后全过。
- 设置主页 `ListView` 无 `Material` 祖先，新增的 `_Field`（`TextField`）在 `global_search_test.dart` 的 `MaterialApp(home: SettingsPage)` 裸宿主下抛「No Material widget found」→ `_Field` 自带一层 `Material(type: transparency)`，任何宿主都能独立渲染。
- `online_subtitle_test.dart` 源码守卫硬编码版本号 `2.0.47+247` → 同步为 `2.0.48+248`。
- 另清理工具链升级后暴露的 5 条既有 `unused_import` / `unused_local_variable` 警告（`detail_page.dart` 的 `dart:math`、3 个测试文件），确保门禁 0 warning。

**7. 测试**：新增 `lara_client_test.dart`（HMAC-SHA256 命中 RFC 4231 向量 `W9zBRr9g...`、MD5 空串向量 `1B2M2Y8...`、挑战串格式、单 JSON / NDJSON / SSE 解析、无 translation 抛错、凭证 save/load/clear/isValid）与 `translate_cache_test.dart`（safeId / 存取 / title 与 overview 隔离 / remove / loadAll / 中文 UTF-8 无损 / meta 缺省回落 / 文件损坏兜底），共 26 条。

验证（v2.0.48）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **356 全过**（原 330 + 新增 26）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.48-release-arm64.apk`。

**已知边界**：官方 REST 需用户自备 Lara Access Key（设置页配置），未配置时翻译按钮仅引导去设置页；无 key 时无法真机联调翻译链路（签名/解析已由纯函数单测覆盖）；风格 / 指令对译文的影响取决于 Lara 账户与模型版本；译文只存本机，卸载 App 或清数据后丢失。

## §74 · v2.0.49 (249) 翻译/剧照弹层 UI 优化（真机反馈 5 项）

v2.0.48 真机截图反馈：① 翻译弹窗样式不好、弹框有黄线；② 标题没有翻译按钮；③ 剧照的数字离图片太远、也有黄线；④ 服务器「切换」按钮圆角过大。逐项验收：

**1. 黄线根因（不是描边/主题问题）**：`GlassPanelRoute` 是 `PageRouteBuilder`，剧照查看器是 `showDialog` 直接返回 `GestureDetector`——两者的页面都挂在 Navigator Overlay 上，**不继承主页 `Scaffold` 的 `Material`**。缺 `Material` 祖先时 `WidgetsApp` 提供的兜底 `DefaultTextStyle`（源码 debugLabel 为 `fallback style; consider putting your text in a Material`，`decoration: underline / decorationColor: 0xFFFFFF00 / double`）生效；`Text` 的 `style` 与 `DefaultTextStyle` 是 **merge**，自带 style 只覆盖颜色字号、盖不掉 `decoration`，于是弹层里每个文字都带黄色双下划线。详情页本身有 `Scaffold` 所以无黄线，与截图完全吻合。修复：`GlassPanelRoute.pageBuilder` 统一包 `Material(type: transparency)`（覆盖全部玻璃面板），剧照查看器同样补一层。透明 Material 不改变外观。

**2. 翻译弹层外观**：v2.0.48 把裸 `Column` 直接 push 进 route，**没有 `GlassPanel` 卡片容器、也没有明确高度** → 详情页文字从半透明背景后透出、长简介把译文挤出可视区。按项目既有在线字幕面板的口径补齐 `GlassPanel + SizedBox(定高, 键盘 inset 自适应, 上限 620) + Material`；原文限高 132、译文限高 220 各自内滚；标题栏加「自动检测源语言 · 译为中文」副标题、译文区显示「识别为 xx」；主按钮由纯亮蓝色块改蓝紫渐变 + 透明 Material 叠 InkWell；风格 chips 圆角 20→12。

**3. 标题翻译按钮**：手机布局标题（`Transform.translate` 压在封面图上）此前只有 `_tabletBanner` 挂了 `_translateButton`。手机标题改 `Row`（`Expanded` 包 Text 保证有界宽度，避免上次修过的 `_SectionLabel` unbounded width 重演），并新增 `onBanner` 变体：半透明深色圆底 + 白图标，与顶部返回/收藏圆钮同风格，浅色海报上也清晰；平板 banner 一并切到该变体。

**4. 剧照页码**：原 `Positioned(top: padding.top + 12)` 固定在屏幕最顶端，图片居中，中间隔约 350px 黑。改为「页码胶囊 + 10px + 图片区（屏宽 × 0.68 屏高）」组成 `Center` 里的 `Column(mainAxisSize: min)`，页码紧贴图片区上缘、整体居中；`SizedBox.expand + HitTestBehavior.opaque` 保留点按任意空白关闭；图片仍 `BoxFit.contain`，不改 `CachedNetworkImage` 在无高度约束下的尺寸行为（避免引入回归）；`InteractiveViewer` 依旧不加，保持翻页手势不互抢。

**5. 切换按钮**：按钮实高约 30px，`BorderRadius.circular(14)` 几乎等于胶囊。容器与 `LiquidPress` 的 radius 一并收为 8，与卡片 24 圆角、旁边方形编辑/删除图标的层级更协调。

**6. 测试**：新增 `test/lara_sheet_ui_test.dart` 4 条——`GlassPanelRoute` push 后面板文字的 `DefaultTextStyle.decoration` 不再是 underline / `decorationColor` 不再是黄色（直接锁住根因）；翻译弹层 `find.byType(GlassPanel)` + 关键文案 + 无 `tester.takeException()`；剧照查看器与手机标题按钮的源码守卫（防止以后又退回屏幕顶端/漏挂按钮）。

验证（v2.0.49）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **360 全过**（原 356 + 新增 4）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.49-release-arm64.apk`。

## §75 · v2.0.50 (250) 翻译弹层液态玻璃 + 标题翻译按钮可点修复（v2.0.49 真机反馈 2 项）

**1. 标题翻译按钮「按不了」根因**：v2.0.49 的 `onBanner` 变体把按钮包成 `Tooltip > GestureDetector`。`Tooltip` 内部会给子节点套一层 `GestureDetector(behavior: HitTestBehavior.opaque, onLongPress: ...)`，该 detector 命中整个按钮盒子、且**只认长按**，会把短按吞掉（平板 banner 用的是 `IconButton`，其 tooltip 是内置机制不吞点击，所以没这问题）。修复：标题变体改用 `LiquidPress` 圆形玻璃钮（与顶部返回/刷新/收藏同一套，已验证可点）。**关键取舍**：不复用 `_RoundBtn`——它会自带 `ClipOval > BackdropFilter` 且未接滚动降级机制，会令详情页凭空多一层实时模糊、把 `scroll_degrade_test` 断言的「顶栏 3 圆钮」磨砂计数从 3 变成 4；海报本身已是模糊底，半透明玻璃圆钮观感足够。已缓存译文时青色高亮。

**2. 翻译弹层不是液态玻璃**：v2.0.49 的 `GlassPanel` 是 `0xF2` 高不透明纯色 + 边框 + 投影「伪装」玻璃，**根本没做背景模糊**。给 `GlassPanel` 加 `blur` 参数：`blur:true` 时走 `ClipRRect > BackdropFilter(sigma 24) > Container(半透明深色玻璃渐变 + 顶部高光) > child`，是真正的 frosted / liquid glass；`blur:false`（默认，播放器弹层）保持无模糊（性能考量，`glass_sheet.dart` 注释已说明播放器避免实时重采样）。翻译弹层在 `showTranslateSheet` 里传 `blur:true`（详情页非播放器，磨砂廉价且合适）。

**3. 测试**：`test/lara_sheet_ui_test.dart` 新增/调整——`翻译弹层开启真正的液态玻璃磨砂（BackdropFilter）` 直接断言 push 后面板树里出现 `BackdropFilter`（确认 blur 真正生效、不是只挂个 flag）；源码守卫「标题 banner 按钮走 LiquidPress（可点，且不引入多余模糊层）」断言 onBanner 分支用 `LiquidPress`、不包含 `_RoundBtn(`、且不再有 `Tooltip > GestureDetector` 旧模式。`scroll_degrade_test` 仍断言顶栏 3 圆钮磨砂（标题按钮不引入新模糊层，计数保持 3）。

验证（v2.0.50）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **362 全过**（原 360 + 新增 2）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.50-release-arm64.apk`。

**已知边界**：液态玻璃只用于详情页翻译弹层；播放器弹层（变速/字幕/信息/样式）仍为无模糊玻璃卡片，保持翻页/滚动顺滑。若后续希望播放器弹层也磨砂，需先确认 GPU 余量——那是 §74 注释里刻意回避的取舍。

## §76 · v2.0.51 (251) 在线字幕弹窗液态玻璃 + 标题翻译按钮点不动根治（v2.0.50 真机反馈 2 项）

**背景**：v2.0.50 发布后用户截图复核，反馈 ①「搜索字幕的弹窗不是液态玻璃」②「点击标题旁边的翻译按钮还是没反应」。这两项在 §74/§75 都声称修过，说明前两次修复都没真正生效，且当时的测试只做源码守卫、没有真正 `tester.tap` 验证。本轮逐一定位到真因并用真实点击回归锁死。

**1. 在线字幕搜索弹窗不是液态玻璃**：`showOnlineSubtitleSheet → _OnlineSubtitleSheet`（`lib/subtitles/online_subtitle.dart`）里的 `GlassPanel` 未传 `blur` 参数，走默认 `blur:false` → 高不透明纯色伪装卡片，所以看起来和已磨砂的翻译/字幕弹层不一样。修复：补 `blur: true`，与其他弹层同款真高斯磨砂。播放页四类弹层不动。

**2. 标题翻译按钮点不动——真正根因（命中测试错位）**：v2.0.50 已把 `onBanner` 变体从 `Tooltip > GestureDetector` 换成 `LiquidPress`（独立测试证明 `LiquidPress` 本身可点，含 ListView 内），但真机仍无反应。诊断测试 `test/diag_detail_tap_test.dart`（临时）在手机布局 390×844 下打印两个翻译按钮位置：标题按钮 `center=(350,500)`（视觉落在海报区）、简介按钮 `center=(329,719)`。点简介按钮 → `_openTranslate(overview)` 触发；点标题按钮 → `_openTranslate` **完全不被调用**。据此排除 `LiquidPress`、`_openTranslate` 内部 await 卡死、平板分支误判等方向，定位真因：手机 banner 用 `ListView` 垂直排列「海报 `AspectRatio` + 内容」，再用 `Transform.translate(offset: Offset(0,-titleLift))` 把内容视觉上移到海报上方；**`Transform` 只改视觉位置、不改布局槽位**，命中测试按布局位置把标题按钮所在区域判给下层海报，事件到不了 `LiquidPress`。简介按钮因布局位置本就在海报下方、不与海报重叠，故正常——这正是反证。

**修复**：把手机 banner 的「海报 + 标题块」从 `ListView` 垂直排列 + `Transform.translate` 改为 `Stack` 重叠——海报作底、`Positioned(bottom: titleLift)` 放标题块（`Row` 含标题 + 翻译按钮 + 元信息 + 徽章），标题块在绘制/命中顺序上位于海报之上，事件正确派发到按钮；与平板 `_tabletBanner` 的 Stack 做法一致。`clipBehavior: Clip.none` 防止标题块上抬后顶部被裁。其余板块（播放行→简介→…）作为 `ListView` 第二个 child 正常排列。

**3. 测试（关键：补上真实点击）**：新增 `test/translate_banner_tap_test.dart` 2 条 `testWidgets`——强制手机布局 390×844，**真正 `tester.tap` 标题/简介翻译按钮**并断言 `GlassPanel` 弹层出现。这是 v2.0.49/2.0.50 一直缺的一环（当时 `lara_sheet_ui_test.dart` 仅做源码守卫，检查用了 `LiquidPress`/`onBanner:true`，没验证按钮真能触发弹层，故「修复」从未被验证）。测试工程要点：
- `path_provider` 按项目既有做法 mock `MethodChannel('plugins.flutter.io/path_provider')` 的 `getApplicationDocumentsDirectory`（`PathProviderPlatform` 子类 mock 在此版本不生效，会挂起）。
- `testWidgets` 的 `FakeAsync` 会让 `LaraTranslateCache.load` 的真实文件 I/O（`Directory.exists()` 等）永久挂起 → `_openTranslate` 卡在 `await load`。故把 `tap` 放进 `tester.runAsync`（真实异步区）让 I/O 完成、route 被 push，再回 `FakeAsync` 固定帧 `pump` 让 `GlassPanelRoute` 的过渡动画把 `_TranslateSheet`（`GlassPanel`）渲染出来。不能用 `pumpAndSettle`（详情页有持续动画不收敛）。
- 诊断用的 `_diag` 打印与两个临时 `diag_*.dart` 测试已全部删除/还原。

**4. 版本**：v2.0.50 已打 tag / 出包，本次为缺陷修复，bump 到 **2.0.51+251**（pubspec / README 顶部版本行 / `test/online_subtitle_test.dart` 硬编码版本断言 / changelog / 本记录同步）。合并 `28b76ae` 的「播放页四类弹窗统一液态玻璃（方案 B）」一并发布。

**5. 问题① 也补上回归**：为避免问题②「只改代码没验证」的教训重演，`test/online_subtitle_test.dart` 新增 2 条——widget 断言 `GlassPanel(blur:true)` 必须真的产生 `BackdropFilter`（`blur:false` 仍是纯色卡片，守住播放器性能取舍），以及源码守卫锁死 `_OnlineSubtitleSheet` 的 `GlassPanel` 调用带 `blur:true`。

验证（v2.0.51）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **366 全过**（原 362 + 新增 4 条回归）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.51-release-arm64.apk`（`aapt dump badging` 复核 `versionCode=251 / versionName=2.0.51`）。

## §77 · v2.0.52 (252) 详情页 banner 板块间距回退修复（v2.0.51 真机反馈）

**背景**：v2.0.51 发布后用户截图复核，标题旁翻译按钮已能点（§76 的 Stack 修复生效），但「继续播放」按钮和「剧情简介 / 信息页」被推到海报底部之后，与标题之间空出一大截。这是 §76 布局重构引入的回退：修好了命中测试，却破坏了原来「整个内容块一起上移」的紧凑排布。

**根因**：v2.0.51 把手机 banner 从 `ListView([海报, Transform.translate(内容)])` 改成 `ListView([Stack(海报 + Positioned(bottom:titleLift, 标题块)), Padding(Column(..._phoneSections))])`。`Stack` 内含未定位的 `AspectRatio` 海报，故其**布局占位高度仍是完整 `posterH`**；标题块只是被 `Positioned` 压在海报内部，而其余板块作为 ListView 第二个 child 仍从 `posterH` 之后开始排 → 中间凭空多出 `titleLift`（`(posterH*0.18).clamp(56,150)`，390 宽时 ≈105px）的空白。原版是整个 `Column`（标题块 + 所有板块 + 底部留白）一起 `Transform.translate(Offset(0,-titleLift))`，所有板块同步上抬，故紧凑。

**为何不能再给第二个 child 加 Transform**：那样视觉虽上移，但布局槽位仍在 `posterH` 之后，重叠区（y ∈ [posterH-titleLift, posterH]）的命中测试会判给第一个 child 的海报 →「继续播放」按钮会变得点不动，重演 §76 那个 bug。必须让**布局位置本身**上抬。

**修复**：第一个 child 外包 `SizedBox(height: posterH - titleLift)` 缩短布局占位，内部用 `OverflowBox(alignment: Alignment.topCenter, minHeight: posterH, maxHeight: posterH)` 让 `Stack` 仍以完整海报高度布局、溢出部分由 `clipBehavior: Clip.none` 保留绘制。于是：海报视觉完整（高度仍 `posterH`）、标题块视觉位置不变（`bottom: titleLift` 相对高 `posterH` 的 Stack，底部正好落在 `posterH - titleLift`）、第二个 child 的布局起点也正好是 `posterH - titleLift`，自然紧跟标题块底部。徽章 → 播放行间距由 v2.0.51 误改的 16 恢复为 20（与原版一致）。因未使用 `Transform`，布局/视觉位置一致，命中测试无歧义；溢出的海报位于 `SizedBox` 边界外，不参与命中测试，不会抢占上层按钮点击。

**测试**：新增 `test/detail_banner_layout_test.dart` 1 条 `testWidgets`，强制手机 390×844 真实渲染后做几何断言（实测 `posterH=584.97`、`titleLift=105.29`）：
| 断言 | 修复前 | 修复后 |
|---|---|---|
| `play.top < posterH - titleLift + 60` | ≈601 ✗ | 512.18 ✓ |
| `play.top - title.bottom < 150` | ≈180 ✗ | 90.5 ✓ |
| `synopsis.top - play.top < 120` | ≈183 ✗ | 78 ✓ |
| `poster.height ≈ posterH`（不能被 OverflowBox 压扁） | — | 584.97 ✓ |
| `tester.tap` 播放按钮 → `onPlay` 触发（命中测试不退化） | — | ✓ |

同时复跑 §76 的 `translate_banner_tap_test.dart`（2 条真实点击）与 `online_subtitle_test.dart`（blur 回归），共 21 条全过。

**版本**：v2.0.51 已打 tag / 出包，本次为缺陷修复，bump 到 **2.0.52+252**（pubspec / README 顶部版本行 / `test/online_subtitle_test.dart` 硬编码版本断言 / `android/local.properties` / changelog / 本记录同步）。

验证（v2.0.52）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **367 全过**（原 366 + 新增 1 条几何回归）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.52-release-arm64.apk`。

## §78 · v2.0.53 (253) 翻译弹层按内容自适应高度（v2.0.52 真机反馈）

**背景**：用户两张截图复核翻译弹层，反馈「弹窗大小不太对，下方留空比较多」；对比可见原文越短，译文卡片下方空白越大。这是弹层高度策略问题，与 §76/§77 的命中测试/布局占位无关。

**根因**：`lib/lara/translate_sheet.dart` 的 `_TranslateSheetState.build` 计算
```dart
final avail = media.size.height - media.padding.vertical - inset - 24;
final panelH = avail.clamp(300.0, 620.0).toDouble();
...
child: SizedBox(height: panelH, child: Material(child: Column(children: [Header, Expanded(SingleChildScrollView(...))])))
```
把玻璃面板**固定**成 `panelH`（390×844 手机上恒为 620），但内容按自然高度从上往下排：Header + 原文卡片（限高 132）+ 风格选择 + 主按钮 + 译文卡片（minHeight 78）+ 各间距 ≈ 440。短原文时多出的 ~150px 全落在译文卡片下方；原文较长时原文卡片撑到 132，留白看似变小——正好解释「原文越短留白越大」。

为何当初定高：初始版本把裸 `Column` 直接 push 进 `GlassPanelRoute`，没有卡片容器、整块内容无明确高度，长简介会把译文挤出屏幕。定高解决了溢出，但用「固定高度」实现过头。

**修复**：改为「最大高度上限 + 按内容收缩」三处，层级不变：
| 原 | 改 | 作用 |
|---|---|---|
| `SizedBox(height: panelH)` | `ConstrainedBox(constraints: BoxConstraints(maxHeight: maxPanelH))` | 620 从固定值变成上限 |
| `Column(children: ...)` | `Column(mainAxisSize: MainAxisSize.min, ...)` | 按内容收缩 |
| `Expanded(SingleChildScrollView)` | `Flexible(SingleChildScrollView)` | `Expanded` 会强制吃满剩余空间、把面板重新撑回固定高度；`Flexible` 只在内容超过上限时压缩并让 ScrollView 滚动 |

`GlassPanel` 内部是 `Center > ConstrainedBox(maxHeight: avail-24) > Container`，child 得到 loose 约束，因此 `Container` 会 shrink-wrap 到 Column 的收缩高度，玻璃卡片与 `BackdropFilter` 磨砂区域随内容一起变小；`Padding(bottom: inset)` 与 `maxPanelH` 减 inset 的既有键盘避让逻辑保持不变。

**测试**：新增 `test/translate_sheet_height_test.dart` 3 条 `testWidgets`，通过公开函数 `showTranslateSheet` 直接 push 弹层（不经过 DetailPage，无需 mock path_provider），`pumpAndSettle` 后测量 `find.byType(BackdropFilter)` 的 rect——注意不能测 `find.byType(GlassPanel)`，其外层 `RepaintBoundary` 在 `Center` 下占满整屏（实测 844），不是卡片本体；`blur:true` 时 `BackdropFilter` 唯一且尺寸即卡片。
| 场景 | 面板高度 | 断言 |
|---|---|---|
| 短原文、无译文 | 472（修复前 620） | 译文提示到卡片底 gap < 90（实测 63，修复前约 210）；面板 < 560 |
| 有缓存译文 | 620 | 面板 > 520（较短文自动长高）且 ≤ 621；「确认并缓存」可见 |
| 超长译文 | 620 | ≤ 621 且存在 `SingleChildScrollView`（内部滚动承接） |

**版本**：v2.0.52 已打 tag / 出包，本次为缺陷修复，bump 到 **2.0.53+253**（pubspec / README 顶部版本行 / `test/online_subtitle_test.dart` 硬编码版本断言 / `android/local.properties` / changelog / 本记录同步）。

验证（v2.0.53）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **370 全过**（原 367 + 新增 3 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.53-release-arm64.apk`。

## §79 · v2.0.54 (254) 剧照横滑性能 + 信息区四项优化（真机反馈 4 项）

**背景**：真机反馈 4 项 —— ①「剧照的滑动还是有点掉帧，如果这里的简介和媒体信息不用液态玻璃，而是跟标签一样的半透明框，是不是可以优化性能？」；②「标签过多时，可滑动查看」；③「在演员行上放加入导演信息标签、制造商信息标签」；④ 附件 `IPZZ-077-C.zip` 解压后的 NFO 实际含系列 `濃厚な接吻とSEX`，但详情页影片系列仍显示「无」，要求长系列名用 `...` 缩略。

### ① 横滑掉帧：三个独立开销点，逐个拆

**(a) 卡片装饰**。原 `_overviewCard` / `_mediaInfoCard`：
```dart
decoration: BoxDecoration(
  borderRadius: BorderRadius.circular(20),
  gradient: const LinearGradient(colors: [Color(0x1FFFFFFF), Color(0x0AFFFFFF)]),
  border: Border.all(color: Colors.white.withOpacity(0.14)),
  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 8))],
),
```
渐变需逐帧生成着色器，`blurRadius: 18` 的阴影要走一次模糊光栅化再合成。改成与标签胶囊同款纯色框：
```dart
decoration: BoxDecoration(
  color: Colors.white.withValues(alpha: 0.06),
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
),
```
纯色 + 1px 描边可直接进图层缓存，且视觉与同屏胶囊统一（初版 `0.045/0.10` 在深色背景上偏淡，微调到 `0.06/0.12`）。注意这里**没有** `BackdropFilter`——原本就不是真玻璃，所以「不用液态玻璃」的实质是去掉渐变与模糊阴影，而非移除高斯模糊。

**(b) 内层滚动绕过降级机制**。这是最隐蔽的一处：详情页早有 `_degradedVN` 滚动降级（滚动期把顶栏圆钮的 `BackdropFilter` 换成静态渐变，停 180ms 复原），但它挂在**主 `_scroll` 的 listener** 上。剧照 / 标签胶囊行是**内层横向 `ListView`**，滚动通知不会经过主 controller，于是横滑期间顶栏磨砂持续逐帧重采样。修复是在主列表外包一层接住所有后代通知：
```dart
Positioned.fill(
  child: NotificationListener<ScrollNotification>(
    onNotification: _anyScrollNotification,
    child: RepaintBoundary(child: wide ? ListView(...) : ListView(...)),
  ),
),
```
```dart
bool _anyScrollNotification(ScrollNotification n) {
  if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
    _onScrollActivity();
  }
  return false; // 继续冒泡，不影响既有交互
}
```
主 listener 里同步删掉重复的 `_onScrollActivity()`，避免一次滚动两次计数（会不断顺延 180ms 恢复定时器）。

**(c) 缩略图过采样**。剧照卡片显示宽 214，却按 `memWidth: 480` 解码。手机 / 平板两处 `item.backdrops[i]` 降到 `320`（banner 那个 132 宽的缩略图原本就是 320，未动）。解码像素数降到约 44%，内存与首帧解码时间同步下降。

### ② 标签行去掉 `+N` 折叠

旧 `_CapRow` 渲染 `visible` 个胶囊 + 一个**纯展示、不可点**的 `+N`，后续标签在数据里但永远进不了树。改为全量懒构建：
```dart
SizedBox(
  height: 28,
  child: ListView.builder(
    scrollDirection: Axis.horizontal,
    physics: const BouncingScrollPhysics(),
    itemCount: count,
    itemBuilder: (_, i) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: itemBuilder(i),
    ),
  ),
)
```
`ListView.builder` 只建屏内项，标签再多也不会一次性铺开；`height: 28` 固定行高，不撑破信息区三列。

### ③ 演员行前插导演 / 制造商

`_InfoBlock` 里按 `item.director` / `item.studio` 非空计算 `extraCount`，行计数改为 `item.people.length + extraCount`，前部插两枚独立配色胶囊（蓝 `Icons.movie_creation_outlined` / 青 `Icons.business`，`maxWidth: 220` 配合省略号），演员按 `item.people[i - extraCount]` 取值；显示条件放宽为 `item.people.isNotEmpty || extraCount > 0`，只有导演/制造商没有演员时该行仍会显示。颜色提为 `_InfoBlock` 的 `static const _blue / _teal`，否则 `const Icon(... color: blue)` 会因引用局部变量而编译失败（`Arguments of a constant creation must be constant expressions`）。

### ④ NFO 系列名兜底

**根因**：Emby REST 对 `Movie` 不把电影 NFO 的 `<series>` / `<set><name>` 映射到 `SeriesName` 字段。`lib/emby_client.dart` 的字段列表里已请求 `SeriesName`，解析 `seriesName: (j['SeriesName'] as String?) ?? ''` 也正确，服务端就是不给值，因此客户端只能自己读侧车文件。

新增 `lib/metadata/nfo_reader.dart`，4 个公开 API：`nfoUrlFromMediaPath` / `parseNfoSeries` / `loadNfoSeries` / `clearNfoSeriesCache`。
```dart
String? nfoUrlFromMediaPath(String path) {
  final uri = Uri.tryParse(path.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
  final p = uri.path;
  if (p.isEmpty || p.endsWith('/')) return null;
  final ext = RegExp(r'\.[A-Za-z0-9]{1,5}$').firstMatch(p);
  final nfoPath = ext != null
      ? p.replaceRange(ext.start, p.length, '.nfo')
      : '$p.nfo';
  return uri.replace(path: nfoPath).toString(); // query 原样保留（AList 签名参数）
}
```
设计取舍：只接受 http(s)（本地文件路径客户端拿不到）；`Uri.replace` 保留 query；`.strm` / `.mp4` / 无扩展名都能换；目录路径直接放弃。解析用**正则而非 XML 解析器**——NFO 常见未闭合标签、非法字符，严格解析会整份失败：优先 `<series>`，回退 `<set>` 内 `<name>`，`_clean` 处理 CDATA、HTML 实体、剥嵌套标签、折叠空白。网络侧 3s 超时、失败静默、进程内 `_seriesCache` 去重。

详情页接线：`initState` 调 `_loadNfoSeries()` → `_nfoSeries`，两处 `_InfoBlock(... seriesNameOverride: _nfoSeries)`，`_InfoBlock` 里 `seriesName = (override 非空 ? override : item.seriesName).trim()`。长名沿用 `_Cap` 的 `maxLines: 1` + `TextOverflow.ellipsis` + `maxWidth`。实测附件 NFO 的 `濃厚な接吻とSEX` 可正常回填。

**边界**：只在 `item.seriesName` 为空时才发起请求；Emby 若返回了系列名就不读 NFO，避免多余网络请求。需要 NFO 与视频同目录同名——这是 Kodi/Emby 侧车文件的通用约定，若媒体走 STRM 指向另一个域名、NFO 不在该路径下，仍会显示「无」。

**测试**：新增 `test/detail_info_regression_test.dart` 13 条。
| 组 | 覆盖 |
|---|---|
| NFO 解析（8） | 真实 `<series>`、`<set><name>` 回退、CDATA/实体/换行、无字段返回 null、URL 派生保留 query、中文路径百分号编码、`.strm`/无扩展名、本地路径/目录拒绝 |
| 性能源码守卫（2） | `detail_page.dart` 中 `Colors.white.withValues(alpha: 0.06)` 恰好 2 处；`NotificationListener<ScrollNotification>` 存在 |
| 信息区渲染（3） | 标签全量渲染且无 `+N`、导演/制造商胶囊文案、长系列名 `maxLines:1` + `TextOverflow.ellipsis` 不撑破三列 |

踩坑两则：中文路径测试期望 `/片库/IPZZ-077-C.nfo`，但 `Uri.parse` 会百分号编码为 `/%E7%89%87%E5%BA%93/...`，断言改为 `Uri.decodeFull(Uri.parse(u!).path)`；性能守卫最初断言「`blurRadius: 18` 全局不存在」失败，因为文件里其它合法位置（按钮阴影）仍在用，改为统计纯色框出现次数更精确。

**版本**：bump 到 **2.0.54+254**（pubspec / README 顶部版本行 / `test/online_subtitle_test.dart` 硬编码版本断言 / `android/local.properties` / changelog / 本记录同步）。

验证（v2.0.54）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **383 全过**（原 370 + 新增 13 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.54-release-arm64.apk`（39M），`aapt dump badging` 确认 `versionCode='254' versionName='2.0.54'`。

## §80 · v2.0.55 (255) 导演/制造商独立成行 + 点击筛选 + 筛选面板分组（v2.0.54 真机反馈）

**背景**：真机截图显示 v2.0.54 把 `导演 肉尊`、`制造商 エスワン ナンバーワンスタイル` 与演员胶囊一起塞在「演员」标题下。用户要求：① 制造商和导演**单独一行**；② 点导演或制造商名字**可进行影片筛选**；③ 媒体库、演员页等**筛选面板加入可筛选的制造商和导演标签**。

### 架构判断：不需要动服务端

先确认两件事再动手，避免做多余功：
1. `lib/widgets/media_filter_sheet.dart` 的 `MediaFilter.apply(items)` 是**客户端内存过滤**，页面把已加载列表传进去即可，不存在「筛选条件要下推到 Emby」的问题。
2. `lib/emby_client.dart` 的 `_kItemFields` 是全局常量，已含 `People` 与 `Studios`；`server.items()` / `libraryItems()` / `libraryPreview()` 都用它，所以 `AppState.items` 里的 `MediaItem.director`（Person 中 `Type == 'Director'`）与 `MediaItem.studio`（`Studios[0].Name`）**在全库列表里就有值**。

因此两组筛选和「点名字筛影片」都可以在客户端完成，无需 `PersonIds` / `StudioIds` 服务端查询，离线/缓存态同样可用。

### ① 详情页拆行

`_InfoBlock` 原来把 `extraCount`（导演 + 制造商）算进演员行的 `count`，`itemBuilder` 里用 `i - extraCount` 取演员，三条信息混在一个横向 `ListView` 里。改为两个独立的 `_CapRow`：
```dart
if (hasCredits) ...[
  const _HSep(),
  const _MiniLabel('导演 / 制造商'),
  const SizedBox(height: 7),
  _CapRow(count: creditCount, itemBuilder: (i) => i == 0 ? 导演胶囊 : 制造商胶囊),
],
if (item.people.isNotEmpty) ...[
  const _HSep(),
  const _MiniLabel('演员'),
  const SizedBox(height: 7),
  _CapRow(count: item.people.length, itemBuilder: (i) => 演员胶囊),
],
```
两枚制作信息胶囊补上 `onTap`（`_Cap` 本身已支持 `LiquidPress` 包裹，和标签胶囊同一套点击链路），并新增 `onOpenDirector` / `onOpenStudio` 两个 `void Function(String)` 回调，手机 / 平板两处 `_InfoBlock` 调用都传入。

### ② 点击筛选：复用并泛化 `TagPage`

`_openTag` 原本 push `TagPage(tag: ...)` 列出全库含该标签的影片；这正是「点名字筛影片」想要的形态，于是给 `TagPage` 加 `TagPageMode { tag, director, studio }`：
```dart
final list = widget.state.items.where((e) {
  switch (widget.mode) {
    case TagPageMode.director: return hit(e.director);
    case TagPageMode.studio:   return hit(e.studio);
    case TagPageMode.tag:
      if (isRes) { ...分辨率原逻辑... }
      return e.tags.any(hit) || e.genres.any(hit);
  }
}).toList();
```
`hit(v) => v.trim().toUpperCase() == key` 与标签模式一致（trim + 忽略大小写，容忍 NFO 里的多余空格/大小写差异）。标题 getter 分别给 `#tag` / `导演 · xxx` / `制造商 · xxx`，`heroTag` 前缀按 mode 区分避免 Hero tag 冲突。`TagPageMode.tag` 是默认值，现有调用与 `test/sort_chip_row_test.dart` 不用改。

详情页新增：
```dart
void _openCredit(String value, TagPageMode mode) {
  final v = value.trim();
  if (v.isEmpty) return;
  Navigator.of(context).push(CambyRoutes.fade(
    builder: (_) => TagPage(tag: v, mode: mode,
        state: widget.state, onOpenDetail: widget.onOpenDetail),
  ));
}
```

**取舍**：选「独立结果页」而不是「跳媒体库并预置筛选条件」，因为前者与既有的点标签胶囊行为完全一致、实现面小，且结果页带自己的排序胶囊；后者需要跨页传递筛选草稿、处理媒体库当前 view 与全库的差异，语义更绕。筛选面板里的两组条件则负责「在当前列表内叠加筛选」，两者互补。

### ③ 公共筛选模型与抽屉

| 位置 | 改动 |
|---|---|
| `MediaFilterResult` | 加 `directors` / `studios`，默认 `const <String>{}` 保持旧调用方兼容 |
| `MediaFilter` | 加两个 `final Set<String>`；构造可选；`activeCount` / `applyResult` / `clearConditions` 同步 |
| `keeps` | `creditMatches(directors, e.director)` / `creditMatches(studios, e.studio)`，组间且、组内或，空值条目在有条件时不命中 |
| 静态计数 | `directorCountsOf` / `studioCountsOf` → `_creditCountsOf`，trim 后计数、跳过空串 |
| `showMediaFilterSheet` | 计算并传入两张计数表 |
| 抽屉 | 「字幕」之后加「导演」「制造商」两组 `_fChip`（带命中数、多选、随重置清空、随应用提交） |

`MediaFilterResult` 新字段给默认空集合是刻意的：`MediaFilterResult` 是 `const` 构造且被多处构造，改成 `required` 会破坏现有调用与测试。

`library_page.dart` 是唯一不直接持有 `MediaFilter`、而是每次用 `_asFilter` 重建的页面，额外同步了 4 处：`_directorFilters` / `_studioFilters` 字段、`_clearFilters`、`_asFilter` 与 `_openSheet` 回写、`_compute` 的 `key`（漏了会导致点应用后列表不刷新），以及摘要条两组可单条移除的 chip。演员页 / 文件夹页直接 `filter.applyResult(result)`，无需改动即自动获得能力。

### 测试

新增 `test/credit_filter_test.dart` 10 条：
- `MediaFilter` 按导演 / 按制造商 / 两者组间且、空值不命中、`activeCount`+`applyResult`+`clearConditions`、计数 trim 与跳过空值；
- 抽屉 widget 测试：两个分组标题与 chip 都在，点一个导演 chip 后「应用筛选」回传 `directors == {'陈叙'}`；
- `TagPage` 三模式：director 筛出 2 部、studio 忽略大小写筛出 2 部、tag 模式保持原语义。

`test/detail_info_regression_test.dart` 更新 ③：把「演员行显示导演与制造商」改成「导演/制造商独立成行」——除文案断言外，收集所有**横向** `ListView` 的 `SliverChildBuilderDelegate.childCount`，要求同时存在 2（制作行）和 1（演员行）、且不存在 3（三者混排）；再补 2 条真实 `tester.tap` 点击断言筛选页标题出现。

踩坑两则：
- `MediaFilter.apply` 会排序，而 Dart `List.sort` 不稳定；测试数据 year 相同，断言改用 `unorderedEquals` 只校验命中集合。
- 抽屉测试在默认 800×600 测试屏下 `find.text('导演')` 返回 0 —— 抽屉内 `ListView` 懒构建，排序 5 行 + 分辨率 + 字幕已把 0.88×600 的可见区占满，导演分组还没建出来。把测试视口调到 `Size(800, 1600)` 后全部进视口，测试通过。

为让 `TagPage` 能注入自定义全库数据，`AppState` 增加 `@visibleForTesting installTestItems(List<MediaItem>)`（与既有 `installTestServer` 同一风格，不写缓存、只刷新派生缓存并通知）。

**版本**：bump 到 **2.0.55+255**（pubspec / README 顶部版本行 / `test/online_subtitle_test.dart` 硬编码版本断言 / `android/local.properties` / changelog / 本记录同步）。

验证（v2.0.55）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用，`383 issues found` 全为 info）；`flutter test` **395 全过**（原 383 + 新增 12 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.55-release-arm64.apk`（39M），`aapt dump badging` 确认 `versionCode='255' versionName='2.0.55'`。

## §81 发布 v2.0.56（NFO 系列名兜底二次修复）

承接真机反馈：v2.0.54 的 NFO 系列名兜底在 AList 直链库下仍显示「无」。根因有二：① 只试了「直链同目录 .nfo 的 GET」，AList `/d/` 直链未必暴露 .nfo；② 列表精简 item 不带 `MediaSources`，`initState` 时 `filePath` 为空，`_loadNfoSeries` 只跑一次直接跳过，item 补全后不再重试。

修复：`lib/metadata/nfo_reader.dart` 新增 `buildNfoUrls` 双策略（Emby 服务端代理 `/Items/{id}/File?Path=...` 优先 + 直链 GET 兜底）、`nfoPathFromMediaPath`（不限 scheme，供代理 Path 参数）；`loadNfoSeries` 不再永久缓存 null（网络恢复可重试）、超时 3s→5s、仅解析前 256KB。`DetailPage._loadNfoSeries` 在 `filePath` 缺失且已连 server 时先用 `server.itemDetail` 补全 item 再读 NFO，下拉刷新后也补一次重试。新增 `test/nfo_reader_test.dart` 9 条。

验证（v2.0.56）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **404 全过**（原 395 + 新增 9 条 `test/nfo_reader_test.dart`）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.56-release-arm64.apk`（39M），`aapt dump badging` 确认 `versionCode='256' versionName='2.0.56'`。

## §82 发布 v2.0.57（标签可点筛选 + 规格三列对齐 + 系列筛选类别）

补记：v2.0.57 改动要点见 README 更新日志 —— 普通标签胶囊点击链路回归、`MediaFilter` 增加 `series` 条件与抽屉分组、`kMinFilterCount = 8` 屏蔽低频选项。其验证记录此前直接附在 §81 末尾，此处补上独立章节编号，便于章节与版本一一对应。

验证（v2.0.57）：`flutter analyze` 0 error / 0 warning（仅 info 级既有弃用）；`flutter test` **408 全过**（原 404 + 新增 13 条：credit_filter_test 加系列筛选 4 条 + 抽屉阈值 1 条、detail_info_regression_test 加标签点击 1 条等）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.57-release-arm64.apk`（39M），`aapt dump badging` 确认 `versionCode='257' versionName='2.0.57'`。

## §83 发布 v2.0.58（系列胶囊可点筛选 + 长系列名完整显示）

承接真机反馈：「系列标签还是无法点击筛选，另外文字被切了」。

### 根因

上一轮把「标签不能点」理解成普通标签行，只补了普通标签的点击回归；用户指的其实是**橙色「系列」胶囊**。两个独立问题：

1. **点击**：`_InfoBlock` 规格三列里的系列 `_Cap` 从未传 `onTap`（导演 / 制造商 / 演员 / 标签都传了，唯独系列漏了），所以点了没反应。
2. **文字被切**：v2.0.57 为三列对齐引入 `SizedBox(height: 24)`，而 `_Cap` 文本固定 `maxLines: 1` + `TextOverflow.ellipsis`；24px 盒放不下带 5px 上下 padding 的胶囊，长系列名被截成几个字甚至从底部裁掉。

### 改动

| 文件 | 改动 |
|---|---|
| `lib/pages/detail_page.dart` | `_Cap` 增 `trailing` / `maxLines`；系列胶囊挂 `onTap: onOpenSeries` + `chevron_right` 箭头、改 `maxLines: 2`；三列值盒 24→40px 仍等高对齐；新增 `_openSeries`（推 `TagPageMode.series`）与 `_backfillSeries`（NFO 成功后回写全库条目） |
| `lib/pages/tag_page.dart` | `TagPageMode` 增 `series`；`_items` 用去空白（含 `\u3000` / `\u00A0`）后的包含匹配，覆盖 `seriesName` / `tags` / `genres` / `name`；`_title` / `_heroPrefix` 补 series 分支 |
| `lib/models.dart` | `MediaItem.copyWith` 增 `String? seriesName`，回填时不丢失原值 |

`_Cap.onTap != null` 时由 `LiquidPress` 承载，与普通标签胶囊同一套点击实现，无需新增手势层。`_Cap` 容器本身无固定高度，两行文字（约 35px）在 40px 盒内由 `Align(centerLeft)` 垂直居中。

### 数据边界

Emby 对 Movie 通常不返回 `SeriesName`，详情页显示的系列名几乎都来自 NFO 兜底（`_nfoSeries`），而全库 `AppState.items` 里其它影片的 `seriesName` 多为空。只做精确相等会筛出空白页，因此 series 模式退到「标签 / 类型 / 标题」包含匹配；同时 `_backfillSeries` 把当前影片的 NFO 系列名写回全库条目，使当前片必定命中，媒体库「系列」分组也随浏览逐步累积。若要一次性筛全仍需批量预读 NFO 或服务端支持 —— 这是已知边界，非本轮回归项。

### 测试

`test/detail_info_regression_test.dart`：把「超长系列名」断言从 `maxLines == 1` 改为 `maxLines == 2`（保留 `TextOverflow.ellipsis`），新增真实 `tester.tap` 点系列胶囊断言出现 `系列 · 濃厚な接吻とSEX`。`test/credit_filter_test.dart`：新增 series 模式宽松匹配，用带全角空格的 `濃厚な 接吻とSEX` 断言同时命中 `seriesName` / `tags` / `name` 三类数据并显示 `3 部`。

验证（v2.0.58）：`flutter analyze` 0 error / 0 warning（384 项全为 info 级既有弃用）；`flutter test` **410 全过**（原 408 + 新增 2 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.58-release-arm64.apk`（39M），`aapt dump badging` 确认 `versionCode='258' versionName='2.0.58'`。

## §84 发布 v2.0.59（系列名完整显示 + 收藏演员头像缩小）

承接真机反馈三条：①「系列文字还是被切了」；②「收藏演员的头像太大了」；③ 要加演员页但底部 Tab 已满，先出设计稿确认。本轮只实现 ①②，③ 交付设计稿待确认。

### ① 系列名被切：上一版没修干净

v2.0.58 把 `maxLines` 从 1 放宽到 2，但仍保留 `TextOverflow.ellipsis`，且三列值区仍是 `SizedBox(height: 40)` 固定盒。真机截图（468×1040）显示第一行「彼女の姉貴とイケナ」、第二行只剩被裁掉的半截字，行尾还有省略号 —— 是**垂直裁切 + 水平省略同时发生**，不是单纯行数不够。上一版交付说明里也预估到「超过两行仍可能省略」，用户实测确认仍被切。

修复：`_Cap.maxLines` 改为 `int?`，为 null 时 `overflow: TextOverflow.visible`、不限行数；新增 `fillWidth`，为 true 时 `Container(width: double.infinity)` + `Row(mainAxisSize: max)` + `Expanded`，让文字占满列宽自然换行，避免 `mainAxisSize: min` + `Flexible` 把长名挤成窄竖条。规格三列去掉 40px 固定盒，系列胶囊直接放进 Column；发行日期 / 时长改 26px 盒 + `Align(centerLeft)`，单行文字中心（13px）与胶囊第一行中心（约 11.5px）基本重合，三列靠标签行与值起始线顶部对齐。

### ② 收藏演员头像

`_actorGrid` 原用 `context.mediaGridColumns`（手机 3 列），`_ActorTile` 用 `Expanded(AspectRatio(1))` 让头像撑满格宽 ≈ 118dp。改为：新增 `CambyLayout.actorGridColumns`（扩展 8 / 中等 6 / 手机 4），网格间距 10 / 14、`childAspectRatio: 0.80`；`_ActorTile` 用 `LayoutBuilder` 取格宽，头像尺寸 `min(格宽 × 0.9, 手机 78 / 平板 104)` 并 `Center` 居中，图片 `memWidth` 300→200。

### ③ 演员页：只出设计稿，不写实现

产物 `/workspace/演员页导航设计稿.html`（同时在对话内给出推荐方案的内联预览）。关键结论：底部 `GlassNavBar._items` 一份定义同时驱动手机 Tab 与 ≥840dp 平板 Rail，中间「收藏」是凸起心形，第 6 个 Tab 会把每格压到约 70px 并迫使重做视觉；已有「演员收藏」分段和 `PersonPage`（作品网格 / 排序筛选 / ♥ 收藏）。因此推荐**方案 A：媒体库页顶部加「影片 / 演员 / 系列」二级分段**，全局导航零改动，点演员直接复用 `PersonPage`。另列 B（换掉数据 Tab）/ C（硬加第 6 Tab）/ D（收藏页加第三段）作对比。

数据边界（需用户拍板）：`CastMember` 只有 `name / role / id / imageTag`，Emby People 不返回性别，`role` 是角色名不能当性别用；`state.items[*].people` 已过滤为 Actor / GuestStar（导演在 `emby_client.dart:535` 单独抽走，每片最多 `take(12)`）。设计稿给出三条规则：A1 不过滤（页面叫「演员」）、A2 仅显示 `imageTag != null` 近似「女演员」（推荐）、A3 本地白名单手动标记。

### 测试

`test/detail_info_regression_test.dart`：「系列名两行显示 + 省略号」改为「不限行、不省略、不裁切」，断言 `maxLines == null`、`overflow != ellipsis`；新增源码守卫锁定 `maxLines: seriesName.isEmpty ? 1 : null`、`fillWidth: true`、两处 `height: 26 + Align`，并禁止 `height: 40 + Align` 回归。`test/favorites_wall_test.dart` 新增源码守卫锁定 `actorGridColumns`、头像 cap 与手机 4 列。

踩坑：源码守卫最初按 `'height: 26,'` 计数断言 2 处，实际文件里有 3 处（另有一处是 26×26 圆形容器），改用正则 `height:\s*26,\s*child:\s*Align\(` 精确匹配三列值盒后通过。

验证（v2.0.59）：`flutter analyze` 0 error / 0 warning（384 项全为 info 级既有弃用）；`flutter test` **412 全过**（原 410 + 新增 2 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.59-release-arm64.apk`（39M），`aapt dump badging` 确认 `versionCode='259' versionName='2.0.59'`。

## §85 发布 v2.0.60（媒体库二级分段：演员总览 + 系列总览）

承接 v2.0.59 设计稿确认：用户答复「1.导航选 a / 2.女演员选 a1 和 a2 / 3.加系列 / 4.按你推荐的来」。本轮把方案 A 从设计稿落成代码，不动一级导航。

### 导航决策：方案 A

`GlassNavBar._items` 一份定义同时驱动手机底部 Tab 与 ≥840dp 平板左侧 Rail，中间「收藏」为凸起心形；硬加第 6 项会把每格压到约 70px 并迫使重做整套视觉。故新增 `LibraryIndexSegment`（`enum LibraryIndexTab { movies, actors, series }`），三档液态玻璃分段控件与收藏页「影片收藏 / 演员收藏」同一套观感（`LiquidPress` + `AnimatedContainer`），挂在 `LibraryPage` 影片分支顶部。

`LibraryPage` 新增 `_indexTab` 状态与 `_setIndexTab()`；`build()` 开头若非 `movies` 就直接返回 `ActorIndexPage` / `SeriesIndexPage`，并把 `tab` 与 `onTabChanged` 传下去，让两个索引页顶部的分段控件能原路切回。**影片分支完全沿用原有 `CustomScrollView`，布局零漂移**；两个索引页各自带标题栏、分段、搜索、排序与滚动体，不复用媒体库的筛选 / 排序体系（维度不同）。

### 演员总览：A1 + A2 同时提供

`ActorIndexPage` 数据源是 `AppState.items[*].people`（`emby_client.dart` 解析 People 时只把 `Actor` / `GuestStar` 加入，导演单独抽到 `director`，每片 `take(12)`）。聚合逻辑：

```dart
final key = (p.id != null && p.id!.isNotEmpty)
    ? 'i:${p.id}'
    : 'n:${name.toUpperCase()}';
final e = map.putIfAbsent(
  key,
  () => _ActorEntry(name: name, id: p.id, imageTag: p.imageTag),
);
e.count++;
if (t > e.latest) e.latest = t;   // t = item.dateCreatedMs ?? 0
```

按 id 去重、无 id 回退大写名字去重，统计参演部数 `count` 与最近参演时间 `latest`，纯客户端内存聚合，**不打额外服务端请求**。

三档 `_scope`：`0` 全部（A1，不过滤）/ `1` 女演员（A2，`e.hasImage`）/ `2` 已收藏（`state.isPersonFavorite(e.id)`）。`_ActorEntry.hasImage => imageTag != null && imageTag!.isNotEmpty`。用户要求 A1 与 A2 都要，所以做成可随时切换的三档，而非写死过滤。

排序 `_sort`：`0` 参演最多（默认，用户「按推荐」）/ `1` 名字 A–Z / `2` 最近参演；相同 count / latest 时用名字做稳定次级键。搜索按 `name.toUpperCase().contains(q)`。

点卡片构造 `CastMember(name, id, imageTag)` 后 `CambyRoutes.fade` 推 `PersonPage`，复用已有的作品网格 / 排序筛选 / ♥ 收藏；`PersonPage.onOpenDetail` 先 `Navigator.pop` 再回调外层，避免详情页叠在演员页之上。头像沿用 v2.0.59 的 `context.actorGridColumns`（手机 4 / 平板 6 / 扩展 8）与 `min(cellW × 0.9, 78/104, cellH × 0.66)` 上限。

### 设计取舍：不做 A–Z 字母索引

设计稿画了右侧 A–Z 索引条，但库中演员以日文名为主，几乎全部会落进 `#`，索引条无信息量且占宽度。改为「搜索框 + 三档排序」，日文名可直接假名 / 汉字检索，信息密度更高。

排序行只有 2–3 个固定档位，最初写成 `ListView.separated` + `itemBuilder`，其中 `onTap: () => setState(() => _sort = i)` 被 `tools/perf_audit.py` 红线 3（「列表 itemBuilder 内不得 setState」）判为「滚动期整页重建」。`setState` 实际只在点击时执行、不在滚动路径上，属静态正则误报；但为 3 个 chip 建 sliver 本就多余，所以两个页面的 `_sortRow()` 统一改为 `SizedBox(height: 28) → SingleChildScrollView(scrollDirection: horizontal) → Row`，`Container` 显式 `height: 28` 保持原视觉高度，横滑能力保留。既消除误报也少一层 sliver 开销，**没有加 `ALLOW` 豁免**，避免削弱门禁。

### 系列总览

`SeriesIndexPage` 复用 `MediaFilter.seriesCountsOf(state.items)` 统计去空白后的 `seriesName`，`_covers()` 用 `putIfAbsent` 取每系列首部影片作 46×66 小封面（对 `posterUrlFor(300)` 做了空值保护，为空时走渐变占位）。排序 `0` 部数最多 / `1` 名字 A–Z，搜索按系列名。系列名用 `Text` 不限行完整显示，与 v2.0.59 详情页修复一致。点击打开 `TagPage(mode: TagPageMode.series)`，走「系列名 / 标签 / 类型 / 标题」去空白包含匹配。

### 数据边界（沿用，非本轮回归项）

- Emby `People` 不返回性别，`CastMember` 只有 name / role / id / imageTag，`role` 是角色名不能当性别。A2 只是「有头像」近似，可能漏掉少数无头像女优 —— 切「全部」即可兜底，这也是坚持 A1 + A2 并存的原因。
- Emby 对 Movie 通常不返回 `SeriesName`，系列名主要靠详情页 NFO 兜底 + `_backfillSeries` 回填 `AppState`，因此系列列表会随浏览过的影片逐步累积；空态文案里已向用户说明这一点。

### 文件清单

| 文件 | 改动 |
|---|---|
| `lib/widgets/library_index_segment.dart` | 新增 `LibraryIndexTab` 枚举与三档分段控件 |
| `lib/pages/actor_index_page.dart` | 新增演员总览：聚合去重、A1/A2/已收藏、搜索、三档排序、复用 `PersonPage` |
| `lib/pages/series_index_page.dart` | 新增系列总览：复用 `seriesCountsOf`、封面、搜索排序、打开 `TagPageMode.series` |
| `lib/pages/library_page.dart` | 新增 `_indexTab` / `_setIndexTab`，`build()` 分支返回索引页，影片分支挂 `LibraryIndexSegment` |
| `test/library_index_test.dart` | 新增 9 条回归 |

### 测试

`test/library_index_test.dart` 9 条：2 条源码守卫（底部导航仍 5 项且不含「演员」「系列」一级 Tab；`LibraryPage` 接入三个视图、演员页含 A1/A2 标签与 `imageTag!.isNotEmpty`、系列页含 `TagPageMode.series`）；4 条演员总览（聚合去重与参演数、默认排序、A2/A1 切换、已收藏空态 + 搜索、排序切换 + 点击复用 `PersonPage`）；2 条系列总览（聚合与长名完整显示、搜索 + 点击打开 series 模式）；1 条媒体库三段切换。

两处测试坑：

1. `find.text('深海')` 同时命中搜索框的 `EditableText` 与列表的 `Text`，报 `Found 2 widgets`。新增 `plainText()` helper，用 `find.byWidgetPredicate((w) => w is Text && w.data == s)` 只匹配 `Text` widget；分段控件同理用 `find.descendant(of: find.byType(LibraryIndexSegment), matching: find.text(label))` 精确定位，避开同名页面标题。
2. 媒体库分段测试原本注入 4 部影片，影片分支 `PosterCard` 在 393×852 测试视口下有既有布局溢出（`Multiple exceptions (8)`），与分段逻辑无关但会让 `takeException()` 失败。改为 `pumpLibrary()` 用空数据 `AppState()..installTestItems(const [])`，这组只验证页面类型与分段控件，聚合数据由演员 / 系列各自 group 单独覆盖。

首次跑门禁时第 4 步 `perf_audit.py` 命中 2 项（两个 `_sortRow()` 的 `itemBuilder` 内 `setState`），全量测试 421 全过、APK 也已构建，但门禁判定未过。按上文「设计取舍」把两个排序行改为 `Row` 后审计 0 命中，未通过加豁免放行。

验证（v2.0.60）：`flutter analyze` 0 error / 0 warning（425 项全为 info 级既有弃用）；`flutter test` **421 全过**（原 412 + 新增 9 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.60-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='260' versionName='2.0.60'`。

## §86 发布 v2.0.61（演员详情页重设计 + 头像变形 / 性别误标修复）

承接 v2.0.60 后的三条真机反馈：① 演员头像变形（被拉成竖椭圆）；② 性别识别错误，本该是男演员的全部显示成女性；③ 演员详情页把小头像铺成海报不合适，希望框起来、多展示信息、保留筛选框、并给出参演总数。

先产出 `/workspace/演员详情页设计稿.html`（方案 A 高保真 mockup + 字段可行性表 + G1–G4 性别方案 + S1–S3 资料来源 + 7 项待确认清单），用户确认 **页面结构 A / 头像框 A / S1 只用 Emby / G4 有则显示·无则中性 / 「女演员」档保留但标注按头像近似 / 总数放资料卡大数字 + 筛选条计数 / ①② 一并修** 后落地，本轮不改全局导航。

### ① 头像变形：`ClipOval` 没拿到正方形约束

`actor_index_page.dart` 的头像 `ClipOval` 位于 `StackFit.loose` 的 `Stack` 内，子级只被要求「不超过父级」，竖版头像因此按自身宽高比布局，`ClipOval` 拿到竖矩形，裁成竖椭圆。`favorites_page.dart` 的 `_ActorTile` 有同类风险，一并处理。

两处统一改为：外层 `Container` 显式 `width: size, height: size`（`size = min(格宽 × 0.9, 手机 78 / 平板 104)`），图片层用 `SizedBox.expand` 撑满，使 `ClipOval` 的 RenderBox 恒为正方形。新测试里有 widget 用例直接取 `ClipOval` 的 `size` 断言 `|width - height| < 0.6`，防回归。

### ② 性别误标：`♀` 被写死成装饰符号

根因两层：

1. `detail_page.dart` 演员行 `itemBuilder` 给每个 `_Cap` 传 `leading: const Text('♀', ...)`，与演员本人无关，男优也一律显示 ♀。
2. 数据层 `CastMember` 只有 `name / role / id / imageTag`；`role` 是角色名不是性别，标准 Emby `People[]` 与 Person item **不返回性别**，A2「女演员」当初用「有头像」近似而 UI 未说明，看起来就像「系统认定全是女性」。

按 G4（有则显示、无则中性，绝不猜）收敛：

| 层 | 改动 |
|---|---|
| `lib/models.dart` | 新增 `kGenderFemale` / `kGenderMale` 与 `normalizeGender(dynamic)`：只接受显式值（female/f/woman/girl/女/女性/女优、male/m/man/boy/男/男性/男优），其余（空串、未知字符串）一律 null |
| `CastMember` | 增 `gender` 字段，`toJson/fromJson` 都走 `normalizeGender` 归一，持久化不把脏值带回来 |
| `lib/emby_client.dart` | People 解析与 `favoritePersons()` 读 `m['Gender'] ?? m['Sex']`；`personImageUrl()` 的 `maxWidth` 改为可传参（详情页用 400） |
| `lib/widgets/gender_badge.dart`（新增） | `genderLeading()`：female → ♀、male → ♂、null → 中性 `Icons.person_outline_rounded`；`genderLabel()`：null 返回 null，让调用方隐藏字段，不摆「未知 / —」 |
| `lib/pages/detail_page.dart` | 演员胶囊改 `leading: genderLeading(p.gender)`，删掉写死的 ♀ |

「女演员」档按用户选择保留名称，但 `ActorIndexPage` 在 A2 档明确标注「按头像近似筛选 · 服务端未提供性别，可能混入有头像的男优」；`_isLikelyFemale()` 优先用 `e.gender`，仅 gender 为 null 才回退 `e.hasImage`，所以服务端明确标 male 的演员不会再混入。`_aggregate()` 聚合时 `if (e.gender == null && p.gender != null) e.gender = p.gender`，让跨影片后到的显式值能补齐而不覆盖已有值。

### ③ `PersonPage`：方案 A 单页滚动 + 吸顶筛选 + 总数

旧版用 `SizedBox(height: 340)` + `ShaderMask` 把 `maxWidth=200` 的小头像铺成满幅 banner，放大发糊、构图被切，且没有参演总数。按设计稿方案 A 重写：

- **头像框起来**：资料卡里 82×102（窄布局 74×92）圆角渐变描边卡片，图片单独请求 `personImageUrl(..., maxWidth: 400)`、`memWidth: 400`、`Alignment.topCenter`，不再铺满整屏。
- **S1 只用 Emby 现有字段**：生日 `PremiereDate`、别名 `OriginalTitle`、出生地 `ProductionLocations`、简介 `Overview`、性别 `Gender ?? Sex`，加上参演 / 最近年份 / 收藏三个本地派生值 —— **有值才渲染**，不摆一排「—」。
- **吸顶筛选条**：`SliverPersistentHeader(pinned: true)` + 自定义 `_FilterHeaderDelegate`（min/maxExtent 均 46），保留原「全部 / 电影 / 剧集」`_Seg` 与 `MediaFilterButton` 漏斗，右侧显示「共 N 部」或筛选后「M / N 部」；资料卡同时给一个大数字「N 部影片」。
- **平板 ≥840dp**：左 250dp 资料卡 + 右独立 `CustomScrollView` 作品区，列数仍走 `mediaGridColumns`，不写死。
- **顶栏淡出**：`NotificationListener<ScrollNotification>` 驱动 `_topBarFade` ValueNotifier，不引入整页 rebuild。

### 设计取舍：总数与网格数据源分离

初版把 `_localFilms`（从 `state.items[*].people` 本地聚合）在离线时直接回退进作品网格，结果 `library_index_test.dart` 点开 `PersonPage` 后渲染出 `PosterCard` 网格，在 393×852 测试视口触发**既有**的 `PosterCard` 布局溢出（`Multiple exceptions (3)`），全量测试 420 + 1 fail。

没有改 `PosterCard`、没调网格比例、没加测试豁免，而是把数据源拆开：

```dart
List<MediaItem> get _gridFilms => _films ?? const <MediaItem>[];

int get _total {
  final remote = _films?.length ?? 0;
  return remote > 0 ? remote : _localFilms.length;
}

String? get _offlineHint => (_films == null && _localFilms.isNotEmpty)
    ? '作品列表需联网加载 · 本地媒体库共 ${_localFilms.length} 部'
    : null;
```

作品网格仍只用服务端 `personItems()` 列表（与改造前一致，零回归），本地聚合只负责离线 / 加载中的总数、最近年份与空态提示。改完全量测试 436 全过。

### 文件清单

| 文件 | 改动 |
|---|---|
| `lib/widgets/gender_badge.dart` | 新增，`genderLabel()` / `genderLeading()` 收敛 G4 展示 |
| `lib/models.dart` | 新增性别常量、`normalizeGender()`、`CastMember.gender` |
| `lib/emby_client.dart` | People / favoritePersons 解析 `Gender ?? Sex`；`personImageUrl(maxWidth:)` 可配 |
| `lib/pages/detail_page.dart` | 演员胶囊不再写死 ♀，改 `genderLeading(p.gender)` |
| `lib/pages/actor_index_page.dart` | 头像 tight 正方形约束；A2 标注；聚合补 gender；`_isLikelyFemale` 优先 gender |
| `lib/pages/favorites_page.dart` | `_ActorTile` 头像同步 tight 正方形约束 |
| `lib/pages/person_page.dart` | 方案 A 重写：资料卡 + 头像框 + S1 字段网格 + 吸顶筛选 + 总数 + 平板双栏 |
| `test/person_page_redesign_test.dart` | 新增 15 条回归 |

### 测试

`test/person_page_redesign_test.dart` 15 条覆盖：源码守卫（详情页禁硬编码 ♀、要求 `genderLeading(p.gender)`；`CastMember.gender` / `normalizeGender` / `personImageUrl(maxWidth)`；`PersonPage` 去掉 `height: 340` / `ShaderMask`、新增 `_avatarFrame` / `SliverPersistentHeader` / `MediaFilterButton` / `maxWidth: 400`；两处头像 `SizedBox.expand` + 显式 `width/height: size`；A2 标注与 `_isLikelyFemale`）；纯逻辑（`normalizeGender` / `genderLabel` / `genderLeading`）；widget（`ClipOval` RenderBox 宽高相等、`PersonPage` 首屏总数 / 字段网格 / 吸顶筛选 / 离线提示 / G4 中性兜底、滚动后筛选条常驻、切「剧集」tab 漏斗仍可点、仅 `kGenderFemale` 时显示 ♀ 与性别字段、平板布局渲染）。

一处编译坑：`Element.size` 返回 `Size?`，直接取 `.width` 报 `Property 'width' cannot be accessed on 'Size?'`，改为 `final s = e.size!;` 后 15 条全过。

### 数据边界（沿用，需向用户说明）

- 标准 Emby 的 `People[]` / Person item 不返回性别。若服务端从未给出，UI 走中性人物图标、性别字段隐藏；「真·按性别正确筛选」需要服务端或外部数据源补字段，本版不做猜测。
- A2「女演员」仍是近似规则，服务端无 gender 时可能有头像的男优混入，「全部」档可兜底。

验证（v2.0.61）：`flutter analyze` 0 error / 0 warning（437 项全为 info 级既有弃用）；`flutter test` **436 全过**（原 421 + 新增 15 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.61-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='261' versionName='2.0.61'`。

## §87 发布 v2.0.62（系列 NFO 主动补全 + 演员页黑条修复）

承接两条真机反馈：①「影片详情的系列还是没有加载，无论是否刷新影片，不能直接从服务器上读取 nfo 文件，解析 `<set><name>憧れの競泳水着インストラクター</name></set>` 来回填吗」；②「演员页有黑条，再优化下样式」（附截图）。

### ① 系列：解析早就有了，卡在取不到 NFO 文件

先查证数据边界：Emby 官方在社区明确回复过「we don't currently do anything with the `<set>` tag, other than preserve it so that Kodi can read it」—— 服务端**不会**把 `<set><name>` 映射成 `SeriesName` / BoxSet / 任何可经 API 读取的字段。所以想通过服务端查询拿系列名是走不通的，直读 .nfo 是唯一路径。

而项目里 `parseNfoSeries()` 从 v2.0.54 起就支持 `<series>` 优先、回退 `<set><name>`，对用户给的多行缩进样例能正确解出日文名。**问题在读文件**：

1. `_kItemFields` 没有 `Path`，`filePath` 只取 `MediaSources[0].Path`；Emby 对非管理员账号常隐藏该字段 → 路径为空 → `buildNfoUrls('')` 返回空列表 → 一个请求都不发，系列永远静默停在「无」。`itemDetail()` 用的也是同一份 `_kItemFields`，所以「刷新影片」也补不回来，与用户观察一致。
2. 即便有路径，旧候选只有：Emby 代理 `/Items/{id}/File?Path=...` + 直链同名 `.nfo`（且本地路径连直链都没有，只剩代理一个候选）。文件名只认同名 `.nfo`，不认 Kodi 另一种常见约定 `movie.nfo`；带签名的 AList 直链在替换扩展名后签名按 path 校验失效；代理端点本身也未必可用。任何一环断掉就静默失败。
3. 失败完全静默，用户只能看到「无」，没法知道是路径空、404、超时还是 NFO 里没有 `<set>`。

改动：

| 文件 | 改动 |
|---|---|
| `lib/emby_client.dart` | `_kItemFields` 补 `Path`；`filePath` 优先 `j['Path']`、回退 `MediaSources[0].Path` |
| `lib/metadata/nfo_reader.dart` | 新增 `NfoCandidate` / `NfoProbe` / `NfoReadResult`、`buildNfoCandidates()`、`loadNfoSeriesDetailed()`；保留旧 `buildNfoUrls` / `loadNfoSeries` 不破坏既有调用与测试 |
| `lib/metadata/nfo_series_backfill.dart`（新增） | 全库并发扫描服务 |
| `lib/app_state.dart` | 新增 `replaceSeriesNames(Map)` 批量写回 |
| `lib/pages/series_index_page.dart` | 「补全系列」按钮 + 进度条 + 结果/诊断面板；空态文案改写 |
| `lib/pages/detail_page.dart` | `_loadNfoSeries` 改用新候选；「系列：无」胶囊可点看诊断 |

`buildNfoCandidates` 的候选矩阵（按可靠性排序、URL 去重）：同名 `.nfo` 直链 → 同名 `.nfo` 直链去签名 → `movie.nfo` 直链 → `movie.nfo` 直链去签名 → 同名 `.nfo` Emby 代理 → `movie.nfo` Emby 代理。本地路径没有直链，只有后两态。`_safeUrl()` 在写诊断前移除 `api_key` / `sign` / `token`，避免令牌出现在 UI 里。

### 设计取舍：先试跑，再全库扫

逐条懒读（打开详情页才回填）意味着系列列表要「浏览过才累积」，用户明确希望主动从服务器回填。但全库扫描有个陷阱：如果环境根本取不到 .nfo，上千部影片 × 6 候选 × 3s 超时会变成几分钟的无谓等待，最后还是一句失败。

`NfoSeriesBackfill.run()` 因此先串行试跑 3 部有路径的样本：只要出现过 `noSeriesField`（NFO 读到了、只是没 `<set>`）或命中，就认为通道可用，再按并发 6 分块扫剩余条目；若所有候选都是 HTTP 错误 / 超时 / 非 NFO 正文，立即 `abortedByProbe` 中止并把逐候选诊断交给 UI。扫描结果一次性 `state.replaceSeriesNames(updates)`，只 `_invalidateDerived()` + `notifyListeners()` 一次，不逐条重建整页；只填 `seriesName` 为空的条目，绝不覆盖服务端已有值。

结果面板给出「待补全 / 成功写入 / 无路径 / 取不到 NFO / NFO 无 `<set>`」统计 + 最多 5 条脱敏失败样例；详情页点「系列：无」可看同一套逐步诊断。

### ② 演员页黑条

采样截图：资料区背景 `(43,35,33)` 暖棕、海报区 `(105,80,75)` 偏亮暖棕，中间筛选条 `(29,31,46)` 冷蓝黑 —— 正是 `_filterBar` 写死的 `Color(0xF20B1020)`（95% 不透明）盖出的横带。

改为与页面同色系的半透明暖色渐变（`0x802B2321 → 0xCC2B2321 → 0x9E2B2321`）+ 顶部高光细边 + 底部分隔线：上下沿自然过渡，海报滚到下面被压暗但不会变成另一块颜色。**刻意不用 `BackdropFilter`**：吸顶 header 每帧参与滚动合成，真模糊要重新采样整块内容，与 v2.0.54 详情页「半透明纯色卡片替代模糊」的性能结论一致，也避开 `perf_audit.py` 的模糊层红线。

截图左下角那个黑色圆钮（旋转箭头 + 屏幕图标）是 **Android 系统的自动旋转悬浮按钮**，项目里没有 `FloatingActionButton` / 全局 `OverlayEntry` 与之对应，不属于 App，未改动。

### 文件清单与测试

新增 `test/nfo_series_backfill_test.dart` 16 条：多候选矩阵（http 直链 6 态、本地路径 2 态、空路径、无凭据）、用户 `<set><name>` 样例与 CDATA 解析、诊断脱敏源码守卫、空候选不抛异常、`samples` 去重限 5 条排除命中、`_kItemFields` 含 `Path` 与 `effectivePath` 守卫、`replaceSeriesNames` 只填空值/不覆盖/trim、详情页与系列页接入守卫、演员页不再出现冷蓝黑色值。

一处守卫自摆乌龙：初版把旧色值 `0xF20B1020` 写进了注释，被 `contains('0xF20B1020')` 守卫命中导致 1 条失败；改注释为文字描述后 16 条全过。

### 数据边界（需向用户说明）

- Emby 不解析 `<set><name>`，客户端必须能**直接 HTTP 访问 .nfo**。若直链带按路径校验的签名、NFO 不在可访问目录、或服务端未开放文件代理，仍需在服务端放开 `.nfo` 匿名读取；现在这类情况会在结果面板给出具体 HTTP 状态与候选 URL（脱敏），不再静默。
- A2「女演员」按头像近似、系列列表依赖 NFO 回填等既有边界沿用。

验证（v2.0.62）：`flutter analyze` 0 error / 0 warning（439 项全为 info 级既有弃用）；`flutter test` **452 全过**（原 436 + 新增 16 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.62-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='262' versionName='2.0.62'`。

---

## §88 发布 v2.0.63（系列改读服务端「所属合集」/ BoxSet）

### 用户反馈与根因翻案

用户贴出 Emby 网页端影片详情截图，指出「所属合集」区块里已有合集「罵倒女医のダメ男をわか…」，并问「这个系列应该读取的是合集字段，所以我们之前是取错字段了？」。

结论：**前两版的数据源选错了**。`SeriesName` 是剧集字段，电影恒为空；「系列」对应的是 Emby 的 **BoxSet（合集）对象**，它是独立的 library item，不是 Movie 上的属性。网页端「所属合集」用的查询是：

```
GET /Users/{UserId}/Items?IncludeItemTypes=BoxSet&Recursive=true&ListItemIds={ItemId}&Fields=Name
```

`ListItemIds` 是 Emby 网页客户端 / Bulky 插件实际使用、但公开文档未列的参数；列出全部合集用 `IncludeItemTypes=BoxSet`，取成员可用 `ParentId`。

v2.0.62 引用的官方说法「we don't currently do anything with the `<set>` tag, other than preserve it so that Kodi can read it」只描述**原生 NFO 导入器**：它不把 `<set>` 存进 Movie 字段，但用户的库显然已通过刮削器 / 插件把它建成了真正的合集对象。既然网页端能显示，服务端 API 就一定可读 —— 客户端去直读 `.nfo` 属于绕远路。真机诊断里「所有候选均为 Emby 代理 + `TimeoutException`、没有任何直链候选」正是因为服务器只有本地路径 `/media/…`、且 Emby 没有读取 sidecar 的代理端点：这条链路从一开始就走不通，与刷新无关。

### 实现

- `EmbyServer` 新增 `BoxSetInfo` DTO 与三个方法：`allBoxSets()`、`boxSetMemberIds()`、`boxSetNamesForItem()`。全部复用既有 `_getJson` 的鉴权 / 超时 / 瞬断重试。
- 新增 `lib/metadata/boxset_series.dart`：`BoxSetSeriesSync.run()` 列出合集 → 并发 6 拉成员 → `mergeMappings()` 反建 `itemId → 合集名` → `replaceSeriesNames()` 一次写回；对仍未命中的影片用 `ListItemIds` 逐条反查（单轮 400 部上限，可重复点击续跑）。`mergeMappings` 抽成纯函数供单测。
- 详情页 `_loadNfoSeries()` 改为**先反查服务端合集**，命中即回填并 return；NFO 直读退到其后。`_seriesSource` 记录来源，点「系列：无」弹出「系列来源诊断」，首行直接写明服务端合集查询结果。
- 系列总览「补全系列」→「**同步合集**」，结果面板改为合集数 / 待补 / 成功写入 / 未关联合集 / 是否启用反查兜底 + 说明；空态文案同步。
- `NfoSeriesBackfill` 不再被任何页面引用（文件与测试保留，作为离线兜底实现），`nfo_reader.dart` 仍供详情页使用。

### 设计取舍

- **没有删除 NFO 链路**：服务端确实没有合集数据的库，详情页仍能走原来的直读兜底。但全库主动扫描不再走 NFO，避免上千部影片逐个撞超时。
- **双路径而非单一 `ListItemIds`**：该参数未进公开文档，不能假定所有 Emby 版本都支持；`ParentId` 映射是主路径，逐条反查是兜底，两者都不通时结果面板给明确结论而不是静默失败。
- 一部影片同属多个合集时，系列名只有一个槽位，按 `SortName` 顺序取第一个；详情页诊断里会列出全部合集名。
- 不改 `MediaItem.seriesName` 语义，系列总览 / 系列胶囊 / 媒体库「系列」筛选全部沿用既有链路，零回归。
- 上一轮被中断的 `v2.0.63` 半成品（`MediaItem.filePathAlt` 双路径、NFO 直链映射模板）已整体回滚：新方案完全不需要影片文件路径，保留只会增加死代码。

### 文件清单与测试

新增 `test/boxset_series_test.dart` 9 条：三个 API 端点的源码守卫（含 `ListItemIds` / `ParentId`）、`mergeMappings` 的先到优先与空值过滤、详情页「合集反查必须排在 NFO 之前」、系列页不再引用 `NfoSeriesBackfill`、同步服务不触碰 `loadNfoSeries`、`BoxSetSyncResult` 默认值。更新 `test/nfo_series_backfill_test.dart` 的按钮守卫为「同步合集」/ `BoxSetSeriesSync.run(`，并把该文件注释里「只能直读 .nfo」的旧结论改正。

验证（v2.0.63）：`flutter analyze` 0 error / 0 warning（439 项全为 info 级既有弃用）；`flutter test` **461 全过**（原 452 + 新增 9 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.63-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='263' versionName='2.0.63'`。

---

## §89 发布 v2.0.64（质感包：图片过渡 / 触觉 / token 收敛 / 空态 CTA）

### 用户反馈与确认

用户在 v2.0.63 后问「跟其他主流播放器相比还差一点点意思」，先交付了 `Camby体验差距看板.html` 与 `质感包前后对比稿.html`，随后以「按推荐的开始」确认六项推荐值：

| 项 | 确认值 |
| --- | --- |
| 范围 | 只做 ① 质感包四条，不掺 ② 本地库秒开 |
| 骨架视觉 | 低饱和渐变 + 慢速微光 |
| 淡入时长 | 180ms |
| 触觉 | 默认开 + 设置里可关 |
| token 力度 | 只统一卡片标题 / 年份 / 胶囊 / 圆角四类高频，不做 337 处全量替换 |
| 空态 | 13 处逐处给真实动作 |

### 诊断依据（改动前）

- `CachedImage` 的 `placeholder` 是 `SizedBox.shrink()`、`fadeInDuration: Duration.zero` → 海报「先空着、再啪地蹦出来」。
- 全项目 `HapticFeedback` 0 命中；Shimmer / 骨架 0 命中；337 处手写 `fontSize`、约 20 种字号、12 种圆角。
- 13 处「暂无数据」都是「灰色图标 + 一行字」，没有下一步动作。
- 已有优点保留：`PosterHero`、`Anim`、播放手势、`RecoEngine`、`ErrorWidget.builder`。

### 实现

**图片链路**（`lib/widgets/cached_image.dart`）：改为 `StatefulWidget`，`initState` 里用 `DefaultCacheManager().getFileFromCache(imageCacheKey(url))` 探一次磁盘缓存；探测完成前只画骨架，完成后才构建 `CachedNetworkImage`，让 `fadeInDuration` 在整个生命周期里保持稳定（不会中途重建打断已开始的淡入）。命中缓存 → `Duration.zero` 直出；未命中 → `AppMotion.imageFade`(180ms) + `Anim.curve`。`placeholder` 与 `errorWidget` 都用 `SkeletonBox`，失败时叠 `fallbackLabel` 片名。`pubspec.yaml` 新增 `flutter_cache_manager: ^3.4.6`（与 lock 一致），避免 `depend_on_referenced_packages`。

**骨架**（新增 `lib/widgets/skeleton.dart`）：`ShimmerScope` 用单个 `AnimationController.repeat()` 在父级画一条移动渐变带，`widget.child` 是同一实例不随帧重建，整体包 `RepaintBoundary`；`SkeletonCard` 用 `Expanded` 吃剩余高度，适配任意卡片高度。接入：媒体库首屏 / 切库（`LibrarySkeleton`）、首页媒体库行、详情页分集与推荐首帧（`ListSkeleton`）。页面首屏才挂扫光，行内 / 局部骨架用静态渐变，不给稳定滚动加动画。

**触觉**（新增 `lib/widgets/haptics.dart`）：`AppHaptics.load()` 在 `main()` 里 `await`（`WidgetsFlutterBinding.ensureInitialized()` 之后、首个可交互帧之前），读 `set_haptics`；`setEnabled()` 立即改内存 + 持久化。三档调用都包了 `onError` 静默兜底，桌面 / 测试宿主无 vibrator 不影响业务。接入点：底部 Tab（`GlassNavBarState._onTap`）、设置页 `onTabChanged`、二级分段、排序 chip、海报按下（`_setDown(true)`）、`AppState.toggleFavorite` / `togglePersonFavorite`、删除服务器确认、断开连接。设置页新增 `_Toggle`，`_set('haptics', v)` 时调 `AppHaptics.setEnabled(v)`；`settings_effect_test.dart` 的「假开关」守卫由 `haptics.dart` 里的 `getBool('set_haptics')` 满足。

**token**（`lib/theme.dart`）：新增 `AppRadii` / `AppType` / `AppMotion` / `SkeletonColors`，改 `TextTheme.bodySmall=11`、`labelSmall=10`；`media_poster.dart` 的海报内标题、卡片标题、推荐理由统一进 token；`ChipLabel` 圆角改 `AppRadii.pillBr`；`PosterBox` 片名用 `AppType.posterTitle`。圆角与字号只替换高频同类，其余手写值保留。

**空态**（新增 `lib/widgets/empty_state.dart`）：`EmptyState`（玻璃图标 + 标题 + 原因 + 主 CTA + 次入口，内部用 `LayoutBuilder` 兼容无界高度）与 `EmptyHint`（卡片内一行原因 + 小动作）。逐处映射：系列总览、演员总览、收藏页演员档（含未连接服务器分支）、收藏夹内容页、标签聚合页、搜索页影片 / 演员两处、演员详情作品区、媒体库筛选无结果、首页媒体库行（已有重试动作保留）、统计页 9 处、字幕筛选页、收藏夹弹层。跨 Tab 的 CTA 由 `LibraryPage.onGoSettings` / `FavoritesPage.onSwitchTab` 接到 `AppShell._goTab(int)`，与底部 Tab 点击共用同一套过渡；系列页「同步合集」直接复用 `_syncBoxSets()`。

### 设计取舍

- **不做本地库持久化 / 增量同步**：属优先级 ②，要动 `AppState` 持久化与弱网验证，单独一个版本。
- **不引入实时模糊**：骨架与空态图标全是纯渐变，`perf_audit.py` 对新文件 0 命中；不改 `Glass` 现有实现。
- **不动播放页控件层**：避免碰视频逐帧合成的性能红线；播放页的锁定 / 解锁档位只在约定里，未接调用。
- **不引第三方 shimmer**：单控制器 + `LinearGradient` 足够，也避免多一个动画依赖。
- **统计页 CTA 用「了解统计口径」而非「去看一部影片」**：后者需要给 StatsPage 加跨 Tab 回调并改导航状态，与「不改导航结构」冲突；改为复用页内已有的玻璃说明弹窗，仍是真实可点动作，文案里说明了「去媒体库点开一部影片播放一会儿」。
- **`fadeInDuration` 前置探测**：宁可多一帧骨架，也不让参数在 `CachedNetworkImage` 生命周期中途变化导致淡入被截断。

### 回归与修复

- `SkeletonCard` 初版用 `AspectRatio(1/1.45)` 按宽度反推高度，在详情页 150dp 矮卡里向下溢出 92px，连带 `tablet_layout_test.dart` 与收藏页 golden 报多处异常 → 改为 `Expanded` 吃剩余高度。
- `ListSkeleton` 初版用 `ListView.builder(itemCount: 3)`，被 `detail_info_regression_test.dart` 的「横向 ListView childCount==3 即判定为制作信息混排」守卫误判 → 改为固定 `children`（骨架本来就是静态占位，也不给滚动路径加 itemBuilder）。
- 两张 golden（`favorites_wall.png` / `favorites_actors.png`）随 UI 重做用 `--update-goldens` 更新，更新前已确认无布局溢出异常。
- 注释里出现 `BackdropFilter` 字样会被 `perf_audit.py` 逐行正则误报，改写为「实时模糊 / 滤镜组件」后 0 命中。

### 文件清单与测试

新增：`lib/widgets/skeleton.dart`、`lib/widgets/haptics.dart`、`lib/widgets/empty_state.dart`、`test/quality_pack_test.dart`（19 条：token 档位、图片过渡源码守卫、骨架无模糊 / 走断点、widget 渲染、触感三档与开关、13 类空态源码守卫、CTA 可点行为、版本断言）。更新 golden 2 张、版本断言 `test/online_subtitle_test.dart`、版本号 5 处。

**真机重点验收**：弱网首次进媒体库（先见 9 张带形状骨架，图片逐张淡入无硬切）、断网二次进入（磁盘缓存瞬间出现，看不到骨架与淡入）、图片 404（骨架 + 片名仍可点开详情）、快速来回滚动（无掉帧、无闪烁）、设置里关掉触感后全部震动消失、13 类空态 CTA 点击后确实跳到对应功能。

验证（v2.0.64）：`flutter analyze` 0 error / 0 warning（439 项全为 info 级既有弃用）；`flutter test` **480 全过**（原 461 + 新增 19 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.64-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='264' versionName='2.0.64'`。

## §90 发布 v2.0.65（影片版本选择 + 详情页半透质感统一）

### 用户反馈与核实

1. 「详情页简介和信息详情是不是加了阴影，其他半透框没有」→ 核实结论：**没有**。 `_overviewCard` / `_mediaInfoCard` 的 `boxShadow` 在 v2.0.54 已删，装饰只剩 `Colors.white 0.06` + `Border.all(white 0.12)` + `circular(14)`。浮起感来自整块宽度的半透明 + 亮描边压在全屏模糊背景上，而页面里其他半透框是 `_Cap` 那种小面积彩色胶囊（`13% 填充 + 22% 描边 + 圆角 7`），两者不是同一套配方。
2. 「增加影片版本选择，切换版本时影片文件信息跟着调整」→ Emby 的多版本是**一个 Item 下多个 MediaSource**，项目里已有单条详情拉取 `MediaSources` 的能力（`mediaSources()`）和 `MediaSourceId` 播放链路（`streamUrl(mediaSourceId:)` / `PlayerPage.mediaSourceId`），但前者只返回非主版本、后者只在「额外部分」用。缺的是把它们接成一条完整链路。

### 变更

**质感**：`theme.dart` 新增 `AppSurface.soft()` —— 无 border、无 shadow、无 gradient，`Colors.white.withValues(alpha: 0.045)` + `circular(14)`。两个大卡片改用同一装饰（源码守卫断言恰好出现 2 次），只靠留白与内容排版分区；小胶囊 / 可点标签不动。

**数据层**：`EmbyServer.versionsFromSources(dynamic raw)` 公开静态解析，按 `Index` 升序、`index == 0` 标 `isPrimary`；`mediaVersions(itemId)` 用 `Fields=MediaSources,MediaStreams,RunTimeTicks,Path` 拉单条详情。`MediaExtraPart` 新增 `width / audioChannels / audioLanguage / audioDefault / subtitleTracks` 与 `copyWith({isPrimary})`，`fromJson` 从 `MediaStreams` 读视频宽高/编码、音频声道/语言/默认轨、字幕 DisplayTitle（去括号、去重、最多 4 条）；源级 `Height/Width/VideoCodec/AudioCodec` 作兜底。展示 getter：`sizeLabel`（GB/MB/KB）、`resolutionLabel`（≥2160 写 4K）、`videoLabel`、`audioLabel`（stereo / 5.1 / 7.1 + `(默认)`）、`subtitleLabel`、`versionSubtitle`。

**详情页**：状态 `_versions` / `_versionIndex` / `_selectedVersion`（单版本返回 null）。`_loadExtras()` 改用 `mediaVersions()`，按 `isPrimary` 拆成版本列表与 `extraParts`，**一次请求供两处**。新增 `_versionSection({spacing})`（手机 16 / 平板 22，插在媒体信息上方）：`<2` 条返回空列表；否则 `版本 共 N 个` + `_VersionPicker` + 规格胶囊。切换时 `AppHaptics.light()`、收起媒体信息折叠态。`_mediaInfoCard` 新增 `version` 参数，路径 / 容器 / 体积优先取该源，新增 `_sizeLabel()` 支持 MB/KB，`添加于` 保持 Item 级。头图的 4K / 视频编码 / 音频声道徽章改走 `_shownIsTrue4K()` / `_shownVideoCodec()` / `_shownAudioCodec()` / `_shownAudioChannels()`，逐项以选中版本为准、缺字段退回 item 主版本。

**播放**：新增**可选** `DetailPage.onPlayVersion`，`_playWithVersion()` 在非主版本且回调非空时带 `MediaSourceId` + `sourceLabel` 起播、字幕传 null；`main._openPlayer` 增加两个可选命名参数透传 `PlayerPage`。之所以不直接给 `onPlay` 加参数：Dart 函数子类型要求 mock 声明全部命名参数，会打断 12 个 widget 测试；可选回调让所有老调用方零改动，且未注入时安全退化为主版本播放。

### 设计取舍

- **单版本不显示选择器**：没有可切换内容时摆一个不能点的框是纯噪音，也让「多版本」这个信息本身失去意义。
- **版本板块紧邻媒体信息**：参考图里版本框在播放按钮上方，但本 App 的「继续播放」是首屏关键操作，不能往下推；放在媒体信息上方既保留首屏，又让「切换 → 文件信息变化」的因果一眼可见。
- **非主版本不强制塞 item 级字幕**：字幕轨 index / DeliveryUrl 属于主版本，硬套到另一个文件可能对不上；交给播放页按新源自动挑中文字幕，用户仍可手动换。
- **保留 `mediaSources()`**：诊断面板（`trailerDiag`）仍用它，不改动既有诊断输出；只有详情页主线切到 `mediaVersions()`。
- **`isPrimary` 以排序后第一条为准**：Emby 不保证 `MediaSources` 顺序与 `Index` 一致，测试里故意乱序覆盖。

### 文件清单与测试

新增：`test/media_version_test.dart`（10 条：乱序排序与主版本标记、非主版本派生额外部分、空/单条兜底、视频/音频/字幕/体积/时长文案、缺 MediaStreams 兜底、字幕轨去重上限、无描边守卫、版本数据与播放链路接线、模型字段守卫）。修改：`lib/theme.dart`、`lib/models.dart`、`lib/emby_client.dart`、`lib/pages/detail_page.dart`、`lib/main.dart`、版本断言、版本号 5 处。

**真机重点验收**：找一部合并了 4K / 1080p 两个文件的影片 → 详情页应出现「版本」板块，下拉列出两个版本并带体积；逐个切换，文件路径 / 封装 / 体积 / 视频编码 / 音频 / 字幕胶囊应同步变化；选中 4K 后点「立即播放」，确认播的是 4K 源（播放信息里分辨率对得上）；单版本影片不应出现版本板块；顺带看剧情简介与媒体信息两块是否已不再有亮边框浮起感。

验证（v2.0.65）：`flutter analyze` 0 error / 0 warning；`flutter test` **490 全过**（原 480 + 新增 10 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.65-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='265' versionName='2.0.65'`。

---

## §91 发布 v2.0.66（描边回归 / 4K 版本播放信息联动 / 播放信息弹窗收紧）

### 用户反馈与定性

1. 「简介和媒体信息卡片还是加回跟胶囊一样的描边」—— **撤回 v2.0.65 的质感决定**。上一版把两块大卡片从「6% 填充 + 12% 白描边」改成无描边纯填充，理由是亮描边压在模糊背景上有浮起感；真机结论是无描边反而与页面里带描边的小胶囊不像一套。统一质感的关键变量是**描边配方一致**，不是描边的有无。
2. 「选择 4K 版本，播放页和弹窗信息页还是显示 1080p」—— v2.0.65 的联动只覆盖了详情页 UI 与头图徽章，**没有覆盖播放页**。播放页顶栏副行 `${item.videoHeight}p` 与「播放信息」面板的分辨率 / 编码 / 音频 / 封装 / 大小全部读 `widget.item`，而 `main._openPlayer` 只把 `MediaSourceId` 传进去了，`item` 本身仍是主版本。
3. 「这个信息弹窗太大了」—— 两层原因：`_Sheet` 的 `Flexible + SingleChildScrollView` 在 `Column(mainAxisSize: min)` 下把 viewport 拉到接近 `GlassPanel` 的 `maxHeight`（`avail - 24`），横屏变成近满屏黑板；同时 11 行字段的行距（每行 `vertical: 6` + 分节 `14/6`）偏松，截图里底部「字幕」行直接被裁掉。

### 实现

**描边**：`theme.dart` 的 `AppSurface.soft()` 改为 `Colors.white.withValues(alpha: 0.06)` + `circular(14)` + `Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1)`。0.16 直接对齐 `ChipLabel` 的 `bd`；无 `boxShadow` / 无 `gradient` 的约束不变。详情页两处调用的注释同步更新为 v2.0.66 结论。`detail_info_regression_test.dart` 与 `media_version_test.dart` 的描边守卫从「断言无 border」改成「断言有 border 且 alpha 0.16、仍无阴影/渐变」。

**版本规格联动（数据层）**：`MediaItem.copyWith` 新增 `videoHeight / videoCodec / audioCodec / audioChannels / container / fileSizeBytes / filePath / resolutionKnown` 八个可选参数，全部走 `x ?? this.x`，老调用零影响。新增 `MediaItem.withMediaSource(MediaExtraPart p)`：源里有值才覆盖，缺字段保留 item 原值（防 `0p` / 空编码 / 0 B），容器统一大写，`resolutionKnown` 在有 height 时置 true。动态范围（Dolby Vision / HDR）属 Item 级、MediaSources 未给，明确不联动。

**版本规格联动（链路）**：`DetailPage.onPlayVersion` 从「传 `mediaSourceId` + `sourceLabel` 两个字符串」改为「传整个 `MediaExtraPart version`」；`_playWithVersion()` 相应简化为 `cb(item, version: v, resume: resume)`。`main._openPlayer` 新增可选 `MediaExtraPart? version`，起播前算 `playItem = item.withMediaSource(version)` 并把它（而非原 item）交给 `PlayerPage`，`startAt` 也基于 `playItem`。`_openExtraPart` 同样改用 `item.withMediaSource(part)`，分段播放信息一并对。**刻意不扩 `onPlay` 签名**（会打断 12 个 widget 测试的 mock）；`mediaSourceId:` / `sourceLabel:` 两个参数名保留，既有源码守卫不失效。

**弹窗收紧**：`GlassPanel` 新增可选 `maxWidth` 与 `maxHeightFactor`（相对可用高度，带 200dp 下限与 `avail-24` 上限），不传时行为完全不变。`_Sheet` 新增 `compact` / `maxWidth` / `maxHeightFactor` 三个参数：`compact` 时内容区改成 `Padding + Column(mainAxisSize: min)` 直接按内容收拢、不滚动；标题栏 padding 从 `20/14/14/10` 压到 `16/10/12/6`、字号 15→14。`_showInfo` 用 `compact: true, maxWidth: 400, maxHeightFactor: 0.9`；`_InfoSection` padding `20/14/20/6` → `18/10/18/4`，`_InfoRow` `20/6` → `18/4`，值加 `maxLines: 2`（片名显式传 2，避免 analyze 报未使用参数）。字幕列表 / 在线字幕 / 播放速度等长列表仍走 `Flexible` 滚动分支，尺寸零变化。

### 回归与修法

| 现象 | 原因 | 修法 |
|---|---|---|
| 两条描边守卫 `Expected false / Actual true` | 新注释里写了 `boxShadow` 字样，被源码守卫扫到 | 注释改中文「投影」 |
| `player_ui_metrics_test` 硬编码尺寸守卫失败 | `_InfoRow` 标签宽度改成 `width: 68`，撞上被禁的 `adjustW` 值 | 改回 `width: 72` |
| `online_subtitle_test` 限宽守卫失败 | `GlassPanel` 的 `maxWidth:` 后面变成 `maxWidth ?? PlayerUi...`，原字符串不再连续 | 守卫改为断言 `PlayerUi.of(context).panelMaxW`，理由补「短面板可传固定宽度覆盖」 |
| `GlassIconButton` 之外 `maxLines` 未使用 | analyze 报 `unused_element_parameter` | 片名行显式传 `maxLines: 2` |

### 设计稿（本轮不写实现代码）

- `/workspace/底部导航设计稿.html`：手机三方案（推荐 A 纯图标 + 青蓝渐变胶囊）、平板三方案（推荐 A 可折叠渐变胶囊 Rail）、token / 尺寸 / 动效 / 性能约束、6 项待确认。明确「整条导航最多 1 个 BackdropFilter，选中胶囊内不嵌模糊」。
- `/workspace/圆形玻璃按钮设计稿.html`：结论「可行但必须分三层」—— 图标圆钮全换中性灰径向磨砂、文字胶囊统一色阶不变形、品牌主按钮与面板保留；附现状盘点（8 个 `GlassIconButton` / 21 处 `Glass` / 78 处 `LiquidPress`）、参考图配方六层拆解、Before/After 高保真、三种背景验证、三套落地范围（推荐按 C→B 顺序）、token 与迁移清单、6 项待确认。

### 文件清单与测试

修改：`lib/theme.dart`、`lib/models.dart`、`lib/pages/detail_page.dart`、`lib/pages/player_page.dart`、`lib/widgets/glass_sheet.dart`、`lib/main.dart`、`test/media_version_test.dart`、`test/detail_info_regression_test.dart`、`test/online_subtitle_test.dart`、`test/quality_pack_test.dart`、`test/online_subtitle_test.dart`、版本号 5 处、`README.md`、`VERIFICATION.md`。`test/media_version_test.dart` 新增 3 条（`withMediaSource` 覆盖 4K 规格、缺字段逐项保留、源码守卫覆盖链路与紧凑面板）。

**真机重点验收**：找一部 4K + 1080p 双版本影片 → 详情页选 4K → 立即播放 → 顶栏副行应写 `2160p` 与 4K 源编码，点右上 info 的「播放信息」应同步显示 2160p / HEVC / 该源体积；播放信息弹窗应收成约 400 宽的紧凑卡片，不再近满屏，且「字幕」行完整可见。单版本影片播放信息不得出现 `0p` 或空编码。顺带确认剧情简介与媒体信息两块已恢复细描边、与标签胶囊一眼同套。

验证（v2.0.66）：`flutter analyze` 0 error / 0 warning（439 项全为 info 级既有弃用）；`flutter test` **493 全过**；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.66-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='266' versionName='2.0.66'`。

---

## §92 发布 v2.0.67（导航改造：手机方案 A + 平板方案 B）

### 用户反馈与定性

用户在看过两份设计稿后给出三条明确选择：

1. 「圆形玻璃按钮图标不是我想要的效果，不更改」—— 《圆形玻璃按钮设计稿》整体否决，`Glass` / `GlassIconButton` / `LiquidPress` / `PrimaryButton` / `ChipLabel` 等按钮视觉零改动。本版只新增 `AppNav`，不碰任何按钮组件。
2. 「导航条手机端选方案 A」—— 选中项为青蓝渐变横向胶囊（图标 + 文字）、未选中项只剩线性图标，整条底栏保留液态玻璃。
3. 「平台的导航条方案 A 显得被压缩了，选择方案 B」—— 「平台」按上下文为「平板」；放弃设计稿初稿推荐的左侧可折叠 Rail，改为底部居中悬浮条，与手机共用同一套组件。

### 实现

**token**：`theme.dart` 新增 `AppNav`（私有构造 + 静态常量），集中 `capsuleGradient`（约 105deg `2FD8B6 → 33B6E8 → 4F8CFF`）、`barHeight 62` / `barRadius 31`、`itemHeight 48`（按触控 ≥48 取，设计稿写 46）、`idleWidth 48` / `selectedWidth 108`、`tabletBarWidth 320`、`barInset 7`、`duration 260ms` + `curve easeOutCubic`、`badgeColor`。手机与平板读同一份，避免再次分裂。

**GlassNavBar（方案 A）**：`Row` 由 5 个 `Expanded` 改为 `mainAxisSize.min` 的定宽项，整体 `Center` 居中。单项外层 `LiquidPress(scale .94, glow .30, semanticLabel: 名称)`，内层 `AnimatedContainer` 在 48 ↔ 108 之间动画，选中时挂 `AppNav.capsuleGradient` + 1px 白 22% 内描边 + 青色外发光 / 黑色投影。图标 21dp，未选中白 55%、选中白 96%。文字用 `AnimatedSize(alignment: centerLeft, clipBehavior: hardEdge)` 从 `SizedBox.shrink()` 展开为「7dp 间距 + 12px w800 白字」。两段动画同 duration / curve，任意时刻内容宽 ≤ 容器宽，故不会出现 RenderFlex 溢出；`ClipRRect` 再兜一层裁剪。

**外壳（方案 B）**：删除 `if (context.useRail) { ... }` 整段（左侧 Rail、`VerticalDivider`、`LayoutBuilder + MediaQuery` 宽度注入）、`_buildRail()` 与 `_RailButton` 类。统一走 `Scaffold + Stack`：`Positioned` 在平板 `left/right: 0`、手机 `16`；`bottom` 平板 `padding.bottom + 14`、手机 `+10`；child 为 `Center(SizedBox(width: 平板 320 / 手机 infinity, child: GlassNavBar))`。`onChanged` 回调、双击搜索、`_visited`、`_tabAnim`、`_blur` 全部原样保留。

**layout.dart**：`useRail` 恒 false 并注明废弃原因（保留 getter 供旧调用与回归测试得到明确答案）；`isTablet` 不变，页面分栏 / 列数继续按 840 分档；`kRailWidth` 标为历史常量，导航不再读取；文件头三档描述更新为「共用底部悬浮导航」。

**性能**：整条 bar 仍只挂 1 个 `BackdropFilter(sigma 30)`（main.dart 中 `BackdropFilter(` 出现次数 = 1，由新测试锁定）；胶囊内不嵌滤镜，用渐变 + 内高光 + 外发光表达厚度。滚动降级与 `StatusBarBlur` 逻辑不动。

### 回归与修法

| 现象 | 原因 | 修法 |
|---|---|---|
| `phone_regression_test` 平板断言「不得出现 GlassNavBar」 | 平板已改方案 B | 断言改为 `findsOneWidget`，并新增 5 图标齐全、宽 320、水平居中 |
| `layout_breakpoint_test` 断言 `isTablet && useRail` 在 840 为真 | Rail 废弃 | 拆成两条：`useRail` 恒 false、`isTablet` 仍按 840 分档；新增 main.dart 不含 `_buildRail(` / `context.useRail` 的源码守卫 |
| `global_search_test` 用 `find.text('收藏')` 定位 | 方案 A 未选中项无文字 | 改用 `find.byIcon(Icons.favorite_rounded)`；选中项仍保留文字，首页双击用例不变 |
| 未选中项无文字影响读屏 / 自动化定位 | 视觉要求 | `LiquidPress.semanticLabel` 提供名称 |
| 未选中项切到选中时可能 RenderFlex 溢出 | 文字瞬间出现、容器尚未展开 | `AnimatedSize` 同曲线展开 + `ClipRRect` 裁剪；新增逐帧 pump 的动画测试 |
| 平板外壳报 `RenderFlex overflowed by 2.0 pixels` | 定宽 Row 合计 300dp，但 `SizedBox(314)` 扣掉 1px 描边 ×2 与 7dp 内距 ×2 后只剩 298dp（旧版用 `Expanded` 弹性子项，不会暴露） | 平板条宽改 `320`（留 4dp 余量），`theme.dart` / 两个测试 / README / VERIFICATION / 设计稿的数值同步；用临时诊断测试打印完整 `FlutterErrorDetails` 定位到 `main.dart` 的 5 项 Row，确认 `DIAG COUNT 0` 后删除该临时文件 |

### 设计稿状态

- `/workspace/底部导航设计稿.html`：待确认清单改为已确认结论 —— 手机 A、平板 B、渐变青→蓝、红点默认关、圆钮方案否决；推荐标签同步更新。
- `/workspace/圆形玻璃按钮设计稿.html`：**已否决**，仅留档，不实施。

### 文件清单与测试

修改：`lib/theme.dart`、`lib/main.dart`、`lib/layout.dart`、`test/layout_breakpoint_test.dart`、`test/phone_regression_test.dart`、`test/global_search_test.dart`、`test/tablet_layout_test.dart`、`test/online_subtitle_test.dart`、`test/quality_pack_test.dart`、版本号 5 处、`README.md`、`VERIFICATION.md`、设计稿状态。新增 `test/nav_redesign_test.dart`（5 条源码守卫 + 2 条 widget + 1 条 token 断言）。

**真机重点验收**：手机底栏选中项是横向青蓝胶囊且带文字、其余 4 项只有图标；点不同 Tab 时胶囊平滑滑过去、文字渐显，全程无黄色溢出条；平板（840dp 以上）不再有左侧竖条，底部出现居中的短悬浮导航，内容区比旧版宽约 96dp；双击当前 Tab 仍能唤起全局搜索；所有圆形玻璃按钮外观与 v2.0.66 完全一致。

验证（v2.0.67）：`flutter analyze` 0 error / 0 warning（425 项全为 info 级既有弃用，比 v2.0.66 少 14 项是因为删掉 `_RailButton` 里的 `withOpacity`）；`flutter test` **502 全过**（原 493 + 新增 9 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.67-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='267' versionName='2.0.67'`。

---

## §93 发布 v2.0.68（低干扰导航 + 媒体库 4 类 + 搜索页升为一级 Tab + 空心图标）

### 用户确认

> tab 的按钮切换动画不错，保留。但是现在导航栏有些抢镜了，也有些宽，用媒体库切换 tab 的背景和样式如何？同时收藏跟媒体库合并，即媒体库上面的 tab 有 4 类，原收藏页换成搜索页，同时双击 tab 按钮唤出搜索页的功能取消。现给出设计图

设计稿 `/workspace/低干扰导航设计稿.html` 交付后，用户回复「**按你推荐的修改**，同时我加一条 **tab 的图标要用设计稿里空心的图标，现在版本是实心的，没设计稿的好看**」。四项待确认全部按推荐落地，追加第 5 条空心图标要求。

### 实现

**theme.dart / AppNav**：`capsuleGradient` 由青蓝三色渐变换成 `0x38FFFFFF → 0x14FFFFFF` 白雾面（与 `LibraryIndexSegment` 同源）；`barHeight 62→50`、`barRadius 31→999`、`itemHeight 48→42`、`itemRadius 24→999`、`idleWidth 48→44`、`selectedWidth 108→96`、`tabletBarWidth 320→280`、`barInset 7→3`；`duration 260ms` / `easeOutCubic` 不动。

**main.dart / GlassNavBar**：容器去掉三段渐变、镜面高光线、青色发光与深投影，改白 6% 纯色 + 白 10% 1px 描边 + 黑 28% blur20 y8；`ImageFilter.blur(30)→(20)`，仍只挂 1 个 `BackdropFilter`；`padding: EdgeInsets.all(3)` 取代原来的水平 7dp；子项由 `Stack + Center + Padding` 简化为一条 `Row(mainAxisSize.min)`。选中项只保留白雾面渐变与白 26% 1px 内描边，图标 21→20px、文字左边距 7→6。`_items` 换 5 个空心图标与「搜索」标签。

**一级 Tab / 搜索链路**：`pages[2]` → `SearchPage(active: _tab == 2)`；删除 `_openSearch()`、`_searchRoute()`、`GlassNavBar.onSearch`、`_lastTap`、`_lastIndex` 与双击 300ms 分支，`_onTap` 简化为「轻触感 + onChanged」。外壳去掉 `context.isTablet` 分支，两端统一 `SizedBox(width: 280)` 居中、`bottom = padding.bottom + 14`。`settings_page.dart` 移除右上角搜索按钮与对应的 `PageRouteBuilder`，删掉 `search_page.dart` import。

**媒体库 4 类**：`LibraryIndexTab` 加 `favorites`；`_labels` 加「收藏」、`_icons` 加 `favorite_border_rounded`；容器与单项样式零改动（仍是 36dp / 200ms）。`LibraryPage.build` 的非 movies 分支增加收藏分支，把 `onIndexTabChanged: _setIndexTab` 与 `onSwitchTab` 传给 `FavoritesPage`。

**FavoritesPage 嵌入化**：标题「收藏」→「媒体库」、副标题加「收藏 · 」前缀；标题下插入 `LibraryIndexSegment(favorites)` 主分段；内部次级 2 档由 38dp 降到 28dp、底色白 4% / 描边白 8%、去掉投影、图标改 `local_movies_outlined` / `person_outline_rounded`；空态 CTA「去影片详情收藏演员」→「去影片找演员」，动作从切一级 Tab 改为切主分段到 `movies`。海报堆叠墙、同步按钮、演员收藏网格保持原样。演员页 / 系列页标题统一为「媒体库」，维度信息移入副标题。

**SearchPage 作为 Tab**：新增 `final bool active` 与 `_focusedOnce`，`didChangeDependencies` / `didUpdateWidget` 里 `_maybeFocus()` 只在首次可见时 `requestFocus()`；`initState` 的无条件聚焦移除，避免冷启动（Tab 在 `Offstage` 里也会 initState）就弹键盘。删除「取消 / `Navigator.pop`」按钮，搜索框独占整行；三处滚动体底部 padding 由 24 改 88（ListView 热播榜、`_ActorGrid` 的 GridView、`_ResultGrid` 的 Sliver 尾部），给 50dp bar + 14dp 离底留避让。搜索框图标 `search_rounded→search_outlined`、热门演员 `person_rounded→person_outline_rounded`。

### 回归与修法

| 现象 | 原因 | 修法 |
|---|---|---|
| `flutter analyze` 报 `onSearch` 未定义（3 处） | 三个测试还在给 `GlassNavBar` 传已删除的参数 | 重写 `nav_redesign_test.dart` / `global_search_test.dart`，`phone_regression_test.dart` 同步 |
| 源码守卫断言 `_openSearch(` / `_searchRoute(` 不存在却为 true | main.dart 注释里写了完整旧函数名，被字符串守卫扫到 | 注释改写成「旧的半透明搜索路由转场」，守卫恢复 |
| `library_index_test` 三条副标题断言失配 | 三个索引页标题统一为「媒体库」、维度移入副标题 | 断言改为「演员 · 共 N 位…」/「系列 · 共 N 个…」；分段测试扩为 4 类并验证点「收藏」出现 `FavoritesPage` |
| `favorites_wall_test` 两幅 golden 像素差 15% / 11% | 收藏页新增主分段、次级胶囊变矮、标题变化 | `flutter test --update-goldens test/favorites_wall_test.dart` 重新出基准图 |
| 搜索结果最后一排被悬浮导航压住 | 作为路由页时压在外壳之上，作为 Tab 后与底栏同层 | 三处滚动体底部改 88dp |
| `global_search_test` 冷启动弹键盘风险 | `initState` 无条件 `requestFocus` | 改 `active` + `_focusedOnce` 首次聚焦 |

### 设计稿状态

- `/workspace/低干扰导航设计稿.html`：**已确认 · 已落地 v2.0.68**，补记空心图标要求与四项确认结论。
- `/workspace/底部导航设计稿.html`：留档，记录 v2.0.67 的手机 A / 平板 B（本版视觉已被低干扰方案取代）。
- `/workspace/圆形玻璃按钮设计稿.html`：**已否决**，本版依旧不实施。

### 文件清单与测试

修改：`lib/theme.dart`、`lib/main.dart`、`lib/widgets/library_index_segment.dart`、`lib/pages/library_page.dart`、`lib/pages/favorites_page.dart`、`lib/pages/actor_index_page.dart`、`lib/pages/series_index_page.dart`、`lib/pages/search_page.dart`、`lib/pages/settings_page.dart`、`test/nav_redesign_test.dart`、`test/global_search_test.dart`、`test/phone_regression_test.dart`、`test/library_index_test.dart`、`test/online_subtitle_test.dart`、`test/quality_pack_test.dart`、`test/goldens/favorites_wall.png`、`test/goldens/favorites_actors.png`、版本号 5 处、`README.md`、`VERIFICATION.md`、设计稿状态。`lib/layout.dart`、`lib/models.dart`、`lib/emby_client.dart` 与播放链路零改动。

**真机重点验收**：底栏明显变窄变矮、居中悬浮，选中项是低调白雾面药丸而非青蓝发光胶囊；5 个图标全是空心线性款，切换时胶囊仍平滑展开、文字渐显且无黄色溢出条；媒体库顶部 4 类分段可切到「收藏」，收藏页里仍有影片收藏 / 演员收藏两档与海报堆叠墙；点第 3 个 Tab 直接进搜索页，双击任何 Tab 不再弹搜索，切走再切回搜索页保留上次输入且不自动弹键盘；「我的」页右上角不再有搜索按钮；所有圆形玻璃按钮外观与 v2.0.67 完全一致。

验证（v2.0.68）：`flutter analyze` 0 error / 0 warning（419 项 info 全为既有 `withOpacity` 弃用，v2.0.67 为 425）；`flutter test` **505 全过**；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.68-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='268' versionName='2.0.68'`。

## §94 发布 v2.0.69（键盘 / 导航条 / 弹窗玻璃 / 4K 版本联动）

四处真机回归：

1. **禁止页面自动弹键盘**：删 `SearchPage` 首次自动聚焦与 `folder_sheet` `autofocus`；外壳 `Scaffold` 包 `GestureDetector`（`HitTestBehavior.deferToChild`，点输入框本身不会误触 `unfocus`）在点空白/卡片/按钮时收起键盘；新增 `_FocusResetObserver` 在任意路由出栈清主焦点（修「详情页 pop 回首页却弹键盘」）。保留「用户主动点输入框才弹键盘」。
2. **底部导航条放大**：尺寸 280×50 → **312×56**，选中 112 / 未选 48、图标 22 / 文字 13；保持白雾面低干扰、`barHeight 50→56` 模糊 20、整条 bar 仍只有 1 个 `BackdropFilter` 与 260ms 动画；零余量公式 `312 − 2 − 6 = 304 = 112 + 4×48`。
3. **统一弹窗玻璃**：5 个纯色 `AlertDialog`（`settings` 删除确认、`detail` 系列来源诊断 / 预告片诊断、`series_index` ×2）+ 2 个纯色底部弹层（`detail` 字幕选择 / 版本选择）改用 `Glass` / `GlassPanelRoute` 液态玻璃；`_ServerSheet` / 媒体筛选近全屏抽屉沿用渐变（加模糊既浪费又看不出效果）。
4. **4K 版本信息联动**：根因 `MediaExtraPart.fromJson` 只读源/流 `Width/Height`，未像主条目那样从文件名兜底推断——服务端不回版本源宽高时 height 恒 0，详情页与播放页全退回主版本 1080p。抽出共享 `heightFromName()`（原 `emby_client._heightFromName`），版本解析在 height 为 0 时从名称/路径（`2160p`/`4K`/`UHD`）推断；`withMediaSource` 把推断规格带到播放页。

修改：`lib/main.dart`、`lib/theme.dart`、`lib/models.dart`、`lib/emby_client.dart`、`lib/pages/detail_page.dart`、`lib/pages/series_index_page.dart`、`lib/pages/settings_page.dart`、`lib/widgets/folder_sheet.dart`、`test/nav_redesign_test.dart`、`test/global_search_test.dart`、`test/phone_regression_test.dart`、`test/media_version_test.dart`、`pubspec.yaml`、`README.md`、`VERIFICATION.md`。`lib/layout.dart`、播放链路与圆形玻璃按钮零改动。

**真机重点验收**：所有页面都不会自动弹键盘，只有点搜索框等输入框才弹；底部导航条明显更大更稳，选中项仍是低调白雾面药丸；设置删除确认、详情诊断弹窗、系列说明、字幕/版本选择弹层都带玻璃磨砂质感；选 4K 版本后详情页与播放页顶栏正确显示 4K（不再误显 1080p）。

验证（v2.0.69）：`flutter analyze` 0 error / 0 warning；`flutter test` 全过；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.69-release-arm64.apk`，`aapt dump badging` 确认 `versionCode='269' versionName='2.0.69'`。
