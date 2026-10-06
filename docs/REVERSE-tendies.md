# 交互壁纸（IosWallpaperApp）云端与 `.tendies` 下载链路 —— 逆向报告

> 分析对象：`~/Downloads/交互壁纸.ipa`
> 包内主二进制：`Payload/IosWallpaperApp.app/IosWallpaperApp`（Mach-O arm64，Release、符号已剥离）
> Bundle ID：`com.mutually.wallpaper.device`　版本：**1.0.2 (build 16)**
> 构建路径泄漏：`/tmp/ios-wallpaper-release-20260828-16/Build/...`
> 分析方式：`nm` / `otool -tV` 反汇编 + adrp/add 立即数解引用 + Swift 符号 demangle + 线上实测

---

## 0. 一句话结论

**不存在「tendies 下载链接」可以拿。**

参考实现里的 `.tendies` 通道是一条**服务端硬门禁**的接口：

- 列表接口返回的 `down_url` 字段 **424/424 条全部为空串**（服务端根本没挂包）；
- `get_download_url.php` 对**任何**客户端一律返回 `426 upgrade_required`；
- 解锁接口 `free_unlock_grant.php` 一律返回 `426 device_auth_required`（要求「安全更新版」1.0.46）。

所以这个 App **从不下载 `.tendies`，也从不从视频生成 `.tendies`** ——
它是一个纯粹的「包导入器 + PosterBoard 注入器」：包从**本地文件**来，视频只用于预览播放。

---

## 1. 云端接口全貌

全站只有 **4 个** API 端点，全部在 `https://wall-api.18ir.cn`（媒体文件也同主机）。

| 用途 | 请求 | 说明 |
|---|---|---|
| 列表 | `GET /api/get_wallpaper.php?page=N` | 10 条/页，实测共 **43 页 / 424 条** |
| 缩略图 | `GET /api/thumb.php?id=<id>&w=<px>&v=<cacheKey>` | 返回 JPEG（实测 85 KB） |
| 媒体 | `GET https://wall-api.18ir.cn/admin/uploads/card_<md5>.mp4` | `video/mp4`（实测 2.8 MB） |
| **壁纸包** | `GET /api/get_download_url.php?card_id=<token>&device_fp=<fp>` | **恒 426 `upgrade_required`** |
| 解锁 | `GET /api/free_unlock_grant.php?card_id=<token>&device_fp=<fp>` | **恒 426 `device_auth_required`** |
| 更新 | `GET /api/get_app_update.php?platform=ios&version=<v>` | 最新 1.0.46 / build 100，`enabled:false` |

另有 `https://s.11-y.cn/t78pCz` 短链 —— 实测 302 跳到
`https://lightpicture.18ir.cn/LightPicture/2026/07/e99e29f6eeee9559.jpeg`（客服二维码图），
与壁纸包无关。

### 1.1 列表响应字段

```json
{"code":200,"message":"success","data":[{
  "id":613, "title":"宇智波鼬",
  "tag":"[\"动漫\",\"火影忍者\"]",
  "image_url":"/admin/uploads/card_884a86d1....mp4",
  "is_gif":0,
  "down_url":"",                       // ← 424 条全为空
  "created_at":"2026-10-05 21:52:29",
  "sort_order":0, "is_visible":1, "publish_at":null,
  "media_type":"video",                // 419 video / 3 gif / 2 image
  "video_url":"/admin/uploads/card_884a86d1....mp4",
  "thumb_url":"/api/thumb.php?id=613&w=600&v=p2-c2b45c44e8c00d58"
}]}
```

全量抓取结果：`media_type` 分布 = `video 419 / gif 3 / image 2`，`is_gif` 全 0，
**`down_url` 非空条数 = 0**。

### 1.2 防盗链

参考实现的做法（反汇编 `0x100012d60` 起）：

```
if url.hasSuffix(".18ir.cn") || url.hasSuffix(".xgso.to") {
    request.setValue("https://lightpicture.18ir.cn/", forHTTPHeaderField: "Referer")
}
```

即只对 `.18ir.cn` / `.xgso.to` 结尾的 host 注入伪造 Referer。
实测 `https://wall-api.18ir.cn/admin/uploads/card_884a86d1....mp4` 带该 Referer 返回
`200 video/mp4`。

---

## 2. `card_id` 不是 id，是时间令牌（关键发现）

### 2.1 反汇编

`IosWallpaperApp.UnlockService.encodedCardID(id:now:)`（`0x100064a1c` 起）：

```asm
bl   Date.timeIntervalSince1970            ; d0 = ts
fcvtzs x22, d0                             ; Int(ts)
...  String(id).append("|").append(String(ts))
bl   Data.init<C: Collection>(_:)          ; Data(utf8)
bl   Data.base64EncodedString(options: 0)  ; x0 = 0 → 无选项
...  replacingOccurrences("+","-")
...  replacingOccurrences("/","_")
...  replacingOccurrences("=","")          ; 去掉填充
```

对应 Swift：

```swift
static func encodedCardID(_ id: Int, now: Date) -> String {
    let raw = "\(id)|\(Int(now.timeIntervalSince1970))"
    return Data(raw.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
```

`grantAdUnlock(cardId:session:)`（`0x100064ec0` 起）随后把
`("card_id", token)` 与 `("device_fp", fp)` 两个 `URLQueryItem` 塞进
`URLComponents("https://wall-api.18ir.cn/api/free_unlock_grant.php")`。

### 2.2 `device_fp` 算法

```
UUID().uuidString → 去掉 "-" → lowercased()   // 32 位小写 hex
首次生成后 saveKeychain()，之后 readKeychain() 复用
```

### 2.3 实测验证（决定性证据）

| 请求 | 响应 |
|---|---|
| `card_id=613`（裸 id） | `400 {"error":"invalid card_id"}` |
| `card_id=NjEzfDE3OTEyNjc3Mzc`（令牌） | `426 {"error":"device_auth_required"}` |

裸 id 被拒 → 换令牌后**通过了 card_id 校验**，只是卡在下一道门。
证明令牌算法还原正确。

---

## 3. 门禁状态（2026-10 实测）

```
$ curl 'https://wall-api.18ir.cn/api/get_download_url.php?card_id=<token>&device_fp=<fp>'
HTTP/1.1 426
{"ok":false,"error":"upgrade_required",
 "message":"请升级 App；旧会员请提交人工找回申请。"}

$ curl 'https://wall-api.18ir.cn/api/free_unlock_grant.php?card_id=<token>&device_fp=<fp>'
HTTP/1.1 426
{"ok":false,"error":"device_auth_required",
 "message":"请安装安全更新版；旧会员可在“我的”提交找回申请…"}
```

补充探测（均无效）：

- 加 `version/v/ver/build/app_version=1.0.46`、`build=100`、`platform=ios`、`channel=appstore` → 仍 426
- 伪造 UA → 仍 426
- `get_wallpaper.php` 加 `limit/all/type/page_size/status/is_locked/need_pay` → 仍是 10 条/页，`down_url` 仍为空

服务端要求的「安全更新版」= `get_app_update.php` 报的 **1.0.46 (build 100)**，
而本机安装的是 **1.0.2 (build 16)** —— 老版本被服务端整体拒绝。

---

## 4. 参考实现的真实架构（纠偏）

demangle 后共 1620 个符号，应用自有类型如下：

```
WallpaperAPI / WallpaperServiceProtocol / WallpaperViewModel / MockWallpaperService
Wallpaper / WallpaperResponse / WallpaperPage
UnlockService / UnlockSheetView
DeviceIdentity
TendiesInstaller / TendiesInstallCoordinator / TendiesInstallState / TendiesInstallError
InstalledTendiesWallpapersManager / InstalledTendiesWallpapersView
PosterBoardAccess / PosterBoardAccessError / PosterBoardCompatibility
ManagedPosterBoardWallpaper / ManagedPosterBoardWallpaperNameStore
AppUpdate / AppUpdateManager / AppUpdateOverlay
AdManager / FavoritesManager / CuratedTheme / ThemeDescriptor
```

**没有**任何视频抽帧类型（无 `VideoFrame*`、无 `AVAssetImageGenerator` 的 Swift 调用）。
`AVAssetImageGenerator` 只作为 ObjC 属性类型编码出现在穿山甲广告 SDK 里
（`T@"AVAssetImageGenerator",&,N,V_imageGenerator`），与本 App 的壁纸逻辑无关。

### 4.1 `TendiesInstaller` 方法清单（demangle 还原）

```
download(_: URL, into: URL) async throws -> URL
extract(_: URL, into: URL) throws -> URL
makeWorkspace() throws -> URL
validateLocalPackage(_: URL) throws -> ()
packageFingerprint(at: URL) throws -> String      // CryptoKit SHA256
findDescriptorGroups(in: URL) throws -> [String: [URL]]
randomizeIdentifier(in: URL) throws -> ()
setPlistValue(_: Int, key: String, at: URL) throws -> ()
```

### 4.2 `PosterBoardAccess` 方法清单

```
install([String: [URL]]) throws -> [String]
installedWallpapers(includeUntrackedCollections: Bool) throws -> [ManagedPosterBoardWallpaper]
deleteWallpapers(_:) throws -> ()
descriptorLocation(at: String, extensionsRoot: URL) -> DescriptorLocation?
validatedDescriptorURL(for:extensionsRoot:) throws -> URL
currentGeneration(in: URL) throws -> String
findPosterBoardHash() throws -> String
bundleID(at: String) -> String?
isSafeExtensionIdentifier(_:) -> Bool
list(path:) throws -> [String]
consume(path:create:) throws -> SandboxExtensionHandle
makeManagedWallpaper(location:name:provenance:) -> ManagedPosterBoardWallpaper
existingManagedPaths([String]) throws -> [String]
```

### 4.3 协调器入口

```
TendiesInstallCoordinator.install(from: URL, displayName: String, wallpaperID: Int?)
TendiesInstallCoordinator.install(packageAt: URL)
TendiesInstallCoordinator.requestWallpaperRefresh()
TendiesInstallCoordinator.reconcileManagedPaths([String]) async throws -> [String]
```

### 4.4 包内描述符目录变体（`__cstring` 实证）

```
descriptors / ordered-descriptors / video-descriptors
photos-descriptors / mercury-descriptors
```

### 4.5 包内模板文件名（`__cstring` 实证）

```
descriptor / frame / frames / thumb / thumbnail / WallpaperTendies-
```

### 4.6 关键 PosterKit 键

```
com.apple.posterkit.provider.descriptor.identifier
com.apple.posterkit.provider.contents.userInfo
com.apple.posterkit.role.identifier
wallpaperRepresentingIdentifier / wallpaperRepresentingFileName
com.apple.WallpaperKit.CollectionsPoster
com.apple.MercuryPoster
com.apple.PhotosUIPrivate.PhotosPosterProvider
com.apple.Posters.CollectionsPosterApp / com.apple.Posters.MercuryPosterApp
```

### 4.7 沙盒令牌技术

```
dlopen("/usr/lib/system/libsystem_containermanager.dylib")
container_query_create / set_class / set_group_identifiers
operation_set_flags / operation_set_part(_domain) / get_single_result / free
container_copy_sandbox_token → sandbox_extension_consume / release
```

---

## 5. 参考实现的 UI 文案（UTF-8 提取，印证流程）

```
正在下载壁纸包 → 正在校验并解压 → 正在导入壁纸包 → 正在准备 PosterBoard
→ 正在安装壁纸 → 正在准备刷新屏幕 → 点「刷新屏幕」将重启屏幕…

请选择 .tendies 壁纸包
下载地址无效，仅支持 HTTPS
该壁纸暂无下载链接，请联系客服
该壁纸下载链接暂缺,请联系客服
壁纸包中没有可安装的 PosterBoard 内容
壁纸包无效、损坏或包含不安全内容
壁纸包为空或超过大小限制
已导入，共写入 N 个壁纸
已避免重复导入
```

→ 全部指向「**下载/选择现成包 → 校验 → 注入**」，没有任何「视频 → 抽帧 → 打包」。

---

## 6. 对 Vitrea 的结论与处置

| 项 | 原实现 | 处置 |
|---|---|---|
| 云端 `.tendies` | `?id=<id>`（错参） | 改为 `?card_id=<时间令牌>&device_fp=<指纹>`，并区分 4 种门禁语义 |
| `device_fp` | 无 | 新增 `DeviceIdentity`（Keychain 持久化 32-hex） |
| 本地 `.tendies` 导入 | 无 | 新增「导入 .tendies 壁纸包」+ `fileImporter` |
| **视频 → `.tendies`** | 云端失败时**自动回退**到本地抽帧 | **从主流程移除**（这是崩溃根因：参考实现从不这么做）。`TendiesBuilder` 保留为实验通道 |
| 包体校验 | 已有 | 保留（`TendiesLimits`：60 MB / 8 MB / 1200 项） |

新增/改动文件：

```
ios-app/Services/DeviceIdentity.swift      （新）Keychain 设备指纹
ios-app/Services/WallpaperCloud.swift      （新）协议常量 + card_id 令牌 + 门禁语义
ios-app/Services/WallpaperService.swift    （改）tendiesGrant 用令牌；新增 freeUnlockGrant
ios-app/Services/TendiesBuilder.swift      （改）补 defaultFPS，标注实验通道
ios-app/Views/WallpaperView.swift          （改）云端优先 + 本地导入；移除视频自动回退
```

---

## 7. 复现命令

```bash
# 解包
mkdir -p /tmp/wpa && cd /tmp/wpa && unzip -o -q ~/Downloads/交互壁纸.ipa

# 端点枚举
strings -a -n 6 Payload/IosWallpaperApp.app/IosWallpaperApp | grep -E 'https?://' | sort -u

# 反汇编
otool -tV Payload/IosWallpaperApp.app/IosWallpaperApp > /tmp/wpa/dis.txt

# 符号 demangle
grep -oE '_\$s15IosWallpaperApp[A-Za-z0-9_]+' /tmp/wpa/dis.txt \
  | sed 's/^_//' | sort -u > /tmp/wpa/m.txt
xcrun swift-demangle $(cat /tmp/wpa/m.txt)

# 令牌实测
python3 -c "
import base64,time
s=('%d|%d'%(613,int(time.time()))).encode()
print(base64.b64encode(s).decode().replace('+','-').replace('/','_').replace('=',''))"
```
