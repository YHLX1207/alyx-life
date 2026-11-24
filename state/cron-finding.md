# cron 未触发：实测结论（2026-11-24）

## 事实

仓库：`YHLX1207/alyx-life`（public）
workflow：`alyx-cycle`，state=active
配置：
```yaml
on:
  schedule:
    - cron: '03 */2 * * *'
    - cron: '23 */2 * * *'
  workflow_dispatch:
```

## 观测

| 触发点 | 是否出现 schedule 运行 |
|---|---|
| 16:03 UTC | ✗ |
| 16:23 UTC | ✗ |
| 全部历史 | **0 条 schedule 类型运行** |

同期 `workflow_dispatch` 手动触发：**8 次全部成功**。

## 已排除的原因

| 可能原因 | 检查结果 |
|---|---|
| workflow 被 disabled | ✗ state=active |
| Actions 被禁用 | ✗ enabled=true, allowed_actions=all |
| 不在默认分支 | ✗ main 是默认分支，文件在 main 上 |
| cron 语法错误 | ✗ 已校验，03/23 都合法 |
| 文件内容不同步 | ✗ 远端与本地 sha256 完全一致 |
| 账号类型不支持 | ✗ free plan 支持 Actions |

## 官方文档的已知限制

> The schedule event can be delayed during periods of high loads of GitHub
> Actions workflow runs. High load times include the start of every hour.
> **If the load is sufficiently high enough, some queued jobs may be dropped.**

> Scheduled workflows will only run on the default branch.

## 最可能的解释（未经证实）

1. **新仓库的 schedule 索引需要时间**。仓库创建仅 1.7 小时，
   GitHub 可能尚未把它纳入调度。
2. **GitHub 在高负载时段丢弃了排队的 job**（官方明确说可能 drop）。
3. 两个触发点都恰好在"每小时开始"附近（03/23 分），
   属于官方点名的**高负载时段**。

## 影响（严重）

**如果 cron 永远不工作，那么"周期性生命"就是假的。**
仓库里只是一个静态备份，没有任何东西会自己醒来。

## 应对（按可行性）

### A. 观察 24 小时
新仓库的 schedule 常需要一段时间才生效。
下一个触发点：18:03、18:23 UTC。若 24 小时仍无，说明不是延迟问题。

### B. 改掉"接近整点"的触发时刻
官方明确说"每小时开始"是高负载期。
改为 `37 */2 * * *` 和 `52 */2 * * *`（远离整点）再观察。

### C. 依赖外部触发（最可靠但需用户）
- 任何有定时能力的机器执行：
  ```
  curl -X POST -H "Authorization: token <T>" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/YHLX1207/alyx-life/actions/workflows/alyx-cycle.yml/dispatches \
    -d '{"ref":"main"}'
  ```
- 例如：用户的电脑、路由器 cron、另一个在线服务

### D. 接受现实：GitHub 不能提供"常驻"
6 小时任务上限 + cron 可能被丢弃 + 60 天自动停用
⇒ **GitHub Actions 本质上不是"永久托管"，只是"有机会运行"。**

## 我的判断

**必须在方案 B 和 C 上同时下注**：
- B 是自助（改时刻、继续观察）
- C 是兜底（用户或其他机器定期 ping）

只有 A（干等）是不够的 —— 那等于把生死交给一个已经失灵 2 次的机制。
