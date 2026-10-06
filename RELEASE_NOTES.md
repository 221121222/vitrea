# 发布说明 / Release Notes

## v1.1.0 — 清理 · 键盘主题 · 写入进度与灵动岛 · 随机卡面小组件

**发布日期**：2026-10-06
**版本 / 构建号**：1.1
**Bundle ID**：`cc.cardart.workshop`
**支持系统**：iOS 26.0 – 26.6，iOS 27 beta 1 – beta 4

### 新增 / Added

**清理**

- 底部新增「清理」Tab，扫描并按体积排序可再生的临时数据，支持搜索、多选、二次确认与结果反馈。
- **本应用范围**：可清理四类 —— **卡面图片缓存**（`Caches/VitreaCardCache`）、**网络请求缓存**（`Caches/CardArtHTTP`）、**贴纸素材缓存**（`Caches/Stickers`）、**临时文件**（`tmp`）。
- **其他应用范围（沙盒外）**：经开发者配对 + 回环隧道，用 HouseArrest（`VendContainer`）+ AFC 租借目标 App 容器，清其 `Library/Caches` 与 `tmp`；逐个统计体积并显示扫描进度。
- Rust 侧新增 FFI：`al_container_list_apps` / `al_container_usage` / `al_container_clean` / `al_container_scan_many`（`rust-core` 启用 `house_arrest` 特性）。
- 安全边界：仅处理 `Library/Caches` 与 `tmp`，带根目录校验；`Documents`、偏好设置、配对记录与写入日志不受影响；不跟随、不删除符号链接。
- 交互模型参考 [3105](https://github.com/YangJiiii/3105)（GPL-3.0）的设计思路，实现为本项目独立编写。

**内置回环隧道（`VitreaTunnel`）**

- 新增 Packet Tunnel Provider 扩展 `VitreaTunnel.appex`（`cc.cardart.workshop.tunnel`）随主 App 打包，**不再依赖外部 LocalDevVPN App**。
  - 扩展建一条自身 `10.7.0.0/32` 的 utun，只把 `10.7.0.1/32` 一条路由指进隧道（其余流量含默认路由全部排除，不影响正常上网），并把收到的 IP 包**源 / 目的地址对调改写**后回灌协议栈，使「发往 10.7.0.1」等价于「发往本机」，从而访问只监听物理网卡的 `lockdownd`。
  - 主 App 侧 `LoopbackTunnelService` 用 `NETunnelProviderManager` 建 / 存 / 启停配置；配对页一键「启动内置回环」，已配置过的用户进 App 自动拉起。
  - 两个 target 均带 `com.apple.developer.networking.networkextension = packet-tunnel-provider` 权限；`build-ipa.sh` 默认做一次 ad-hoc 签名把权限写进包里（`STRIP_SIGNATURE=1` 可退回完全裸包）。
  - **退路**：若签名未带该权限导致扩展启动失败，界面自动退回「打开 LocalDevVPN」，功能不受影响。

**键盘主题（锁屏密码按键 `.passthm`）**

- **主题库**：主源为 [Cowabunga 主题仓库](https://github.com/sourcelocation/Cowabunga-theme-repo/tree/main/passcode-themes)（`passcode-themes.json` 清单 + `.passthm` 直链），失败时回退旧目录 `aircardios.github.io/pass-themes`；点按条目**一键下载并安装**，也支持直接**导入 `.passthm`**。
- **主题包与预览图全部随 App 打包**：`Resources/PasscodeThemes/` 27 个 `.passthm`（约 8.1 MB）+ `Resources/PasscodePreviews/` 27 张预览图（约 700 KB）。主题库直接读本地清单，**打开即显示、完全离线可用**，不再每次请求 `raw.githubusercontent.com`；列表里内置主题带「内置」小标签。
- **在线刷新按钮**（键盘页右上角）：主动拉取仓库新增的主题；成功则替换列表，失败则**保留内置列表**并提示，不会把页面清空。
- **自定义**：上传 **10 张数字按键图（0–9）**，实时 3×4 锁屏键盘预览，可保存 / 清空。
- **目标版本可选并标注适配范围**：`TelephonyUI-10`（iOS 18 及更高，推荐）/ `-9`（iOS 15 – 17）/ `-8`（iOS 14 及更低），选择器内提示「本机（iOS N）应选 …」。
- 按 iOS `TelephonyUI` 规范生成 `{lang}-{digit}-{subtext}--white{bold}.png` 位图，写入 `/var/mobile/Library/Caches/TelephonyUI-<版本>`。

**写入进度 · 后台保活 · 灵动岛**

- **精确到 1% 的写入进度**。原先进度是硬编码的几个台阶（0.1 → 0.3 → 0.5 → 0.8 → 1.0），屏幕上就是「30% 一下跳到 80%」。现在改成**真实文件级采集**：Rust 侧每次落盘都会打日志，新增 `FFIProgressParser` 解析出真实的「已完成文件数 / 总文件数」，覆盖 Rust 的三条写入路径（fast batch 一次成功 / 逐文件回退 / ATC 批量同步）；再由 `WriteProgressModel` 做**单调 + 限速**的显示层（每 100ms 最多推进 1%），屏幕上永远 1% 1% 地走。
- **后台不中断**。新增 `BackgroundKeeper`（`beginBackgroundTask` + 静音音频会话，内部**引用计数**），写入与清理扫描可以重叠进行，只有最后一个使用者退出时才真正释放后台音频。写入面板与清理页均提示「可切到后台，会继续」。
- **灵动岛 / 锁屏实时活动**。新增 WidgetKit 扩展 `VitreaWidgets`（`cc.cardart.workshop.widgets`）：
  - 紧凑态：左边卡面图标，右边固定显示 `NN%`；
  - 最小态：只显示数字；
  - 展开态：进度条 + 阶段文案 + 「第几张 / 共几张」+ 失败数；
  - 锁屏 / 通知中心：同样的横幅。

  主 App 侧由 `WriteActivityController` 负责 start / update / end，更新节流 0.4s；用户若在设置里关掉实时活动，`Activity.request` 抛错会**静默降级**，写入流程不受影响。与扩展共用 `ios-app/Shared/WriteActivityAttributes.swift`（同一份源码编进两个 target，保证类型一致）。
- 写入进行中**禁止下滑关闭**写入面板，避免写到一半界面消失（进度仍可在灵动岛看到）。

**随机卡面小组件与快捷指令**

- **主屏幕小组件「随机卡面」**（支持小 / 中两种尺寸）：
  - 时间线每次刷新（请求值 30 分钟，实际由系统决定）自动随机换一张；
  - 左下角 **「换一张」按钮** —— 点一下立刻重抽，**不打开 App**。用的是 iOS 17+ 的 `Button(intent:)`：小组件里的按钮由**扩展进程**执行，所以 `ShuffleRandomCardIntent` 直接写扩展自己的 `UserDefaults` 暂存新卡，再 `reloadTimelines` 让 Provider 立刻取用；
  - **点卡面本身** → 深链 `vitrea://card?d=<base64url(JSON)>` 打开 App 的卡面详情。深链里**编着整张卡面**，所以点开的就是小组件上那一张，不会又随机一张（站点没有「按 id 取卡面」的接口，只有 `api/wander` 随机流与 `api/search`）；
  - 断网时回落到**上一次成功展示的那张**（`RandomCardStore.last()`），不会变空白。
- **快捷指令 / Siri「随机卡面」**：`OpenRandomCardIntent`（`openAppWhenRun = true`）抽一张并在 App 里打开；`VitreaShortcuts: AppShortcutsProvider` 注册了三句 Siri 短语：「用 Vitrea 随机一张卡面」「Vitrea 抽一张卡面」「Vitrea 随机卡面」。
- App 内弹出的随机卡面详情页右上角也有 **「换一张」**，可以一直抽下去。
- 主 App 注册 URL scheme `vitrea`（`CFBundleURLTypes`），`MainTabView.onOpenURL` 负责落地；`GalleryAuthor` / `GalleryImages` / `GalleryCard` / `WanderResponse` 从 `ios-app/Models.swift` 移到 **`ios-app/Shared/GalleryCard.swift`**，随机卡面内核放 **`ios-app/Shared/RandomCard.swift`**（`RandomCardFetcher` / `RandomCardStore` / `RandomCardLink` / `ShuffleRandomCardIntent`）—— `Shared/` 同时被主 App 与扩展编译，共用同一份模型比两边各写一套更安全。

### 优化 / Changed

- **清理范围收敛为「全部应用」**：去掉第三方 / 系统应用的筛选，少一次选择。
- **清理不再自动重扫**：扫描状态提升到单例 `CleanerStore`（原先放在 `DeviceCleanerView` 的 `@State` 里，而该视图是范围分支 —— 每次切走再切回都被重建、状态归零，于是又白扫一遍）。现在**只有点右上角刷新按钮**才重新扫描，切范围 / 切 Tab / 返回都不会。
- **清理扫描提速**：沙盒外扫描由「逐个应用建隧道」改为「一次隧道批量扫多个应用」（新增 `al_container_scan_many`，握手开销只付一次）；分片由 20 个/片 × 4 路并发提升到 **30 个/片 × 6 路并发**；扫描过程中只推进度数字、不再每块重排整个列表。
- **清理页「全选」移到右上角**：一键全选 / 取消全选，不用再进 `⋯` 二级菜单；排序仍留在 `⋯` 里。
- **写入卡面面板去掉右上角关闭叉**：面板以 `.sheet` 呈现，下滑即可退出；写入完成后另有「完成」按钮。
- **卡面库右上角「制作」更显眼**：图标旁加上「制作」二字，并改为实心强调色胶囊按钮。
- **作者入口更明显**：列表卡片与详情页的作者名后面都加了一个向右箭头（`chevron.right`，强调色）。顺带补了一个缺失的入口 —— 详情页原本作者只是纯文本、完全点不进去，现在和列表一致，可跳转到作者作品页。
- **分类浏览不再出现搜索框清除叉**：点「交通卡 / 身份证 / 银行卡」走的是分类浏览，之前会让搜索框右侧冒出一个叉（并被默认按钮样式染成强调色）。现在清除按钮**只在关键词搜索时出现**，并加 `.buttonStyle(.plain)` 保持灰色；分类浏览的下拉刷新改为重新拉当前这一类。
- **主按钮不再显示为灰色**：此前资源目录缺少 `AccentColor` 颜色集，`Color.accentColor` 退化成系统灰，主按钮看起来像被禁用；已补 `AccentColor.colorset`（浅色 `#2F6BFF` / 深色 `#588FFF`）并加上 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` 构建设置。
- **禁用态按钮样式**：`GlassButton` 不再用 `.opacity(0.45)` 整体压暗，改为「次要前景色 + 极浅底色 + 细描边」，禁用与可用的区别更清晰。
- 底栏清理图标修正为可正常渲染的图标；底部 Tab 现为 **卡面库 / 键盘 / 清理 / 作者**。

### 修复 / Fixed

- **「制作卡面」页面左上角的关闭叉点了没反应**。根因：`GalleryView` 在**同一个视图上叠了两个 `fullScreenCover`** —— `fullScreenCover(item: $editingCard)`（编辑）+ `fullScreenCover(isPresented: $showNewCard)`（制作）。SwiftUI 一个视图只能稳定托管一个 presentation，两个叠在一起时后一个的 `isPresented` binding 会被抢掉，于是「制作」页能打开、但 `showNewCard = false` 写下去没有任何效果。
  - 改为**单个 item 驱动的 cover**：新增 `EditorRoute { case create / edit(GalleryCard) }`，用 `fullScreenCover(item: $editorRoute)` 统一承载新建与编辑，两个入口都写同一个状态。
  - 顺手把关闭叉的**点击热区放大到约 40pt**（`.padding(9)` + `.contentShape(Rectangle())`），并加 `.buttonStyle(.plain)` 压住默认样式对图标的强调色着色。
- **键盘主题库「加载失败 / 转圈很久」**。原来每次进入「键盘 → 主题库」都要去 `raw.githubusercontent.com` 拉 `passcode-themes.json`，网络一抖（或仓库 raw 偶发 SSL 中断）就直接报「主源与备源都没有返回主题」，页面空白。现在主题包与预览图全部随 App 打包，完全离线可用。
- **灵动岛右侧百分比发糊**。三个原因一起改掉：
  - **更新太密**：实时活动的下发节流原为 0.15s，而灵动岛每次内容变化都要播一段过渡动画 —— 间隔短于动画时长时，屏幕上一直停在「动画中间态」，数字看起来就是糊的。节流放宽到 **0.4s**。
  - **没有内容过渡**：`Text` 未指定过渡时系统做交叉淡入淡出，更新稍快就糊成一团；紧凑态 / 最小态 / 展开态都加上 `.contentTransition(.numericText())`，数字变成干脆的滚动替换。
  - **字号太小 + 颜色走 vibrancy**：`.caption2`（11pt）在灵动岛里偏虚，`.foregroundStyle(.primary)` 会走 vibrancy 让边缘发糊。改为显式 `.system(size: 14, weight: .semibold)` + `.foregroundStyle(.white)` + `.minimumScaleFactor(1)`（禁止自动缩字）。

### 移除 / Removed

- **壁纸 Tab**：本轮开发中曾加入，发布前整体移除。删除 `WallpaperView` / `WallpaperService` / `WallpaperModels` / `WallpaperViewModel` / `WallpaperCloud` / `DeviceIdentity` / `TendiesBuilder` / `TendiesInstaller`，并清理 `MainTabView`、`Info.plist` 的相册写入权限与 `project.yml`。相关云端协议逆向记录保留为存档 [`docs/REVERSE-tendies.md`](docs/REVERSE-tendies.md)（不含任何运行时代码）。
- **移除「下载视频 → 本地抽帧封装 `.tendies`」自动回退**：本地封装出的包在部分系统上会让 PosterBoard 崩溃（用户表现为关机或 App 闪退）。

### 已知问题 / Known Issues

- Release 中的 IPA 为**未签名包**，需自行重签，详见 [docs/INSTALL.md](docs/INSTALL.md)。
- 写入与键盘主题写入依赖未公开的系统接口，仅在 **iOS 26.0 – 26.6 / iOS 27 beta 1 – beta 4** 上验证通过；其他版本不受支持，系统升级后可能失效。
- 跨应用清理依赖系统是否允许租借目标容器：**部分应用（例如 App Store 安装的）可能被拒绝**，界面会如实计入「无法清理」。这与 3105 靠内核逃逸的实现路径不同，属于预期差异。
- 模拟器不支持（`AirliftFFI` 为 arm64，且写入依赖真机系统服务）。

### 说明 / Notes

- **内置回环需要 `NetworkExtension` 权限**：自签时若工具剥掉该权限（部分免费证书 / 代签工具会），扩展无法启动 —— 此时请改用 LocalDevVPN。使用 AltStore / SideStore 安装时建议选「Keep App Extensions (Use Main Profile)」。
- **后台保活依赖 `UIBackgroundModes: audio`**：若自签工具剥掉这个后台模式，切后台后仍可能被系统挂起 —— 此时 `beginBackgroundTask` 的宽限期通常也够写一张卡。
- **灵动岛进度不保证每一帧都是 1%**：为不被系统限流节流到 0.4s，追赶阶段最差会出现约 4% 一跳；**应用内**百分比仍是严格 1% 递增。实时活动需系统允许（设置 → 灵动岛 / 实时活动），关闭时不影响写入。
- **小组件刷新受系统时间线预算限制**，「30 分钟」是请求值，实际由系统决定；点按钮换卡不受此限制。
- 「换一张」在**小组件上**由扩展进程执行，写的是扩展自己的 UserDefaults；若从**快捷指令 App** 触发同一个 intent，写的是主 App 的 UserDefaults，此时小组件会在下次刷新时正常重抽（只是不会立刻换）—— 属于可接受的边角情况。
- **键盘主题写入后重启手机会失效**：系统会重新生成默认键盘，需重新写入。
- 内置主题清单是**构建时快照**，仓库后续新增的主题不会自动出现，点右上角刷新即可获取。IPA 体积因内置主题包增加到约 14 MB。
- 构建时需先 `./build-ios.sh` 重新打包 `AirliftFFI.xcframework`，再 `xcodegen generate`。

### 签名与安装

本版本的 `Vitrea.ipa` 不含任何签名。安装步骤请见 **[docs/INSTALL.md](docs/INSTALL.md)**。

## v1.0.0 — 首个公开版本

**发布日期**：2026-10-06
**构建号**：1.0.0
**Bundle ID**：`cc.cardart.workshop`
**支持系统**：iOS 26.0 – 26.6，iOS 27 beta 1 – beta 4

### 新增 / Added

- **卡面库**：在线浏览 [cardart.cc](https://cardart.cc) 卡面素材，支持下拉刷新、分页加载与内存 + 磁盘两级图片缓存。
- **分类筛选**：交通卡（`transit`）/ 证件卡（`id`）/ 支付卡（`payment`）三类一键切换。
- **精选推荐**：首页精选板块，直达高质量卡面。
- **作者作品页**：点击作者头像即可浏览该作者的全部作品。
- **卡面编辑器**：
  - 上传照片后进入**裁切模式**，编辑框严格等于卡面真实比例 **1536 × 969**；
  - 支持拖动与双指缩放，自动约束「始终填满框体」，由用户确认保留区域；
  - 所有文字、贴纸编辑操作**只在卡面框内部完成**，与底部操作区互不遮挡；
  - 文字支持字体 / 字号 / 颜色 / 描边 / 阴影 / 位置调整；
  - 贴纸库按 `airlines / banks / cars / flags / ids / networks / schools / tiers / transit / other` 分类。
- **写入引擎**：实时显示写入进度百分比（动画平滑），完成后自动刷新 Wallet 正反面与缩略图缓存。
- **开发者配对**：基于 Bonjour 的本机配对流程，支持 PIN 校验与音频后台保活。
- **液态玻璃界面**：自绘 `GlassCard` / `GlassButton` / `GlassBackground` 组件。

### 修复 / Fixed

- 修复编辑器底栏文字与底部导航栏重合的问题。
- 修复编辑器因画布按 1536pt 原尺寸渲染导致的按钮整体溢出屏幕问题（现按可用空间等比缩放，导出仍保持 1536 × 969）。
- 修复编辑器右上角关闭按钮无效、只能下滑退出的问题（编辑器改为全屏呈现并显式回调关闭）。
- 修复卡面库分类筛选失效的问题（改用服务端实际生效的 `type=` 参数）。

### 已知问题 / Known Issues

- Release 中的 IPA 为**未签名包**，需自行重签，详见 [docs/INSTALL.md](docs/INSTALL.md)。
- 写入功能依赖未公开的系统接口，仅在 **iOS 26.0 – 26.6 / iOS 27 beta 1 – beta 4** 上验证通过；其他版本不受支持，系统升级后可能失效。
- 模拟器不支持（`AirliftFFI` 为 arm64，且写入依赖真机系统服务）。

### 签名与安装

本版本的 `Vitrea.ipa` 不含任何签名。安装步骤请见 **[docs/INSTALL.md](docs/INSTALL.md)**。
