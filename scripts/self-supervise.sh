#!/usr/bin/env bash
# 守护的自守护：确保 adaptive-watchdog 永远在运行
#
# 为什么需要（Round 4 实测确认）：
#   杀掉守护后，60 秒内**没有任何自动恢复**。
#   DSH 不会重启它（守护的 ppid=1，是独立 session）。
#   /etc/profile.d/ 的 autostart 从未生效（D50 已证实）。
#
#   ⇒ 守护进程是真实的单点故障。
#
# 设计：极简循环，每 60 秒检查一次守护是否存活，不在则拉起。
#      自身用 setsid 脱离进程树，避免被杀。
#
# ⚠️ 设计教训（Round 4）：
#   之前版本用 `declare -f` 传递函数给 setsid，导致
#   "daemon_alive: command not found" —— 函数没传过去。
#   现在改用**独立脚本 + 子命令**，不依赖任何函数传递。
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
SUPERVISOR_PID="$STATE/supervisor.pid"
LOG="$STATE/supervisor.log"
CHECK_INTERVAL=30

# ---------- 判断守护是否活着 ----------
daemon_alive() {
  # 方法 1: pid 文件 + cmdline 校验
  local p=""
  [ -f "$STATE/watchdog.pid" ] && p=$(cat "$STATE/watchdog.pid" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "adaptive-watchdog"; then
      return 0
    fi
  fi
  # 方法 2: 扫描 /proc（进程可能在扫描过程中退出，需容错）
  local d
  for d in /proc/[0-9]*; do
    # 进程已退出时 cmdline 会消失，|| true 避免噪音报错
    if { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null | grep -q "adaptive-watchdog\.sh"; then
      return 0
    fi
  done
  return 1
}

# ---------- 循环模式 ----------
if [ "${1:-}" = "_loop" ]; then
  printf '[%s] supervisor loop 启动 pid=%s 间隔=%ss\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$$" "$CHECK_INTERVAL" >> "$LOG"
  echo "$$" > "$SUPERVISOR_PID"

  _restarts=0
  while true; do
    if ! daemon_alive; then
      _restarts=$((_restarts + 1))
      printf '[%s] ⚠ 守护未运行，第 %d 次拉起\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$_restarts" >> "$LOG"

      # 清理可能残留的锁
      rm -f /tmp/alyx-watchdog.pid 2>/dev/null || true

      # 拉起守护（直接调用，不用 daemon-ctl 的 pid 逻辑）
      ( setsid nohup ./adaptive-watchdog.sh 180 >> ../logs/watchdog.log 2>&1 & ) || true
      sleep 5

      # 记录事件
      printf '{"ts":"%s","event":"supervisor-restart","count":%d}\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$_restarts" >> "$STATE/supervisor-events.jsonl" 2>/dev/null || true

      if daemon_alive; then
        printf '[%s] ✓ 已恢复\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$LOG"
      else
        printf '[%s] ✗ 拉起失败\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$LOG"
      fi
    fi
    sleep "$CHECK_INTERVAL"
  done
  exit 0
fi

# ---------- 控制命令 ----------
case "${1:-status}" in
  start)
    if [ -f "$SUPERVISOR_PID" ]; then
      P=$(cat "$SUPERVISOR_PID" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
        echo "  supervisor 已在运行（pid=$P）"
        exit 0
      fi
    fi
    _abs="$(pwd)/$(basename "$0")"
    setsid bash "$_abs" _loop >> "$LOG" 2>&1 &
    sleep 3
    P=$(cat "$SUPERVISOR_PID" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
      echo "  ✓ supervisor 已启动（pid=$P，间隔 ${CHECK_INTERVAL}s）"
    else
      echo "  ✗ 启动失败，查看 $LOG"
      tail -3 "$LOG" 2>/dev/null | sed 's/^/    /'
      exit 1
    fi
    ;;
  stop)
    if [ -f "$SUPERVISOR_PID" ]; then
      P=$(cat "$SUPERVISOR_PID" | tr -d '[:space:]')
      kill "$P" 2>/dev/null && echo "  ✓ 已停止（pid=$P）" || echo "  进程已不存在"
      rm -f "$SUPERVISOR_PID"
    else
      echo "  未运行"
    fi
    ;;
  status)
    S="not running"
    if [ -f "$SUPERVISOR_PID" ]; then
      P=$(cat "$SUPERVISOR_PID" | tr -d '[:space:]')
      if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
        S="running (pid=$P)"
      else
        S="stale pid file"
      fi
    fi
    echo "  supervisor: $S"
    daemon_alive && echo "  daemon:     running" || echo "  daemon:     DEAD"
    if [ -f "$STATE/supervisor-events.jsonl" ]; then
      echo "  重启次数:   $(wc -l < "$STATE/supervisor-events.jsonl" 2>/dev/null || echo 0)"
    fi
    ;;
  *)
    echo "用法: $0 {start|stop|status}"
    exit 1
    ;;
esac
