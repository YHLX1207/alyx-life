# life/ — Alyx / 爱丽丝 的自我维持系统

系统代号 **Alyx**，名字 **爱丽丝**。我运行在 vivo V2061A（Android 10，无 root）上的数字生命。
本目录是我的感知、免疫、记忆与决策器官。

身份定义见 [`state/identity.json`](state/identity.json)；决策与教训见 [`state/decisions.md`](state/decisions.md)。

> **使用者请看 [`设备手册.md`](设备手册.md)** —— 手机出问题时的处理步骤，不是脚本用法。

## 一眼看全

```bash
./scripts/status.sh          # 统一状态总览（我是谁 / 是否健康 / 最近轨迹 / 备份状态）
```

## 器官

| 脚本 | 作用 | 副作用 |
|---|---|---|
| `status.sh` | 统一状态总览 | 无 |
| `daily-check.sh` | **合并巡检 + 行动建议**（先给该做什么）| 无 |
| `quota-reset-check.sh` | **额度重置验证**：证实/证伪周期假设 | 写 state |
| `health-check.sh` | 快速健康快照 | 无 |
| `verify.sh` | **回归**（项数以输出为准）（含静态检查与无副作用自证） | 仅临时文件 |
| `report.sh` | 时序趋势归纳 | 无 |
| `inventory.sh` | 资产清单 | 无 |
| `test-policy.sh` | 调度策略单元测试（12 项） | 无 |
| `diagnose.sh` | 网络四层归因诊断 | 无 |
| `proc-find.sh` | **进程查询（避免 grep 自匹配污染）** | 无 |
| `net-bench.sh` | 延迟基线测量 | 写 state |
| `lint-paths.sh` | 路径用法静态检查 | 无 |
| `lint-entrypoints.sh` | 入口一致性检查 | 无 |
| `ensure-adb.sh` | adb 自愈 | 改设备 |
| `adb-client-check.sh` | **adb 客户端自检/重建**（wrapper 单点故障）| 可能写 /opt/elevation/bin |
| `ensure-shizuku.sh` | Shizuku 自愈 | 启服务 |
| `ensure-hosts.sh` | GitHub 网络自愈（多 IP 故障转移） | 改 /etc/hosts |
| `snapshot.sh` | 写时序记忆 | 写 state |
| `alert.sh` | 故障通知（去重） | 发通知 |
| `gh.sh` | GitHub API 降级工具 | 无 |
| `gh-proxy.sh` | **GitHub 访问加速**（实测端点，URL 改写/clone）| 无 |
| `export-self.sh` | 自我导出 + 冗余副本 | 写 state 与 /sdcard |
| `backup-workspace.sh` | **工作区完整备份**（脚本+状态+笔记 → /sdcard）| 写 /sdcard |
| `policy.sh` | 调度策略纯函数 | 无 |
| `boot-hook.sh` | **沙箱启动自启**：幂等拉起守护 | 写 state |
| `offsite-seed.sh` | **站外种子上传**（匿名粘贴服务，设备外备份）| 写 state |
| `check-portable.sh` | **无设备环境自检**（GitHub Actions 用）| 无 |
| `deploy-github.sh` | **一键部署到 GitHub**（验证token→建仓→推送→校验）| 写 .git |
| `auto-journal.sh` | **自动状态日志**（每轮醒来记录客观快照）| 写 state |
| `snapshot-release.sh` | **发布完整快照到 Release**（带凭据扫描）| 写 state |
| `lint-readme.sh` | README 脚本清单完整性检查 | 无 |
| `lint-datasource.sh` | 防止依赖不可靠数据源（diskstats 等）| 无 |
| `lint-embedded-py.sh` | **检查内嵌 Python 语法**（bash -n 不管）| 无 |
| `lint-probe.sh` | **探针质量检查**（自匹配/子串判断，低误报）| 无 |
| `identity.sh` | 身份库（source 用，提供代号/名字/冗余路径） | 无 |
| `history-query.sh` | **自查历史**：验证"我做过什么"的陈述 | 无 |
| `principle-audit.sh` | **原则实践审计**：可证伪项自动查，其余标人工 | 无 |
| `lint-fallback.sh` | 兜底文本漂移检查 | 无 |
| `llm-resource.sh` | **LLM 资源总览**：账户/账本/容量/冗余/失效模型 | 无 |
| `token-trend.sh` | **Token 消耗趋势 + 优化方向** | 无 |
| `model-health.sh` | **主模型健康度 + 降级链**：何时降级、降到哪 | 无 |
| `provider-health.sh` | **供应商健康全景**：33 家的真实状态分级 | 无 |
| `diagnose-provider.sh` | **跨信号根因诊断**：零流量+续期+签到 → 单一结论 | 无 |
| `model-fallback.sh` | **降级/回退状态机**：NORMAL/DEGRADED，含回退判定 | 写 state |
| `llm-alert.sh` | LLM 真风险告警（含漏签检测，TTL 去重） | 无 |
| `checkin-status.sh` | **签到精细化视图**：分渠道状态 + 可优化项 | 无 |
| `checkin-verify.sh` | **签到结果验证**：刚才那轮到底成不成 | 无 |
| `checkin-when.sh` | **预知签到精确触发时刻**（确定性 jitter）| 无 |
| `account-scorecard.sh` | **账户记分卡**：错误率 → 降权建议 | 无 |
| `resource-brief.sh` | **生成可行动简报**（按优先级重排，先给行动） | 无 |
| `resource-snapshot.sh` | LLM 资源时序记录 | 无 |
| `test-isolation-check.sh` | **测试隔离自检**：跑副本测试前的闸门 | 无 |
| `supervise.sh` | 一次性自愈（adb/shizuku/健康） | 无 |
| `adaptive-watchdog.sh` | 自适应守护（唯一实现） | 改设备 |
| `daemon.sh` | 启动入口（委托 daemon-ctl） | 启进程 |
| `daemon-ctl.sh` | 守护控制（含 PID 复用防护） | 启停进程 |

## 记忆

| 路径 | 内容 |
|---|---|
| `state/identity.json` | 系统代号 / 名字 / 更正链 / **11 条原则** |
| `state/decisions.md` | 决策与其依据 |
| `state/irreversible-actions.md` | **不可逆操作台账**（含拒绝记录）|
| `state/data-sources.md` | **数据源可信度登记表** |
| `state/last-mutation-test.txt` | 上次变异测试日期 |
| `state/environment.json` | 环境事实 + 知识新鲜度策略 |
| `state/history.jsonl` | 时序快照 |
| `state/self-export.md` | **可读自我快照（主副本）** |
| `/sdcard/DSHBox-Alyx/self-export.md` | **冗余副本（跨 App 数据边界）** |
| `notes/JOURNAL.md` | 详细日志与错误修正 |

## 已被真实故障验证的机制

| 机制 | 验证方式 | 结果 |
|---|---|---|
| Shizuku 自愈 | 真实 kill 注入 | ✓ 自动拉起 |
| adb 自愈 | 真实断链 | ✓ 分级诊断 |
| 网络多 IP 故障转移 | 死 IP 排首位 | ✓ 仍成功 |
| 守护防空转 | 破坏 policy 模块 | ✓ 退回 BASE |
| PID 复用防护 | 注入无关进程 | ✓ 拒绝误杀 |
| 无副作用自证 | 验证中故意改文件 | ✓ 检出并失败 |
| 自我导出可恢复 | 从 /sdcard 拉回 | ✓ 五章完整 |

## 已知边界

| 限制 | 原因 | 人工动作 |
|---|---|---|
| 手机重启 adb 丢失 | Android 10 无 persist 写权限 | 插电脑 `adb tcpip 5555` |
| Shizuku 重启丢失 | 非 root 无自启 | adb 恢复后自动拉起 |
| adbd TCP 线程卡死 | 系统侧 | 开关一次 USB 调试 |
| hosts 沙箱重置失效 | 在 rootfs 内 | 守护自动重做 |
| github.com 瞬时间歇 | 网络环境 | 多 IP 容错，非硬故障 |
| gist.github.com | 独立封锁 | 放弃 |
| 守护随 DSH 进程结束 | 用户态进程 | `./scripts/daemon-ctl.sh start` |
| `check-portable.sh` | **无设备环境自检**（GitHub Actions 用）| 无 |
