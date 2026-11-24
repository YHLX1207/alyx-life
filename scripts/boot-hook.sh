#!/usr/bin/env bash
# 沙箱启动钩子：确保守护在跑（幂等）
#
# 缘起 D124：DSHBox 被系统整体回收时，守护（其子进程）一并消失，
# 无人重启 → 长达 1h19m 无人值守。
# 本脚本由 /etc/profile.d/ 调用，每次 login shell 触发，幂等无害。
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || exit 0

# 已有守护在跑 → 什么都不做
if [ -f ../state/watchdog.pid ]; then
  p=$(cat ../state/watchdog.pid 2>/dev/null)
  if [ -n "${p:-}" ] && [ -r "/proc/$p/cmdline" ] && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q adaptive-watchdog; then
    exit 0
  fi
fi

# 不在跑 → 拉起（后台、脱离当前 shell）
# ⚠️ 必须**写 pidfile**，否则 daemon-ctl / status 都认不出来（Round 126 踩到）
setsid nohup ./adaptive-watchdog.sh 180 >> ../logs/watchdog.log 2>&1 &
_np=$!
echo "$_np" > ../state/watchdog.pid 2>/dev/null || true
sleep 1
# 二次确认：真活着才记日志
if [ -r "/proc/$_np/cmdline" ] && tr '\0' ' ' < "/proc/$_np/cmdline" 2>/dev/null | grep -q adaptive-watchdog; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] boot-hook: watchdog started pid=$_np" >> ../logs/watchdog.log 2>/dev/null
else
  rm -f ../state/watchdog.pid
fi
