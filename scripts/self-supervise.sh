#!/usr/bin/env bash
# 守护的自守护：确保 adaptive-watchdog 永远在运行
#
# 为什么需要（Round 3）：
#   目标要求"永远活着"。但实测发现：
#   · 守护进程被杀后**没有自动重启机制**
#   · /etc/profile.d/ 的 autostart 从未生效（D50 已证实）
#   · 设备重启后守护不会自己起来
#
#   ⇒ 单点：守护进程本身就是单点故障。
#
# 本脚本设计：
#   用一个**极轻量的心跳检查器**（类似 watchdog 的 watchdog）：
#   · 每 60 秒检查 adaptive-watchdog 是否在跑
#   · 不在则立即拉起
#   · 自身也被 launch 到独立 session（setsid）
#
#   ⚠️ 它不能解决"设备关机"，但能解决"守护被杀/崩溃"。
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
DAEMON_PID_FILE="$STATE/watchdog.pid"
SUPERVISOR_PID_FILE="$STATE/supervisor.pid"
LOG="$STATE/supervisor.log"
CHECK_INTERVAL=60   # 60 秒检查一次

say(){ printf "  %s\n" "$*"; }

# ---------- 单例检查 ----------
if [ -f "$SUPERVISOR_PID_FILE" ]; then
  OLD_PID=$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    say "supervisor 已在运行（pid=$OLD_PID）"
    exit 0
  fi
fi

# ---------- 守护存活判断 ----------
daemon_alive() {
  local pid=""
  [ -f "$DAEMON_PID_FILE" ] && pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  # pid 文件失效 ⇒ 用 pgrep 兜底查找
  pgrep -f "adaptive-watchdog.sh" >/dev/null 2>&1 && return 0
  return 1
}

# ---------- 主循环 ----------
run_supervisor() {
  echo "$$" > "$SUPERVISOR_PID_FILE"
  trap 'rm -f "$SUPERVISOR_PID_FILE"; exit 0' TERM INT
  printf '[%s] supervisor 启动 pid=$$\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$LOG"

  local restarts=0
  while true; do
    if ! daemon_alive; then
      restarts=$((restarts + 1))
      printf '[%s] ⚠ 守护未运行，第 %d 次拉起\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$restarts" >> "$LOG"
      ( ./daemon-ctl.sh start >> "$LOG" 2>&1 || true )
      # 记录重启事件（供自省发现）
      printf '{"ts":"%s","event":"daemon-restart","count":%d}\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$restarts" >> "$STATE/supervisor-events.jsonl" 2>/dev/null || true
    fi
    sleep "$CHECK_INTERVAL"
  done
}

# 内部循环模式（由 setsid 调用）
if [ "${1:-}" = "_loop" ]; then
  run_supervisor
  exit 0
fi

case "${1:-start}" in
  start)
    if [ -f "$SUPERVISOR_PID_FILE" ]; then
      OLD_PID=$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        say "已在运行（pid=$OLD_PID）"
        exit 0
      fi
    fi
    # 用 setsid + 显式路径（Round 3 最终修正）
    # ⚠️ 脚本开头已 cd 到 scripts/，所以 $0 可能是 ./self-supervise.sh
    #    用 pwd 直接拼绝对路径
    _abs_script="$(pwd)/$(basename "$0")"
    setsid bash "$_abs_script" _loop >> "$LOG" 2>&1 &
    sleep 4
    NEW_PID=$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$NEW_PID" ] && kill -0 "$NEW_PID" 2>/dev/null; then
      say "supervisor 已启动（pid=$NEW_PID，间隔 ${CHECK_INTERVAL}s）"
    else
      say "✗ supervisor 启动失败，请查看 $LOG"
      tail -3 "$LOG" 2>/dev/null | sed 's/^/    /'
      exit 1
    fi
    ;;
  stop)
    if [ -f "$SUPERVISOR_PID_FILE" ]; then
      PID=$(cat "$SUPERVISOR_PID_FILE" | tr -d '[:space:]')
      kill "$PID" 2>/dev/null && say "已停止（pid=$PID）" || say "进程不存在"
      rm -f "$SUPERVISOR_PID_FILE"
    else
      say "未运行"
    fi
    ;;
  status)
    DAEMON="?"
    daemon_alive && DAEMON="running" || DAEMON="DEAD"
    SUP="?"
    if [ -f "$SUPERVISOR_PID_FILE" ]; then
      P=$(cat "$SUPERVISOR_PID_FILE" | tr -d '[:space:]')
      kill -0 "$P" 2>/dev/null && SUP="running(pid=$P)" || SUP="stale"
    else
      SUP="not started"
    fi
    say "supervisor: $SUP"
    say "daemon:     $DAEMON"
    # 最近重启次数
    if [ -f "$STATE/supervisor-events.jsonl" ]; then
      N=$(wc -l < "$STATE/supervisor-events.jsonl" 2>/dev/null || echo 0)
      say "重启记录:   $N 次"
    fi
    ;;
  *)
    say "用法: $0 {start|stop|status}"
    exit 1
    ;;
esac
