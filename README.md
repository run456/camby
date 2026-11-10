# Camby

> Android 端 Emby 播放器 · 液态玻璃 UI · 双播放内核（ExoPlayer / MPV）

Camby 是一款面向 Emby 媒体服务器的 Android 播放客户端。界面采用统一的液态玻璃（Liquid Glass）设计语言，播放内核抽象为可切换的双引擎（ExoPlayer 兼容最佳、MPV 支持 ASS 特效字幕与更强硬解），并针对大媒体库的浏览、搜索、详情与播放体验做了大量性能与交互优化。

当前版本：**v2.0.74 (274)** · 构建目标：arm64 Release APK

> ⚠️ **源码重建说明**：本工程由 `Camby-v1.7.38` APK 反编译取证 + 旧仓库对拍重建为基线，持续迭代至当前 **v2.0.74 (274)**。完整发版记录与重建取证过程见 [CHANGELOG.md](./CHANGELOG.md)。

---

## 目录

- [核心特性](#核心特性)
- [技术架构](#技术架构)
- [目录结构](#目录结构)
- [环境要求](#环境要求)
- [构建与运行](#构建与运行)
- [测试](#测试)
- [更新日志](./CHANGELOG.md)
- [隐私与开源许可](#隐私与开源许可)

---

## 核心特性

| 模块 | 能力 |
| --- | --- |
| **双播放内核** | ExoPlayer（兼容最佳·通用渲染）/ MPV（ASS 特效字幕·`hwdec=auto-safe` 自动硬解），设置内一键切换，播放页统一抽象 `PlaybackController`；**支持硬解/软解播放中热切换**（MPV 走 `hwdec` 属性实时生效，Exo 恒为硬解） |
| **字幕** | 外挂 / 内封字幕加载；MPV 原生挂载字幕轨；ExoPlayer 由播放页 Flutter 叠加层自绘；切字幕**不重建播放器**、不跳进度 |
| **在线字幕** | 字幕弹窗内按文件名搜迅雷 / SubtitleCat，下载后 UTF-8 / GBK 自动解码写入叠加层；两源并行、单源失败静默降级；手机 / 平板共用玻璃搜索面板；**按影片 ID 缓存**下次自动加载，可**导出 .srt** 到手机 |
| **Lara 翻译** | 标题 / 剧情简介旁一键翻译：官方 REST API（Access Key 签名鉴权）、自动检测源语言译中文、忠实/流畅/创意三风格；确认后**按影片缓存译文**，下次点开直接查看（设置页配置凭证、可测试连接） |
| **字幕样式** | 叠加层字幕的字号 / 位置 / 偏移 / 不透明度 / 描边 / 颜色全部可调，实时预览；播放页长按「字幕」、设置页「字幕样式」双入口；持久化键 `camby_sub_*` |
| **播放控制** | 进度条点击跳转 + 拖动预览；快进/快退对称手势；双击判定（去竞技场延迟）；长按锁定；亮度/音量侧滑浮层与倍速条互斥 |
| **画面比例** | 自适配（完整显示）/ 满屏（裁切铺满），实时生效 |
| **缓冲可视化** | 底栏「缓冲至」进度 + 网络缓冲速度（字节/秒），MPV 轮询 `cache-speed`、Exo 用 `buffered` 兜底 |
| **进入/退出动画** | 纯黑幕遮罩 + 横竖屏切换延迟，规避系统旋转与路由转场叠加导致的歪斜旋转 |
| **媒体库** | 排序 + 多维筛选抽屉（分辨率多选带计数、仅中文字幕、类型/标签组内或组间且）；应用后摘要条可单条✕/一键清空 |
| **首页** | 按库分组预览；空结果不缓存 + 自动重试，杜绝「暂无内容」永久卡死；Hero 区**每日推荐**：跨天自动换一批、同一部作品 3 天冷却，支持手动「换一批」（种子与冷却表持久化） |
| **搜索** | 影片 / 演员分段；圆头像网格；动态模糊背景；半透明淡入上浮转场 |
| **详情页** | Hero 转场；相似推荐 + 「媒体文件信息」液态玻璃卡（路径超 2 行折叠/展开、长按复制、URL 中文自动解码）；`RepaintBoundary` + 缓存范围优化滚动性能 |
| **数据页** | Playback Reporting 插件 / 内置活动日志聚合 / 最近播放 Top10 |
| **播放进度的服务端同步** | 起播后每 10 秒（节流 5 秒）写一次 `POST /Users/{UserId}/Items/{ItemId}/UserData`，携带 `PlaybackPositionTicks`；退出播放页再补一次，服务端「继续观看」与其它设备上的续播位置因此跟着走 |
| **演职员页** | 作品列表支持「全部 / 电影 / 剧集」分段切换，并可叠加年代区间与排序（年份 / 评分 / 片名），筛选摘要可直接看清当前条件 |
| **收藏 / 标签 / 文件夹** | 收藏切换、标签筛选、文件夹树浏览 |

---

## 技术架构

- **UI 框架**：Flutter 3.x（Dart），`MaterialApp` + 自定义 `AppShell`（保活式 `IndexedStack`，切 Tab 不重建整页，已访问页保活、未访问页占位）。
- **播放内核抽象**：`lib/player/playback.dart` 定义 `PlaybackEngine{exo,mpv}` 与统一接口 `PlaybackController`，暴露 `fit`、`setSubtitle`、`cacheSpeedBytes`、`seek(preview)` 等；播放页只依赖该接口，内核可独立演进。
- **字幕工具**：`lib/subtitles/subtitles.dart` 解析 SRT/VTT，提供 `textAt(cues, t)` 按时间取文本、URL 编解码、Emby `Stream.ass/ssa/vtt/...` → `Stream.srt` 正则重定向（让无原生字幕的内核也能取文本流）。
- **状态管理**：`AppState`（ChangeNotifier）统一持有服务器连接、库视图、预览缓存；`previewForView(view,{force})` 空结果绝不写缓存，下拉刷新走 `force` 直连服务端。
- **模糊性能**：`inspire_blur` 预热着色器 + 图片内存缓存上调（`maximumSize=1200` / `192MB`），千部库滚动不抖动。
- **关键依赖**：`media_kit`（MPV）、`video_player`（Exo 兜底）、`cached_network_image`、`volume_controller`、`screen_brightness`、`shared_preferences`、`http`。

---

## 目录结构

```
lib/
├── main.dart                  # 入口、AppShell、详情/播放/搜索转场
├── app_state.dart             # 全局数据源（连接、库、预览缓存、播放报告）
├── emby_client.dart           # Emby API（鉴权、条目、字幕、播放报告、活动日志）
├── models.dart                # 数据模型（MediaItem/SubtitleTrackInfo/媒体文件信息…）
├── theme.dart                 # 暗色液态玻璃主题
├── player/
│   └── playback.dart          # 双内核抽象 PlaybackController（Exo/Mpv 实现）
├── subtitles/
│   └── subtitles.dart         # SRT/VTT 解析与取词
├── pages/                     # home/library/detail/player/search/settings/stats/favorites…
└── widgets/                   # glass_toast/liquid_press/status_bar_blur/media_poster…
test/                          # 单元 + 组件测试（字幕解析、筛选、Hero、收藏墙…）
android/                       # Gradle / 原生工程
```

---

## 环境要求

- Flutter SDK `^3.13`（本工程实测 Flutter 3.47.x）
- Android SDK（构建 APK 需 `ANDROID_SDK_ROOT`）
- JDK（推荐 Zulu / JDK 17+）
- 仅 Android 平台

## 构建与运行

```bash
# 1. 拉取依赖
flutter pub get

# 2. 调试运行（连接设备/模拟器）
flutter run --release

# 3. 构建 arm64 Release APK
export ANDROID_SDK_ROOT=/opt/android-sdk
export JAVA_HOME=/path/to/jdk
export GRADLE_OPTS="-Xmx4g"
flutter build apk --release --android-skip-build-dependency-validation

# 产物：build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

首次进入需在「我的」页连接 Emby 服务器（地址 + 账号），或开启内置演示库离线浏览。

---

## 测试

```bash
flutter test            # 运行全部（字幕解析、筛选逻辑、Home Hero、收藏墙、液态按压等）
flutter analyze         # 静态分析，目标 0 错误 0 警告
```

当前测试套件覆盖：`subtitles_test`（SRT/VTT 解析、`Stream.srt` 重定向、对齐泄漏）、`subtitle_filter_test`、`home_hero_test`、`favorites_wall_test`、`liquid_press_test` 等。

---

## 更新日志

完整发版记录（v2.0.69 一路回溯至早期 1.7.x 基线）与源码重建的完整取证过程，已迁移至独立文档：**[CHANGELOG.md](./CHANGELOG.md)**。

---

## 隐私与开源许可

- 应用仅连接**用户自己配置的** Emby 服务器，所有凭据（地址 / Token / 账号）保存在本机 `shared_preferences`，不上传任何第三方。
- **在线字幕是显式点击才触发的功能**：只有用户点「在线搜索字幕…」时，App 才会把**清理后的影片标题 / 番号**（不含服务器地址、账号、Token）发给迅雷与 SubtitleCat 的公开端点，下载的字幕只在本机内存里解析显示，不落盘、不上传任何播放记录。不使用该功能时没有任何对外请求。
- 内置「演示库」为离线占位数据，不含真实服务器信息。
- 许可证见仓库 `LICENSE` 文件（如有）。在线字幕模块移植自 MIT 项目 `PotplayerJavChineseSubs_subtitlecat` 3.0，按 MIT 要求随附许可全文于 `licenses/LICENSE-UPSTREAM.txt`（版权人 `Exhen & Contributors` 原样保留）。MIT 只覆盖代码，不覆盖第三方字幕网站 / 接口的服务条款。
- 内置字幕字体 `FangSong.ttf` 为 **Noto Serif SC + Noto Serif TC 的并子集**，版权归 Google / SIL（OFL-1.1 可商用、可再分发），许可全文见 `licenses/OFL-NotoSerif.txt`。导出 / 缓存的字幕文件保存在 App 私有目录，不会上传，用户可经系统分享自行拷到 NAS。

---

© Camby · 由 WorkBuddy 协助开发与维护
