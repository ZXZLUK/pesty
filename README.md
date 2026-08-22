# ClipBar

**macOS 原生剪贴板历史管理器** —— 按 `⌘⇧V` 从屏幕底部唤出卡片条，打字即搜索，回车直接粘贴进当前应用。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Zero Dependencies](https://img.shields.io/badge/dependencies-0-green)

> ClipBar is a native macOS clipboard history manager. It is an actively
> developed fork of the MIT-licensed
> [pesty](https://github.com/momenbasel/pesty) by Moamen Basel — deep thanks to
> the upstream project. All original copyright preserved under MIT.

## 特性

- **卡片条界面**：全宽底部滑出，按来源 App 着色的卡片头，⌘1–9 快速粘贴
- **全类型**：文本、富文本、链接、图片、文件、颜色
- **无限历史**：无条数上限，按时间自动清理（如每周），Pinboard 永久保存
- **搜索**：打字即搜；`⌘⇧T` 按类型过滤（文本/链接/图片…）
- **直接粘贴**：回车即注入前台应用（需辅助功能授权，未授权自动降级为复制）
- **复制提示音**：14 种系统音效可选、低音量、可试听
- **Pinboard**：常用内容收藏到命名面板，永不清理
- **隐私**：数据全部本机；自动忽略密码管理器的隐藏复制；可按 App 排除；
  无遥测、无分析、无网络上传（iCloud 多设备同步在重新设计中，当前版本不启用）

## 存储与可靠性

- SQLite（WAL）单库存储，>128KB 的大文本/富文本自动外置为独立文件
- 内存只保留大条目的预览，粘贴时按需读取全文——复制多大都不卡
- 数据库损坏自动隔离（保留现场）并重建；每日自动备份，滚动保留 7 份
- 启动时清扫崩溃残留的孤儿文件

## 构建

需要 macOS 14+ 与 Xcode 16+（Swift 6 工具链），零第三方依赖。

```bash
git clone https://github.com/ZXZLUK/pesty.git
cd pesty
swift test                          # 34 个测试
swift run                           # 直接运行
VERSION=0.1.0 BUILD=1 ./scripts/build_app.sh   # 组装 .app（通用二进制）
open packaging/ClipBar.app
```

首次粘贴会请求**辅助功能**授权（系统设置 → 隐私与安全性 → 辅助功能 → 开启 ClipBar），随后重启一次 ClipBar 生效。

## 快捷键

| 键 | 动作 |
| --- | --- |
| `⌘⇧V` | 呼出 / 收起卡片条（可自定义） |
| `return` | 粘贴选中项到前台应用 |
| `⌘1`–`⌘9` | 快速粘贴第 N 张 |
| `⇧⌘1`–`⇧⌘9` | 以纯文本粘贴第 N 张 |
| 打字 | 搜索 |
| `⌘⇧T` | 循环类型过滤 |
| `⌘⇧S` / `⌘⇧P` | 设置 / 暂停捕获 |
| `esc` | 清搜索 → 关卡片条 |

## 与上游 pesty 的关系

基于上游 `70fd6b2` 冻结基线开发。主要差异：SQLite 存储后端、无上限保留策略、
内存懒加载、身份函数统一、热键状态机修复、粘贴事务化、全中文界面、复制提示音。
冻结审计文档见 [BASELINE.md](BASELINE.md)、[ARCHITECTURE.md](ARCHITECTURE.md)、
[RISKS.md](RISKS.md)、[TESTING.md](TESTING.md)。

## 已知限制

- 多设备 iCloud 同步停用中（删除一致性问题重新设计前不启用，见 RISKS.md）
- Mac App Store 沙盒构建路径未维护（需自有开发者证书）
- 睡眠唤醒 / 多显示器路径未自动化测试

## License

[MIT](LICENSE) © 2026 Moamen Basel（上游）+ ClipBar 贡献者。
