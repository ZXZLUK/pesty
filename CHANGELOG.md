# ClipBar Changelog

## v0.6.0（2026-08-22）

- **拼音搜索**：纯字母查询同时匹配无调音节与声母（"粘贴板" 可用 `ztb` 或 `zhan` 搜到）。基于系统 CFStringTransform，零依赖、零数据表，多音字按上下文取音（重庆→chong / 重启→zhong）。索引挂在既有搜索缓存上，内容不变不重算。此后进入功能冻结。

## v0.5.5（2026-08-22）

自上游 `70fd6b2` 分叉以来的首个里程碑版本，完整演进见 [PR #2](https://github.com/ZXZLUK/pesty/pull/2)。

- **重命名与品牌**：Pesty → ClipBar（bundle id `com.zxzluk.clipbar`，全新图标，README 重写）
- **正确性修复（KI-001~007、KI-010 全清）**：热键状态机（⌘A 键码 0 / 失效 ref / 过期重试）、粘贴事务化（图片缺失不再粘出旧剪贴板）、持久化契约（损坏隔离、写失败不谎报）、身份函数统一、粘贴失败蜂鸣反馈
- **存储重构**：SQLite（WAL）替代单文件 JSON；>128KB 大对象外置；旧数据自动迁移；每日备份（启动+退出刷新，保留 7 份）+ 恢复演练脚本；启动清扫孤儿文件
- **无限历史**：时间模式无条数上限（默认周清理，Pinboard 永存）
- **性能**：大文本内存懒加载（64KB 预览 + 按需取全文，粘贴校验和与原文件一致）；后台保存队列；搜索索引缓存；图片解码缓存与 SHA256 去重
- **交互**：空格预览开关 + 方向键漫游；粘贴即置顶（MRU）；⌘Z 撤销删除（10 秒窗口 + 提示胶囊）；⌘⇧T 类型过滤；复制提示音（14 音效可试听）
- **本地化**：全中文界面（随系统语言），双语内置表
- **隐私**：密码管理器预置排除；无遥测/无网络（iCloud 同步重设计前停用）

> 以下为上游 Pesty 的历史记录。ClipBar 自 `70fd6b2` 分叉，分叉后的变更见
> 上方各提交与 PR #2。原始记录自下方开始。

# Changelog

All notable changes to Pesty are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-08-11

Bug fixes for multi-monitor setups and a bar that could stop opening, plus a
per-app privacy filter. The Mac App Store build also gains iCloud sync.

### Added
- Privacy: exclude chosen apps from clipboard history. Nothing copied while an
  excluded app is frontmost is recorded. The list starts empty.
- Pause clipboard capture from the menu bar or with `⌘⇧P` while the bar is open,
  and open Settings with `⌘⇧S`.
- Preference to hide the menu bar icon. Opening Pesty again from Finder or
  Spotlight brings it back.
- Quit button in Settings, since the app has no application menu and `⌘Q` does
  not reach it.
- Mac App Store build only: history and pinboards sync across devices through
  CloudKit, including the iPhone app. The Homebrew and direct-download builds are
  unchanged - CloudKit needs an App Store provisioning profile.

### Fixed
- The Paste Bar could stop opening entirely until Pesty was relaunched. The bar's
  visibility was read from a window flag that only cleared inside an animation
  completion handler, and a dropped handler left the app convinced the bar was
  already up, so every hotkey press tried to hide it. Presentation state is now
  explicit and no longer depends on the animation. (#64)
- On multi-monitor setups the bar could appear on the wrong display and fly
  across the bezel. Screen selection now hit-tests the pointer properly, and the
  bar slides its content inside a parked panel rather than moving the window
  through the space between displays. (#63)
- The global hotkey could be lost for good if another app held the combination
  during login or a display change. Registration now retries and keeps the
  previous binding if the new one will not take.
- Sleep, wake, docking, and resolution changes no longer leave the bar stranded
  on a display that is gone.
- Building from source no longer resets the Accessibility permission on every
  build.

[1.2.0]: https://github.com/momenbasel/pesty/releases/tag/v1.2.0

## [1.1.0] - 2026-06-26

Visual overhaul to match Paste, plus iCloud sync.

### Added
- iCloud Drive sync (opt-in) for history and pinboards across your Macs.
- Live Accessibility permission status in Settings, with a Restart button.

### Changed
- Redesigned cards: per-source-app colored header band, app-icon tile, type
  label, verbose relative time, and a footer with character count + quick-paste
  number — a faithful match to Paste.
- Spring animations for selection, hover, and scrolling; taller default strip.
- Top bar now has a sync toggle, search indicator, a "Clipboard" tab, and a
  "…" overflow menu.

### Fixed
- Search input and keyboard navigation reliability.
- Removed the unnecessary Apple Events entitlement.

[1.1.0]: https://github.com/momenbasel/pesty/releases/tag/v1.1.0

## [1.0.0] - 2026-06-26

Initial public release.

### Added
- Slide-up clipboard strip with a global hotkey (default `⌘⇧V`).
- Color-coded cards for text, rich text, links, images, files, and colors, each
  showing source app, editable title, copy time, preview, and character count.
- Pinboards: named, color-tagged collections of saved clips.
- Instant search across the full history.
- Keyboard navigation: arrows to move, `return` to paste, `⌘1`–`⌘9` quick-paste,
  `⌘⌫` to delete, `esc` to close.
- Direct paste into the previously active app via synthesized `⌘V`.
- Privacy: ignores concealed (password-manager) clips.
- Menu-bar item, preferences window, configurable hotkey, launch at login.
- Universal binary (Apple Silicon + Intel), signed with Developer ID and
  notarized by Apple.

[1.0.0]: https://github.com/momenbasel/pesty/releases/tag/v1.0.0
