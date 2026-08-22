# KNOWN_ISSUES.md — 冻结源码失败协议

这些条目用于复现和拆分 remediation PR，不代表应长期保留缺陷。

## KI-001 Hotkey：A 键码导致注销后无注册

前置：

- App 已有有效热键；
- Settings recorder 录入含 Command/Option/Control 的 A 组合。

路径：

```text
kVK_ANSI_A == 0
→ Settings 写入 keyCode 0
→ HotKeyCenter.reload()
→ unregister old
→ guard keyCode != 0 returns
```

期望：A 是合法按键，应注册或明确拒绝且保留旧组合。  
实际：旧组合被注销，新组合未注册。  
任务：`pesty-hotkey-state-machine-v01`

## KI-002 Hotkey：失败恢复复用失效 ref

前置：新组合被其他进程占用。

路径：

```text
previous = hotKeyRef
unregister(previous)
register(new) fails
hotKeyRef = previous
```

期望：旧组合重新注册。  
实际：变量保存的是已注销 ref。  
任务：`pesty-hotkey-state-machine-v01`

## KI-003 Hotkey：过期 retry 覆盖新配置

前置：

1. 配置 A 注册失败并排队；
2. retry 触发前改为 B；
3. B 注册成功。

路径：A 的 retry 醒来后注销当前 ref。  
期望：过期 retry 被 generation token 取消。  
任务：`pesty-hotkey-state-machine-v01`

## KI-004 Missing image：粘贴旧剪贴板

前置：

- history 中有 image clip；
- 删除对应 `images/<id>.png`；
- 系统剪贴板预置 canary 文本；
- 选择该 image 并执行 paste。

期望：操作失败，不激活/注入，不改变 canary。  
冻结实现可能结果：向目标 App 粘贴 canary。  
任务：`pesty-paste-transaction-v01`

## KI-005 Persistence：写失败仍发送 saved

前置：

- 把 storage directory 置为不可写，或注入 write failure；
- 修改 history 触发 `saveNow()`。

期望：返回失败，不发送 `.pestyStoreDidSave`。  
冻结实现：`try?` 吞错，通知仍发送。  
任务：`pesty-persistence-contract-v01`

## KI-006 Corrupt store：空状态覆盖原文件

前置：

- 有合法历史；
- 截断或删除 `Pinboard.colorHex`；
- 启动 App；
- 触发任一保存。

期望：坏文件 quarantine，禁止覆盖。  
冻结实现：空状态启动，后续可能覆盖坏文件。  
任务：`pesty-persistence-contract-v01`

## KI-007 Content identity：路径间语义冲突

样本：

```text
a = .text("https://example.com")
b = .link("https://example.com")
```

冻结行为：

```text
a.sameContent(b) == false
contentKey(a) == contentKey(b)
```

期望：全系统使用一个明确身份函数。  
任务：`pesty-content-identity-v01`

## KI-008 iCloud：删除复活

前置：两台 Mac 已同步同一条 X。

步骤：

1. 断开 B；
2. A 删除 X 并保存；
3. B 仍保留 X；
4. 重新连接并触发 whole-file merge。

期望：X 保持删除。  
冻结协议：union merge 可让 X 复活。  
任务：`pesty-icloud-sync-semantics-v01`

## KI-009 File watch：目标文件缺失后静默停止

前置：启用直装版 iCloud Drive sync。

步骤：

1. 删除/驱逐/改名 `store.json`；
2. 触发 watch event；
3. `startWatching` 对不存在路径执行 `open`；
4. `open` 失败后直接返回；
5. 后续重新创建文件并修改。

期望：watch 自动恢复。  
冻结实现：可能不再收到事件。  
任务：`pesty-icloud-sync-semantics-v01`

## KI-010 Direct paste：focus timeout 无结果

前置：目标 App 激活耗时超过约 600ms，或拒绝成为 frontmost。

期望：返回明确失败，成功音不播放。  
冻结实现：剪贴板已改变，但 paste 是否发生不可观测。  
任务：`pesty-paste-transaction-v01`
