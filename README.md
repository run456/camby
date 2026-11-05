# Camby

> Android 端 Emby 播放器 · 液态玻璃 UI · 双播放内核（ExoPlayer / MPV）

Camby 是一款面向 Emby 媒体服务器的 Android 播放客户端。界面采用统一的液态玻璃（Liquid Glass）设计语言，播放内核抽象为可切换的双引擎（ExoPlayer 兼容最佳、MPV 支持 ASS 特效字幕与更强硬解），并针对大媒体库的浏览、搜索、详情与播放体验做了大量性能与交互优化。

当前版本：**v2.0.49 (249)** · 构建目标：arm64  Release APK

> ⚠️ **源码重建说明**：v1.7.21 (61) 之后的源码工作副本丢失，本工程由 `Camby-v1.7.38-arm64-release.apk`（versionCode 78）反编译取证 + v1.7.21 旧仓库代码对拍重建而成。详见文末 [源码重建说明](#源码重建说明)。重建后以 v1.7.38 为基线，由 WorkBuddy 持续迭代至当前 **v1.7.56 (96)**，全过程见上方「更新日志」。

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

> 本节汇总 v1.7.x 系列的改动。**v1.7.22 → v1.7.40 的版本履历已从原始会话的分享存档中复原**（见 `04-原会话履历复原与差距清单.md`），因此下面 v1.7.38 之后的内容不再是推断，而是对照真实改动逐条补齐。

### v2.0.45 (245) 在线字幕搜索（迅雷 + SubtitleCat）

播放页字幕弹窗新增「**在线搜索字幕…**」，按文件名并行搜索两个公开字幕源，选中后
下载 → 解码 → 解析成 `SubtitleCue` 写入播放页叠加层。**不重建播放器、不丢进度、
不占用 Emby 服务端字幕轨、不写临时文件**。没有外挂字幕、又不想去 Emby 装插件时，
在 App 里直接搜一条就能用。

| 项 | 实现 |
|---|---|
| 中文主力 | 迅雷 `oracle/subtitle` JSON 接口，读真实 `languages` 字段；返回字幕实测为 **GBK** 且带 `<font>` 内联标签 |
| 补充源 | SubtitleCat 搜索页 → 限并发 4 抓最多 8 个详情页 → 解析静态 `.srt` + `-orig.srt` 兜底。该站「中文」是页面 JS 实时机翻，`-zh-CN.srt` 静态链接实测 404，因此不硬找 |
| 容错 | 两源 `Future.wait` 并行、各自 25s 整体超时 / 8s 单请求超时，单源失败静默降级为空列表，不拖累另一源；按 url 去重、中文优先排序 |
| 关键词 | `cleanTitle()` 去站点前缀 / 方括号 / 扩展名 / 画质编码标签，提取 JAV 番号；剧集拼 `S01E02`（文件名已带则不重复拼）；弹层里可手动改关键词重搜 |
| 编码 | BOM → 严格 UTF-8 → 注入的 `gbkDecoder`（`gbk_codec`）→ `latin1` 兜底；解码后 `stripInlineTags()` 去掉 `<font>/<b>/<i>/<u>` 等标签 |
| 挂载 | SRT/VTT 一律走 App 叠加层 `_cues`（先 `setSubtitle(null)` 摘掉 MPV 内核轨避免重叠）；ASS/SSA + MPV 交给内核原生渲染保住特效 |

**状态同步**：在线字幕不是 `SubtitleTrackInfo`，项目里有 3 处用 `_subtitle == null` 判断
「字幕关闭」。新增 `_onlineSubtitle` 单独记录，底栏显示「字幕 · 在线」、播放信息面板显示
「在线 · 迅雷 / SubtitleCat」，选回服务端轨道或关闭字幕时清掉。已挂载时字幕菜单里会多出
一条带选中态的当前项，点它可重新搜索。

**UI**：把播放页原先私有的玻璃面板 / 居中路由 / 行组件抽成
`lib/widgets/glass_sheet.dart`，在线字幕搜索面板复用同一套外观 —— 居中卡片、同样的
底色边框与入场动画，按屏幕短边限宽（手机 470 / 平板 620），不再是拉满整屏的底部抽屉；
横屏也用可用高度自适应，输入框不会被键盘遮住。结果行带「迅雷 / SubtitleCat」来源角标、
语言与格式。

**合规**：上游思路来自 MIT 项目 `PotplayerJavChineseSubs_subtitlecat` 3.0，用 Dart 重写；
许可全文随附于 `licenses/LICENSE-UPSTREAM.txt`，版权人 `Exhen & Contributors` 原样保留。
两个数据源均为第三方未文档化端点 / HTML 结构，随时可能变更，故设计为**显式点击触发**
而非起播自动搜索。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` **319 全过**（新增
`online_subtitle_test.dart` 16 条，含手机/平板限宽的 widget 测试）；`perf_audit.py` 0 命中；
`verify_release.sh --build` 出包 `releases/camby-2.0.45-release-arm64.apk`。

### v2.0.49 (249) 翻译/剧照弹层 UI 优化：消除黄线 + 补标题按钮 + 圆角/间距调整

承接 v2.0.48 真机反馈的 5 项 UI 问题，逐项修复：

- **弹层黄色双下划线（根因）**：`GlassPanelRoute` 与剧照查看器都是裸 route（前者 `PageRouteBuilder`、后者 `showDialog` 直接返回 `GestureDetector`），不继承主页 `Scaffold` 的 `Material`。缺 `Material` 祖先时 `WidgetsApp` 的兜底 `DefaultTextStyle`（`debugLabel: "fallback style; consider putting your text in a Material"`，**黄色双下划线**）会 merge 进每个 `Text`——`Text` 自带 `style` 只能覆盖颜色/字号，盖不掉 `decoration`。两处统一补透明 `Material`，一次性修好所有玻璃面板。
- **翻译弹层样式**：此前把裸 `Column` 直接 push 进 route，缺 `GlassPanel` 卡片容器和明确高度，详情页文字从半透明背景后透出、长简介把译文挤出屏幕。补齐 `GlassPanel + 定高 + Material` 三件套；原文/译文各自限高内滚、加副标题与「识别为 xx」源语言提示、主按钮改蓝紫渐变、风格 chips 收成小圆角。
- **标题翻译按钮**：手机布局标题压在封面上，此前只有平板 banner 挂了按钮。手机标题改 `Row` 挂按钮，并新增 `onBanner` 变体（半透明深色圆底 + 白图标），保证在浅色海报上也看得清。
- **剧照页码**：原固定在屏幕最顶部、与居中的图片隔一大片黑。改为「页码 + 图片区」组成居中 `Column`，页码紧贴图片区上缘 10px；`SizedBox.expand` 保留点按空白关闭。
- **服务器「切换」按钮**：~30px 高的按钮用 14 圆角几乎成胶囊，收成 8px 小圆角矩形，与卡片 24 圆角、旁边方形编辑/删除图标更协调。

新增 `test/lara_sheet_ui_test.dart` 4 条回归：`GlassPanelRoute` 提供 Material（直接断言面板文字 `DefaultTextStyle.decoration` 不再是黄色下划线）、翻译弹层含 `GlassPanel` 且无布局异常、剧照查看器与手机标题按钮的源码守卫。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` **360 全过**（新增 4 条）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.49-release-arm64.apk`。

### v2.0.48 (248) Lara 翻译：标题 / 简介一键中译 + 确认后本机缓存

集成 **Lara Translate 官方 REST API**（按用户选择走「官方 API + 我的 key」，非免密钥网页接口）：详情页**标题旁**、**剧情简介标题旁**（手机 / 平板两处布局）各加一个翻译按钮，点击弹出玻璃面板，自动检测源语言翻译成中文，可选**忠实 / 流畅 / 创意**三种风格；点「确认并缓存」后译文落到 App 私有目录，下次点开直接回显，翻译按钮高亮为「已译」。

- **官方鉴权客户端** `lib/lara/lara_client.dart`：移植官方 SDK `@translated/lara` v1.18.2 的 Access Key 签名换 JWT 流程（`POST /v2/auth` 用 `X-Lara-Date` + `Content-MD5` + `Authorization: Lara:<HMAC-SHA256 签名>`；`x-lara-refresh-token` 续期；`POST /v2/translate` 发送 `q/target/style/instructions`）。响应兼容单 JSON / NDJSON / SSE 流式。新增依赖 `crypto: ^3.0.6`。
- **凭证设置** `设置 → Lara 翻译`：填 Access Key ID + Secret（存 SharedPreferences），可「测试连接」验证有效性；未配置时点翻译会引导去设置页。
- **本机缓存** `lib/lara/translate_cache.dart`：按 `MediaItem.id + 字段`（title / overview）写 `lara_translate_cache/<id>_<field>.json`，含译文与来源元信息（目标语 / 风格 / 检测到的源语言 / 时间）；读不到或文件损坏静默返回 null，绝不卡住详情页。翻译属个人偏好，故只存本机，不写服务器。
- **弹层** `lib/lara/translate_sheet.dart` 复用 `GlassPanelRoute`；已缓存时打开即展示译文，可「重新翻译」（沿用上次风格）/「复制」/「确认并缓存」。
- **测试**：新增 `lara_client_test.dart`（HMAC-SHA256 / MD5 命中 RFC 基准向量、签名挑战串、多格式响应解析、凭证存取）与 `translate_cache_test.dart`（存取 / 标题与简介隔离 / 中文 UTF-8 无损 / meta 缺省 / 文件损坏兜底）。

> 修复回归：新按钮把 `_SectionLabel`（内部含 `Spacer`/`Expanded`）包进 `Row` 曾导致「unbounded width」渲染异常、以及设置页新增输入框缺 `Material` 祖先——分别用 `Expanded` 包裹标签、`_Field` 自带透明 `Material` 解决；同步更新了 `online_subtitle_test.dart` 的版本号守卫。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` **356 全过**（新增 26 条 Lara 测试）；`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.48-release-arm64.apk`。

### v2.0.47 (247) 导出字幕按影片名（优先视频文件原名）命名

承接 v2.0.46 的「导出字幕…」：导出文件名从 `cleanTitle(片名)` 改为**优先用视频文件原名**（去扩展名），
确保字幕落到影片旁时 Emby 按同名自动关联；拿不到服务器路径时回退到影片展示名，再不行兜底到字幕来源标题，
绝不会落到无意义的 `subtitle.*`。命名形如 `<视频文件原名>.zh-CN.srt`（如 `Movie.2023.1080p.zh-CN.srt`），
与 Emby 外挂字幕习惯一致，拷到影片目录即被识别。

- `OnlineSubtitleCache.exportFileName` 不再额外去画质标签（保留原文件名好匹配），仅清洗非法字符 + 拼 `语言.格式`；
- `export()` 新增影片名兜底链：调用方传入名 → 缓存字幕标题 → `subtitle`；
- 播放页 `_exportMovieName()` 取 `MediaItem.filePath` 基名（跨 `/` `\` 分隔）作为导出名。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` 全过（`subtitle_cache_test.dart` 命名用例已同步更新）；
`perf_audit.py` 0 命中；`verify_release.sh --build` 出包 `releases/camby-2.0.47-release-arm64.apk`。

### v2.0.46 (246) 在线字幕：本机缓存复用 + 导出 + 简繁宋体

**1. 字幕本机缓存与自动复用**
播放页下载在线字幕后，按 `MediaItem.id` 把**解码并去标签后的字幕原文**与来源元信息写入 App
私有文档目录 `subtitle_cache/<id>.{sub,json}`（不占 Emby 字幕轨、不污染媒体库、不写临时文件）。
下次进入该影片播放页时，若**没有外部指定字幕轨、用户未手动选过轨、且影片本身无 Emby 服务端
字幕轨**，则自动 `parseAny` 挂回叠加层，省掉再次联网搜索。底栏 / 信息面板据此显示「字幕 · **本机**」
而非「字幕 · 在线」，避免用户以为又搜了一次。

**2. 导出字幕到手机**
字幕菜单新增「**导出字幕…**」：写成用户可见的 `.srt`（命名 `片名.zh-CN.srt`，与 Emby 外挂习惯一致，
拷到影片目录即可被识别），并弹出面板提供「**系统分享…**」（发 NAS / 文件管理器）与「**复制文件路径**」。
> 为什么不是直接写到影片所在文件夹：`MediaItem.filePath` 是 **Emby 服务器上**的路径，手机 App 无写权限；
> Emby 也**没有字幕上传 API**（官方至多建议手动拷到媒体目录，Jellyfin 才有对应端点）。故采用本机缓存 +
> 用户自行拷到 NAS 的稳妥路径。

**3. 内置宋体升级为简繁并集子集**
`assets/fonts/FangSong.ttf` 由原先的 **GB2312 简体子集**替换为 **Noto Serif SC + Noto Serif TC 的并集子集**
（OFL 可商用），用 `fontTools` 子集化到 GB2312 + Big5 一级常用 + 港台补字，内部 family 名保持 `FangSong` 不变。
实测简繁样本均不再缺字，繁体字幕（如 `zh-TW` 结果、外挂繁体）不再回退系统黑体/豆腐块。许可全文随附
`licenses/OFL-NotoSerif.txt`。

**4. 清理与健壮性**
- `export()` 对非 Android 平台用 `try/catch` 兜住 `getExternalStorageDirectory()` 的异常并回退文档目录；
- 缓存 `load` / `remove` 全程 try/catch，读不到 / 损坏一律返回 null，绝不因缓存问题卡住播放页；
- 字幕菜单加「**删除本机字幕**」：删后立即撤下当前字幕并标记本页不再自动选轨，下次不再自动加载。

验证：`flutter analyze` 0 error / 0 warning；`flutter test` **332 全过**（新增 `subtitle_cache_test.dart`
9 条存取/导出/边界、`release_2_0_46_test.dart` 4 条交付守卫）；`perf_audit.py` 0 命中；
`verify_release.sh --build` 出包 `releases/camby-2.0.46-release-arm64.apk`。

### v2.0.44 (244) 状态栏模糊与首页对齐（取消降级、sigma 恢复 30）

用户反馈「这次快很多了」，要求把详情页滚动时的状态栏模糊改成首页的样子。

之前为了省 GPU，详情页的状态栏带做了两处削弱：`degraded`（滚动时换纯渐变）
和 `sigma: 14`（首页是默认 30）。结果是滚动时状态栏视觉「变了样」，跟首页对不上。

现在两处都回滚：

| | 首页（main.dart shell） | 详情页（本版） |
|---|---|---|
| `degraded` | 不传（始终实时模糊） | **不传** |
| `sigma` | 默认 30 | **默认 30** |
| `active` | 上滑后才显示 | 同上 |

顶部与首页完全一致。底部那条模糊带已在 v2.0.43 删除、3 个圆钮仍保留降级，
所以详情页滚动负载已经降到很低，这条不需要再省。

测试同步调整：`scroll_degrade_test` 改为断言**状态栏不降级、sigma=30**，
同时断言**圆钮仍降级**（`ClipOval` 里包 `BackdropFilter` 的数量 3 → 0 → 3）。

### v2.0.43 (243) 海报断层回滚 + 播放按钮内联到简介上方 + 系列空值标「无」

实测反馈三点：①滑动快了一点但效果一般，**大封面出现断层**；②底部悬浮的
播放/重播按钮压住内容；③没有系列时那一格是空的。

**一、海报底部断层：回滚 v2.0.41 的「渐变叠加」**

v2.0.41 为了省 `saveLayer`，把 `ShaderMask` 换成「叠一层纯色渐变」，用的是
固定色 `#06080E`。但页面背景是随主色变化的，两者对不上就在海报底部露出硬边——
就是看到的断层。

恢复 `ShaderMask`（真实 alpha 渐隐，透明处直接透出页面背景，不依赖色值）。
性能上并不亏：外层本来就有 `RepaintBoundary`，`saveLayer` 的结果会被缓存成图层，
滚动时只是平移复用。

**二、播放按钮从底部悬浮改为内联（+ 顺带再少一处实时模糊）**

原来底部一条常驻的 `BottomBarBlur`（第三处 `BackdropFilter`）+ 56×58 的重播圆钮，
飘在内容之上，把剧情简介和剧照压住。改为：

```
[ ▶ 继续播放（蓝色进度填充）]  [ 字幕 ▾ ]     ← 排在「剧情简介」卡片上方
```

- 高度 58 → 46，内联进内容流，不再遮挡任何东西。
- 字幕选择器从「媒体信息」卡里搬出来，紧贴播放按钮右侧（仅手机；平板仍留在原处）。
- 重播圆钮取消，改为**长按播放按钮 = 从头播放**，功能没丢。
- 底部 `SizedBox(120)` 留白改为 `24 + 手势条高度`。
- 详情页的 `BackdropFilter` 从 3 类降到 2 类（两条带 + 3 个圆钮）。

**三、系列为空也显示，标「无」**

空着会让三列看着像少了一格、以为没加载出来。现在固定三列，「系列」无值时
显示中性灰胶囊「无」（`#7E8DA6`，与胶囊行末尾 `+N` 同色，语义都是弱信息占位）。

**新增测试** `play_row_test` 4 条：播放按钮在简介之上、底部无悬浮条、有字幕时
字幕在按钮右侧同一行、系列空值显示「无」/有值显示名称。

### v2.0.42 (242) 方案 A 落实到位：补齐漏网的 3 个圆钮模糊 + 消除滚动期全页重建

用户确认「性能优化用方案 A（滚动时自动降级，静止保留完整玻璃）」。v2.0.41 已实现骨架，
本轮把 A 真正做彻底——复查时发现骨架有 4 处漏洞，都会让降级形同虚设：

| # | 问题 | 后果 | 修法 |
|---|---|---|---|
| 1 | 顶栏 3 个圆钮各带一个 `BackdropFilter(sigma 16)`，**没纳入降级开关** | 滚动时仍在实时模糊，A 只挡了 2 条带、漏了 3 个钮 | `_RoundBtn` 加 `degraded`，降级时不创建 `BackdropFilter` |
| 2 | `_onScrollActivity` 每帧 `cancel()` + `new Timer()` | 60fps 下每秒造 60 个 Timer，GC 压力把省下的帧吃回去 | 改为「滚动序号」机制，每帧只 `++` 一个 int（零分配） |
| 3 | 恢复判定用 `DateTime.now()` 比对 | **墙钟与 Timer 时钟不同源**，NTP 校时后会误判，表现为「停下后模糊再也回不来」（新测试直接复现了） | 改为比对滚动序号：期间又滚过就顺延一轮，不依赖任何系统时钟 |
| 4 | 降级状态用 `setState` | 滚动起始帧整页 build 重跑（10 个板块 widget 全部新建），正好发生在最不该掉帧的时刻 | 改为 `ValueNotifier<bool>`，只让「3 个圆钮 / 顶部带 / 底部带」三处局部重建 |

另修：顶栏原来把「渐变 + 3 个按钮」整体包在 `ValueListenableBuilder<double>(_offsetVN)` 里，
滚动时**每帧重建 3 个按钮**；现拆成两层，每帧只重建一个 `DecoratedBox`。

**新增测试** `scroll_degrade_test`：断言「静止不降级 → 拖动后立即降级 → 停下恢复」。
这个测试抓出了第 3 条墙钟 bug——写测试时就红了。

### v2.0.41 (241) 详情页信息区重排 + 板块紧凑化 + 滑动卡顿修复（实测反馈）

实测：预告片与额外部分已正常，但**手机端布局太占空间**（主演/标签/预告片/额外部分/剧照
纵向叠了 3 屏），且**详情页滑动明显卡顿，媒体库页却丝滑**。

**一、新增「信息区」（参考用户提供的三列 + 三色胶囊设计稿，改深色版）**

- 规格三列：**系列 / 发行日期 / 时长**。系列用橙色胶囊（`SeriesName` 为空时该格隐藏），
  日期与时长用纯文字（`45m` / `2h32m`，与参考稿一致）。
- **演员**：紫色胶囊，带 `♀` 性别符号，点击进演员页。
- **标签**：绿色胶囊，「中文字幕」排第一。
- 按确认的**紧凑版**执行：单行横滑、超出折成 `+N`，**去掉锁图标**。
- 新增数据字段：`MediaItem.premiereDate`（`PremiereDate` 截成 `YYYY-MM-DD`）、
  `MediaItem.seriesName`（`SeriesName`）；请求字段补 `SeriesName`。
  旧缓存缺字段时回退空串，不崩。

**二、板块紧凑化（功能零删减）**

- **预告片 + 额外部分 → 合并为「视频」板块**：一行横滑，卡片左上角挂来源角标
  `预告`（蓝）/ `分段`（橙）/ `花絮`（绿）/ `外链`（蓝）。卡片 168×98 → 132×74。
- 剧照 136 → 104，板块间距 22 → 16。
- 手机与平板共用同一套 `_InfoBlock` 与 `_videoSection`。
- 清理死代码：`_castRow` / `_TagButton` / `_InfoTag`（已被信息区取代）。
- 净省约 **380px**，板块 5 → 4。

**三、滑动卡顿：定位到液态玻璃（`BackdropFilter`），按方案 A 修复**

根因（与媒体库页对比得出）：

| 元凶 | 位置 | 为什么卡 |
|---|---|---|
| `BackdropFilter` ×2 | 顶部状态栏模糊、底部播放条模糊 | 每帧把**整块滚动内容**重新采样 + 跑模糊着色器（`inspire_blur` 内部就是 `BackdropFilter`） |
| `ShaderMask` | 海报底部渐隐 | 给约 500px 高的图层开 `saveLayer`，滚动每帧重新合成 |

媒体库页用懒加载 `CustomScrollView`，**无任何常驻 BackdropFilter 压在滚动内容上**，
所以丝滑。

修复（方案 A：滚动时自动降级）：

- `StatusBarBlur` / `BottomBarBlur` 新增 `degraded` 参数：为 true 时直接渲染
  **同色半透明渐变**（包 `RepaintBoundary`），完全不碰 `BackdropFilter`。
- 详情页监听滚动：滚动开始 → 立即降级；停止 180ms → 恢复完整液态玻璃。
  静止态视觉与之前完全一致。
- 海报 `ShaderMask` 换成叠一层背景色渐变（省掉 `saveLayer`），视觉几乎无差。
- 两条模糊带都补 `RepaintBoundary`，避免把滚动重绘扩散给整棵子树。

**四、测试**

- 新增 `info_block_test`（10 条）：日期解析（含 7 位小数秒）、新字段往返、旧缓存兼容、
  时长格式化、演员数量。
- `extra_parts_section_test` 改为断言「视频」板块 + 分段角标 + cd2 名称。
- `tablet_layout_test` 的「主演」断言改为「演员」。
- 全量 **298 通过**，0 error / 0 warning，性能审计无红线。

### v2.0.40 (240) 真正根因：`ChildCount==0` 闸门掐死同目录兜底（实测：v2.0.39 仍无变化）

v2.0.39 加的单条详情补拉没解决问题，诊断依旧全 404。继续查后发现**两个真正的坑**：

- **坑 1（致命）**：同目录兜底被 `if (dir.isEmpty || childCount == 0) return;`
  卡死。而 `-cd1`/`-cd2` 这类分段影片，两个文件属于**同一个 Emby 条目**，
  `ChildCount` 天然就是 **0**——闸门一卡，兜底永远不跑。改为只看目录前缀
  （含结尾分隔符，防 ABP-01 串到 ABP-018），并放宽 `IncludeItemTypes`
  到 `Video,Movie,Episode,MusicVideo`。
- **坑 2**：额外部分探测漏了 Emby 官方的 `AdditionalParts` 端点
  （`/Videos/{id}/AdditionalParts`、`/Items/{id}/AdditionalParts`）——
  网页版「附加媒体」正是走它。已补进 `_extraProbes`，两条 baseUrl 都试。
- 诊断升级：
  - `[分段]` 段提到**最前面**，打开第一屏就能看到；
  - 新增 `[同目录]` 段——按影片路径前缀全库反查同文件夹所有视频，列出
    `名称 [类型/ExtraType] | 路径`，无论服务端把 cd2 存成什么形态都能一锤定音；
  - 弹窗新增 **「复制」** 按钮，一键复制纯文本，不必再靠截图（截图常被滚动截断，
    前两次都因为只截到底部而看不到 `[分段]` 段）。
- 新增 `extra_parts_childcount_test`：假 Emby 复现 `ChildCount=0` + cd2 独立条目，
  断言能取到 cd2、排除自身、排除预告片、不串到别的影片目录（3 条）。
- 全量测试 288 通过，0 error / 0 warning，性能审计无红线。

### v2.0.39 (239) 分段（Cd1/Cd2）额外部分真正显示（实测：诊断全 404 误判）

实测反馈：影片 15607（`IPZ-018-C-cd1.mp4`，带 `-cd2`）在网页版能切换 `附加内容` 分段播放，
但 App 详情页「额外部分」不显示，诊断弹窗 `[额外]` 段全 404 / 0 项。

- 根因（两处）：
  1. **Emby 批量 `/Items` 列表查询只回「主版本」那一条 MediaSource**，完整的
     `-Cd1/-Cd2` 分段只有**单条详情** `/Users/{uid}/Items/{id}` 才给全。旧代码只从
     列表条目里的 `MediaSources` 解析额外部分，于是 cd2 永远取不到；
  2. 诊断弹窗 `[额外]` 段只探测了 `SpecialFeatures` / 子项接口，**根本没看 `MediaSources`**，
     所以即使分段存在也被误报成「没有额外部分」。
- 新增 `EmbyServer.mediaSources(id)`：走单条详情补拉一次，解析出非主版本的额外分段
  （跳过 `Index` 最小 / `Id` 与 `MediaSources[0]` 相同的主版本）。
- `_fromJson` 的额外部分解析抽成静态 `_extraPartsFromSources`，与 `mediaSources()`、
  诊断共用同一逻辑，避免三处漂移。
- 详情页 `_loadExtras()` 同时调用 `mediaSources()` 并写回 `_item.extraParts`；
  `_onStateChanged` 全局状态回写时保留已加载的分段，避免被只带主版本的列表条目覆盖。
- 诊断弹窗新增 `[分段]` 段：如实报告 `MediaSources` 真实条数与解析出的额外分段，
  不再被 `SpecialFeatures` 404 误导。
- 新增 `media_sources_test`：本地假 Emby 验证「单条详情带 cd1+cd2 → 只解析出 cd2」
  「单条 1 个源 → 空」「缺字段 → 空」等 4 条；全量测试 285 通过，0 error/0 warning。

### v2.0.38 (238) 诊断入口两端统一（实测：平板有预告片时入口消失）

实测反馈：平板端「预告片」已显示，「额外部分」没有，但**诊断入口也看不见**，无法排查。

- 根因：手机与平板两套布局各写一份诊断入口条件，平板那份仍是旧逻辑
  「有预告片就整行隐藏」——内容只拿到一半时入口反而消失。
- 统一为 `_showDiagEntry`：**预告片或额外部分任一缺失就显示**，两端共用。
- 手机端板块序列抽成 `_phoneSections()`（与 `_tabletSections()` 对称），
  条件随 `setState` 状态刷新；顺带消除 build 里的巨量内联。
- 诊断弹窗升级为「预告片 / 额外部分诊断」，`trailerDiag` 增加 `[额外]` 段，
  逐条列出额外部分各入口的状态；「重新加载」同时刷新两类内容。
- 新增 `diag_entry_test`：3 档屏幕 × 4 种内容组合（都无 / 只预告片 /
  只额外 / 都有）共 12 条，锁死入口可见性。

### v2.0.37 (237) 「额外部分」覆盖独立子条目（实测：15607 无栏目）

v2.0.36 只覆盖了「同一影片的多个 MediaSource」，实测某些服务端会把 `-Cd2` 扫成
**独立子条目**（有自己的片名与时长），`MediaSources` 仍只有一条，于是栏目整块不出现。

- `EmbyClient.extraParts()`：与预告片同款多入口探测，命中即停
  （`/Items/{id}/SpecialFeatures`、`/Users/{uid}/Items/{id}/SpecialFeatures`、
  子项查询 `ParentId × Recursive=false/true`，每条再分带 `/emby` 前缀与站点根路径）；
  结果**排除预告片**（避免与预告片栏目重复）与影片自身。
- 全落空时兜底：按影片目录前缀全库反查（`IncludeItemTypes=Video,Movie`），
  以 `ChildCount == 0` 作闸门，绝大多数无花絮的影片不会触发全库扫描。
- 详情页栏目合并两类来源：子条目在前（有自己海报/时长，直接起播）、
  MediaSource 在后（带 `MediaSourceId` 起播）；都空才整块隐藏。
- 诊断入口扩展为「没看到预告片/额外部分？点此诊断」，会逐条列出额外部分的探测结果。

### v2.0.36 (236) 详情页「额外部分」栏目（-Cd1 / -Cd2 分段）

预告片实测通过后，补齐 Emby 网页版另一块内容：同一影片的多个 MediaSource。

- `MediaItem.extraParts`：解析 `MediaSources`，跳过主版本（首条 / 与 `MediaSources[0].Id` 相同），
  其余按 `Index` 排序；新增 `MediaExtraPart`（名称 / 路径 / 时长 / 分辨率 / 编解码 / 体积），
  名称缺失时退化为文件名去扩展名。
- 详情页新增「额外部分」栏目，排在「预告片」之后、「剧照」之前，**手机与平板两套布局同步**；
  卡片缩略图用影片 backdrop，标题下方标规格（如 `1080P H264 · AAC · 2小时32分钟`），无分段则整块不出现。
- 起播：`PlayerPage` 新增 `mediaSourceId` / `sourceLabel`，直接按指定来源取流
  （`/Videos/{id}/stream?MediaSourceId=...`），失败再退 HLS 同源；播放页标题后缀显示分段名，
  避免误以为在播主版本。分段不继承主版本的续播位置。
- 新增单测：`extra_parts_test`（解析/命名/时长格式化 5 条）与
  `extra_parts_section_test`（手机 / 平板 / 大平板三档渲染 + 顺序 3 条）。

### v2.0.35 (235) 预告片入口矩阵探测 + 根路径/`api_key` 兼容（实测诊断）

实测诊断显示：`LocalTrailerCount=1`（服务端认这条预告片），但 `/Items/{id}/Trailer`、`/Items/{id}/LocalTrailers`、`/Items/{id}/SpecialFeatures` 与本机所有子项查询**全部 404**，而网页版能播。

- 新增 `_trailerProbes()`：把「可能取到预告片」的入口列成清单逐条试，命中即停。覆盖
  `/Items/{id}/{LocalTrailers,Trailer,SpecialFeatures}`、老版用户级路径
  `/Users/{uid}/Items/{id}/{LocalTrailers,SpecialFeatures}`、子项查询
  `ParentId × Recursive=false/true` ×（`/Users/{uid}/Items` 与 `/Items`），
  每条再分「带 `/emby` 前缀」与「站点根路径」两种——不少服务端的 `/emby` 只是部分路由的别名。
- 所有探测请求补 `api_key=` 查询参数，并同时发 `X-Emby-Authorization` 头
  （部分服务端缺该头会直接 404 隐藏路由）。
- 条目 DTO 若内嵌 `LocalTrailers` 直接采用（绕开路由，用同一个必然可用的 `/Items/{id}`）；
  全落空且 `LocalTrailerCount>0` 时退化「全库扫 Trailer/Video + 按影片目录前缀筛」。
- 单条探测 3s 硬超时，命中即停，避免拖慢详情页。
- 诊断改为逐条列出每个入口的「状态 · 条目数 · 命中数」，一眼看出哪条路通。

### v2.0.34 (234) 修复请求参数被覆盖的底层 bug + 按 LocalTrailerCount 保底全库扫描（实测诊断）
- **底层 bug（关键）**：`_getJsonAny` / `_getAny` 用 `Uri.parse(path).replace(queryParameters: qp)`，会把 **URL 里内嵌的 `?ParentId=..&Recursive=true` 整体覆盖**，只留 `UserId`/token。于是子项查询实际变成了「查根目录全量」，诊断里那「8 项」全是媒体库文件夹（本地珍藏/合集/123strm/播放列表…），「4801 项」是整台服务器——**全是假数据**。改为**合并 `base.queryParameters` + 显式 query**，并抽成 `buildRequestUri()` 加单测回归
- **权威信号 `LocalTrailerCount`**：实测该片 `LocalTrailerCount=1`，说明 Emby 明确知道有 1 个本地预告片。`trailers()` 现在先读详情拿 `LocalTrailerCount` + `Path`，再走多路
- **子项查询补 `Recursive=false`**：电影的直接子项就是花絮，四种组合（Recursive false/true × 是否 IncludeItemTypes）全试取并集
- **保底全库扫描**：前几路全落空且 `LocalTrailerCount>0` 时，拉库内 `Trailer`（无则 `Video`）+ 客户端按影片目录前缀过滤（Emby 忽略 `PathStartsWith`）。该路只在必要触发，且只带 `Path/ExtraType` 两字段控制体积
- **诊断更准**：修合并 bug 后，诊断终于显示**真实子项**；末尾新增「全库扫描 · Trailer 共 N 条 · 本片目录命中 M」，可直接判定是「没取对」还是「Emby 压根没索引这条预告片」

### v2.0.33 (233) 按 Path 前缀反查 trailers/ 目录 + 诊断明细（实测诊断结果）
- **实测数据**：`/Trailer`、`/LocalTrailers`、`/SpecialFeatures` 全部 **404**；子项查询（两种参数组合）均 **200 但只返回 8 项、命中 0**。说明 Emby 没有为 `trailers/` 子目录里的预告片建「本片子条目」，之前的 D 路（子项过滤）因此永远拿不到
- **新增 E 路：按影片 `Path` 前缀全库反查**。读取影片 `Path`（如 `/media/ABP-018/ABP-018.mkv`），截出父目录 `/media/ABP-018/`（**保留结尾分隔符**，避免 `ABP-01` 误匹配 `ABP-018`），以 `PathStartsWith` + `Recursive` 查询，再按 trailer 特征过滤。这条不依赖 Extra 分类，直接按物理目录取，是针对「网页能播、App 不行」最可靠的兜底
- **诊断增强**：除各端点状态，还输出影片自身 `LocalTrailerCount` / `RemoteTrailerCount` / `RemoteTrailers` 数量、真实 `Path`，以及子项查询返回的**每一条明细**（Name / Type / ExtraType / Path），可直接看出那 8 项究竟是什么

### v2.0.32 (232) 子项查询放行 Extra + 预告片诊断入口（实测反馈）
- **修正服务端判定**：用户网页 URL `#!/item?id=15512&serverId=94d1...` 表明这是 **Emby**（Jellyfin 用 `/web/#/details`），且 `94d1...` 是 **serverId 而非影片 ID**。此前拿 serverId 请求 `/Items/94d1.../Trailer` 得到 404「找不到文件」，不是端点问题，是**拿错了 ID**。真实影片 ID 形如 `15512`
- **子项查询放行 Extra（关键）**：Emby `/Users/{uid}/Items` **默认过滤 Extra**，而 `trailers/` 目录扫出的预告片正是 `ExtraType=Trailer` 的 Extra，不加 `IncludeItemTypes` 就永远查不到。改为两种参数组合各试一次取并集（`IncludeItemTypes=Trailer,Video` / 无类型过滤），并补 `Fields=ExtraType`
- **新增「预告片诊断」入口**：详情页在没有预告片时显示「没看到预告片？点此诊断」，逐个端点列出状态码、返回条目数、命中数（含真实影片 ID），一眼看出是哪个接口没通，替代盲猜

### v2.0.31 (231) 接入 Jellyfin 专用端点（`/LocalTrailers`）——预告片终于能取到（实测反馈）
- **定位到服务端是 Jellyfin**：用户实测 `/Items/{id}/Trailer` 返回 404「找不到文件」，但网页能播。Jellyfin 根本没有 `/Trailer` 端点，本地预告片走的是 **`/Items/{id}/LocalTrailers`**——这是此前一直空列表的真正原因
- `trailers()` 改为**四路并发**抓取并合并去重：① Emby `/Items/{id}/Trailer`；② **Jellyfin `/Items/{id}/LocalTrailers`**（主力）；③ `/Items/{id}/SpecialFeatures`（花絮集合，按 trailer 特征过滤）；④ 子项递归兜底。任一路 404/失败退化为空，不影响其它路
- 请求层仍是 `_getJsonAny`（兼容裸数组 / `{Items}` 两种返回）；子项递归仅电影启用

### v2.0.30 (230) 预告片抓取真正的根因修复（响应数组 + 全点子项）（实测反馈）
- **根因①：`/Items/{id}/Trailer` 可能返回 JSON 数组**，而请求层 `_getJson` 用 `as Map` 强转，数组会抛 `TypeError` 被上层 `catch` 静默吞掉 → 永远拿不到预告片。新增 `_getJsonAny()` 保留原始 `dynamic`，`trailers()` 用容错解析兼容「数组」与「`{Items:[...]}`」两种返回
- **根因②：本地 `trailers/` 子目录里的文件类型判定不一**。v2.0.29 用 `IncludeItemTypes=Trailer,Video` 过滤，部分 Emby 版本的类型归类不一致导致漏检。改为**不带 IncludeItemTypes 的全量子项查询 + 客户端特征过滤**，并用 `EmbyServer.looksLikeTrailer()` 综合 `ExtraType / Type / Path / Name / MediaSources[].Path` 五个信号判定（服务端隐藏 Path 时用 Name 或媒体源路径兜底）
- 剧集（Series）下递归会拉海量分集，故子项查询仅对电影启用；剧集远程预告片由官方端点覆盖
- 判定方法单测扩到 9 条（新增 Name、MediaSources[].Path 两路）

### v2.0.29 (229) 预告片识别加固 + 栏目置顶 + 剧照滑动去卡顿（实测反馈）
- **预告片识别加固（本机 trailer 文件）**：上版只按 `IncludeItemTypes=Trailer` 查子条目，而 Emby 对本地 trailer 常以 `Type=Video` + `ExtraType=Trailer` 形态存储、且放在 `trailer/` 子目录时会再嵌套一层，导致漏检。改为**递归拉取子项 + 客户端按 `ExtraType/Type/路径含 trailer` 过滤**，兼容两种存储形态与嵌套目录；查询限定 `Trailer,Video` 两类，避免把剧集 Episode 拉进来。判定逻辑抽成 `EmbyServer.looksLikeTrailer()` 静态方法并加 7 条单测
- **预告片栏目上移到剧照之上**：按要求把「预告片」板块放在「剧照」上方；仅当检测到本地 trailer 或远程外链时才显示该模块，读不到则不出现。手机与平板双布局同步调整
- **剧照全屏滑动去卡顿**：`_showBackdrops` 的每页 `InteractiveViewer` 会与 `PageView` 横向翻页在手势竞技场互相抢，是滑动卡顿的主因——移除 `InteractiveViewer`，翻页恢复顺滑（缩放能力随之取消，换取滑动跟手）；解码宽度再降到 1100，点按空白关闭由外层手势处理

### v2.0.28 (228) 偏好影片修复 + 本地预告片 + 详情页性能（实测反馈）
- **偏好影片修复（服务器+本机次数取较大值）**：v2.0.27 仅认服务端 `userPlayCount`，而很多服务器不会给「普通播放」自动 +1，导致榜单长期为空。v2.0.28 恢复本机播放计数（起播一次 +1，落盘持久化 `play_count_json`），与服务器次数取较大值作为「有效播放次数」。这样本机看过的片必然进榜，其它设备/官方客户端看过的也照常计入，且不会因各记一遍而重复膨胀。数据源徽标改为「服务器+本机次数」
- **预告片栏目兼容本地 trailer 文件**：原 `trailers()` 只查 `/Items/{id}/Trailer`（网页关联的预告片），识别不到用户放在电影文件夹里的本地预告片（`trailer.mp4` / `trailer/trailer.mkv` 等被扫成 `ExtraType=Trailer` 子条目）。改为两路都抓并合并去重：关联预告片 + 按 `ParentId` 查的本地预告片 Extra，任意一路失败都不影响另一路，绝不抛异常。本地预告片无自身海报时退回电影 backdrop 当缩略图
- **详情页性能优化（滑动/剧照切换更顺）**：① `CachedImage` 外包 `RepaintBoundary`，列表与详情滚动时未变化的图不再整帧重绘；② 剧照查看器解码宽度 1600→1280 并逐页 `RepaintBoundary`，左右滑动切换更跟手；③ 详情页顶/底实时模糊 sigma 下调（状态栏 20→14、底部条 20→16），滚动时模糊带每帧重采样的 GPU 开销降低

### v2.0.27 (227) 偏好影片改服务器播放次数 + 详情页预告片/剧照滑动（实测反馈）
- **偏好影片改用服务器播放次数（方案 A）**：移除 v2.0.26 自增的本地 `_playCount` 整套逻辑（计数机 + 持久化 + 起播记一次 + 测试），`LibraryStats.compute` 的 `topMovies` 改为直接读服务端 `userPlayCount`。结果跨设备一致、重装不丢，且 App 起播/退出已回传会话事件，服务端 `PlayCount` 会持续累积（口径为「看完才 +1」）。统计页徽标同步改为「服务器播放次数」
- **影片详情新增「预告片」栏目**：`MediaItem` 新增 `trailerUrls`（解析 Emby `RemoteTrailers` 远程外链）；`emby_client` 新增 `trailers(itemId)` 拉取本地预告片（Emby 独立视频项）。详情页在剧照之后插入「预告片」板块：本地预告片点按即在 App 内直接播放；远程外链点按跳转系统浏览器（新增 `url_launcher` 依赖 + Android 11+ 浏览器 `<queries>`）
- **剧照支持左右滑动查看**：原 `_showBackdrop` 单图对话框升级为 `PageView` 轮播，进入即定位到所点剧照，可左右滑动切换、顶部显示「N / 总数」页码，点按空白关闭。手机与平板双布局同步

### v2.0.26 (226) 偏好演员并入完成观看 + 偏好影片本地播放次数（实测反馈）
- **偏好演员统计扩展**：统计对象从「继续观看」扩展为「继续观看 ∪ 完成观看」（完成观看=已看标记或进度≥90%），两种都算「真正看过的片」，演员各计 1 次，同一部不重复计数。说明弹窗文案同步更新
- **偏好影片（新区块）**：统计页新增「偏好影片」卡片，按**本机 App 播放次数**取前 10 部电影（每次起播 +1，仅计电影，剧集不计入）。与服务端「最常看作品 Top」区分：这里只认本地播放计数，不依赖服务器权限，重装/换端会重置（属预期）
- **本地播放次数持久化**：`app_state` 新增 `_playCount`（`movie_play_count_json` 持久化）+ `addPlayCount` / `flushPlayCount`；`player_page` 起播成功后记一次（每个实例仅一次，引擎切换重建不重复记）；`LibraryStats.compute` 新增 `playCounts` 参数驱动 `topMovies`

### v2.0.25 (225) 播放兼容修复 + 偏好演员口径调整（实测反馈）
- **杜比视界绿屏修复**：DV Profile 5 用 IPT 色彩空间，需播放器做 IPT→BT.2020 转换，否则整体发绿。`MpvController.open` 新增 `dovi=yes` 属性，让 libmpv 处理 DV 的 RPU 元数据（无 DV 时为 no-op，不影响普通片源）。Exo 内核无法解码 DV P5，会静默黑屏，故 DV 片走 MPV 内核
- **TrueHD / DTS-HD MA 无声修复**：`MediaItem` 自带 `audioCodec`，起播 URL 为 `Static=true` 直连无转码。TrueHD / DTS-HD MA 等无损多声道经 ffmpeg 解码成 7.1 PCM 后，Android AudioTrack 常因声道掩码不支持而直接不出声。`open()` 新增 `audioCodec` 参数，检测到 TrueHD / DTS-HD 时强制 `audio-channels=stereo` 立体声下混，保证出声（其余编码保持原声道）
- **偏好演员口径调整 + 移除本地累计规则**：用户反馈「本地 APP 累计播放时长算已看」规则去掉。`LibraryStats.compute` 移除 `localPlaySeconds` 参数与「已看」的 15 分钟本地累计判定；偏好演员改为统计**「继续观看」影片**（续播进度 1%~99%）的演员，不再按「已看」统计；同步移除 app_state / player_page 整套本地累计播放秒数 machinery（计时器、落盘、回写服务器）与对应测试；说明文案改为描述「继续观看」口径

### v2.0.24 (224) 多服务器切换与收藏夹归属修复
- **本地累计播放越过 15 分钟 → 回写服务器「已看」**：用户确认要把 App 本地累计的播放时长同步到服务器。`addLocalPlaySeconds` 在累计秒数跨过 900s 门槛（且已连接）时，调用 `_server.markPlayed(id, played:true)` 把「已看」布尔写回服务端 UserData，网页端 / 其他设备即能看见这部已看。注意：累计秒数本身服务端无对应字段（只有「续播位置」与「是否看完」），故只同步布尔结果、不同步数字，避免污染续播点
- **切换服务器后收藏夹仍显示旧服务器缓存（bug 修复）**：原 `folders` 是跨所有服务器的扁平列表，收藏页直接展示全部，于是从 Emby 切到 Jellyfin 后仍挂着 Emby 的收藏夹。新增 `activeFolders` getter（按 `_activeServerId` 过滤，旧版 `serverId` 为 null 的夹归当前服务器兼容），收藏页头部计数与网格、以及「加入收藏夹」弹层均改为只展示**当前服务器**名下的收藏夹；切到 Jellyfin 即拉取 Jellyfin 的播放列表，Emby 的夹不再混入
- **服务器切换 UI 重做（用户反馈操作隐蔽/提示不清）**：① 取消「编辑需长按列表」的隐藏操作，改为每张卡片右侧显式的铅笔「编辑」+ 垃圾桶「删除」按钮；② 非当前服务器卡片新增醒目的渐变「切换」按钮，点按即切换并给出明确反馈（「正在切换到『X』…」→「已切换到『X』」/ 失败显示具体原因并去掉 `EmbyException:` 前缀）；③ 当前服务器卡片加青色描边 + 「当前」徽标 + 状态行（● 已连接 / ● 离线（显示缓存）/ ○ 点按卡片切换）；④ 区块标题下加一行操作提示「点按卡片切换 · 右侧铅笔编辑 · 垃圾桶删除」，空状态重复文案去重

### v2.0.23 (223) 统计页反馈（液态玻璃说明 + 累计播放计时已看）
- **「?」按钮居中 + 弹窗液态玻璃**：v2.0.22 的「?」圆钮内问号因字体度量未垂直居中（略偏上），改为 `SizedBox` + `TextAlign.center` + `height:1` + `leadingDistribution: even` 真正居中；弹窗由纯色 `AlertDialog` 改为 `Glass`（自带 `BackdropFilter` 实时模糊 + 折射高光），与全局玻璃质感统一
- **累计播放时长纳入「已看」口径**：用户希望「一部影片累计播放超过 15 分钟就算已看」。新增本地累计播放秒数（itemId→秒，落盘 `local_play_seconds_json`）：播放页每 5 秒、仅 `isPlaying` 且非 demo 时 `addLocalPlaySeconds(id, 5)`，退出时 `flushLocalPlaySeconds()` 立即落盘。`LibraryStats.compute` 的「已看」判定新增第三条 `本地累计 ≥ 900s`，与「已看标记 / 进度>90%」为「或」关系；跨门槛时使统计缓存失效重算。本地计数独立于 Emby UserData，重装/换端会重置（属预期）
- **说明文案同步**：弹窗口径说明增补「在本 App 内累计播放时长 ≥ 15 分钟」一条
- **手机/平板同步**：统计页为同一 `StatsPage` 响应式布局（kTabletBreakpoint 双栏），播放页计时两端共用，`app_state` 全局生效，无需分别改动
- **测试**：`local_play_watched_test`（compute 在 899s 不计入、900s 计入、与已看标记/进度 90% 为「或」）、`stats_explain_test` 增补「15 分钟」文案与 `Glass` 弹窗断言；全量 245 全过

### v2.0.22 (222) 统计页两项反馈（去重环 + 偏好演员口径说明）
- **观看完成率顶部重复环移除**：v2.0.21 把「库存覆盖率」并入「观看完成率」后，卡片内出现了两个同为 7% 的环（顶部「库内已看完影片占比」+ 底部「已看/库内」），口径一致属于重复。现删除顶部环，卡片只保留「已看 X / 库内 Y 部 / 还有 Z 部 未看」一个环 + 最近播放 10 部列表
- **偏好演员「已看加权」改为「?」说明按钮**：原胶囊文字 `已看加权` 改为标题行右侧的圆形「?」按钮，点击弹出 AlertDialog 说明统计口径——「已看」= 已看标记 或 播放进度 >90%；每部已看影片最多取前 5 位演员（按影片内顺序去重）计频；「次」= 该演员出现在多少部已看影片；条形长度按「次数÷最高次数」归一化仅用于显示比例。手机/平板同一卡片，两端生效
- **测试**：`stats_explain_test`（顶部环文案 `库内已看完影片占比` 消失 / `已看加权` 消失 / 「?」点击弹出含「什么叫已看一次」「进度超过 90%」的说明、点「知道了」关闭）；全量 241 全过

### v2.0.21 (221) 实测反馈 3 项（首页播放列表隐藏 + 统计卡片合并 + 进度条方向）
- **首页隐藏「播放列表」区块**：收藏夹同步出的 Emby Playlist 视图（`collectionType=playlists`）不是媒体库，`userViews` 与「合集/BoxSets」一并过滤（旧版 Emby 无 collectionType 时按名称「播放列表」兜底）
- **统计页「库存覆盖率」并入「观看完成率」**：两卡指标高度重复（完成率 7% ≈ 覆盖率 7%）。覆盖率圈环与「已看 X / 库内 Y 部、还有 Z 部未看」文案移入完成率卡片（分隔线下方独立一行），独立卡片移除。手机/平板共用同一 children 列表，一处修改两端生效
- **平板详情页观看进度改靠左 + 从左往右**：文字列 `crossAxis.end` → `start`（文字与进度条同一左对齐线）；进度轨道加 `width: double.infinity` + `alignment: centerLeft` 定满宽、填充从左缘锚定向右生长（旧实现轨道随内容收缩且被右对齐，观感是「从右往左走」）
- **测试**：`views_filter_http_test`（真 socket 假 Emby，验证 playlists 视图过滤；独立文件——与 testWidgets 混用会因 binding 劫持 HttpClient 全部 400）、`v2021_ui_test`（统计页卡片合并 + 覆盖率字段仍可算）、`tablet_layout_test` 增补进度条靠左/从左往右填充断言；全量 239 全过

### v2.0.20 (220) 收藏夹改名 400（实测反馈）
- **问题**：用户服务器对 `POST /Items/{id}`（UpdateItem）无论整包还是最小 body 都返回 400，「人妻」改名永远失败，手机/平板端同步均报 400。v2.0.4 补 ProviderIds、v2.0.16 最小 body 重试在该服务器均不奏效
- **根因**：该 Emby 实例 UpdateItem 端点对播放列表改名路径死 400（与字段完整性无关），而创建/删除/加片为独立端点、实测可用
- **修复**：`renamePlaylist` 改为四层兜底——① 整包回传 ② 最小 body 重试 ③ 完整字段回传（GET 带 `Fields=ProviderIds,PlaylistItems,…`）④ **重建式改名（终极兜底，必成）**：`createPlaylist(目标名, 本地片单)` 新建 → `deletePlaylist(旧列表)` 删除，彻底绕开 UpdateItem。已有同名残留则复用并补差集，幂等
- **返回语义**：`renamePlaylist` 由 `bool` 改为 `String?`（成功返回可能变化的最终 Id，失败返回 null）。`_reconcileUpload` 在换 Id 时换绑 `playlistId` 并跳过本轮加/移片；`renameFolder` 以 `null` 判失败置 `pendingSync`

### v2.0.19 (219) 平板详情页横幅信息区重排（实测反馈）
- **海报与背景框等距**：原海报贴底（上 44 / 下 24 / 左 26 不等距）。改为垂直居中：上下间距 = (330-262)/2 = 34，水平边距同步 34，四边视觉等宽
- **信息列垂直居中不再贴底**：原 `CrossAxisAlignment.end` 把徽章/标题/元信息压到底部。改为垂直居中，与海报中线对齐
- **信息流顺序重排**：媒体徽章（H264/AAC 等）→ 标题 → 「2026·已看43%·主演」元信息 → 观看进度信息（右对齐，含百分比+剩余分钟+细进度条）→ 播放按钮行。观看进度从独立右下悬浮块（`Positioned`）挪进信息列，删除按钮区右侧 250px 占位 hack
- **测试**：`tablet_layout_test` 增补海报上下等距守卫断言（顶距/底距 = 34±1）

### v2.0.18 (218) 字幕加粗开关 + 字体可切换（系统/仿宋）
- **字幕加粗开关**：`SubtitleStyle` 新增 `bold` 字段（默认 true，对应影院风格截图），面板新增「加粗」Switch；MPV 链路 `sub-bold` 随开关切换为 `yes`/`no`，Flutter 叠加层 `fontWeight` 在 `w800`/`w500` 间切换。用户想要细字幕可自行关掉
- **字幕字体可切换**：`SubtitleStyle` 新增 `font` 枚举（`system` / `fangsong`），面板新增「字体」选择行（系统 / 仿宋）；Flutter 叠加层通过 `fontFamily: 'FangSong'` 渲染。仿宋字体采用**开源思源宋体（Noto Serif SC，OFL 可商用）**，按 GB2312 字符集子集化为 `assets/fonts/FangSong.ttf`（2.6MB，原 12MB），在 pubspec 注册 family 名 `FangSong` 并同步改 TTF 内部 family 名为 `FangSong` 保证两端一致；MPV 链路在选仿宋时把内置 ttf 抽到应用目录并通过 `sub-fonts-dir` 暴露给 libmpv（按内部 family 名匹配）。字幕偏好新增 `bold`/`font` 持久化键
- **测试**：`camby_1738_test` 的 `SubtitleStyle` group 增补 `bold`/`font` 断言（含 `fontFamily` 与 `w500` 兜底）；`mpv_sub_style_test` 增补 `sub-fonts-dir`/`FangSong`/`_ensureFangSongFont` 守卫

### v2.0.17 (217) 实测反馈 2 项
- **平板详情页横幅模糊对齐首页**：`_tabletBanner` 的 backdrop 原来是清晰直出（`memWidth 1200`），与首页 Hero（高斯模糊 sigma 40 + 低清采样 220）观感不一致。改为同款 `ImageFiltered` 高斯模糊（sigma 40 + `memWidth 220`），外层 `Transform.scale(1.12)` 防止模糊羽化在圆角边缘露透明。渐变压暗层不变
- **字幕样式固定为「影院风格」+ 面板只留大小/位置**：用户截图要求字幕为白色加粗 + 黑色描边。`SubtitleStyle` 砍掉「描边/不透明度/颜色/偏移」可调项，样式固定为**白字加粗（w800）+ 8 向黑色硬描边**（比旧默认更粗，更接近影院字幕）；MPV 链路同步固定下发 `sub-color` 白 / `sub-border-color` 黑 / `sub-border-size 3` / 新增 `sub-bold=yes`（系统黑体加粗，零打包体积）；设置面板仅剩「大小」「位置」两行滑杆，删掉了描边/不透明度滑杆与颜色色板。已存用户偏好只保留 size/pos 生效。字体采用系统黑体方案（Android 自带 Noto/MiSans/HarmonyOS 均为黑体系，观感一致）

### v2.0.16 (216) 实测反馈 3 项
- **手机端收藏夹重复文件夹修复**：同步只按 `playlistId` 匹配、从不看名字——本地夹的播放列表 Id 失效（或从未上云）时直接在服务端**新建**同名播放列表，服务端同名的再被拉回本地，就出现「哈哈×2、OL×2」这类重复。`_reconcileUpload` 两步收敛：① 未上云 / Id 失效的收藏夹**先按名字收养**服务端同名播放列表（只补本地缺的片单，不新建），收养不到才创建；② 同步收尾对当前服务器的收藏夹**按名字去重合并**（历史事故留下的本地重复夹收敛为一个，片单取并集，绑定的多余服务端播放列表一并删除）。另：播放列表改名 400（部分 Emby 版本对整包回传 DTO 仍拒绝，实测「人妻」永远卡重试）增加**最小 body 重试兜底**——播放列表唯一要改的就是名字，片单由 /Playlists/{id}/Items 独立接口管理不受影响
- **统计页「缺简介 0 部」修复**：`missingOverview` 计数条件是 `overview.isEmpty`，但解析层把空简介替换成「暂无简介」占位符，计数永远 0，而下方列表用另一套条件（含占位符）所以能列出条目。计数改为与列表同一套条件（`missingPoster` 同步统一）
- **平板详情页按设计稿 `docs/detail_sections_proposal.html` 重排**：v2.0.14 只修了标题对齐、双栏结构没动，与已确认设计稿不符。现改为**单列**：顺序 = 分集(剧集) → 剧情简介 → 媒体信息 → 主演 → 标签 → 剧照 → 相似推荐，所有板块标题与内容严格同一左缘；扩展档（≥1200）占满内容区、中等档（840–1199）限宽 760 居中。顺带修复扩展档左栏 `Column` 缺 `crossAxisAlignment: start` 导致标签 chip 少时整排居中的问题。手机端不动

### v2.0.15 (215) 移除「选择码率」功能
- 经核验，码率切换依赖**服务端实时转码**（Emby 按 `MaxStreamingBitrate` 重新出流）；当前服务端无转码能力，该功能实际完全无效，且选档后弹「已设 X Mbps」属于虚假反馈。按用户决策**完全移除**：
  - 播放页：底栏「码率」胶囊、播放信息面板「码率上限」行、`_changeBitrate` / `_applyBitrate` / `_bitrateText` / `_bitrateShort` / `_showGlassPanel` 方法及 `_maxBitrate` 字段、`_bitrates` 常量、首播读取 `set_max_bitrate` 一并删除（首播本就直连原片，无行为损失）
  - 设置页：「最大码率」设置项（`_bitrates`、读写 `set_max_bitrate`）删除
  - `EmbyServer.streamUrl` 移除 `maxBitrate` 参数与 `MaxStreamingBitrate` 拼接（无调用方）
  - 测试：`camby_1738_test` 码率拼接用例、`player_boot_order_test` 的 `set_max_bitrate` 断言同步删除；测试总数 235 → 232
  - README 特性表移除「码率上限」一行

### v2.0.14 (214) 实测反馈（详情页重设计 + 图标 + 返回栈）
- **详情页下部板块重设计（按 `docs/detail_sections_proposal.html`）**：修复「标签标题与标签没左对齐」bug——根因是旧版「剧情简介/媒体信息」玻璃卡片把标题内嵌在卡片内（左 padding 16），而其它板块标题贴列左缘（0），中等档并入右栏后错位 16px。改为所有板块标题统一为**列左缘外部标题**，卡片只放正文（`_overviewCard`/`_mediaInfoCard` 加 `withTitle` 参数，手机端默认 true 零改动）；主演横向滚动圆角头像、标签胶囊 chip 流（与标题同左缘）、剧照/相似横向滚动条（标题右侧显示数量）
- **启动图标加白底（方案 A，按 `docs/logo_proposal.html`）**：原蓝标黑底 → 白底圆角方块（圆角 22%）+ 原蓝标居中 60%；导出 mdpi48/hdpi72/xhdpi96/xxhdpi144/xxxhdpi192 五档 mipmap 覆盖 `ic_launcher.png`
- **返回栈逐级返回 bug 修复（手机+平板通用）**：详情页点演员→演员页→点影片详情，旧实现给演员页的 `onOpenDetail` 里先 `Navigator.pop(context)`（context 属详情1，弹掉的正是演员页自己），栈变成 `[首页→详情1→详情2]`，返回跳过演员页。改为直接复用 `widget.onOpenDetail`（与「相似推荐」卡片同一套逐级压栈），现在 `详情1→演员→详情2` 返回逐级回演员页

### v2.0.13 (213) 实测反馈 2 项
- **详情页去掉重复播放按钮**：底部常驻「继续播放·90%」进度条按钮改为仅手机保留；平板横幅操作行已有「继续播放 / 从头播放」，底部再放一条属于重复（平板内容底部预留 120→32）
- **播放器进度条圆点与轨道居中对齐**：轨道 top 旧实现按按下态高度（barActiveH）计算而实际渲染高度随 pressed 切换、圆点 top 是硬编码 8/10，两套偏移在平板档位下中心最大偏差 6px。现统一以热区中线（barHitH/2）垂直居中：轨道 `top = barHitH/2 - trackH/2`、圆点 `top = barHitH/2 - r`

### v2.0.12 (212) 实测反馈 6 项
- **详情页按设计稿 `docs/detail_tablet_proposal.html` 落地**：① 头部横幅 330 定高 —— 横版 backdrop 全宽铺底 + 底部/左侧双向渐变压暗，竖版海报（180×262、圆角 16、投影）悬浮在左，标题/徽章/元信息/操作按钮压左下，右下角观看进度条；操作行含 **立即/继续播放（渐变主按钮）+ 从头播放 + 收藏 + 标记已看**（新增服务端 `markPlayed` / `AppState.togglePlayed` 直写 UserData.Played）；② 扩展档（≥1200）内容双栏 1fr / 340px，右栏 = 剧情简介 + 媒体信息；③ 中等档（840–1199）横幅同款 + 右栏并入改为限宽居中单列；④ 手机端（<840）完全不动
- **统计页数据第四轮修复（真正的根因）**：本账号归一化匹配后一条都没命中时（实测服务器日志里的 UserId 是另一套内部 Id，与登录 GUID 对不上——「日志播放 519 条，本账号 0 条」），**自动回退为全部播放统计**并在诊断文案说明口径，不再整版丢空
- 首页 Hero 卡：海报左边距 36 → **22**，与上下间距一致
- Rail：搜索与首页之间去掉多余的 8dp（此前实际视觉间距 16，与 Tab 间 8 不一致）
- 媒体库 / 演员页栅格：中等档 5 列 → **7 列**（`mediaGridColumns` 中等档与扩展档统一 7），与首页行宽一致
- 演员页：头部卡片避让状态栏（`padding.top + 12`）；作品网格与媒体库完全同一套参数（边距 24、行距 14、比例 0.55）

### v2.0.11 (211) 实测反馈 6 项
- 统计页数据兜底再补三层：活动日志接口不再传 `HasUserId=true`（部分服务器版本加该参数后日志直接为空——「统计页又没数据」的疑凶）；插件与日志都不可用时，改用「已看历史」（`/Users/{id}/PlayedItems`，普通用户权限 100% 可用）近似生成**每日观看时长**（按片长估算）、**播放时段分布**（DatePlayed 小时分布）、**最常看作品 Top**（条目级 PlayCount），数据源徽章显示「已看历史近似」
- 平板整体下移避让状态栏：Rail 顶部避让 `padding.top + 10`（此前搜索按钮顶进状态栏）；首页 Hero 卡顶部同样避让（手机满幅设计不动）
- Rail 间距统一：搜索与 Tab 组之间的间距统一为按钮间标准间距（8，与 Tab 按钮间一致）
- 首页连接状态胶囊（wifi+数量）：平板上从页面顶层悬浮**移进 Hero 滚动卡内右上角**（随卡滚动），手机保持原悬浮
- 首页横行卡片左间距 24 → **12**，与卡片间 gap、上下间距统一；行标题同步对齐
- 收藏页：平板瓦片高度按内容收窄（比例 0.54 → 0.66，封面贴底后上方大空白消失）、行距 18 → 12、顶部留白 6 → 2，与切换栏的间距明显收紧；手机端全部不动

### v2.0.10 (210) 实测反馈 6 项
- 统计页没数据根因修复：`_loadPlayback` 四项请求（播放报告/活动日志/最近播放/已看历史）以前串在一个 try 里，Playback Reporting 插件接口一失败全部连坐置空 → 拆成独立 try，任何一项失败不再影响其余
- 收藏页：角标贴到**封面右上角**（此前固定在瓦片 top:8，平板上封面贴底后角标悬空）；新建收藏夹虚线框平板下按海报原生比例收窄，与收藏夹封面同大
- 首页推荐位落地设计稿**方案 C**：横版剧照高斯模糊铺满整卡做氛围底 + 左侧清晰竖版海报做识别主体 + 右侧信息列（换一批挪进信息列底部）
- Rail：去掉顶部 Logo（与状态栏叠放观感不对）；**搜索挪到最顶部**（首页上方），Tab 组贴顶上移
- 详情页头部与首页推荐位效果一致（方案 C 同款）
- 全量测试 235 通过（收藏墙 golden 因角标移位重新生成基线）

### v2.0.9 (209) 实测反馈 7 项（详情页重设计另出方案待确认）
- 媒体栅格加密：媒体库/搜索/标签/字幕筛选等 6→**7** 列（中等档 4→**5**），收藏页 5→**6** 列（中等 4→**5**）——封面不再偏大
- 统计页双栏重写：废弃「两两塞同一 Row」（矮卡下方留洞、左右错位），改为**两条独立流式纵列**左右交替，高度互不影响
- 首页行样式统一：最近添加与「按媒体库」行统一为**一屏 7 张整卡 + 露出下一张一小截**（peek 0.35），最近添加数量 9→20
- 首页继续观看：一屏 7 张→**5 张**，封面显著变大
- 首页推荐 Hero：背景由横版剧照改为**竖版海报铺满整卡**（海报为主题），左→右压暗不变
- 平板导航 Rail 重做：弃用 NavigationRail（图标 21dp 太小），改为**液态玻璃按钮**（选中项玻璃胶囊 + 实时模糊、未选中半透明省 GPU），触控目标 ≥56dp；**搜索升级为 Rail 独立按钮**
- 详情页重设计方案（头部横幅 + 海报悬浮 + 双栏）已出 HTML 稿，**待确认后实施**
- 全量测试 235 通过

### v2.0.8 (208) 播放器 UI 随平板分辨率放大
- 新增 `PlayerUi` 度量表（`lib/layout.dart`）：播放页所有控件尺寸/间距/字号抽成两套常量——**手机端逐项等于改造前写死值（零漂移）**，平板端按设计稿整体放大
  - 中央三键：快进退钮 50→**56**、播放钮 66→**84**、按钮间隔 26→**44**、图标 23/30→**26/36**
  - 顶栏：内边距 14/8→**26/16**、图标 15→**19**、标题 13.5→**16**、元信息 10→**12**、内核胶囊 34→**38**
  - 底栏：左右留白 16→**30**、离底 10→**18**、与进度条间隔 8→**12**、时间字号 11→**13.5**、功能胶囊 30→**38**、胶囊间隔 8→**12**
  - 进度条：热区 34→**46**、轨道 4→**6**、按下态 8→**11**（拖动更好按）
  - 双击 ±10 秒气泡：宽 92→**112**、字号 17→**21**，位移由 `tipOffset` 公式自动算出 181→**242**
  - 拖动大时间提示 32/12→**44/15**；亮度/音量条 宽 68→**84**、离边 48→**72**、进度条高 150→**190**
  - 弹窗/面板限宽 470→**620**；外挂字幕字号 ×1.6（设计稿 `.psub` = 27 ≈ 基准 17×1.6；平板画面更大，同样 dp 相对偏小）
- **顺带修 bug**：`tipOffset` 原公式漏算一次快进退钮整宽（`+sideBtn/2` 应为 `+sideBtn`），算出的位移会让气泡压在按钮上；已修正并加断言「气泡左缘 ≥ 按钮右缘且间距正好一个 clusterGap」
- 判定方式复用屏幕**短边 ≥620**（与播放器强制横屏策略一致），横屏手机 852×393 不会被误判成平板
- 新增 `test/player_ui_metrics_test.dart`（手机 27 项度量逐项回归 + 平板设计稿值 + 620 边界 + 播放页无遗留硬编码）、`player_double_tip_layout_test.dart` 升级为「源码走度量 + 公式校验」双保险
- 全量测试 235 通过

### v2.0.7 (207) 剩余页扫尾 + 每版固定验证 + 性能门禁
- 剩余页平板适配：搜索结果/演员 6 列、标签页与字幕筛选页 6 列、人物页头部改 300 定高卡片（左头像右信息）、设置页限宽 720 居中、统计页双栏卡片
- 栅格列数统一走断点：新增 `context.mediaGridColumns`（扩展 6 / 中等 4 / 手机 3）与 `favoriteGridColumns`（5/4/3），替换散落的硬编码列数
- 详情主从分栏按设计稿只在 **≥1200（expanded）** 生效；840–1199（中等档）侧栏折叠为单列
- 每版固定验证：`tools/verify_release.sh`（版本一致性 + analyze + 全量测试 + 性能静态审计 + 构建，一条命令、失败即禁止发布）；新增 `test/phone_regression_test.dart` 手机端不回归守卫（底部 Tab/满幅 Hero/单列详情/16 边距）与平板形态守卫
- 性能：`tools/perf_audit.py` 静态红线（模糊层需 RepaintBoundary、图片必带 memWidth、itemBuilder 内禁 setState、禁 shrinkWrap 长列表、列数走断点）；`PERFORMANCE.md` 给出 profile 真机测量阈值表
- 播放器方向策略定稿：**手机与平板一律强制横屏**（一套控件树，两端行为一致），已在代码注释中记录决策与日后支持竖屏的改法
- 全量测试 230 通过

### v2.0.6 (206) 平板首页/详情/收藏按设计稿适配（实测反馈 5 项）
- 首页每日推荐：平板改为设计稿 `.hero` 卡片——定高 300、圆角 18、横版封面整卡铺满 + 左侧压暗信息列（徽章/标题/元信息/简介/换一批/页码点），保留 PageView 翻页；手机整版竖图不动
- 首页继续观看：平板按设计稿 `.hrow` 一屏 **7 张横版卡**（800/538 零裁切），`ContinueCard` 支持自定义比例；手机 16:9 全宽大卡不动
- 首页最近添加：平板按设计稿 `.hrow-hp` 一屏 **9 张竖版横排行**（替换原 3×3 网格的 0.53 拉伸比例）；"按媒体库"行同步升为一屏 7 张自适应
- 详情页：平板落地 `.detailHead`（定高 300 横版头部 + 左侧信息列）+ `.detailBody` **1fr/380px 主从分栏**（左=分集/主演/标签/剧照/相似推荐，右=剧情简介+媒体信息）；手机单列不动
- 收藏页：平板 5 列（设计稿 `.collection`），堆叠瓦片按海报原生比例（宽×1.45）约束卡高，修复封面上下裁切；演员收藏 6 列；夹内网格与媒体库一致 6 列
- 回归测试：新增 `tablet_layout_test.dart`（Hero 定高 300/边距 30、详情头部 300/右栏 380、收藏渲染），全量 224 测试通过

### v2.0.5 (205) 平板改造 M1：统一断点 + 左侧 Rail 外壳

**平板/手机单 APK 适配 · 第一阶段（形态解锁）**
- 新增 `lib/layout.dart`：按设计稿 `camby_tablet_redesign.html` 三档断点——`<840` 手机（底部 Tab）、`840–1199` 中等（图标条 Rail）、`≥1200` 扩展（带标签 Rail + 主从分栏）；收敛原散落在 4 个页面的 `MediaQuery...size.width >= 840` 魔法数字为 `context.isTablet` / `context.breakpoint`
- `main.dart` 导航外壳改造：**唯一裁决者**按 `breakpoint` 分支——手机走原样底部玻璃栏（零改动），平板走左侧 96px `NavigationRail` + `Expanded(内容区)`
- 关键修复：Rail 分支通过 `LayoutBuilder` + `MediaQuery` **把"内容区宽度"注入**页面，避免 `home_page` 用全设备宽算「继续观看」大卡宽高导致溢出 96px（设计稿评审缺陷 #2）
- 手机路径代码一行未动；页面保活（`Offstage`+`TickerMode`）、切 Tab 过渡、状态栏模糊全部复用
- 新增 `test/layout_breakpoint_test.dart`：锁定三档 840/1200 与 `isTablet/useRail` 一致性
- 回滚锚点：`git tag pre-tablet-phase1`（= v2.0.4 手机版），随时 `git reset --hard pre-tablet-phase1`

### v2.0.4 (204) 修复收藏夹改名 400

**收藏夹同步后在 APP 改名提示 400 失败（真机 2.0.3）**
- 根因：改名走 `GET /Users/{uid}/Items/{id}` 取完整对象 → 只改 `Name` → `POST /Items/{id}` 写回。但 Emby 的 `ItemUpdateService.UpdateItem`（`ItemUpdateService.cs:327`）会对 `request.ProviderIds` 直接 `.ToList()`；而该 GET **默认不返回** `ProviderIds`（`DtoService.cs:861` 仅在请求 `ItemFields.ProviderIds` 字段时才塞进 DTO）→ 回传 DTO 里 `ProviderIds` 为 null → 服务端 `ArgumentNullException: source` → **400**。Emby Web 能改名是因为它的元数据编辑器显式请求了 `ProviderIds` 字段，APP 之前没请求
- 修复：回传前给 DTO 补上 `ProviderIds`（及 `Genres/Tags/Studios/People` 等常见集合字段）空值，保证形态完整；播放列表本就没有这些元数据，补空不会丢数据
- 新增 `test/rename_playlist_providerids_test.dart`：模拟 Emby 默认 GET（不带 ProviderIds）+ 复刻服务端「缺 ProviderIds 即 400」行为，断言修复后改名成功

### v2.0.3 (203) 双击 ±10 秒提示布局统一

**双击快进/快退提示不统一（真机 2.0.2）**
- 旧布局把「+10秒 / -10秒」都浮在按钮组正上方、仅做 34dp 方向感偏移，左右提示视觉上没和对应按钮对齐，方向感弱
- 改为**紧贴对应按钮的同一水平线**：
  - `+10秒` → 贴在**快进按钮右侧**，与其水平对齐
  - `-10秒` → 贴在**快退按钮左侧**，与其水平对齐
  - 与按钮的间距 == 快进↔播放 / 快退↔播放 的间隔（**26dp**，与 `_centerControls` 的 `SizedBox(width:26)` 完全一致）
- 几何按 `_centerControls` 复刻（播放钮半宽 33 + 间隔 26 + 快进退钮半宽 25 → 快进钮右缘 109 / 快退钮左缘 -109），气泡固定宽 92，故位移恒为 ±181、纵向 0，保证不论屏宽都精确对齐
- 更新 `test/player_double_tip_layout_test.dart` 覆盖新布局（贴边、同水平、26dp 间距、固定宽 92）

### v2.0.2 (202) 会话上报改 query 双形态 / 播放历史兜底 / 双击提示错位

**播放记录与活动日志仍为空（真机 2.0.1）**
- 根因：Emby 10.9 起 `/Sessions/Playing|Progress|Stopped` 用 `[FromQuery]` 绑定模型，只认 **query 参数**，body JSON 被忽略 → ItemId 为空，服务端 204 但活动日志一条不落（与 `addToPlaylist` 同一个坑）
- 修复：会话事件统一走 `_postSession()`，**先 query（Emby 10.9+）再 body（Jellyfin/旧版）**，任一成功即成功；两种都失败时把原因写进 `lastSessionError`
- 心跳不再依赖 UserData 写入成功（两条链路解耦），UserData 被拒也会照发会话事件
- 起播事件丢失时，Progress/Stopped 会先补发一次 `Playing`，避免孤立事件被服务端忽略
- 监听前后台：退到后台 / 被系统回收前补发 `Stopped`，回到前台重新起会话——上滑杀 App 也不会只剩「开始播放」没有「停止播放」
- 新增 `playedHistory()`（`/Users/{id}/Items?Filters=IsPlayed`，普通用户可读、不依赖活动日志权限），「继续观看」在本地续播点为空时用它兜底
- 收藏同步加固：`listPlaylists` 失败**中止**同步（旧实现当成「服务端没有播放列表」，会误判每个收藏夹已被删而逐个重建，产生重复播放列表）

**播放页双击快进提示与按钮重叠**
- 旧布局把「+10秒」气泡放在与中央按钮**同一水平线**、距中心 148dp 处，窄横屏（1092×525）上正好压在快进按钮上
- 改为按钮组正上方：常规上移 60dp、窄屏 46dp，横向只做 34dp 方向感偏移

### v2.0.1 (201) 收藏夹加片 / 播放会话上报修复

- **修复：收藏夹同步后服务端播放列表是空的**。`addToPlaylist` 把 `Ids` 放在 JSON body 里，而 Emby 的加片接口只认 **query**（`/Playlists/{id}/Items?Ids=&UserId=`）——服务端返回 2xx 却一条都没加。改为 query 传参（与 v1.7.68 修 `createPlaylist` 同类问题）
- **修复：服务端活动记录里没有 APP 的记录**。会话事件补上 `PlaySessionId`（部分 Emby 版本缺失即 400，旧实现把异常吞了），并记录 `lastSessionError`，统计页空态直接展示失败原因
- **修复：「继续观看」被重置**。`/Sessions/Playing` 起播时带上**当前续播位置**（`PositionTicks`），此前不带会被服务端按 0 处理，把已有进度清掉；起播事件也改为先于 UserData 写入
- **设备名统一为 `Camby`**：服务端活动日志里能直接认出是本 APP，而不是 `Android`
- 新增 `test/playlist_add_http_test.dart`：加片参数必须走 query + 失败写入 `lastPlaylistError`

### v2.0.0 (200) · 重大版本：统计体系修正与播放上报升级

- **修复：统计页三条卡片全空（真正根因）**。1.7.72 用严格字符串 `UserId == 本账号Id` 过滤活动日志，但 Emby 同一账号在不同接口返回的 GUID **可能带/不带连字符、大小写不同**，播放事件**还可能不带 UserId**——结果本账号网页/TV 的播放全被误判成「非本人」丢弃。v2.0 改为**归一化匹配**（去连字符 + 转小写），空 UserId 视为本人，他人账号仍排除
- **诊断可见**：活动日志统计附带 `lastActivityDiag`（如「日志播放 128 条，本账号 128 条」），三张卡片空态直接展示，能区分「确实没数据」和「账号/权限没匹配上」
- **保留并升级播放上报**：v1.7.73 引入的会话型上报（`/Sessions/Playing`、`/Progress`、`/Stopped`）继续生效，APP 内播放从此与其他客户端一致写入活动日志（带本账号 UserId）
- 新增 `test/activity_log_account_match_test.dart`：GUID 带/不带连字符、大小写、空 UserId、他人账号排除 4 种场景 + 诊断信息 1 条守卫

### v1.7.73 (113)

- **修复统计页三条卡片全空**（每日观看时长 / 播放时段统计 / 最常看作品 Top）：根因是这三张卡片的数据源是服务器**活动日志**，只有会话型播放（网页端 / TV 端）才写入，而本 APP 此前只走 `UserData` 直写、从不产生活动日志条目——1.7.72 按账号过滤后，日志里没有本账号的记录，统计全部清零（此前的数据其实全部来自其他客户端/家人的播放）
- **治本：APP 播放接入标准会话上报**——起播 `POST /Sessions/Playing`、30s 心跳 `/Sessions/Playing/Progress`、退出 `/Sessions/Stopped`（`emby_client.dart` 新增 `reportPlaybackStart/Progress/Stop`；`AppState` 增加 `reportServerPlaybackStart/Stop`；播放页 `_open()`/`dispose()` 各挂一次）。APP 播放从此带本账号 UserId 进入活动日志，统计页数据真实且只属于本人；会话事件尽力而为、失败静默，不影响播放
- **空态文案修正**：三张卡片的「暂无」提示改为说明数据来源与生效时间（1.7.73 起 APP 播放计入），避免再次误解为数据丢失
- 新增 `test/session_playback_report_test.dart`：本地 mock 服务器验证会话三事件契约（Playing/Progress/Stopped 请求体）+ 服务端 500 不抛异常 2 条守卫

### v1.7.72 (112)

- **标签页排序统一**：新增共用组件 `SortChipRow`（年份/标题/评分），「#分辨率/标签」页（TagPage）与「中文字幕」页（SubtitleFilterPage）同款；点选字段默认**倒序**（↓），再点同字段切**正序**（↑），来回切换；中文字幕页旧的「最近添加」字段移除，三字段全端统一
- **偏好演员 Top 4→5 条**（`LibraryStats.compute` 的 `topPeople.take(5)`）
- **常看作品裸 Id 修复（如「34847」）**：活动日志里出现、但不在当前库列表的条目（已从服务器删除/其它类型），先向服务器批量反查片名（`itemNamesByIds`），查不到显示「库外影片（已删除）」，不再显示裸 Id
- **活动日志按账号过滤**：管理员账号拉到的日志含全家用户，现按 `UserId == 本人` 过滤，统计不再混入他人播放
- 新增 `test/sort_chip_row_test.dart`：排序方向翻转、TagPage/中文字幕页 chip 渲染与交互 3 条守卫

### v1.7.71 (111)

- **全局搜索 · 方案 C 落地**：双击「当前所在」Tab（300ms 内连点同一格、不切换）唤起搜索页；改为 `StatefulWidget` 的 `GlassNavBar`，用 `_lastTap`/`_lastIndex` 做双击判定，第三次连点不会重复触发
- **「我的」页右上角搜索按钮**：新增玻璃质感的搜索圆钮（与首页旧搜索钮同款），点击唤起搜索页（`SettingsPage` 增加 `onOpenDetail` 入参）
- 新增 `test/global_search_test.dart`：双击触发搜索且不再切换、点其它 Tab 只切换、我的页搜索钮打开 `SearchPage` 三条守卫；同步修复 `settings_render_test`/`all_pages_render_test` 因新增必填参数导致的编译失败

### v1.7.70 (110)

- **收藏页网格一行 2 个 → 3 个**：`crossAxisCount` 2→3、间距与 `childAspectRatio` 同步收窄（0.60→0.54），标题/片数不挤压；新增守卫测试锁定 3 列，黄金图 `favorites_wall.png` 已更新
- **首页顶栏精简**：移除左上角 `CAMBY` 品牌字与「服务器 · 片数」副标题、移除搜索圆钮（搜索将改为全局可唤醒，见 `docs/global_search_proposal.html`）；顶栏仅保留右上角连接状态胶囊，并清理了随之无用的 `_sourceInfo` / `_searchRoute` / `_GlassCircleBtn` 与 search 导入
- **全局搜索方案设计稿**：`docs/global_search_proposal.html` 给出悬浮球 / 下拉唤醒 / 双击 Tab 三方案对比与推荐组合（A1 常驻悬浮球 + C 双击兜底），待你确认后实施

### v1.7.69 (109)

- **修复 v1.7.68 遗留：收藏夹带旧 playlistId 但服务端播放列表已消失时，之前只标 pending 永远卡「待重试」**——现改为用本地名称与片单**重新创建**播放列表
- **失败原因可见**：播放列表 API（创建/改名/加片/移片/删除）失败原因写入 `lastPlaylistError`，同步后 toast 显示「N 个待重试：「夹名」创建失败：请求失败 (500)」这类具体原因，不再静默
- **创建播放列表兼容性增强**：补 `MediaType=Video`；部分 Emby 版本 2xx 但空 body 不回 Id 时，自动按名字重新拉列表匹配兜底
- **真 HTTP 测试**：新增 `playlist_http_mock_test.dart`（本地假 Emby 服务），验证 Name/Ids/UserId 确实走 URL query、空 body 兜底、rename 先取全对象再写回

### v1.7.68 (108)

- **收藏夹同步机制修复（治本）**：Emby 创建播放列表的参数在 **URL query** 而非 JSON body，之前放 body 导致服务端创建出「空名空片」播放列表并返回合法 Id，同步时又用空壳覆盖本地好名字。现改为 `POST /Playlists?Name=&Ids=&UserId=`；`renamePlaylist` 改为先取完整对象再写回，避免整包覆盖丢片
- **以谁为准（按用户拍板）**：本地已有收藏夹 → **APP 为准**（名称、片单全部推到服务端，服务端独有非空名播放列表拉回本地不丢数据）；本地无内容（新装）→ **服务端为准**（自动恢复）
- **合并规则**：仅服务端名称**非空**才覆盖本地；服务端**空名**播放列表自动删除（事故脏数据清理），不再建成本地收藏夹，也不会冲掉本地名
- **上行失败不再静默**：新增 `pendingSync` 标记（持久化），创建/改名/增删影片上云失败时置位，下次同步自动重试；同步 toast 显示「N 个收藏夹（M 个待重试）」
- **测试**：新增 `sync_folders_upload_test.dart`（上行/下行/pending 全链路，假服务端）+ `sync_folders_test.dart` 补决策用例，共 12 条全绿

### v1.7.67 (107)

- **收藏页布局二次修正**：① 海报真正贴底——v1.7.66 外层改了贴底但 `_layer` 内部 `Center` 又把海报居中了一次（间距没变），现改为 `Align(bottomCenter)`、名称间距 6→3；② 「新建收藏夹」**虚线外框缩小到与海报卡同尺寸**（0.85 缩放 + 贴底），内部按钮/文字还原原尺寸；③ 标题行「收藏 / 副标题 / 同步按钮」改水平居中对齐

### v1.7.66 (106)

- **修复收藏夹未同步到服务端**：根因是 `Ids` 参数格式错误——Emby 要求逗号分隔字符串，之前传 JSON 数组被服务端 400 拒绝后又被静默吞掉，播放列表从未创建成功；收藏夹映射现已真正生效
- **收藏页新增同步按钮**：标题行右上角，一键把本地收藏夹推上服务端 + 拉回其他设备的改动，转圈指示 + 完成后汇报数量
- **收藏页布局优化**：海报堆叠改贴底对齐（封面与标题间距明显收紧）；「新建收藏夹」卡整体放大（图标 40→54、加号 21→26）
- 测试 176 → **183**

### v1.7.65 (105)

- **多设备同步（进度/收藏夹）**：播放进度上报重写——补写「已看完」标记、校验 HTTP 状态码（不再把 500 当成功）、瞬时错误自动重试、新增持久化待上报队列（App 被杀也不丢）；播放页心跳 10s → **30s**；另一台手机/刷新后即可续播
- **收藏夹映射到 Emby 服务端播放列表**：新建/改名/删除/增删影片都会同步到服务端，换设备/重装登录后自动拉回；顺手修复多服务器下收藏夹互相串号的 bug（新增 `serverId` 字段）
- **卸载重装自动恢复**：开启 Android Auto Backup 让服务器配置与收藏夹随 Google 备份还原；设置页「我的服务器」已连接时新增「从服务器恢复收藏夹」手动入口
- 测试 168 → **176**

### v1.7.64 (104)

- **播放中屏幕常亮**：接入 `wakelock_plus`，播放时不黑屏不锁屏，暂停/退出播放页自动恢复系统默认
- **亮度/音量指示条加高**：竖向进度条 88 → 150、胶囊加宽，离屏幕边缘 22dp → 48dp，更醒目不顶边
- **收藏页标题区收紧**：标题 → 分段控件 → 封面的间距压缩（网格顶留白 16 → 6），与「夹名 ↔ 新建卡」的节奏一致
- 测试 165 → **168**

### v1.7.63 (103)

- **收藏夹海报扇形收敛**：修「两个收藏夹的扇形互相压盖」——后卡扇角 ±7° → **约 ±2.5°**、水平探出 6% → **2%**、卡片缩放 0.86 → **0.85**，扇形整体收进格内（约 6dp 余量），相邻收藏夹不再重叠
- 保留后层真实海报、压暗渐变、前卡微倾与上探露顶边的层次感
- 测试 162 → **165**（新增扇形幅度守卫测试，避免以后又把幅度调大）

### v1.7.62 (102)

- **拖动进度条中央时间实时刷新**：修复「底部小字已到 04:54、中央大时间还停在 01:01」——气泡原来直接读 `_scrubPos` 且只靠整页 `setState` 重建（拖动期间整页不重建，气泡冻结）；改为 `ValueListenableBuilder` 订阅 `_posNv`，跟着手指实时走
- **亮度/音量指示条换到对侧**：左半屏上滑调亮度 → 指示条显示在**右**侧；右半屏上滑调音量 → 指示条显示在**左**侧，不再被手指挡住
- 测试 160 → **162**（新增手势修复守卫测试）

### v1.7.61 (101)

- **取消字幕背景块**：移除 v1.7.58/59 加的半透明黑底圆角块，字幕回到纯文字；可读性交给样式面板的描边/阴影。保留「文字居中 + 限宽 85% 自动换行」，长句不顶出屏幕
- 测试 160 不变

### v1.7.60 (100)

- **拖动进度条松手回弹**：修复「圆点先到目标、松手后先弹回起点再跳目标」——`_scrubbing` 与 `_seeking` 必须同帧切换；并新增跳转后「粘滞显示」（900ms 窗口，等内核真实位置追上再交还），消除 position 回调滞后带来的回跳
- **设置页版本号动态化**：改为运行时读 `package_info_plus` 包信息，不再硬编码（发版不会再漏改）
- 测试 157 → **160**

### v1.7.59 (99)

- **字幕背景块贴文字宽度**：修复 v1.7.58 背景块横贯整行的问题（`Positioned(left+right)` 紧约束把块撑满全宽）；外包 `Align` 让块随文字收缩居中，多行长字幕限宽 85% 自动换行
- 测试 157 不变

### v1.7.58 (98)

- **文本字幕统一外观**：SRT/VTT 一律改由 App 叠加层渲染（ASS/SSA 仍走 MPV 内核保留特效），两内核统一为「白字 + 半透明黑底圆角块」。mpv 0.36/0.37 无法给文本字幕指定 BorderStyle（`sub-border-style` 不存在、`sub-ass-style-overrides` 对 SRT 无效），故换渲染主体而非加属性
- 切换字幕/切内核时按类型分流，避免内核渲染与叠加层两份字幕重叠
- 测试 153 → **157**

### v1.7.57 (97)

- **MPV 字幕样式修复**：样式面板「大小/位置/描边/不透明度/颜色」在 MPV 内核下不生效——根因是 `sub-opacity` 属性在 mpv 中根本不存在，而 media_kit 的 setProperty 吞掉错误码静默失败。现把不透明度烤进颜色 alpha（`#AARRGGBB`），描边属性带 `sub-outline-*` 旧名回退 + 写后回读校验
- 测试 152 → **153**

### v1.7.56 (96)

- **播放中顶栏内核胶囊切换失效修复**：`onTap: _switchEngine`（`Future<void> Function({bool silent})` 被赋给 `VoidCallback?`，编译通过但 Future 被静默丢弃）改为显式无参 `_toggleEngine()` + `unawaited`；MPV↔Exo 互切统一三条 toast（切换中 / 已切换 / 失败）。测试 **152/152**。

### v1.7.55 (95)

- **起播加载弹窗合并为一套**：删除独立路由 `strm_loading_dialog` 与播放页内部胶囊层，新增 `StrmBootOverlay` 由播放页直接渲染；点「切换 Exo」（显式 `_switchTo` 非取反）与超时自动回退真正作用于播放器 State，不再因弹窗是另一路由而失效。测试 **149/149**。

### v1.7.54 (94)

- 播放页锁定钮与未锁定时同位置对位；收藏页/演员页筛选控件统一为媒体库同款 `MediaFilter`（排序×升降 + 分辨率多选 + 仅中文 + 标签多选）；字幕样式面板补「恢复默认/确认」且修复不生效（MPV 增发 `sub-ass-override=force` 覆盖 ASS 原生样式）。测试 **139/139**。

### v1.7.53 (93)

- 首页下拉刷新加「已同步 N 项」提示；媒体库改为下拉刷新并移除顶栏按钮；收藏夹「全部影片」接入演员页同款筛选（抽出公共 `lib/widgets/media_filter_sheet.dart`），删约 340 行重复代码。测试 **139/139**。

### v1.7.52 (92)

- 所有页面顶栏按钮统一液态玻璃；添加服务器弹窗端口/协议两列对齐；媒体库加刷新按钮；演员页未选中标签改白色 90%；详情页收藏按钮改为心形状态钮（已收藏实心 + 粉红描边）。测试 **139/139**。

### v1.7.51 (91)

- 收藏页堆叠墙「边缘被裁剪」修复：`LiquidPress` 新增 `clip` 开关（默认 `true` 保持既有行为），`_StackTile` 传 `clip: false` 解除裁剪；三卡统一缩到 0.86 居中、后卡 ±7° 扇开探出。测试 **139/139**。

### v1.7.50 (90)

- 六屏 UI 对齐设计稿（逐项）：播放页控件布局/底栏码率 chip/字幕弹窗黄线/字幕调节面板/详情弹窗；收藏页堆叠墙（真实后层 + 加大扇形）；设置页清冗余项 + MPV 显示修复；演员页背景模糊 + 滚动懒加载 + 筛选 + 液态玻璃按钮；详情页媒体信息后置；首页 tab 按下态 + 图标磨砂。测试 **139/139**。

### v1.7.49 (89)

- 修复「设置选 MPV 实则永远开 Exo」（`initState` 并发读设置、`_open()` 不等读取完成）；STRM 加载弹窗改为进入播放页前弹出（片名/三阶段/切 Exo/插件提示）；播放信息弹层裁切修复；字幕样式入口与底部按钮补齐；收藏夹弹窗补字数计数与取消收藏。测试 **139/139**。

### v1.7.48 (88)

- 删除「在线字幕搜索」占位开关（不做就不占开关位，避免假开关）；新增守卫：设置页出现「预留/暂未接入」等字样直接失败，且不再有任何例外白名单。测试 **122/122**。

### v1.7.47 (87)

- 接通字幕默认语言自动选轨（`SubtitlePicker.pick` 纯函数，语言优先于 `IsDefault`、不被 forced 轨劫持）；ASS 特效字幕渲染真开关（`sub-ass`）；在线字幕如实标注「未接入字幕源」；新增假开关静态守卫测试。测试 **122/122**。

### v1.7.46 (86)

- 修复「我的」页渲染崩溃（`type 'Null' is not a subtype of type 'int'`：v1.7.42 删 `_load()` 键却漏删 Widget 树引用）；删除 4 组失效 UI（字幕语言/弹幕/主题/画中画）、补齐活键、落地「STRM 优先 Exo」开关；新增全页面渲染测试（数据驱动扫码源与初始化键差集）。测试 **105/105**。

### v1.7.45 (85)

- 启动黑屏修复：Impeller 回退 Skia、删除 `_ShaderWarmup` 离屏图层、`main()` 各初始化逐个 `try`、`restore()`/`ErrorWidget.builder` 加固可见化异常。测试 **98/98**。

### v1.7.44 (84)

- STRM 起播三件套（A/B/D）：加载态玻璃胶囊（片名/已等待 N 秒/切 Exo/插件提示，秒数走 ValueNotifier）；MPV `user-agent`/`network-timeout` 调优 + 10s 无首帧自动切 Exo；STRM 优先 Exo 智能内核判据；抽离 `BootWatchPolicy` + 首帧信号。测试 **97/97**。

### v1.7.43 (83)

- 收藏夹弹窗 v2：头部可点红心切换收藏、内联新建夹（回车即建/同名复用）、未收藏态禁用、键盘与手势条分别避让不叠加、`AppState.disablePersistence` 测试开关。测试 **84/84**。

### v1.7.42 (82)

- 设置项与隐性优化复查：默认内核/最大码率/缓存大小不生效修复、自动连播下一集、设置页「推荐」分栏、首页 CAMBY 字距、演员页筛选计数行、播放信息文件大小。测试 **76/76**。

### v1.7.41 (81)

- 重建代码复核：修复推荐引擎种子/权重/多样性（已看完排除、同系列 1 部）、详情页 `_onStateChanged` 进度刷新、`AppState.updateProgress` 进度回写、continueWatching 排序与文件大小。测试 **73/73**。

### v1.7.40 (80)

> 在重建版 v1.7.38 的基础上，把原会话 v1.7.23 之后遗漏的 7 项逐条补齐。

**稳定性（P0）**

- **字幕响应体积上限 8MB + 视频魔数嗅探（对齐 v1.7.28）**：`/Items/{id}/File` 这类端点在 strm 片源上偶尔会**直接返回视频本体**，几 GB 一次性读进内存就是 OOM 闪退 —— 这正是「加载字幕时 App 突然闪退」的根因。现在：先看 `content-length`，超限一个字节都不收；再流式读取边读边查上限；返回内容以 EBML（MKV）或 `ftyp`（MP4）开头就判定为视频、直接拦截；失败 600ms 后自动重试一次，对应「字幕有时加载不出来、重启才好」的偶发问题。失败原因会写进 `EmbyServer.subtitleDiag`，播放页提示里能直接看到是「体积超限」还是「返回了视频本体」。
- **字幕地址第 5 级 `/Items/{id}/File?Path=`（对齐 v1.7.25）**：strm 片源的 `/Videos/…/Subtitles/…` 常 404，而字幕文件在服务器上的绝对路径是唯一的可靠线索。候选顺序补成五级：`DeliveryUrl` → 带 `/0/` 标准路由 → 无 `/0/` 路由 → 旧路由 → **文件直取**，逐个尝试。

**播放器（P1）**

- **高频刷新解耦（对齐 v1.7.38）**：`_ticker` 原本每 300ms 就 `setState` 一次，整页（含一堆毛玻璃控件）跟着重建，拖进度、切倍速时肉眼可见掉帧。现在拆成三个 `ValueNotifier` —— `_posNv`（位置）、`_bufNv`（缓冲文字）、`_cueNv`（字幕文本），进度条、时间文字、缓冲速率、字幕叠加层各自用 `ValueListenableBuilder` 局部刷新，页面本身不再每 300ms 重建一次。字幕样式滑杆另走 `_styleRev` 信号，拖动时只重画叠加层。
- **底栏重排（对齐 v1.7.33 / v1.7.40）**：改成单行 —— 左边当前时间，中间胶囊区（字幕 / 画面比例 / 倍速 / 硬解软解）弹性占据并可横向滚动，右边**缓冲速率 + 总时长固定贴右且常显**（无数据时显示 `-- MB/s` 占位，不再忽隐忽现）。

**交互与观感（P2）**

- **四类弹层统一为居中玻璃面板（对齐 v1.7.32）**：播放速度、选择字幕、播放信息、字幕样式原本都是 `showModalBottomSheet` 从屏幕底边推上来，遮住进度条又不方便单手够。现在统一为居中卡片：最大宽度 470、高度留 12% 余量、内容超出时面板内部滚动，圆角 24 + 描边高光 + 投影。
- **面板返回手势退场动画（对齐 v1.7.39）**：`showGeneralDialog` 底层的 `RawDialogRoute` 不接受返回手势，系统侧滑时面板会「啪」地消失。改用 `_GlassPanelRoute`（标准 `PageRouteBuilder`），参与返回手势并驱动反向过渡。
- **路由转场统一（对齐 v1.7.39）**：新增 `lib/routes.dart` 的 `CambyRoutes.fade()`，把原本用 `MaterialPageRoute`（默认右滑/缩放，平台相关且时长不可控）的筛选、标签、文件夹、演员、播放器共 6 处入口全部切到统一淡入 + 8dp 上浮。
- **动效规范常量（对齐 v1.7.38）**：`theme.dart` 新增 `Anim` 类（`curve`/`curveIn` + `fast` 160ms / `base` 220ms / `slow` 320ms / `exit` 280ms），路由与面板都从它取值，不再散落 150/200/260/280/300ms。
- **Impeller + 首帧着色器预热（对齐 v1.7.39）**：`AndroidManifest` 显式开启 Impeller（构建期预编译着色器）；启动时用 2×2 的隐形控件把毛玻璃、圆角裁剪、缩放、淡入四类 shader 先画一遍，两帧后自行移除，消除「第一次进详情页/第一次弹面板卡一下」。

### v1.7.38 (78)

> 本版源码为**重建版本**（见文末说明）。以下每一条都对应 `libapp.so` 中实际存在的新符号或新字符串，标注了证据来源。

**播放页**

- **硬解 / 软解热切换**：顶栏新增「硬解 / 软解」胶囊，长按切换，不需要重建播放器。MPV 内核通过 `platform.setProperty('hwdec', 'auto-safe' | 'no')` 实时生效，Exo 内核恒为硬解（切换时给出提示）。播放中切换会同步回写 `set_hw_decode`，与设置页双向一致。证据：`_toggleHardware`、`hwdec`、`hwdec-codecs`、`getDefaultHwdec`。
- **码率上限现场切换**：`MaxStreamingBitrate` 从「只能进设置页预设」变成播放页可调。Emby 侧会以该值重新出流，因此比客户端侧限速更省流量。取值 `-1` 走 `-1` 哨兵表示「不限」并返回原片地址。证据：`_changeBitrate`、`MaxStreamingBitrate=`、`set_max_bitrate`、`fallback_bitrate_handler`。
- **字幕样式面板**：外挂字幕叠加层原来硬编码「17 号白字 + 四向黑描边」，在明亮动画画面 / 横屏大屏上偏小偏淡。现开放字号、位置、偏移、不透明度、描边六项 + 六色调色板，拖动手势即时预览（`_emit`，不落盘）、松手写盘（`_commit`）；滑块旁补 ± 微调按钮（`_nudge`，大屏上滑块很难拖准）。入口有两处：播放页长按「字幕」胶囊、设置页「字幕样式」。持久化键沿用 APK 中的 `camby_sub_size / pos / opa / stroke / offset / color`。
- **字幕样式双内核落地（v1.7.22 对齐）**：面板改的不只是 Exo 叠加层。MPV 内核真正接管字幕渲染，样式会被翻译成 libmpv 原生属性下发：`sub-scale`（字号，以 `SubtitleStyle.baseSize` = 17 为 1.0 基准）、`sub-pos`（位置，方向相反——App 存「距底比例」，libmpv 吃「距顶百分比」，换算 `(1 - bottomRatio) * 100`）、`sub-delay`（偏移，正值 = 字幕延后）、`sub-color`、`sub-border-color`（恒黑描边）、`sub-opacity`、`sub-border-size`。任一项失败都被吞掉，不打断播放；切内核与冷启动读盘后都会重新下发一次。证据：`applySubtitleStyle`、`_mpvColor`、`sub-pos`、`sub-delay`、`sub-border-color`、`sub-opacity`。
- **字幕地址多候选（v1.7.22 对齐）**：Emby 的字幕路由在各版本上不一致，旧实现只拼 `/Videos/{id}/Subtitles/{idx}/Stream.ext`，缺 `mediaSourceId` 与 `StartPositionTicks`，部分服务器直接 404 —— 表现就是「没有字幕，且没有任何报错」。现在优先用服务器返回的 `DeliveryUrl`（相对路径会自动补成绝对地址），并同时准备「带 mediaSourceId 的新路由」与「旧路由」两份候选，`Subtitles.load` 逐个尝试，任一成功即用。证据：`DeliveryUrl`、`_absolutize`、`SubtitleTrackInfo.altUrls`。
- **中央按钮精简（v1.7.22 对齐）**：去掉中央的「上一部 / 下一部」两个按钮，它们既挤压播放键的呼吸空间，又和双击 ±10 秒提示抢位置。中央只留「快退 / 播放 / 快进」，双击提示直接占回腾出的位置（设计值距屏幕中心 148dp，窄屏自动内收）。
- **播放进度写回服务器**：原来播放位置只写本机，换台设备 / 重装就丢。现在 `_reportProgress`（节流 5 秒）+ `_reportProgressNow` 定时把当前位置写回条目 UserData，服务端「继续观看」与其它设备上的续播位置跟着走。  上报选择了 `POST /Users/{UserId}/Items/{ItemId}/UserData` 而不是 `Sessions/Playing*` 三件套——APK 里只有 `/Users/`、`/Items/`、`/UserData` 三个插值片段，找不到 `Sessions` 或 `Playing/` 字面量；前者单请求即可入账，也不需要维护会话生命周期。证据：`_reportProgress`、`_reportProgressNow`。
- **长按锁定 / 解锁**：顶栏新增锁形入口，锁定后隐藏所有控件并禁用手势，`GestureDetector(onLongPress)` 长按才解锁，避免躺着看手机误触。「锁定态」有两处证据：`_lockScreen`、`_unlockScreen`。
- **倍速胶囊**：底栏倍速按钮在 ≠1× 时用冷色描边高亮，一眼看出当前是否在变速播放。

**首页**

- **Hero 每日推荐**：原来 Hero 轮播是「随机 6 部 + 每次进 App 重新摇」。现在是带状态的推荐引擎：按「未看完 > 新入库 > 高评分 > 随机」加权打分，同一部作品 3 天内不再出现（冷却表），跨天自动刷新（含 0 点定时器），也可以点右侧「换一批」手动重摇。种子与冷却状态持久化到 `home_reco_seed / home_reco_recent / home_reco_at`。证据：`_pickRecommendations`、`_recoWeight`、`_shuffleReco`、`_scheduleMidnightRefresh`、`_persistReco`、`_restoreRecoState`、`_rebuildHeroPool`、`_commitShown`。

**演职员页**

- **作品筛选**：作品列表原来是「全部 / 电影 / 剧集」三颗 `_FilmTab`，现在是分段控件 `_Seg` + 右侧漏斗入口 `_showFilterSheet`，可叠加「年代区间」（含未上映）与「排序」（年份 / 评分 / 片名）。当前条件以摘要条形式展示。证据：`_Seg`、`_showFilterSheet`。

**Emby 数据层**

- **文件名分辨率兜底**：部分条目服务端没给 `MediaStreams.Height`（老版刮削器 / 手动匹配的网盘原盘），卡片一片 `?p`。新增 `_heightFromName`，从 `Path`/`Name` 里认 `2160p / 1080p / 720p` 这类显式标记，以及 `4k / 8k / uhd / uhdremux / hdrip` 这类隐含标记。
- **`streamUrl` 支持 `maxBitrate`**，配合上面的码率切换使用。

### v1.7.21 (61)
- **点击画面视频停顿（重点）**：与 v1.7.0（基准分支）APK 做符号比对确认——v1.7.0 根本没有 `_beginScrub/_endScrub/_commitSeek` 这套拖动状态机，所以点画面不可能触发跳转。后来加的 `onHorizontalDragCancel` 是**无条件**调用 `_endScrub()`，普通点按在手势竞技场判负时也会走到，把 `_scrubPos`（初值 0 或上次拖动留下的旧位置）当成目标真跳一次 → 视频重新缓冲约 1 秒、并从稍早的帧继续。现已加 `_scrubbing` 守卫，并让「目标与当前位置相差 ≤1 秒」的 seek 直接跳过。
- **Exo 字幕（SRT）加载失败**：下载通道改为传**原始字节**，新增 UTF-8/UTF-16LE/UTF-16BE/GBK 解码（中文 SRT 常为 UTF-16，原来按 UTF-8 解会连时间轴都读不出）；新增 ASS/SSA `Dialogue` 解析（Emby 有时不按扩展名转码）；主地址失败时用原格式地址再试一次。失败提示改为带具体原因（HTTP 状态 / 内容为空 / 识别不到时间轴）。
- **首页搜索按钮**：图标恢复 `Icons.search_rounded`；真正的问题是圆钮外圈——顶部那条高光直线在圆弧上像一道断开的弦，且边框比右侧胶囊更亮。现统一成与「wifi + 片数」胶囊相同的玻璃参数，去掉高光直线。

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

## 源码重建说明

v1.7.21 (61) 之后的工作副本丢失，本仓库的 v1.7.38 由以下两条线索交叉取证后重建：

| 线索 | 内容 | 用途 |
| --- | --- | --- |
| APK | `Camby-v1.7.38-arm64-release.apk`（33 MB，versionCode **78** / versionName **1.7.38** / 仅 `arm64-v8a` / minSdk 28 / targetSdk 36 / `package cn.camby.camby`） | 版本锚点：确立 1.7.38 ↔ versionCode 78 的对应，并确认权限清单（仅 INTERNET / ACCESS_NETWORK_STATE / WAKE_LOCK）与 ABI 裁剪策略 |
| APK · 符号表 | `libapp.so` 中 34,777 条 Dart 符号，按 `ClassName@<库哈希>` 聚合 | 定位「哪些源文件动过」——同哈希 = 同编译单元 |
| APK · 字符串 | 二进制 AndroidManifest + `strings` 提取 | 确认新 UI 文案、新配置键、新 API 参数 |
| 旧仓库 | `github.com/run456/camby` @ v1.7.21 (61)，17,109 行 Dart | 代码基线，避免凭空重写 |

**归并结果**：13 个库里只有 5 个存在新符号 —— `player_page`（13 个）、`home_page`（8 个）、`person_page`（2 个）、`emby_client`（1 个）、`settings_page`（5 个）；其余 8 个文件（`main` / `app_state` / `detail` / `library` / `search` / `favorites` / `stats` / `subtitle_filter`）**零新增符号**，判定为未改动，直接沿用旧仓库实现。改动因此被收敛到 6 个文件而非整个 App。

**验证**：

1. `flutter analyze` → **0 error / 0 warning**（299 条 info 全部是基线代码就有的 `withOpacity` 弃用提示与风格建议）。
2. `flutter test` → **25/25 通过**（含新增 `test/camby_1738_test.dart`）。
3. `flutter build apk --release --target-platform=android-arm64` → 成功产出 **34.4 MB**（原始 APK 33 MB）。
4. 把重建 APK 的 `libapp.so` 与原始 APK 做符号对拍：**26 个 1.7.38 新增符号全部命中，且库哈希完全一致**（`player_page` = 28472116、`home_page` = 559049366、`person_page` = 596023365、`emby_client` = 555127961）。

> 库哈希一致说明：同一个 Dart 文件编译出的符号带同一个 `@hash`，哈希由**文件路径**决定而非内容——所以这几份重建文件虽重新写过注释与内部实现，交付编译后仍落到与原始 APK 完全相同的编译单元上。

**与原始 1.7.38 的已知差异**：

1. **字幕样式面板的位置**：原始把它放在 `settings_page` 的编译单元里（`@605399474`），播放页要使用它就得 import 整个设置页。重建时抽成独立文件 `lib/widgets/subtitle_style_sheet.dart`（`@604383483`）—— 逻辑、类名、持久化键完全一致，只是编译单元不同；这是本次唯一一处哈希对不上的地方。
2. **辅助方法**：为了可读性抽出了若干小方法（`_bitrateText`、`_subInfoText`、`_applyBitrate`、`_dedupeSeries`、`_jumpToPage`、`_syncHeroNotifiers`、`_filterSummary`、`_SheetBtn`、`_openSubtitleStyle`、`_subStyleSummary`、`_colorRow`、`_copyBy`），原始 APK 里没有这些符号，说明当时是内联写的。行为等价。
3. **命名之外的部分**：注释、日志文案、Toast 措辞无法从 APK 还原，属重写。
4. **v1.7.22 → v1.7.37 中间版本**：无 APK 留存，其改动已全部折叠进 v1.7.38 的特性清单，无法再做版本拆分。
5. UI 参数（圆角、间距、配色）以旧仓库同族组件为准；APK 只能证明「存在某个组件」，证明不了像素值。

---

## 隐私与开源许可

- 应用仅连接**用户自己配置的** Emby 服务器，所有凭据（地址 / Token / 账号）保存在本机 `shared_preferences`，不上传任何第三方。
- **在线字幕是显式点击才触发的功能**：只有用户点「在线搜索字幕…」时，App 才会把**清理后的影片标题 / 番号**（不含服务器地址、账号、Token）发给迅雷与 SubtitleCat 的公开端点，下载的字幕只在本机内存里解析显示，不落盘、不上传任何播放记录。不使用该功能时没有任何对外请求。
- 内置「演示库」为离线占位数据，不含真实服务器信息。
- 许可证见仓库 `LICENSE` 文件（如有）。在线字幕模块移植自 MIT 项目 `PotplayerJavChineseSubs_subtitlecat` 3.0，按 MIT 要求随附许可全文于 `licenses/LICENSE-UPSTREAM.txt`（版权人 `Exhen & Contributors` 原样保留）。MIT 只覆盖代码，不覆盖第三方字幕网站 / 接口的服务条款。
- 内置字幕字体 `FangSong.ttf` 为 **Noto Serif SC + Noto Serif TC 的并子集**，版权归 Google / SIL（OFL-1.1 可商用、可再分发），许可全文见 `licenses/OFL-NotoSerif.txt`。导出 / 缓存的字幕文件保存在 App 私有目录，不会上传，用户可经系统分享自行拷到 NAS。

---

© Camby · 由 WorkBuddy 协助开发与维护
