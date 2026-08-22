# TESTING.md — 三层测试证据

任务：clipboard-foundation-v01 ｜ 日期：2026-08-22 ｜ 环境：macOS 26.5（25F71）· Xcode 26.6（17F113）· arm64

本文件严格区分三类证据：**自动单元测试**（进程内、隔离、不证明真实系统行为）、**GitHub CI 构建**（云端干净环境、只证明可编译与打包）、**本机真实运行测试**（真实 AppKit/剪贴板/TCC 环境）。任何一层都不冒充另一层的结论。

## 第一层：自动单元测试

| 项 | 值 |
| --- | --- |
| 命令 | `swift test` |
| 退出码 | **0** |
| 结果 | 21 个测试 / 4 个套件全部通过（框架：Swift Testing，随 Swift 6 工具链内置） |
| 位置 | `Tests/PestyBaselineTests/BaselineTests.swift` |

覆盖范围（全部为**纯值类型**，无 I/O、无窗口、无单例实例化）：

- `ClipItem`：sameContent 各类型语义、plainText 派生、displayTitle（自定义标题优先/链接取 host/首行截断 60）、searchableText、JSON Codable 往返
- `ClipType`：rawValue 往返、label/symbol 非空
- `Pinboard`：完整编解码往返；**并冻结现状**——缺 `colorHex` 字段时解码抛错（合成 Codable 不用 init 默认值）
- `NSColor/Color` hex：6 位解析、非法输入返回 nil、往返
- `HotKeyCenter`：describe 修饰键顺序 `⌃⌥⇧⌘`、默认热键显示 `⇧⌘V`、未知键码回退 `?`

**这一层不证明的事**（明确声明）：不涉及 NSPasteboard 捕获、持久化读写、窗口生命周期、热键注册、粘贴注入、同步——以上全部只由第三层或代码审计覆盖。这是快照式基线（冻结上游行为供重构回归），不是行为充分性证明。

## 第二层：GitHub CI 构建

| 项 | 值 |
| --- | --- |
| Workflow | `.github/workflows/ci.yml`（随冻结基准继承，未修改） |
| Runner | `macos-15` + Xcode 26.3（与本机 26.5/26.6 不同版本，属交叉旁证） |
| 步骤 | `swift build -v` → `VERSION=0.0.0 BUILD=ci ./scripts/build_app.sh` |

**CI 实测（如实记录，2026-08-22）**：本 fork 上 CI **未能触发**——fork 经 API 创建后 GitHub 未向分支派发任何 workflow 运行（已尝试：确认 Actions enabled、空提交重触发、PR 关闭/重开、workflow enable API；workflow 索引在空与非空之间反复，零 run）。需要仓库所有者在网页端首次启用 workflows 后才会运行。因此本 PR 的 CI 层**无结论**，不以下述旁证冒充本分支运行结果。

**旁证（非本分支运行）**：同一 workflow 文件在上游 `momenbasel/pesty` 的 **base SHA `70fd6b2`** 上结论为 `Build (Swift 6, macOS): success`（GitHub check-runs API 查询）。本分支未修改 ci.yml 且生产源码与 base 完全一致（`git diff 70fd6b2 -- Sources` 为空），故该结论对"上游代码可编译打包"有效，但对新增的 Tests target 与文档**无覆盖**——新增部分的可编译性由本机 `swift build`/`swift test`（退出码 0）证明。

CI 只证明云端可编译与可打包，不运行单元测试（workflow 未包含 `swift test`），也不做任何运行时验证。

## 第三层：本机真实运行测试

被测对象：`scripts/build_app.sh` 产出的真实 `.app`（universal，ad-hoc 签名 + 稳定 DR）。方法：真实进程 + 真实 `NSPasteboard.general`（经 `osascript`/Swift 脚本写入）+ AppleScript System Events 驱动键盘 + `store.json`/`pbpaste`/`lsof` 外部取证。**非 mock、非仿真。**

隔离与清理：测试前确认本机无 Pesty 进程、无历史数据目录；所有测试数据写入后已整体删除（`~/Library/Application Support/Pesty`、defaults 域、临时文件、TextEdit 测试文档不保存关闭）。测试期间真实系统剪贴板被测试字符串覆盖（已向用户披露）。

| # | 验证项 | 方法 | 结果 |
| --- | --- | --- | --- |
| 1 | 文本复制捕获 | `osascript` 写入剪贴板 → 1.2s 后查 store.json | ✅ type=text 入库，目录 0700 / 文件 0600 |
| 2 | URL 复制捕获 | 写入 `https://example.org/pesty-test/42` | ✅ 正确分类为 type=link |
| 3 | 图片复制捕获 | 程序生成 PNG 写入剪贴板 | ✅ type=image，SHA256 记录，文件落盘 images/ |
| 4 | 文件复制捕获 | AppleScript 置文件引用 | ✅ type=file，fileURLs 完整 |
| 5 | 搜索 | 面板内键入 `8f3k`（全局唯一匹配子串）→ 回车 | ✅ 粘贴的正是唯一匹配项（过滤+选择+执行全链路） |
| 6 | 重启后持久化 | AppleScript 退出 → 核对磁盘 4 条 → 重启 → 再捕获 1 条 | ✅ 保存文件含旧 4 条 + 新 1 条（证明从磁盘重载而非内存残留） |
| 7 | 全局快捷键 ⌘⇧V | System Events 合成热键，计数 Pesty 窗口 | ✅ 窗口 0→1（开）→0（再按关闭），Carbon 注册真实生效 |
| 8 | 粘贴回前台 App | TextEdit 前台 → 热键 → 搜索 → 回车 | ✅ 目标文本真实注入 TextEdit 文档（完整 ⌘V 合成路径） |
| 9 | Accessibility 拒绝时降级 | 同 8，但改用 `open`（LaunchServices）启动以切断 TCC 授权继承 | ✅ 降级路径与源码一致：剪贴板已更新（pbpaste=目标）但**不注入**目标文档、不抢焦点 |
| 10 | 敏感 App 排除 | 观测归因 bundleID → 写入 `ignoredSourceAppBundleIDs` → 重启 → 再复制 | ✅ 条目数不增、内容未入库；期间实证归因随前台 App 实时变化（微信↔浏览器） |
| 11 | 默认无未声明网络 | App 空闲运行中 `lsof -nP -i -a -p <pid>` | ✅ 零网络连接（iCloud 同步默认关闭，未开启） |
| 附 | 密码管理器隐藏标记 | Swift 脚本写剪贴板并附 `org.nspasteboard.ConcealedType` | ✅ 完全不捕获（store.json 未创建） |

关于第 8/9 项的 TCC 机制说明（如实记录）：直接注入路径首次是在"从已获辅助功能授权的宿主 shell 启动"的实例上验证的（macOS TCC 的 responsible-process 授权继承）；第 9 项用 `open` 启动切断继承后，同一二进制立即表现为降级路径。两次对比构成授权状态的因果证据，而非巧合。**未**测试"用户在系统设置中手动为正式安装的 App 授权"的标准安装路径。

## 未验证事项（诚实清单）

1. **多显示器**（外接屏切换、纵排布局）与 **睡眠唤醒**路径——需要物理显示器/电源事件，未执行。相关代码有针对性设计（ARCHITECTURE §6），逻辑未实测。
2. **正式安装场景的 Accessibility 授权流程**（系统设置手动授权 + 重启提示）——需要交互式授权界面。
3. **Secure Input 场景**（密码框聚焦时合成 ⌘V 被吞）——未构造（RISKS R6）。
4. **Pinboard 创建/同步 UI 流**、菜单栏全部入口、编辑器（ClipEditor）、拖拽导出、Writing Tools——未在本次 11 项范围内。
5. **iCloud Drive 同步与 CloudKit（MAS）**——默认关闭未开启；MAS 构建依赖上游证书，fork 不可构建（RISKS R7）。
6. **CI 与本机工具链差异**（Xcode 26.3 vs 26.6）带来的行为差异未排查，仅有双方各自通过的事实。
7. 单元测试对 **store.json 损坏恢复**尚无覆盖（现状：静默清空，见 RISKS R3——属下一阶段修复项而非本基线缺口）。

## 复现步骤

```bash
# 第一层
swift test                                   # 期望：21 passed，exit 0
# 第二层：向分支推送后查看 GitHub Actions "CI" workflow
# 第三层（本机，会使用真实剪贴板，测试后请自行清理）
VERSION=0.1.0 BUILD=local bash scripts/build_app.sh
open packaging/Pesty.app                     # 或直接运行其内二进制
osascript -e 'set the clipboard to "TEST-TEXT"'
sleep 1.2 && plutil -p ~/Library/"Application Support"/Pesty/store.json | head
```
