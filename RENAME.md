# RENAME.md — 重命名改动清单

> 前提约束：不得使用 Paste 的名称/图标/图片/专有文案；须保留原 MIT LICENSE 与 © 2026 Moamen Basel 版权声明（MIT 条款要求）；上游品牌资产（`docs/assets/*`、IconGen.swift 绘制的图标、"Pesty" 名称本身）不得复用。
> 清单基于 `70fd6b2` 的逐行 grep，新名称以下用 `<New>` 占位（含 bundle ID 用 `<new.bundle.id>`）。

## 0. 命名决策输入（改名前须定）

| 决策项 | 说明 |
| --- | --- |
| 产品名 `<New>` | 影响 executable、菜单栏、所有 UI 文案 |
| bundle ID `<new.bundle.id>` | 影响数据目录迁移决策（见 §8）、Accessibility 重授权 |
| 是否保留 MAS 形态 | 若砍掉 MAS（建议），§2/§3/§5 的 MAS 相关项全部作废，清单缩短一半 |
| 数据目录策略 | 改 `Application Support/Pesty` 路径 = 老用户数据不可见；需决定"全新开始"还是迁移读取旧目录 |

## 1. executable / product / target 名称

| 位置 | 现值 | 改为 |
| --- | --- | --- |
| `Package.swift:5` | `name: "Pesty"` | `name: "<New>"` |
| `Package.swift:8` | `.executable(name: "Pesty", targets: ["Pesty"])` | 同步替换（两处） |
| `Package.swift:12-13` | target `name: "Pesty"`、`path: "Sources/Pesty"` | target 名 + **目录改名** `Sources/Pesty → Sources/<New>` |
| `Tests/PestyBaselineTests/`（本轮新增） | `@testable import Pesty` | 模块名变更后同步；target 名可顺带改 |
| `scripts/build_app.sh:12` | `--show-bin-path)/Pesty` | 二进制产物名 |
| `scripts/build_app.sh:21` | `cp "$BIN" "$APP/Contents/MacOS/Pesty"` | 可执行文件名（须与 Info.plist CFBundleExecutable 一致） |
| `scripts/build_mas.sh:18,24` | 同上 | 同上（若保留 MAS） |

注：Swift 单 module，无跨文件 `import Pesty`，目录改名即可，无源内模块引用。

## 2. bundle identifier

| 位置 | 现值 | 改为 |
| --- | --- | --- |
| `packaging/Info.plist:10` | `com.greycorelabs.pesty` | `<new.bundle.id>` |
| `Sources/Pesty/Monitor/PasteService.swift:7` | `packagedBundleID = "com.greycorelabs.pesty"` | `<new.bundle.id>`（剪贴板来源标记的兜底值） |
| `scripts/build_app.sh:33-34` | codesign `--identifier com.greycorelabs.pesty` 与 DR 字符串（两处） | `<new.bundle.id>`（**保留 designated requirement 写法**，见 RISKS R4） |
| `packaging/Pesty-MAS.entitlements:6` | `H3WXHVTP97.com.greycorelabs.pesty` | 自有 team + 新 ID（若保留 MAS） |
| `Sources/Pesty/Sync/CloudKitSchema.swift:8` | `iCloud.com.greycorelabs.pesty` | 自有 CloudKit 容器（若保留 MAS；换容器 = 放弃上游云端数据，fork 场景本来就必须） |

## 3. 菜单栏与 UI 文案（用户可见字符串）

`AppController.swift`：菜单项 "About Pesty"(127,179)、"Hide Pesty"(131)、"Quit Pesty"(132,181)、"Open Pesty …"(170)、"Pause Pesty"/"Resume Pesty"(174,204)、Settings 窗口标题 "Pesty Settings"(449)、About 面板 applicationName "Pesty"(218) 与 credits(221)、状态图标 accessibilityDescription "Pesty"(211)。
`Settings/SettingsView.swift`：约 12 处字符串（24, 31, 74, 75, 110, 136, 138, 183, 196, 323, 335）。
`UI/BarView.swift`：112-113（"About Pesty"/"Quit Pesty"）。
`UI/ClipEditor.swift`：42。
`Util/ClipDragProvider.swift`：54（拖出文件名前缀 "Pesty Image …"）。
`Util/LaunchAtLogin.swift`：17（NSLog 前缀）。
`Util/DemoSeed.swift`：12（上游 repo URL）。
`SettingsView.swift` About：GitHub/Issues 链接指向 `github.com/momenbasel/pesty`(331-332) → 指向自有仓库或移除。
"Inspired by Paste" 文案（AppController 221、SettingsView 326、README）：事实性致敬不构成商标使用，可保留；如需更稳妥可改为 "open-source clipboard manager"（去品牌词）。

## 4. App 图标（必须全新绘制，不可复用上游资产）

| 位置 | 动作 |
| --- | --- |
| `scripts/IconGen.swift` | 用 SwiftUI Canvas 画原图标——**重写为新设计**（这是上游品牌资产） |
| `scripts/make_icon.sh:8,24-25` | iconset/icns 文件名 `Pesty.iconset`/`Pesty.icns` → `<New>.icns`（3 处） |
| `packaging/Info.plist:14` | `CFBundleIconFile: Pesty` → `<New>` |
| `scripts/build_app.sh:22`、`build_mas.sh:25` | icns 复制路径与目标名 |
| `docs/assets/icon.png`、`og-image.png`、`demo.gif`、`screenshot-strip.png` | 上游品牌/截图资产，**删除不搬运** |

## 5. plist / entitlements / 打包产物路径

| 位置 | 现值 | 改为 |
| --- | --- | --- |
| `packaging/Info.plist` | CFBundleName/CFBundleDisplayName `Pesty`；CFBundleExecutable `Pesty`；CFBundleIconFile `Pesty` | `<New>` ×4（CFBundleIdentifier 见 §2） |
| `packaging/Pesty.entitlements` | 文件名 + `scripts/sign_notarize.sh:8` 引用 | `<New>.entitlements`（内容仅 app-sandbox=false，不变） |
| `packaging/Pesty-MAS.entitlements` | 文件名 + 内容（team/容器，见 §2） | 若保留 MAS 一并处理 |
| `scripts/build_app.sh:7`、`build_mas.sh:7-10`、`sign_notarize.sh:6-7,29,41` | `packaging/Pesty.app`、`Pesty-$VERSION.dmg`、`Pesty-MAS-$VERSION.pkg`、`Pesty.zip`、staging 里 `Pesty.app` | 全部路径/产物名（约 10 处） |
| `scripts/sign_notarize.sh:10-13` | **硬编码上游作者**的 Developer ID 姓名与 ASC key id/issuer 默认值 | 删除默认值，强制从环境变量传入（fork 永远不该带上这些） |
| `scripts/build_mas.sh:11-12` | 上游作者签名 identity 默认值 | 同上 |
| `sign_notarize.sh:43` | `hdiutil -volname "Pesty"` | `<New>`（DMG 卷名） |

## 6. CI / Release / Homebrew 元数据

| 位置 | 动作 |
| --- | --- |
| `.github/workflows/release.yml:78,89-94` | DMG 文件名、release 标题与说明中的 "Pesty"、`brew install --cask momenbasel/pesty/pesty`（上游 tap，fork 不拥有 → 删除该安装指引） |
| `.github/workflows/ci.yml:18` | Xcode 版本 pin（26.3）按自有环境调整；与本机 Xcode 26.6 的差异记录到 BASELINE |
| Homebrew | 上游 cask 在其个人 tap（不在本仓库）。fork 需要时自建 tap/cask，无文件可改 |
| `CHANGELOG.md` | 上游历史——保留（MIT 尊重历史），顶部加分隔说明自 v 下游起新 changelog |
| `CONTRIBUTING.md`、`README.md` | 整体重写（README 含大量上游 SEO 文案与 Paste 对比表，不可照搬） |
| `docs/`（index.html、privacy.html、support.html、sitemap、robots、llms.txt） | 上游官网源码——**整体删除**，与 App 无关 |

## 7. 数据目录 / 持久化路径（有迁移后果，慎重）

| 位置 | 现值 | 后果 |
| --- | --- | --- |
| `Store/ClipboardStore.swift:52,64` | `Application Support/Pesty/` 与 `CloudDocs/Pesty/` | 改名后新装读不到旧数据。建议：新路径 + 一次性只读迁移（存在旧目录且新目录为空时导入 store.json+images），或明确"全新开始"写入 README |
| `Sync/CloudKitSchema.swift:69` | `Application Support/Pesty/ck-tmp` | 随上项 |
| `ClipboardStore.swift:5` | `Notification.Name("PestyStoreDidSave")` / `pestyStoreDidSave` | 纯内部，改名无迁移后果（连同 `pestyStoreDidSave` 符号名） |
| `AppController.swift:202,314` 等 | `togglePestyPause`、`isPesty`、`PestyMain`(Main.swift:4) 等内部符号名 | 纯代码风格，可改可不改（建议趁目录改名一次性做，避免半旧半新） |
| `HotkeyCenter.swift:12` | signature `0x50535459`('PSTY') | 顺手换为新 4 字节签名 |
| UserDefaults | 键名均不含 Pesty（见 ARCHITECTURE §3 列表），**无需改**；但换 bundle ID 后 UserDefaults 域随之切换，老偏好丢失（与数据目录同一决策） |

## 8. 不需要改的位置（排查过的负结果）

- 所有 UserDefaults 键名（不含品牌词）。
- `org.nspasteboard.*` 剪贴板类型（行业约定，不是品牌）。
- 源码内无 `import Pesty`（单模块）。
- `#if MAS` 编译标志本身。
- LICENSE 文件与版权行（MIT 要求保留；可在 README/About 追加 fork 说明）。

## 9. 建议的执行顺序（重命名里程碑）

1. 定 §0 四个决策 → 2. 目录/Package/构建脚本机械替换（§1、§5 脚本部分）→ 3. Info.plist/entitlements/codesign 标识（§2、§5）→ 4. UI 字符串（§3，可 grep `Pesty` 收尾验证：源码中应仅剩注释与 LICENSE 归属）→ 5. 新图标（§4）→ 6. CI/release/文档（§6）→ 7. 数据迁移逻辑（§7，若选迁移）→ 8. 全量 grep 验证 + 双架构构建 + `swift test`。
