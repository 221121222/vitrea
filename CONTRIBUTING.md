# 贡献指南 / Contributing

感谢你对 **Vitrea** 感兴趣！欢迎通过 Issue 与 Pull Request 参与共建。

## 开发环境

| 工具 | 版本 / 说明 |
| --- | --- |
| Xcode | 16+ |
| XcodeGen | `brew install xcodegen` |
| Rust | `rustup` + `aarch64-apple-ios`、`aarch64-apple-ios-sim` target |
| 设备 | **iOS 26.0 – 26.6** 或 **iOS 27 beta 1 – beta 4** 真机（模拟器不支持写入） |

## 本地构建

```bash
# 1. 生成 Xcode 工程（改动 project.yml 或新增文件后都要重跑）
xcodegen generate

# 2. 构建 Rust FFI（仅在 rust-core/ 变更后需要）
./build-ios.sh

# 3. 打包未签名 IPA
./build-ipa.sh Release
```

> `AirliftFFI.xcframework/` 与 `*.xcodeproj/` 都在 `.gitignore` 中，属于生成产物，**不要提交**。

## 提交规范

采用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)：

```text
feat(editor): 支持文字描边颜色单独设置
fix(crop): 修复裁切框在横图下无法填满的问题
docs(readme): 补充 LocalDevVPN 安装说明
```

常用类型：`feat` / `fix` / `docs` / `refactor` / `style` / `chore` / `build`。

## Pull Request 流程

1. Fork 本仓库并从 `main` 切出功能分支：`git checkout -b feat/your-feature`。
2. 保持改动聚焦，一次 PR 只解决一件事。
3. 确保 `./build-ipa.sh Release` 能构建通过（不要提交构建产物）。
4. 在 PR 描述中说明**改动内容、动机、验证方式**；涉及界面改动请附截图。
5. 等待维护者 Review。

## 代码风格

- Swift 遵循官方 API Design Guidelines，缩进 4 空格。
- 界面改动请复用 `ios-app/Glass/` 下的液态玻璃组件，保持视觉一致。
- 中文注释可以接受，但请保持简洁、说明「为什么」而不是「做了什么」。

## 报告问题

提 Issue 前请先搜索是否已有相同问题。提交时请附上：

- 设备型号与 **iOS 版本**
- Vitrea 版本号（见「作者」页或 Release 标签）
- 复现步骤、期望结果、实际结果
- 相关截图或录屏
