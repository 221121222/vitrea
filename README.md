<p align="center">
  <img src="ios-app/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" height="128" alt="Vitrea App Icon" style="border-radius: 28px; box-shadow: 0 8px 24px rgba(0,0,0,0.18);" />
</p>

<h1 align="center">Vitrea</h1>

<p align="center">
  <b>Apple Wallet 卡面工坊</b> —— 在 iPhone 上直接为 Apple Wallet 卡片换上自定义卡面，<br/>
  无需越狱、无需电脑、不触碰任何支付凭据。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-26.0%20~%2026.6%20%7C%2027.0%20b1~b4-blue?style=flat-square&logo=apple" alt="iOS 26.0–26.6 | 27.0 b1–b4" />
  <img src="https://img.shields.io/badge/Swift-5.0-orange?style=flat-square&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Rust-FFI%20Core-red?style=flat-square&logo=rust" alt="Rust" />
  <img src="https://img.shields.io/badge/UI-Liquid%20Glass-8b5cf6?style=flat-square" alt="Liquid Glass" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License" />
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/badge/Download-IPA-2ea44f?style=flat-square&logo=apple" alt="Download IPA" /></a>
  <a href="docs/INSTALL.md"><img src="https://img.shields.io/badge/Docs-%E7%AD%BE%E5%90%8D%E4%B8%8E%E5%AE%89%E8%A3%85-0969da?style=flat-square" alt="Install Docs" /></a>
</p>

---

## 简介 / Overview

**Vitrea**（原名 *卡面工坊*）是一款运行在 iPhone 本机的 Apple Wallet 卡面自定义工具。它在线浏览卡面素材库、把照片裁剪成与卡面等比的画布、叠加文字与贴纸，最后把成图写入 Apple Wallet 的图像缓存，让钱包里的银行卡、交通卡、证件卡立刻换上你想要的样子。

整个写入过程**在设备上完成**：App 通过本地回环隧道（`10.7.0.1` / `127.0.0.1`，由 LocalDevVPN 提供）与本机系统服务通信，实际的文件操作由 `AirliftFFI`（`rust-core/`）负责。全程**不越狱、不访问 Secure Enclave、不读取或修改任何支付凭据**，只替换 Wallet 的图像缓存文件。

> [!IMPORTANT]
> **兼容性**：Vitrea 支持 **iOS 26.0 – 26.6** 与 **iOS 27 beta 1 – beta 4**，且必须配合 [LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN) 建立本地回环隧道才能完成写入。

### 兼容性 / Compatibility

| iOS 版本 | 状态 | 说明 |
| :--- | :--- | :--- |
| **iOS 26.0 – 26.6** | ✅ 支持 | 已验证可正常写入 |
| **iOS 27 beta 1 – beta 4** | ✅ 支持 | 已验证可正常写入 |
| iOS 18 及更低 | ❌ 不支持 | 未适配 |
| iOS 27 beta 5 及更高 | ❌ 不支持 | 不在支持范围内 |

## 功能特性 / Features

### 🎨 卡面库（在线素材）
- 从 [cardart.cc](https://cardart.cc) 在线拉取卡面素材，瀑布流浏览，支持**下拉刷新**与分页加载。
- 按类别筛选：**交通卡**（`type=transit`）、**证件卡**（`type=id`）、**支付卡**（`type=payment`）。
- **精选推荐**板块，首页直达高质量卡面。
- **作者作品页**：列表卡片与详情页的作者名后面都带一个小小的向右箭头（`chevron.right`，强调色），一眼看出可以点进去浏览该作者的全部作品。
- **搜索框只在关键词搜索时出现清除按钮**：点「交通卡 / 身份证 / 银行卡」属于**分类浏览**，搜索框右侧不会再冒出那个叉；要回到全部，点最左边的「全部」即可。
- 图片多级缓存（内存 + 磁盘），滚动流畅不重复请求。

### 📲 随机卡面（小组件 · 快捷指令）
- **主屏幕小组件「随机卡面」**（小 / 中两种尺寸）：
  - 每次时间线刷新（30 分钟）自动随机换一张卡面；
  - 左下角 **「换一张」按钮**，点一下立刻重抽，**不打开 App**（iOS 17+ 的 `Button(intent:)`，在扩展进程里跑）；
  - **点卡面本身** → 通过深链 `vitrea://card?d=…` 打开 App 的卡面详情。深链里**编着整张卡面**，所以点开的就是小组件上那一张，不会又随机一张（站点没有「按 id 取卡面」的接口，只能把 JSON 编进 URL）。
- **快捷指令 / Siri「随机卡面」**：抽一张并在 App 里打开；Siri 可直接说「用 Vitrea 随机一张卡面」。
- App 内打开的那张卡面详情页右上角也有 **「换一张」**，可以一直抽下去。
- 断网时小组件回落到**上一次成功展示的那张**，不会变空白。

### ✂️ 卡面编辑器
- **照片裁切**：上传照片后进入裁切模式，编辑框严格等于卡面真实比例（**1536 × 969**）。可拖动、双指缩放，并自动约束「始终填满框体」，由你确认保留区域后再进入编辑。
- **编辑区域隔离**：所有文字、贴纸等编辑操作都只在卡面框内部完成，不会在整屏范围内编辑，框体与底部操作区互不遮挡。
- **文字排版**：字体、字号、颜色、描边、阴影、位置自由调整。
- **贴纸系统**：内置按 `airlines / banks / cars / flags / ids / networks / schools / tiers / transit / other` 分类的贴纸库（清单约 580 KB，图片在线加载）。
- 导出分辨率锁定为 **1536 × 969**，与 Wallet 缓存所需的 `cardBackgroundCombined` 尺寸一致。

### 💳 写入与配对
- 实时检测 Apple Pay 唤起的卡片标识，精确匹配目标卡。
- **精确到 1% 的写入进度**：Rust 侧每次落盘都会打日志（`found N file(s)` / `[i/N] writing` / `FileComplete sent [i/N]` / `fast batch write succeeded` …），App 解析这些行拿到**真实的文件级进度**，再由显示层平滑成「每 100ms 走 1%」，不会出现 30% 一下跳到 80% 的情况。
- **切到后台不会中断**：写入期间用 `beginBackgroundTask` + 静音音频会话（复用已声明的 `audio` 后台模式）保活，划出后台也能把整批卡写完。清理页的扫描与清理共用同一套保活（`BackgroundKeeper`，内部按引用计数，可与写入重叠）。
- **灵动岛 / 锁屏显示进度**：通过 Live Activity 把百分比同步到灵动岛（紧凑态只显示 `NN%`，展开态是进度条 + 阶段文案 + 第几张卡），锁屏横幅同样可见。
- 写入进行中禁止下滑关闭面板，避免写到一半界面消失。
- 写入完成后自动刷新正反面与缩略图缓存，Wallet 打开即为新卡面。
- **开发者配对**：通过 Bonjour（`_remotepairing-pairable-host._tcp`）与本机完成配对，支持 PIN 校验流程。

### ⌨️ 键盘（锁屏密码按键主题）
- 独立「键盘」Tab：
  - **主题库（全部内置）**：27 个主题来自 [Cowabunga 主题仓库](https://github.com/sourcelocation/Cowabunga-theme-repo/tree/main/passcode-themes)，
    **主题包（`.passthm`）与预览图都随 App 打包**（`Resources/PasscodeThemes` + `Resources/PasscodePreviews`，共约 8.8 MB），
    清单读本地 `themes.json` —— 打开即显示、**无需联网、可离线安装**，不再出现「加载失败 / 转圈很久」。
    点按条目即一键安装（直接读本地包），也可直接**导入 `.passthm`**。
  - **在线刷新**：右上角按钮可主动去 GitHub 拉取仓库新增的主题；失败时保留内置列表并提示，不会清空页面。
  - **自定义**：上传 **10 张数字按键图（0–9）**，实时 3×4 锁屏键盘预览，可保存 / 清空 / 一键应用。
- **目标版本可选**：`TelephonyUI-10`（iOS 18 及更高，推荐）/ `-9`（iOS 15 – 17）/ `-8`（iOS 14 及更低），选择器内直接标注适配系统范围，并提示「本机（iOS N）应选 …」。
- 按 iOS `TelephonyUI` 规范生成 `{lang}-{digit}-{subtext}--white{bold}.png` 位图（`en` / `other` 及可选全语言），写入 `/var/mobile/Library/Caches/TelephonyUI-<版本>`。

### 🧹 清理（有限清理）
- 独立「清理」Tab，两个范围：
  - **本应用**：清理 Vitrea 自己沙盒内的四类可再生数据 —— **卡面图片缓存**（`Caches/VitreaCardCache`）、**网络请求缓存**（`Caches/CardArtHTTP`）、**贴纸素材缓存**（`Caches/Stickers`）、**临时文件**（`tmp`）。
  - **其他应用（沙盒外）**：经开发者配对 + 回环隧道，用 HouseArrest（`VendContainer`）把目标 App 的容器租借出来，清其 `Library/Caches` 与 `tmp`。**范围固定为「全部应用」**，不再区分第三方 / 系统应用。
- **全选在右上角**：一键全选 / 取消全选，不用进二级菜单。
- **不会自动重扫**：扫描结果保存在共享状态里，切换范围、切 Tab、返回本页都不会重新扫描；**只有点右上角刷新按钮才会**。
- **扫描与清理都支持后台**：跨应用扫描要逐个租借容器，可能几十秒；这段时间用 `BackgroundKeeper`（`beginBackgroundTask` + 静音音频会话）保活，划出后台也会继续跑完，回来就能看到结果。
- 两个范围都是：搜索 + 按体积排序 + 多选 + 二次确认 + 结果反馈（实际释放空间 / 删除文件数 / 失败项）。
- **批量扫描**：沙盒外扫描改为「一次隧道扫多个应用」（`al_container_scan_many`），握手开销只付一次，比逐个应用建隧道快一个量级；界面侧再按 **30 个/片 × 6 路并发** 分片跑，且扫描过程中只推进度数字、不反复重排整个列表。
- **安全边界**：只处理 `Library/Caches` 与 `tmp`，`Documents`、偏好设置、钥匙串、账号数据与写入日志一律不动；不跟随、不删除符号链接；越界路径直接拒绝。
- 跨应用清理与写入同前置条件（有效配对 + 回环隧道）。部分应用（例如 App Store 安装的、系统未授权访问容器的应用）会被系统拒绝，界面按「无法清理」如实统计，不会静默失败。

### 🔁 回环隧道（内置）
- **内置回环**：Vitrea 自带一个 Packet Tunnel Provider 扩展（`VitreaTunnel.appex`），在设备上建一条 `/32` 的 utun 隧道并把 `10.7.0.1` 的流量弹回本机协议栈，使 App 能连到只监听物理网卡的 `lockdownd`。**不再需要另外安装 VPN App**。
- 配对页一键「启动内置回环」；已配置过的用户进入 App 会自动拉起。
- 只需一条 `10.7.0.1/32` 路由进入隧道，其余流量（含默认路由）全部排除，**不影响正常上网**。
- **退路**：若当前签名未包含 `NetworkExtension` 权限（部分自签方式会剥掉），界面会自动退回「打开 LocalDevVPN」按钮，功能不受影响。

### 🪟 界面
- 基于 iOS 26 **液态玻璃（Liquid Glass）** 的视觉风格，自绘 `GlassCard` / `GlassButton` / `GlassBackground` 组件。
- 底部 Tab 导航：**卡面库** / **键盘** / **清理** / **作者**，编辑器以全屏方式独立呈现，不占用 Tab。
- 卡面库右上角是带「**制作**」字样的实心胶囊按钮，一眼可见。

## 预览 / Preview

> 📷 **截图待补充**：把实机截图放到 `docs/screenshots/` 下（建议命名 `gallery.png` / `crop.png` / `editor.png` / `write.png`），然后取消下面这段的注释即可。

<!--
<p align="center">
  <img src="docs/screenshots/gallery.png" width="24%" alt="卡面库" />
  <img src="docs/screenshots/crop.png" width="24%" alt="照片裁切" />
  <img src="docs/screenshots/editor.png" width="24%" alt="卡面编辑" />
  <img src="docs/screenshots/write.png" width="24%" alt="写入进度" />
</p>
-->

| 界面 | 说明 |
| --- | --- |
| **卡面库** | 在线素材瀑布流，交通卡 / 证件卡 / 支付卡分类 + 精选推荐 |
| **照片裁切** | 严格 1536 × 969 卡面比例裁切框，拖动 / 双指缩放，确认后进入编辑 |
| **卡面编辑** | 框内叠加文字与贴纸，实时预览最终效果 |
| **写入进度** | 显示写入百分比，完成后自动刷新 Wallet 缓存 |

## 环境要求 / Requirements

| 项目 | 要求 |
| --- | --- |
| 设备系统 | **iOS 26.0 – 26.6**，或 **iOS 27 beta 1 – beta 4**（真机，不支持模拟器） |
| 架构 | `arm64`（模拟器仅 `arm64`，已排除 `x86_64`） |
| 开发工具 | Xcode 16+ / Swift 5.0 |
| 工程生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`） |
| Rust 工具链 | `rustup` + `aarch64-apple-ios`、`aarch64-apple-ios-sim` |
| 依赖 | 可选：[LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN)。回环隧道已内置（`VitreaTunnel.appex`），仅当自签剥掉了 `NetworkExtension` 权限时才需要它。 |

## 安装 / Installation

### 方式一：直接安装 Release 中的 IPA（推荐）

1. 前往本仓库的 [**Releases**](../../releases/latest) 页面，下载最新的 `Vitrea.ipa`。
2. 因为 Release 中的 IPA 是**未签名**包，需要用自签工具重签后再安装，详见 **[docs/INSTALL.md](docs/INSTALL.md)**。
3. 常用自签工具：**AltStore / SideStore / Sideloadly / ESign / 爱思助手**。
4. 安装完成后打开 Vitrea，在配对页点「启动内置回环」即可（隧道已内置，无需额外装 VPN App）。

> [!WARNING]
> Release 中的 `Vitrea.ipa` 已剥离 `embedded.mobileprovision`，仅保留一次 **ad-hoc 签名**（用于携带 `NetworkExtension` 权限，重签时会被你的证书替换）。无法直接双击安装，必须用自己的 Apple ID / 证书重签。**请勿使用来源不明的企业证书**，也不要把它交给第三方代签。
>
> 若重签工具把 `NetworkExtension` 权限丢掉了，内置回环会启动失败 —— 界面会自动退回「打开 LocalDevVPN」，功能不受影响。

### 方式二：从源码构建（见下一节）

## 从源码构建 / Building

```bash
# 1. 克隆仓库
git clone https://github.com/221121222/vitrea.git
cd vitrea

# 2. 构建 Rust 静态库并打包 AirliftFFI.xcframework
#    （首次会 rustup target add，耗时较长）
./build-ios.sh

# 3. 安装 XcodeGen 并生成 Xcode 工程
brew install xcodegen
xcodegen generate

# 4. 打包未签名 IPA → build/Vitrea.ipa
./build-ipa.sh Release
```

产物位于 `build/Vitrea.ipa`。若要直接跑在真机上，用 Xcode 打开 `Vitrea.xcodeproj`，在 *Signing & Capabilities* 中选择你自己的 Team 后运行即可。

### 打包脚本说明

| 脚本 | 作用 |
| --- | --- |
| `build-ios.sh` | 交叉编译 `rust-core/`，产出 `AirliftFFI.xcframework`（`aarch64-apple-ios` + `aarch64-apple-ios-sim`）。`rust-core/` 变更后需重跑，并重新 `xcodegen generate`。 |
| `build-ipa.sh [Debug\|Release]` | 调用 `xcodebuild` 构建 `Vitrea.app`（含 `PlugIns/VitreaTunnel.appex` 与 `PlugIns/VitreaWidgets.appex`），剥离描述文件后由内向外做 **ad-hoc 签名并写入 entitlements**，打包为 `build/Vitrea.ipa`。想要旧行为（完全裸包）用 `STRIP_SIGNATURE=1 ./build-ipa.sh Release`。 |
| `project.yml` | XcodeGen 工程定义（Bundle ID `cc.cardart.workshop`、隧道扩展 `…tunnel`、实时活动扩展 `…widgets`、版本号、依赖、链接参数、entitlements）。 |

## 工作原理 / How it works

1. **素材层**：`CardArtAPI` 请求 `cardart.cc` 的卡面接口，`ImageCache` 做内存 + 磁盘两级缓存，`StickerService` 从 `Resources/Manifests/stickers.json` 读取贴纸索引、图片按需在线加载。
2. **编辑层**：`CropView` 把照片按卡面比例（1536 × 969）裁切并扁平化，`EditorView` 在等比例画布上叠加文字与贴纸，`SVGRenderer` 负责矢量绘制。
3. **写入层**：`WriteEngine` 通过 `AirliftFFI`（Rust）与本机 `AirTraffic` 服务通信，替换 Passbook 缓存中的 `cardBackgroundCombined@3x.png` / `@2x.png` / `.pdf`，并刷新正反面与缩略图缓存。进度由 `FFIProgressParser` 从 Rust 日志解析出**真实文件级**计数，`WriteProgressModel` 再平滑成 1% 递增；`BackgroundWriteKeeper` 负责后台保活，`WriteActivityController` 把百分比推给 `VitreaWidgets` 扩展显示在灵动岛。
4. **配对层**：`PairingController` 用 Bonjour 广播 `_remotepairing-pairable-host._tcp` 完成开发者配对，`PINNotifier` 在配对期间以音频后台保活，保证输入 PIN 时不被系统挂起。
5. **清理层**：`CleanerService` 按白名单扫描 App 沙盒内可再生的缓存（`Library/Caches` 与 `tmp`），扫描前后各统计一次体积以得出真实释放量；`DeviceCleanerService` 则经 HouseArrest（`VendContainer`）+ AFC 在沙盒外统计并清理其他 App 容器的同名目录。两者共用 `CleanerStore` 保存扫描状态 —— 视图重建不会丢，所以切范围 / 切 Tab / 返回都不会重扫，只有刷新按钮会。跨应用扫描走 `al_container_scan_many` 批量隧道，再按 30 个/片 × 6 路并发分片。
6. **键盘主题层**：主题包与预览图全部内置，`PasscodeThemeCatalog.loadBundled()` 读 `Resources/PasscodeThemes/themes.json` 得到目录（离线、秒开），网络源只作回退与手动刷新；`PasscodeKeypad` 按 `TelephonyUI` 命名规范生成多语言 × 标准/粗体位图；`PasscodeThemeApplier` 取本地 `.passthm`（内置直接拷，否则联网下载）解包（`al_passthm_extract`）后经 `al_exploit_write_dir` 写入设备缓存目录。
7. **回环层**：`LoopbackTunnelService` 用 `NETunnelProviderManager` 管理内置的 `VitreaTunnel.appex`（Packet Tunnel Provider）。扩展建一条自身 `10.7.0.0/32` 的 utun，只把 `10.7.0.1/32` 指进隧道，并把收到的 IP 包**源/目的地址对调改写**后塞回协议栈 —— 于是「发往 10.7.0.1」等价于「发往本机」，只监听物理网卡的 `lockdownd` 就能被访问到。若权限缺失则自动退回外部 LocalDevVPN。

> [!NOTE]
> 跨应用清理与写入走的是**开发者配对通道**，不是越狱或内核逃逸：能清哪些应用取决于系统是否允许租借其容器。

> [!WARNING]
> 本项目的写入能力依赖**未公开的系统接口**，仅在特定 iOS 版本上验证可用。系统更新后行为可能失效，这是预期内的风险。

## 目录结构 / Repository structure

```text
.
├── ios-app/                     # SwiftUI 应用源码
│   ├── App/                     # 应用入口（VitreaApp.swift）
│   ├── Glass/                   # 液态玻璃组件（GlassCard / GlassButton / GlassBackground / GlassTheme）
│   ├── Services/                # 网络 / 写入 / 进度 / 保活 / 实时活动 / 随机卡面 / 缓存 / 渲染 / 配对 / 清理服务
│   ├── Shared/                  # 与小组件扩展共用的类型（GalleryCard / WriteActivityAttributes / RandomCard）
│   ├── Views/                   # 全部界面（卡面库、清理、编辑器、裁切、写入、作者页…）
│   ├── Resources/
│   │   ├── Manifests/           # 素材与贴纸清单 JSON（嵌入 App）
│   │   ├── PasscodePreviews/    # 键盘主题预览图（嵌入 App，27 张，约 700 KB）
│   │   ├── PasscodeThemes/      # 键盘主题包 .passthm + 本地清单（嵌入 App，27 个，约 8.1 MB）
│   │   └── credits/             # 作者头像（嵌入 App）
│   │   # Stickers/ 为 ~137MB 本地素材镜像，未纳入仓库；
│   │   # App 运行时由 StickerService 从 https://cardart.cc/maker/ 在线加载
│   ├── Assets.xcassets/         # App 图标
│   ├── Models.swift             # 数据模型
│   ├── NetworkStatus.swift      # 网卡 / 隧道路由探测
│   ├── Vitrea.entitlements      # NetworkExtension（packet-tunnel-provider）权限
│   └── Info.plist               # 权限与 Bonjour 声明
├── TunnelProv/                  # 内置回环扩展（Packet Tunnel Provider）
│   ├── PacketTunnelProvider.swift
│   ├── TunnelProv.entitlements
│   └── Info.plist
├── VitreaWidgets/               # 实时活动扩展（灵动岛 / 锁屏写入进度）
│   ├── WriteActivityWidget.swift
│   └── Info.plist
├── rust-core/                   # AirliftFFI：与本机服务通信的 Rust 静态库源码
├── project.yml                  # XcodeGen 工程定义
├── build-ios.sh                 # 构建 Rust xcframework
├── build-ipa.sh                 # 打包未签名 IPA
├── docs/
│   ├── INSTALL.md               # 签名与安装指引
│   └── REVERSE-tendies.md       # 存档：早期壁纸功能所用的云端协议逆向记录（功能已移除）
├── .github/                     # Issue 模板
├── RELEASE_NOTES.md             # 发布说明
├── CONTRIBUTING.md              # 贡献指南
├── LICENSE                      # MIT
└── README.md
```

## 致谢 / Acknowledgements

- **[AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)** —— Vitrea 的写入链路与 `AirliftFFI` 源自该项目（MIT），感谢原作者 **[@mak5er](https://github.com/mak5er)** 与 **[@merybist](https://github.com/merybist)** 的开源工作。
- **[AirLift](https://github.com/0xjohnnydev/airlift)** by **[@0xjohnnydev](https://github.com/0xjohnnydev)** —— `AirliftFFI` 底层依赖的 AirTraffic / ATAirlock 沙盒逃逸研究。
- **[cardart.cc](https://cardart.cc)** —— 卡面素材来源，素材版权归原作者所有。
- **[3105](https://github.com/YangJiiii/3105)** by **[@YangJiiii](https://github.com/YangJiiii)** —— 清理功能的交互模型（扫描 → 排序 → 多选 → 二次确认 → 结果反馈）与「有限清理」边界思路参考自该项目。本项目的清理实现为独立编写，仅沿用其设计思路；3105 采用 GPL-3.0，与本项目 MIT 不兼容，故未复用其任何源码。
- **[LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN)**（SideStore Team）—— 内置回环隧道（`TunnelProv/PacketTunnelProvider.swift`）沿用其「`/32` utun + 单条 `/32` 路由 + 地址对调回灌」机制，本仓库为独立实现；仍推荐把它作为权限缺失时的退路。
- **[AirCard](https://github.com/Mak5er/AirCard)** by **[@mak5er](https://github.com/mak5er)** —— 锁屏密码按键主题（`.passthm`）的写入路径与 `TelephonyUI` 文件命名规范参考自该项目（MIT）。
- **[Cowabunga-theme-repo](https://github.com/sourcelocation/Cowabunga-theme-repo)** by **[@sourcelocation](https://github.com/sourcelocation)** —— 锁屏按键主题目录与主题包来源；内置的 27 张预览图取自该仓库的 `passcode-theme-previews/`（等比压缩后随 App 分发），主题版权归各作者所有，本应用仅提供浏览与安装。
- **[aircardios.github.io](https://aircardios.github.io/pass-themes/)** —— 主题库的备用目录源；本应用仅提供浏览与导入。
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** —— 工程文件生成。

## 许可 / License

本项目基于 [MIT License](LICENSE) 开源，仅供**个人学习与技术交流**，请勿用于商业用途或任何违规场景。

卡面素材版权归原作者所有；本 App 不对写入结果作任何保证，使用后果由使用者自行承担。
