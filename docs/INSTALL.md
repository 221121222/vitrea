# 签名与安装指引 / Signing & Installation Guide

Release 页面提供的 `Vitrea.ipa` 是**未签名包**。它在打包时已剥离 `embedded.mobileprovision`，并做了一次 **ad-hoc 签名**（仅用于把内置回环所需的 `NetworkExtension` 权限带在包里，重签时会被你的证书替换），因此**无法直接安装**，必须先用自己的证书重签。

本文档说明常见的几种自签与安装方式。

---

## 0. 前置说明

| 项目 | 说明 |
| --- | --- |
| Bundle ID | `cc.cardart.workshop`（重签时可自定义，但需保证唯一） |
| 支持系统 | **iOS 26.0 – 26.6**，或 **iOS 27 beta 1 – beta 4** |
| 设备 | 仅 **arm64 真机**，不支持模拟器 |
| 必要依赖 | 无（回环隧道已内置）。仅在自签剥掉了 `NetworkExtension` 权限时才需要 [LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN) 作为退路 |

> [!WARNING]
> 请**不要**把 IPA 交给任何第三方代签服务，也不要使用来源不明的企业证书。企业证书随时可能被吊销，并可能带来隐私风险。

---

## 1. 推荐方案：AltStore / SideStore

适合没有付费开发者账号、希望长期自动续签的用户。

1. 在 iPhone 上安装 **AltStore** 或 **SideStore**（需要一台电脑完成首次引导）。
2. 把 `Vitrea.ipa` 传到手机（AirDrop / 文件 App / iCloud Drive）。
3. 打开 AltStore → **My Apps** → 左上角 `+` → 选择 `Vitrea.ipa`。
4. 首次安装会要求登录 Apple ID（仅用于生成免费开发证书，凭据保存在本机钥匙串）。
5. 免费账号签发的证书 **7 天有效**，AltStore 会在后台自动续签；也可手动点击 *Refresh All*。

## 2. 电脑侧方案：Sideloadly

适合在 Windows / macOS 上用数据线一次性安装。

1. 下载并安装 [Sideloadly](https://sideloadly.io/)。
2. 用数据线连接 iPhone，信任此电脑。
3. 把 `Vitrea.ipa` 拖入 Sideloadly，填写 Apple ID。
4. 点击 **Start**，等待签名与安装完成。
5. 安装后如提示「不受信任的开发者」，前往 **设置 → 通用 → VPN与设备管理**，信任对应证书。

## 3. 越狱 / TrollStore 环境

> [!NOTE]
> **TrollStore 不适用**：它最高只支持到 iOS 17.x，而 Vitrea 需要 **iOS 26.0+**，无法安装。

- **越狱设备**：可用 `AppSync` 或 `Filza` 直接安装 IPA（系统版本需在支持范围内）。

## 4. 爱思助手 / ESign 等国产工具

把 `Vitrea.ipa` 导入工具，选择「IPA 签名」→ 使用自己的 Apple ID 或证书签名 → 安装。注意这些工具通常会要求上传证书，**请确认来源可信**。

---

## 5. 回环隧道（已内置，通常无需额外操作）

Vitrea 的写入 / 清理 / 壁纸注入都依赖一条「能连回本机 `lockdownd`」的隧道。这条隧道**已内置**在 App 里（`VitreaTunnel.appex`，Packet Tunnel Provider）：

1. 打开 Vitrea，配对页会显示「启动内置回环」，点一下即可（首次会弹一次系统 VPN 授权，需 Face ID / 密码确认）。
2. 隧道连上后进入配对流程。
3. 之后每次进 App 会自动拉起，不用重复操作。

若写入时提示连接失败，请先确认：

- 配对页里隧道状态为**已连接**（或系统「设置 → 通用 → VPN与设备管理」里有 `Vitrea 内置回环` 且已连接）；
- Vitrea 已获得**本地网络**权限（设置 → 隐私与安全性 → 本地网络）；
- 设备未处于飞行模式。

### 5.1 内置回环不可用时（退路）

内置回环需要 `NetworkExtension` 权限。**部分自签方式会把这个权限剥掉**，此时 App 会自动检测到并在配对页显示：

> 内置回环不可用（当前签名未包含 NetworkExtension 权限）。请改用 LocalDevVPN。

遇到这种情况：

1. 从 App Store 安装 **LocalDevVPN**（或使用其 AltStore 源）。
2. 打开它，启动 VPN 隧道（状态栏出现 VPN 图标）。
3. 回到 Vitrea，点「打开 LocalDevVPN」→ 等待隧道连上 → 继续配对。

> [!TIP]
> 用 AltStore / SideStore 安装时选择 **「Keep App Extensions (Use Main Profile)」**，只占用 1 个 App ID，扩展的权限也更容易保留。
>
> 想自己确认权限是否写进包里，可在电脑上执行：
> `codesign -d --entitlements :- Vitrea.app/PlugIns/VitreaTunnel.appex`
> 应能看到 `com.apple.developer.networking.networkextension → packet-tunnel-provider`。

---

## 6. 从源码构建自己的签名包

如果你有自己的开发者证书，可以直接用 Xcode 构建并签名，无需上面的重签流程：

```bash
git clone https://github.com/221121222/vitrea.git
cd vitrea
./build-ios.sh
brew install xcodegen && xcodegen generate
open Vitrea.xcodeproj
```

在 Xcode 的 *Signing & Capabilities* 中选择你的 Team，连接真机后直接 Run 即可。
