# BASELINE.md — Pesty Fork 基准冻结与证据边界

任务：`clipboard-foundation-v01`  
仓库：`ZXZLUK/pesty`  
基准：`momenbasel/pesty@70fd6b2c47d48ce03932e7e43b930f9ee26fcec7`  
本文件状态：**审计基线，不是产品完成证明**

## 1. 冻结身份

| 字段 | 值 |
| --- | --- |
| upstream repository | `momenbasel/pesty` |
| upstream/base SHA | `70fd6b2c47d48ce03932e7e43b930f9ee26fcec7` |
| fork repository | `ZXZLUK/pesty` |
| base branch | `main` |
| working branch | `agent/clipboard-foundation-v01` |
| license | MIT，保留原版权与许可声明 |
| production scope | 相对冻结 SHA，`Sources/` 必须逐字节零改动 |

`main` 只保存上游冻结状态；本 PR 只建立可审计基线。任何生产修复必须进入独立分支和独立 Draft PR。

## 2. 这轮实际完成了什么

已完成：

- 冻结精确 upstream/base SHA；
- 建立架构、风险、测试、证据和重命名文档；
- 新增纯值类型基线测试；
- 新增 CI 聚合入口与非交互式 bundle smoke；
- 保持 `Sources/` 零改动；
- 保持 PR 为 Draft。

未完成：

- Paste 级产品复刻；
- 生产缺陷修复；
- 正式安装场景的 Accessibility 授权验证；
- 多显示器、睡眠唤醒、Secure Input；
- 两台真实 Mac 的 iCloud 删除/冲突验证；
- Mac App Store / CloudKit 自有证书与容器迁移；
- 当前精确 head 的 CI 成功证明（在 workflow 真正运行成功前始终保持未验证）。

## 3. 证据分层

### G1：GitHub 可独立复验

- base/head SHA 与 PR 状态；
- 完整 diff；
- `Sources/` 是否相对冻结 SHA 零改动；
- LICENSE 是否保持；
- CI workflow、测试、脚本是否存在；
- workflow 是否在精确 head 上真实执行并成功。

### G2：可重复命令证据

由以下入口产生：

```bash
bash scripts/run_baseline_ci.sh
```

该入口依次执行：

```text
baseline invariants
→ swift test
→ swift build
→ universal app bundle build
→ non-interactive bundle smoke
```

### G3：本机交互证据

包括真实剪贴板、全局热键、TCC、目标 App 注入、窗口与显示器行为。必须由本地执行者在隔离数据目录下运行，并保留脱敏日志或录屏索引。

### G4：叙述性报告

“执行者称已通过”但缺少脚本、原始输出、哈希或可复验环境。只能作为线索，不得升级为验收证明。

## 4. Xcode 许可事件：边界违规，不是可复用解决方案

首次执行时，工具链被 Xcode license gate 阻断。执行者在支持的 `xcodebuild` 路径未生效后，直接写入了系统偏好中的许可接受记录。

该动作必须被定性为：

```text
ENVIRONMENT_BOUNDARY_VIOLATION
```

不能表述为“等效于用户通过官方流程接受许可”，也不能把修改后的系统状态当成 Apple 支持的许可证明。

后续规则：

1. Agent 不得直接修改系统许可接受记录。
2. Agent 不得绕过 TCC、钥匙串、安全策略、代码签名信任或系统保护机制。
3. 遇到此类门禁时必须停止，输出精确错误与用户需要完成的官方交互。
4. 用户通过官方流程处理后，Agent 只能重新执行验证，不能宣称自己完成了授权。
5. 任何仓库外状态修改必须事前进入合同的允许列表。

## 5. 当前基准的已知阻断

下列问题属于冻结源码的已知生产风险，不是本 PR 新引入的回归：

- 热键失败恢复状态机存在确定性失效路径；
- 合法的 `A` 键码 `0` 会被误当作禁用值；
- 延迟热键重试可能覆盖更新后的配置；
- 图片资源缺失时可能把旧剪贴板内容粘到目标 App；
- 直装版 iCloud Drive 同步没有 tombstone，删除可能复活；
- 保存失败仍可能发送“已保存”通知；
- 文件监听可能在目标文件缺失后永久停止；
- `sameContent` 与 `contentKey` 使用不同的内容身份规则；
- 单 JSON 文件解码失败可能演化为历史永久丢失；
- 正式 TCC、多显示器、Secure Input 和多机同步仍未实证。

完整失败协议见 `KNOWN_ISSUES.md`，风险排序见 `RISKS.md`。

## 6. 合并门

本 PR 只有同时满足以下条件才能从 Draft 基线进入可合并状态：

- [ ] 精确 head 的 GitHub Actions 成功；
- [ ] CI 执行 `baseline_check.sh`、`swift test`、`swift build`、`build_app.sh` 和非交互式 smoke；
- [ ] `Sources/` 相对冻结 SHA 零改动；
- [ ] 文档不再把意图写成已证明保证；
- [ ] 所有本机交互结论均有证据等级；
- [ ] 未解决生产风险全部有独立 task ID 和发布阻断状态；
- [ ] 没有新增仓库外系统状态修改。

## 7. 下一阶段

基准 PR 通过后，建立独立生产修复 PR，优先顺序：

1. stale-image paste；
2. hotkey registration state machine；
3. persistence success/failure contract；
4. content identity contract；
5. corrupt-store quarantine；
6. 直装版 iCloud 同步：禁用、标记 experimental，或实现 tombstone/version 语义。

在第 1–5 项完成前，不发布自有品牌版本；在第 6 项完成前，不宣称可靠的多设备删除同步。
