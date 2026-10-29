# Camby

> Android 端 Emby 播放器 · 液态玻璃 UI · 双播放内核（ExoPlayer / MPV）

Camby 是一款面向 Emby 媒体服务器的 Android 播放客户端。界面采用统一的液态玻璃（Liquid Glass）设计语言，播放内核抽象为可切换的双引擎（ExoPlayer 兼容最佳、MPV 支持 ASS 特效字幕与更强硬解），并针对大媒体库的浏览、搜索、详情与播放体验做了大量性能与交互优化。

当前版本：**v1.7.20 (60)** · 构建目标：arm64  Release APK

---

## 目录

- [核心特性](#核心特性)
- [技术架构](#技术架构)
- [目录结构](#目录结构)
- [环境要求](#环境要求)
- [构建与运行](#构建与运行)
- [测试](#测试)
- [更新日志](#更新日志)
- [隐私与开源许可](#隐私与开源许可)

---

## 核心特性

| 模块 | 能力 |
| --- | --- |
| **双播放内核** | ExoPlayer（兼容最佳·通用渲染）/ MPV（ASS 特效字幕·`hwdec=auto-safe` 自动硬解），设置内一键切换，播放页统一抽象 `PlaybackController` |
| **字幕** | 外挂 / 内封字幕加载；MPV 原生挂载字幕轨；ExoPlayer 由播放页 Flutter 叠加层自绘（白字黑描边）；切字幕**不重建播放器**、不跳进度 |
| **播放控制** | 进度条点击跳转 + 拖动预览；快进/快退对称手势；双击判定（去竞技场延迟）；长按锁定；亮度/音量侧滑浮层与倍速条互斥 |
| **画面比例** | 自适配（完整显示）/ 满屏（裁切铺满），实时生效 |
| **缓冲可视化** | 底栏「缓冲至」进度 + 网络缓冲速度（字节/秒），MPV 轮询 `cache-speed`、Exo 用 `buffered` 兜底 |
| **进入/退出动画** | 纯黑幕遮罩 + 横竖屏切换延迟，规避系统旋转与路由转场叠加导致的歪斜旋转 |
| **媒体库** | 排序 + 多维筛选抽屉（分辨率多选带计数、仅中文字幕、类型/标签组内或组间且）；应用后摘要条可单条✕/一键清空 |
| **首页** | 按库分组预览；空结果不缓存 + 自动重试，杜绝「暂无内容」永久卡死 |
| **搜索** | 影片 / 演员分段；圆头像网格；动态模糊背景；半透明淡入上浮转场 |
| **详情页** | Hero 转场；相似推荐 + 「媒体文件信息」液态玻璃卡（路径超 2 行折叠/展开、长按复制、URL 中文自动解码）；`RepaintBoundary` + 缓存范围优化滚动性能 |
| **数据页** | Playback Reporting 插件 / 内置活动日志聚合 / 最近播放 Top10 |
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

> 本节汇总 v1.7.x 系列（尤其 v1.7.10 → v1.7.14）的所有改动。更早版本以版本号演进为准。

### v1.7.20 (60)
- **播放器缓冲速度**：ExoPlayer 内核此前只能显示「缓冲至 00:00」，现改为用「已缓冲时长增速 × 平均码率」估算下载速度，底栏显示 `缓冲 x.x MB/s`（MPV 仍读 libmpv 的 `cache-speed`，更精确）。
- **收藏堆叠墙**：恢复设计稿的「扑克牌」效果。原来 4 层都画海报，色调相近叠成一张；现改为后 3 层使用不同色调的渐变卡（蓝灰 / 浅蓝 / 酒红）并按 8°/4°/-4° 扇形散开，最上层才是夹内最新海报。
- **首页搜索图标**：Material 的 `search` 线太细、柄太短，20dp 下像字母 Q；改为自绘粗线长柄放大镜。
- **媒体库顶栏**：排序按钮与漏斗按钮打开的是同一个抽屉（纯重复），合并为一个入口——显示当前排序字段 + 方向箭头，筛选条件数作为角标。
- **媒体库筛选**：移除「类型」分组，只保留分辨率、中文字幕、标签。

### v1.7.19 (59)
- **播放控件层关闭实时模糊**：控件层原有十几个 Glass(`BackdropFilter`) 压在逐帧更新的视频纹理上，中低端 GPU 每帧重算模糊，表现为唤出控件时视频卡顿约 1 秒、像暂停了。播放页统一关模糊，只保留半透明渐变质感。

### v1.7.18 (58)
- **网络瞬断自动重试**：Wi-Fi/移动数据切换、锁屏唤醒导致的 `ECONNABORTED/ECONNRESET`，GET 请求自动重试一次。
- **连接失败中文诊断**：把底层 socket 错误翻译为中文，并识别局域网地址（`192.168.x.x` 需同一 Wi-Fi）。

### v1.7.17 (57)
- **隔离视频渲染面**：视频 widget 实例缓存为独立子树，控件显隐不再牵连原生 Surface。
- **Exo 字幕加载**：外挂字幕改走 App 的 Emby 鉴权下载通道（Token 头 + 忽略自签证书）。

### v1.7.16
- 双击快进/退加位置约束（两击 < 64dp）与 700ms 防抖，杜绝误触导致的播放/暂停死循环。
- Toast 黄色下划线修复（根 Overlay 包透明 Material）。
- 满屏改 `SizedBox.expand` + `BoxFit.cover`，修复点「满屏」未铺满。
- 倍速从右侧竖排滑轨移到底栏「画面比例」旁。

### v1.7.15
- 单击立即切换控件显隐（去掉 250ms 延迟），唤出后重置隐藏计时。

### v1.7.14 (54)
- **详情页性能**：背景 `ImageFiltered` 加 `RepaintBoundary`；状态栏/底栏模糊 sigma 30→20；`ListView cacheExtent: 800`，滑动更顺。
- **媒体文件信息卡**：相似推荐后新增「媒体文件信息」液态玻璃卡，展示封装格式·大小·添加时间；路径超 2 行折叠，支持展开/收起 + 长按复制；URL 中文自动解码。
- 旧缓存条目首次进详情不显示该卡，刷新该影片即可。

### v1.7.13
- **进入/退出动画重做**：改用纯黑幕遮罩（`_veil`）+ `PopScope` 接管系统返回；横竖屏切换延迟 280ms 藏在黑幕后，消除录屏中详情页 45° 歪斜旋转。

### v1.7.12
- **字幕 4 项修复**：
  1. 选字幕不加载 → `setSubtitle` 原生换轨（MPV）/ 叠加层（Exo），不再销毁重建播放器；
  2. 开关字幕进度跳回 00:00 → 仅换轨不重置进度；
  3. 点画面关弹窗顺带关字幕 → 引入 `_SubPick` 哨兵区分「关闭字幕」与「点外部关闭」；
  4. 拖动时间提示残留 → `onHorizontalDragCancel` + 1.2s 看门狗防 `_scrubbing` 卡死。
- **媒体库页按 `camby-library-filter-design.html` 设计稿重做**：排序按钮 + 漏斗角标、筛选抽屉（5 字段独立升降、分辨率多选计数、仅中文字幕、类型/标签多选）、应用后摘要条单条✕/清空。

### v1.7.11
- **播放页（13 项问题）**：变速按钮与浮层重叠、快进/退不对称、按下态需长按、按钮重叠、缓冲速度展示、Toast 黄横线（实为底栏溢出）、软硬解与双内核取舍。
  - 决策：**双内核保留** + MPV 加 `hwdec=auto-safe` 自动硬解；缓冲速度置于字幕选项旁（替换重复标题）。
- **其他（6 项）**：首页媒体库信息不显示、搜索返回动画、右上角按钮玻璃感、搜索结果进详情、搜索影片/演员分类、搜索背景动态模糊。
- 修复「搜索点不进详情」（`_open()` 误 `maybePop` 把刚 push 的详情页 pop 掉）。
- 修复「首页媒体库不显示」（空结果被永久缓存 → 不缓存 + `force` + 1.5s 自动重试 + 「点此重试」）。

### v1.7.10
- **进度条交互**：点击进度条跳转（区别于拖动）；跳转时间提示与播放控件重叠修复；字幕旁第二个变速改为「画面比例：自适配 / 满屏」。
- **双内核检查**：统一 Exo/MPV 的 seek、缓冲、字幕挂载行为，修复手势滑动进度不同步。

---

## 隐私与开源许可

- 应用仅连接**用户自己配置的** Emby 服务器，所有凭据（地址 / Token / 账号）保存在本机 `shared_preferences`，不上传任何第三方。
- 内置「演示库」为离线占位数据，不含真实服务器信息。
- 许可证见仓库 `LICENSE` 文件（如有）。

---

© Camby · 由 WorkBuddy 协助开发与维护
