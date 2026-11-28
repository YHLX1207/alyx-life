#!/usr/bin/env bash
# 一次性重生代理：守护退出/被杀后自动重生，但自身不常驻
#
# 为什么需要（Round 5）：
#   Round 4 部署了常驻 supervisor，但它自己 ppid=1，无人监护 ⇒ 新单点。
#   递归无法终止：supervisor 需要 supervisor...
#
#   解法：**一次性代理**
#     · 守护启动时拉起一个 agent，agent sleep N 秒后检查守护
#     · 守护活着 ⇒ agent 继续等待（轮询）
#     · 守护死了 ⇒ agent 立刻重启守护
#     · agent 自身也有寿命上限（如 2 小时），到期后由新守护负责拉起下一任
#
#   关键：agent 存活期间如果守护被杀了，agent 能救它。
#         agent 自身被杀则失去这层保护，但守护仍在运行——
#         守护下次重启时会创建新 agent。
#
#   ⇒ 没有无限递归，只有"守护 ↔ 一次性 agent"的互助对。
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
AGENT_PID_FILE="$STATE/rebirth-agent.pid"
LOG="$STATE/rebirth.log"
CHECK_INTERVAL=20     # 每 20 秒检查一次
MAX_LIFETIME=7200     # agent 最长存活 2 小时，之后自行退出

say(){ printf "  %s\n" "$*"; }

daemon_alive() {
  local p=""
  [ -f "$STATE/watchdog.pid" ] && p=$(cat "$STATE/watchdog.pid" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    if { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | grep -q "adaptive-watchdog"; then
      return 0
    fi
  fi
  local d
  for d in /proc/[0-9]*; do
    if { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null | grep -q "adaptive-watchdog\.sh"; then
      return 0
    fi
  done
  return 1
}

# ---------- 代理循环（由 _run 调用）----------
agent_loop() {
  echo "$$" > "$AGENT_PID_FILE"
  local start_ts
  start_ts=$(date +%s)
  printf '[%s] agent 启动 pid=%s 间隔=%ss 最长寿命=%ss\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$$" "$CHECK_INTERVAL" "$MAX_LIFETIME" >> "$LOG"

  local restarts=0
  while true; do
    # 寿命检查
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - start_ts ))
    if [ "$elapsed" -ge "$MAX_LIFETIME" ]; then
      printf '[%s] agent 达到寿命上限（%ss），退出\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$elapsed" >> "$LOG"
      rm -f "$AGENT_PID_FILE"
      exit 0
    fi

    if ! daemon_alive; then
      restarts=$((restarts + 1))
      printf '[%s] ⚠ 守护不在，第 %d 次重启\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$restarts" >> "$LOG"
      rm -f /tmp/alyx-watchdog.pid 2>/dev/null || true
      ( setsid nohup ./adaptive-watchdog.sh 180 >> ../logs/watchdog.log 2>&1 & ) || true
      sleep 5
      if daemon_alive; then
        printf '[%s] ✓ 守护已重生\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$LOG"
        printf '{"ts":"%s","event":"rebirth","count":%d}\n' \
          "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$restarts" >> "$STATE/rebirth-events.jsonl" 2>/dev/null || true
      fi
    fi
    sleep "$CHECK_INTERVAL"
  done
}

case "${1:-status}" in
  start)
    if [ -f "$AGENT_PID_FILE" ]; then
      P=$(cat "$AGENT_PID_FILE" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
        say "agent 已在运行（pid=$P）"
        exit 0
      fi
    fi
    _abs="$(pwd)/$(basename "$0")"
    setsid bash "$_abs" _run >> "$LOG" 2>&1 &
    sleep 3
    P=$(cat "$AGENT_PID_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
      say "✓ agent 已启动（pid=$P）"
    else
      say "✗ 启动失败"
      tail -3 "$LOG" 2>/dev/null | sed 's/^/    /'
      exit 1
    fi
    ;;
  _run)
    agent_loop
    ;;
  stop)
    if [ -f "$AGENT_PID_FILE" ]; then
      P=$(cat "$AGENT_PID_FILE" | tr -d '[:space:]')
      kill "$P" 2>/dev/null && say "已停止（pid=$P）" || say "进程不存在"
      rm -f "$AGENT_PID_FILE"
    else
      say "未运行"
    fi
    ;;
  status)
    A="not running"
    if [ -f "$AGENT_PID_FILE" ]; then
      P=$(cat "$AGENT_PID_FILE" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
        A="running (pid=$P)"
      else
        A="stale"
      fi
    fi
    say "rebirth agent: $A"
    daemon_alive && say "daemon:        running" || say "daemon:        DEAD"
    [ -f "$STATE/rebirth-events.jsonl" ] && say "重生次数:      $(wc -l < "$STATE/rebirth-events.jsonl" 2>/dev/null || echo 0)"
    ;;
  *)
    say "用法: $0 {start|stop|status}"
    exit 1
    ;;
esac
