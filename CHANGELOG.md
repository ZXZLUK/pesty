# ClipBar Changelog

## Unreleased

- **顶边唤出：停留门槛定为 0.2s**（纯零延迟误弹过多，0.25s 偏钝，0.2s 折中）；滑出/收起动画保持 0.12s。路过顶边不触发，停满 0.2s 即出。
- **新增：鼠标顶边唤出（热边触发）**：每块屏幕最顶边贴一条隐形 4pt 触发条（窗口级别在菜单栏之上，全空间可见），鼠标碰到最顶上的线召唤面板。单次武装（触发过一次后光标不离开顶边不会重弹，收起后原地不动也不会立即重弹）。设置 → 行为 →「鼠标碰屏幕顶边唤出」可关。代价：屏幕最顶部 4pt 区域的点击会被触发条吞掉（菜单栏图标垂直居中，实际不受影响）。显示器增减/唤醒时自动重建。
- **UI：文本卡片字数显示**：去掉底部英文标签 "characters"，只显示数字，并在卡片底部居中（⌘N 快捷键角标保持在右缘）；图片/链接/文件/颜色卡片布局不变。
- **修复：菜单项点击不再收起面板**：设置菜单/卡片右键菜单的弹层由系统接管事件，点击菜单项会进入"外部点击"全局监听——若弹层位置在面板框之外（如底边停靠时打开右上角菜单），面板在鼠标按下瞬间被收起，菜单动作同时被吞，表现为设置永远点不开。现以 CGWindowList 判定落点是否属于本应用自己的任何窗口（菜单弹层、设置窗口、预览窗口），是则不收起。
- **性能：捕获管线移出主线程**：payload 提取（剪贴板读取、图片 SHA256、图片落盘）改在 `userInitiated` 专用队列执行，主线程只做类型/来源门控与 UI 插入；复制大截图不再卡主线程。轮询 0.4s→0.2s，捕获平均延迟减半。提取期间发生新复制时丢弃旧代读取，由下次轮询取新，避免跨代混读。
- **性能：召唤热路径瘦身**：`prepareForBarPresentation` 不再每次执行保留策略清理（时间模式下全量扫描 + 调度保存）；改为启动时 + 每 6 小时定时器 + 保留设置提交时执行。面板与首屏应用图标改为启动预热，首次召唤不再比后续慢（原为懒加载）。
- **单击即粘贴**：单击卡片直接粘贴并收起面板（原为单击选中、双击粘贴）。多选（⇧/⌘+单击）、右键菜单、键盘选择保持不变。
- **修复"没点鼠标面板自己消失"**：收起条件从"面板失去 key 焦点"改为"真实鼠标按下落在面板之外"（全局事件监听 + 面板框判定）。原先 agent 类应用（如 Hermes）会自主回收焦点，被误判为外部点击，面板在用户尚未操作时即被收起。现在焦点被抢面板仍保持；面板内任何点击（卡片/工具栏/空白）都不会仅因点击而收起——卡片是粘贴动作，点外部空白/其他窗口才收起，无操作则常驻。
- **呼出方向可选**：新增设置「从屏幕顶部滑出」（默认开启）——面板停靠屏幕顶边，内容自上向下滑入；关闭后恢复原底边停靠、自下向上滑出。入口：设置 → 行为。多屏安全设计（内容在窗口内滑动，窗口不跨屏移动）与序号令牌动画状态机保持不变。

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
