# TESTING.md — 验证矩阵与证据等级

基准：`70fd6b2c47d48ce03932e7e43b930f9ee26fcec7`

## 1. 唯一 CI 聚合入口

```bash
bash scripts/run_baseline_ci.sh
```

它必须依次执行：

1. `bash scripts/baseline_check.sh`
2. `swift test`
3. `swift build`
4. `VERSION=0.0.0 BUILD=ci bash scripts/build_app.sh`
5. `bash scripts/smoke_noninteractive.sh`

任何步骤非零退出即整体失败。

## 2. 测试分层

| 层级 | 证明什么 | 不证明什么 |
| --- | --- | --- |
| T1 纯值单测 | 模型、编码、字符串与静态语义 | Pasteboard、窗口、TCC、Carbon 注册 |
| T2 构建/打包 | 当前 head 可编译并组装 `.app` | App 运行行为正确 |
| T3 非交互 bundle smoke | plist、架构、签名和 bundle 完整性 | 捕获、粘贴、窗口、同步 |
| T4 本机自动化 | 真实 NSPasteboard 与进程链 | 多显示器、人工 TCC、跨设备 |
| T5 人工/多机 | 正式安装、TCC、多屏、Secure Input、同步 | 长期稳定性 |
| T6 叙述性报告 | 提供调查线索 | 可重复验收 |

## 3. 当前 T1 覆盖

`Tests/PestyBaselineTests/BaselineTests.swift` 当前覆盖：

- `ClipItem.sameContent`；
- plain text 派生；
- display title；
- searchable text；
- Codable round trip；
- `ClipType` raw values；
- Pinboard 编解码现状；
- Color/NSColor hex；
- Hotkey 展示字符串。

明确不覆盖：

- Carbon 注册/恢复/重试；
- ClipboardStore I/O；
- NSPasteboard 捕获；
- 图片资源丢失；
- 直接粘贴；
- iCloud Drive merge；
- CloudKit；
- NSPanel 生命周期。

## 4. CI 状态规则

只有满足以下条件才能写“CI 通过”：

- workflow run 绑定当前精确 head；
- job conclusion 为 success；
- 日志显示完整执行 `run_baseline_ci.sh`；
- 不使用 upstream/base 的 run 代替；
- 不使用本机结果代替；
- head 变化后旧 run 自动失效。

当前 inherited workflow 曾只运行 build 和 bundle assembly，未运行测试与 baseline checks；本 PR 已将完整入口加入 workflow。新 head 未产生真实成功 run 前，状态仍为：

```text
CI: UNVERIFIED
```

## 5. 非交互 smoke

`scripts/smoke_noninteractive.sh`：

- 在临时目录复制 `.app`；
- 校验 plist；
- 校验 executable；
- 校验 arm64 + x86_64；
- 校验 ad-hoc code signature 与 designated identifier；
- 不启动 App；
- 不读取真实剪贴板；
- 不访问真实 Application Support；
- 失败时保留隔离目录用于诊断。

这只是 bundle smoke，不得表述为运行时 smoke。

## 6. 本机运行证据

此前执行者报告过 11 项真实本机观察，包括文本、URL、图片、文件、搜索、重启、热键、TextEdit 粘贴、无 TCC 降级、ignored app 与空闲网络连接。

这些记录目前归类为：

```text
T6 / agent-reported observations
```

原因：

- 没有提交完整自动化 harness；
- 没有脱敏原始输出 manifest；
- 没有逐步骤输入哈希；
- 没有可独立重放的 fixture；
- 部分步骤依赖执行者机器的 TCC inherited state。

它们可以指导下一轮测试设计，不能单独作为发布 gate。

## 7. 本地 Agent 必须补齐的 T4/T5

### 正式安装与 TCC

- 从 Finder/`open` 启动已安装 `.app`；
- 在系统设置手动授权；
- 重启后验证授权稳定；
- 撤销授权后验证降级；
- bundle ID / signature 变化后验证重新授权路径。

### 热键

- A 键码 `0`；
- 新组合注册失败；
- 旧组合恢复；
- 连续快速修改三次；
- 睡眠唤醒；
- 组合被其他 App 占用。

### 粘贴

- 图片文件删除；
- 图片文件损坏；
- 目标 App 激活超时；
- Secure Input；
- TextEdit、浏览器、Terminal；
- 成功音只在成功事务后出现。

### 持久化

- store JSON 截断；
- schema 缺字段；
- 目录只读；
- 磁盘满模拟；
- 写入失败不得发 saved notification；
- 损坏文件必须 quarantine。

### 多机同步

至少两台 Mac，验证：

- A 创建 → B 收到；
- A 删除 → B 删除且不复活；
- 双方同时编辑；
- clear history；
- Pinboard rename/delete；
- 文件删除/驱逐后 watcher 恢复；
- 冲突副本。

## 8. 证据输出格式

每次验证必须输出：

```text
TASK_ID
REPOSITORY
BASE_SHA
HEAD_SHA
MACHINE / OS / XCODE
COMMAND
EXIT_CODE
STARTED_AT
FINISHED_AT
INPUT_FIXTURE_HASH
OUTPUT_ARTIFACT_HASH
CLEANUP_STATUS
LIMITATIONS
```

不得提交真实剪贴板正文、密码、聊天内容、浏览器 cookie、TCC 数据库或个人路径。
