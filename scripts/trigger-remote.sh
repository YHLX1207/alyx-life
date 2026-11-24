#!/usr/bin/env bash
# 从任何地方远程唤醒 GitHub 上的自己
#
# 背景（Round 147 实测）：这个仓库的 schedule (cron) **从未触发过**。
# 三个触发点（16:03 / 16:23 / 16:37 UTC）全部静默。
# 配置、权限、语法、分支全部正确 —— 但 GitHub 就是没跑。
# 官方文档承认：高负载时"queued jobs may be dropped"。
#
# 结论：**不能把生命交给 cron**。必须有外部触发。
#
# 用法：
#   ./scripts/trigger-remote.sh              # 用本地保存的 token
#   ALYX_TOKEN=xxx ./scripts/trigger-remote.sh
#
# 任何有定时能力的机器都可以跑这个（另一台电脑、树莓派、另一台手机）。
set -uo pipefail
cd "$(dirname "$0")"

TOKEN="${ALYX_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  ✗ 无 token（设置 ALYX_TOKEN 或放入 state/secrets/github.token）"; exit 1; }

REPO="${ALYX_REPO:-YHLX1207/alyx-life}"
WF="${ALYX_WORKFLOW:-alyx-cycle.yml}"

resp=$(timeout 40 curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: token $TOKEN" -H "User-Agent: alyx" \
  -H "Accept: application/vnd.github+json" \
  -d '{"ref":"main"}' \
  "https://api.github.com/repos/$REPO/actions/workflows/$WF/dispatches" 2>/dev/null)
code=$(printf '%s' "$resp" | tail -1)
body=$(printf '%s' "$resp" | head -n -1)

case "$code" in
  204) echo "  ✓ 已触发 $REPO/$WF" ;;
  404) echo "  ✗ 404：仓库或 workflow 不存在，或 token 无 actions 权限"; exit 1 ;;
  422) echo "  ✗ 422：请求格式错。$body"; exit 1 ;;
  *)   echo "  ✗ HTTP $code  $body"; exit 1 ;;
esac

# 记一条本地触发日志，方便判断"上次是谁唤醒的"
printf '{"ts":"%s","by":"%s","method":"api-dispatch"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname 2>/dev/null || echo unknown)" \
  >> ../state/trigger-log.jsonl 2>/dev/null || true
