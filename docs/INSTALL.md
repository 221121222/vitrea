# 签名与安装指引 / Signing & Installation Guide

Release 页面提供的 `Vitrea.ipa` 是**未签名包**。它在打包时已剥离 `_CodeSignature/` 与 `embedded.mobileprovision`，因此**无法直接安装**，必须先用自己的证书重签。

本文档说明常见的几种自签与安装方式。

---

## 0. 前置说明

| 项目 | 说明 |
| --- | --- |
| Bundle ID | `cc.cardart.workshop`（重签时可自定义，但需保证唯一） |
| 最低系统 | iOS 18.0 |
| 设备 | 仅 **arm64 真机**，不支持模拟器 |
| 必要依赖 | [LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN)，用于建立 `10.7.0.1` 本地回环隧道 |

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

- **TrollStore**（仅支持存在 CoreTrust 漏洞的系统版本）：直接把 `Vitrea.ipa` 分享给 TrollStore 打开即可永久安装，无需重签。
- **越狱设备**：可用 `AppSync` 或 `Filza` 直接安装 IPA。

## 4. 爱思助手 / ESign 等国产工具

把 `Vitrea.ipa` 导入工具，选择「IPA 签名」→ 使用自己的 Apple ID 或证书签名 → 安装。注意这些工具通常会要求上传证书，**请确认来源可信**。

---

## 5. 安装 LocalDevVPN（必需）

Vitrea 的写入功能依赖本机回环隧道，安装完 App 后还需要：

1. 安装 **LocalDevVPN**。
2. 打开它，启动 VPN 隧道（状态栏出现 VPN 图标）。
3. 回到 Vitrea，在配对页完成与本机的开发者配对。
4. 配对成功后再进行卡面写入。

若写入时提示连接失败，请先确认：

- LocalDevVPN 隧道处于**已连接**状态；
- Vitrea 已获得**本地网络**权限（设置 → 隐私与安全性 → 本地网络）；
- 设备未处于飞行模式。

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
