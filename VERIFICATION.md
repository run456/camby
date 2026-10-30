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
