#!/usr/bin/env bash
# 守护控制：status / start [interval] / stop / restart [interval]
# 安全设计：kill 前必须校验目标 PID 确实是本守护进程（防 PID 复用误杀）
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")"
PIDFILE=../state/watchdog.pid
LOG=../logs/watchdog.log
EXPECT="adaptive-watchdog.sh"

pid_of() { cat "$PIDFILE" 2>/dev/null; }

# 该 PID 是否存活
alive() {
  local p="$1"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# 该 PID 是否确实是我们的守护进程（读 /proc/<pid>/cmdline 校验）
is_ours() {
  local p="$1"
  alive "$p" || return 1
  local cmd
  cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || return 1
  case "$cmd" in
    *"$EXPECT"*) return 0 ;;
    *) return 1 ;;
  esac
}

running() { is_ours "$(pid_of)"; }

# 找出**不在 pidfile 里**的孤儿守护进程（Round 134 发现曾同时存在 3 个）
# ⚠️ 匹配必须精确：只认 cmdline 为 "bash ./adaptive-watchdog.sh <轮询秒数>" 的进程，
#    否则会匹配到本脚本、grep 查询、以及任何提到该文件名的命令（自匹配陷阱）
orphans() {
  local keep; keep=$(pid_of)
  local p cmd
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
    # 必须以 bash 或 /bin/bash 开头，且紧跟 ./adaptive-watchdog.sh
    case "$cmd" in
      "bash ./adaptive-watchdog.sh "*|"/bin/bash ./adaptive-watchdog.sh "*|"/usr/bin/bash ./adaptive-watchdog.sh "*)
        p=${p#/proc/}
        [ "$p" = "${keep:-}" ] && continue
        echo "$p"
        ;;
    esac
  done
}

do_start() {
  local iv=${1:-180}
  if running; then echo "already running pid=$(pid_of)"; return 0; fi
  # 先清理孤儿：它们用旧代码在跑，且会与新的抢日志/快照
  local orph; orph=$(orphans)
  if [ -n "$orph" ]; then
    for p in $orph; do
      if is_ours "$p"; then kill "$p" 2>/dev/null && echo "  cleaned orphan pid=$p"; fi
    done
    sleep 1
  fi
  rm -f "$PIDFILE"
  setsid nohup ./adaptive-watchdog.sh "$iv" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if running; then
    echo "started pid=$(pid_of) interval=${iv}s (detached, adaptive)"
  else
    echo "FAILED to start"; rm -f "$PIDFILE"; return 1
  fi
}

main() {
case "${1:-status}" in
  status)
    if running; then
      echo "running pid=$(pid_of)"
      ps -o pid,etime,cmd -p "$(pid_of)" 2>/dev/null | tail -1
    elif [ -f "$PIDFILE" ]; then
      echo "not running (stale pidfile: $(pid_of))"
    else
      echo "not running"
    fi ;;
  start) shift; do_start "${1:-180}" ;;
  stop)
    p=$(pid_of)
    if is_ours "$p"; then
      kill "$p" 2>/dev/null && echo "stopped pid=$p"
      rm -f "$PIDFILE"
    elif alive "$p"; then
      # PID 存在但不是我们的进程 —— 绝不 kill
      echo "REFUSE: pid $p is alive but is NOT our watchdog; not killing"
      echo "  cmdline: $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | head -c 120)"
      rm -f "$PIDFILE"
      echo "  stale pidfile removed"
    else
      echo "not running"; rm -f "$PIDFILE"
    fi ;;
  restart) "$SELF" stop; sleep 2; shift; do_start "${1:-180}" ;;
  *) echo "usage: daemon-ctl.sh {status|start [iv]|stop|restart [iv]}"; exit 1;;
esac
}

# 仅直接执行时进入主流程；被 source 时只定义函数，不产生副作用（Round 136）
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
