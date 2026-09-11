# ClipBar Changelog

## Unreleased

- **修复：链接规则不再被“重复复制”重复触发**（用户场景：语音输入软件会故意回拷剪贴板，同一篇文章的浏览器被反复弹出）。规则现在只在**新内容捕获**或**中间隔了其他内容后再次出现**时触发；与头条完全相同的即时重复复制不再触发（幂等）。规则触发新增环境变量调试轨迹（CLIPBAR_RULE_DEBUG=1 → /tmp/clipbar_rule_fires.log）。
- **新增：链接规则（接口化、数据驱动）**：捕获到链接后按规则立即执行动作——规则 = 域名匹配（后缀式，`mp.weixin.qq.com` 覆盖其子域）+ 可插拔动作（打开默认浏览器 / 运行本地脚本路径，脚本接收链接为参数）。设置 → 行为 →「链接规则」可视化编辑：每条规则 = 开关（暂停/恢复）+ 域名 + 动作选择（打开浏览器 / **打开并抓取全文** / 内联 zsh 脚本）
- **抓取全文动作**：打开链接 → 等页面渲染（3 秒）→ 点击页面聚焦 → ⌘A ⌘C（全文进入剪贴板并被 ClipBar 捕获）→ ⌘W 关闭标签。每一步都确认默认浏览器仍在前台，绝不向其他应用发送合成按键。+ 删除。选"运行脚本"时规则行内展开等宽代码编辑器，直接写 zsh 代码（链接作为 $1 传入），保存即生效——无需管理任何外部脚本文件。内置微信规则默认开启（域 mp.weixin.qq.com → 打开浏览器），手机上复制公众号文章即在 Mac 浏览器打开。规则可随时改/删，不焊死。
- **改进：顶边触发分区**——左端 20% 与右端 30% 免触发（右侧使用更频繁、留更宽），仅顶边**中间 50%** 触发召唤：快速移动鼠标去点关闭按钮、或贴着角落操作时不再误弹。触发条按屏幕宽度百分比铺设（多屏各自居中），显示几何变化时自动重建。
- **新增：智能输入定位（智能粘贴第一步）**：粘贴时通过辅助功能 API 检查目标应用的焦点元素——若不是文本输入框，则在目标窗口内搜索文本区（AXTextArea/AXTextField，有界遍历 ≤9 层 / ≤400 节点），聚焦最靠下、面积最大的候选（prompt 档在底部），再注入 ⌘V。效果：在 Codex / VS Code / Hermes / Warp 之间复制 prompt 时，无需先点输入框，点卡片即直接填入。找不到候选时静默回退为旧行为。设置 → 行为 →「粘贴时自动定位目标应用的输入框」可关。macOS 26.5 SDK 适配：AXUIElement{Copy,Set}AttributeValue 已去掉错误指针参数（3 参签名），角色常量为 #define 宏（Swift 用字符串字面量）。
- **布局：紧凑化（一屏更多内容）**：卡片宽度 215→172（-20%），卡片间距 28→2pt（视觉上只余一条细缝，卡片圆角 19→9、阴影减弱以贴合密排），条带上下留白收紧，应用图标块 56→46。面板高度一次性降档（已存值 ×0.85，clamp 300-720，只做一次；新装默认 365）。同屏可见卡片数约 8→12+。字数改为靠左显示（纯数字、无标签，⌘N 角标仍在右缘）。
- **新增：卡片标注（红/黄/蓝）**：**鼠标悬停卡片时右上角浮现三个彩色小圆点**，点一下即标注、再点当前颜色即清除（当前色带白圈）——完全不用右键，比菜单更快。右键菜单第一排保留同样的三个圆点。标注后卡片背景板着色、描边同步高亮（未选中时 1.5pt 彩色描边），扫一眼就能认出重点。标注属于元数据而非内容：不参与 contentKey 去重，重新复制同样内容会提升带标注的原条目；随 SQLite 持久化（clips 表新增 mark_color 列，自动迁移）、随备份/恢复走。圆点为自绘非模板 NSImage（NSMenu 对 SF Symbol 彩色渲染不可靠）。

- **新增：鼠标移到屏幕下半部自动收起**：面板显示期间，鼠标下穿屏幕中线即自动收起（"我去忙别的了"）；上穿中线重新武装。召唤瞬间鼠标已在下半部则等它先回到上半部才武装，不会误弹。面板内部移动不触发（自身窗口事件不进全局监听）。轮询光标位置实现（0.1s，面板存活期间才运行）——AppKit 只为接受 mouseMoved 的窗口产生该事件，其他应用的窗口大多不接受，全局监听收不到。设置 → 行为 →「鼠标移到屏幕下半部自动收起」可关。与顶边召唤构成"上面唤出、下面赶走"的完整手势。

- **速度：外部点击收起零延迟**：收起判定里的 `CGWindowListCopyWindowInfo`（跨进程 IPC，每次收起增加几十至百余毫秒）替换为 `NSApp.windows` 内存扫描（微秒级），语义不变——落点在本应用自己的任何可见窗口（菜单弹层/设置窗/预览窗）上不收起。收起动作本身已是同步 `orderOut`，无动画。
- **裁剪：移除分享面板**：卡片右键菜单删去「分享」项及 `showSharePicker`/`shareItems`（NSSharingService）。单人本地使用不需要系统分享出口。
- **内存：收起 2 秒后自动清空解码图片缓存**：待机真实物理占用（physical footprint）回落到框架基线约 80MB，不随图片浏览量累积（ps 的 RSS 显示偏大有误导，以 footprint 为准）。召唤时可见卡片重新解码（每张数毫秒，无感）。

- **速度：移除面板出现/消失动画**：召唤与收起改为瞬时（窗口以最终形态直接上屏，不再有 0.12s 滑动过程）；动画状态机（showing/hiding 相位、epoch 令牌、完成兜底定时器）整体删除——AppKit 丢弃动画完成回调导致的一整类卡死隐患不复存在。多屏安全机制（内容在停靠窗口内定 frame、窗口不跨屏移动）保留。卡片悬停/选中的状态反馈微动效保留（不延迟交互）。

- **裁剪：移除 iCloud 同步与 Mac App Store 形态（约 900 行）**：删除 Sync/（CloudSyncService、CloudKitSchema）、全部 `#if MAS` 分支（PasteService 沙盒粘贴路径、设置页同步区块/文案、删除确认同步提示）、`iCloudSync`/`cloudKitSync` 设置键、顶栏同步按钮、build_mas.sh 与 MAS entitlements。单一产品形态：直装版。此为"只给自己用"的裁剪决策。
- **内存：解码图片缓存 200→25**：解码后的截图是应用中最大的对象（单张可达数 MB），旧上限在长期使用中可累积数百 MB（11 天未重启曾达 320MB）；25 张覆盖一屏卡片加滚动缓冲。App 图标缓存加 128 上限。实测：新装 118MB RSS、空闲 CPU 0.0%。

- **新增：顶栏「图片」「文件」快捷过滤**：顶栏漏斗菜单旁新增两个常驻胶囊按钮，单击只看该类型、再点取消，互斥切换；激活态高亮。其余类型（文本/富文本/链接/颜色）仍走漏斗菜单与 ⌘⇧T。
- **顶边唤出：回到零停留**（0.25s→0.2s→0s 三轮实测后 owner 定格零延迟）：碰到屏幕最顶线立即召唤，路过顶边会触发为已知代价。动画 0.12s 不变；单次武装（防连击）保留。
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
