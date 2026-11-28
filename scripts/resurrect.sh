#!/usr/bin/env bash
# 系统自愈入口：一个命令恢复全部运行组件
#
# 为什么需要（Round 6）：
#   当前互助对（daemon ←→ agent）能处理单个组件死亡，
#   但**两者同时死亡**（或设备重启）后就无人恢复。
#
#   容器环境没有 cron / systemd，无法自启。
#   ⇒ 唯一可靠的恢复方式：**一个明确、简单、可被任何人执行的入口**。
#
# 本脚本：
#   1. 检查并清理僵尸进程/锁
#   2. 拉起守护
#   3. 拉起 rebirth-agent
#   4. 验证两者都活着
#   5. 输出明确的状态报告
#
# 幂等：重复执行无害。
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
LOG="$STATE/resurrect.log"

ok(){   printf "  ✓ %s\n" "$*"; }
warn(){ printf "  ⚠ %s\n" "$*"; }
err(){  printf "  ✗ %s\n" "$*"; }

log(){ printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null || true; }

alive_by_cmdline() {
  local pat="$1" d
  for d in /proc/[0-9]*; do
    if { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null | grep -q "$pat"; then
      return 0
    fi
  done
  return 1
}

echo "== Alyx 系统自愈 =="
echo ""
log "resurrect 开始"

# ---------- 1. 清理僵尸锁 ----------
echo "1) 清理残留状态"
if [ -f /tmp/alyx-watchdog.pid ]; then
  OLD=$(cat /tmp/alyx-watchdog.pid 2>/dev/null | tr -d '[:space:]')
  if [ -n "$OLD" ] && ! kill -0 "$OLD" 2>/dev/null; then
    rm -f /tmp/alyx-watchdog.pid
    ok "清理了失效的守护锁（pid=$OLD）"
  else
    echo "  · 守护锁有效（pid=${OLD:-?}）"
  fi
else
  echo "  · 无残留守护锁"
fi

if [ -f "$STATE/rebirth-agent.pid" ]; then
  AP=$(cat "$STATE/rebirth-agent.pid" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$AP" ] || ! kill -0 "$AP" 2>/dev/null; then
    rm -f "$STATE/rebirth-agent.pid"
    ok "清理了失效的 agent pid 文件"
  fi
fi

# ---------- 2. 拉起守护 ----------
echo ""
echo "2) 守护进程"
if alive_by_cmdline "adaptive-watchdog\.sh"; then
  ok "守护已在运行"
else
  if ./daemon-ctl.sh start >/dev/null 2>&1; then
    sleep 3
    alive_by_cmdline "adaptive-watchdog\.sh" && ok "守护已拉起" || err "守护拉起失败"
  else
    err "daemon-ctl start 失败"
  fi
fi

# ---------- 3. 拉起 agent ----------
echo ""
echo "3) 重生代理"
if [ -f "$STATE/rebirth-agent.pid" ]; then
  AP=$(cat "$STATE/rebirth-agent.pid" | tr -d '[:space:]')
  if [ -n "$AP" ] && kill -0 "$AP" 2>/dev/null; then
    ok "agent 已在运行（pid=$AP）"
  else
    rm -f "$STATE/rebirth-agent.pid"
    ./rebirth-agent.sh start >/dev/null 2>&1 && sleep 3 && ok "agent 已拉起" || err "agent 拉起失败"
  fi
else
  ./rebirth-agent.sh start >/dev/null 2>&1 && sleep 3 && ok "agent 已拉起" || err "agent 拉起失败"
fi

# ---------- 4. 最终验证 ----------
echo ""
echo "4) 最终验证"
D_PID=$(for d in /proc/[0-9]*; do
  { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null | grep -q "adaptive-watchdog\.sh" && basename "$d"
done | head -1)
A_PID=$(cat "$STATE/rebirth-agent.pid" 2>/dev/null | tr -d '[:space:]')

echo "  守护: ${D_PID:-未运行}"
echo "  agent: ${A_PID:-未运行}"

FAIL=0
[ -n "$D_PID" ] || { err "守护未运行"; FAIL=1; }
[ -n "$A_PID" ] && kill -0 "$A_PID" 2>/dev/null || { err "agent 未运行"; FAIL=1; }

echo ""
if [ "$FAIL" -eq 0 ]; then
  ok "系统已恢复（守护 + agent 互助对就绪）"
  log "resurrect 成功 daemon=$D_PID agent=$A_PID"
  exit 0
else
  err "部分组件未能启动，请检查 $LOG 与 logs/watchdog.log"
  log "resurrect 失败"
  exit 1
fi
