# EVIDENCE.md — 证据账本

本文件只记录可复验状态，不记录用户真实剪贴板内容。

## 当前对象

```text
repository: ZXZLUK/pesty
base_sha: 70fd6b2c47d48ce03932e7e43b930f9ee26fcec7
branch: agent/clipboard-foundation-v01
purpose: baseline/audit only
production_sources_changed: false
```

## 证据等级

- `G1`：GitHub 原生对象可直接验证；
- `G2`：仓库内命令可重复执行；
- `G3`：有脱敏日志/哈希的本机执行；
- `G4`：执行者叙述，未独立复验；
- `U`：未知或未执行。

## 声明矩阵

| 声明 | 等级 | 当前状态 |
| --- | --- | --- |
| PR 是 Draft、未合并 | G1 | 可验证 |
| base SHA 精确冻结 | G1 | 可验证 |
| `Sources/` 相对 base 零改动 | G1/G2 | `baseline_check.sh` |
| LICENSE 保持 | G1/G2 | hash + grep |
| 纯值测试存在 | G1 | 可验证 |
| 纯值测试在本机通过 | G4 | 执行者报告 |
| 当前精确 head 的 CI 成功 | U | workflow 成功前不得宣称 |
| universal `.app` 可构建 | G4/G2 | 本机报告；等待 CI |
| bundle 结构完整 | G2 | `smoke_noninteractive.sh` |
| 真实文本/图片捕获通过 | G4 | 等待可重复 harness |
| 正式安装 TCC 通过 | U | 未验证 |
| 多显示器通过 | U | 未验证 |
| Secure Input 降级正确 | U | 未验证 |
| iCloud 删除收敛 | 反证成立 | 当前协议不支持 |
| hotkey 失败恢复可靠 | 反证成立 | 当前源码存在失效路径 |
| 缺失图片安全失败 | 反证成立 | 当前可能粘贴旧内容 |

## 不接受的证据替代

- upstream base run 不能替代 fork head run；
- mock 不能替代真实 AppKit/TCC；
- 录屏不能替代代码、命令和日志；
- 一次成功不能证明恢复、并发或长期稳定；
- 系统偏好键被修改不能证明官方许可流程完成；
- “没有看到网络连接”不能证明所有执行路径永不联网。

## 证据文件约束

允许提交：

- 命令；
- 退出码；
- 工具版本；
- 脱敏日志；
- fixture hash；
- 二进制/DMG hash；
- 失败堆栈；
- 录屏索引。

禁止提交：

- 真实剪贴板正文；
- cookie；
- API key；
- Apple ID；
- 证书；
- provisioning profile；
- TCC 数据库；
- 私人文件路径；
- 用户聊天截图。
