#!/usr/bin/env bash
# 日志轮转：防止 watchdog.log 无限增长
#
# 为什么需要（Round 187）：
#   watchdog.log 积累到 770 行，其中 114 条是已修复问题的历史噪音。
#   噪音会淹没真问题 —— 而"找不到真失败"比"没有日志"更危险。
#
# 策略：
#   · 主日志超过 MAX 行时，把旧的部分移到归档文件
#   · 归档文件按日期命名，最多保留 KEEP 个
set -uo pipefail
cd "$(dirname "$0")"

LOG=../logs/watchdog.log
MAX="${1:-2000}"
KEEP="${2:-3}"

[ -f "$LOG" ] || { echo "  无日志，跳过"; exit 0; }

_lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
if [ "${_lines:-0}" -le "$MAX" ]; then
  echo "  日志 $_lines 行（上限 $MAX），无需轮转"
  exit 0
fi

_archive="../logs/watchdog-$(date -u +%Y%m%d).log"
_keep=$(( _lines - MAX ))

# 把前 _keep 行移到归档
head -n "$_keep" "$LOG" >> "$_archive" 2>/dev/null || { echo "  ✗ 归档失败"; exit 1; }
tail -n "$MAX" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"

echo "  已归档 $_keep 行 → $(basename "$_archive")，保留 $MAX 行"

# 清理过旧的归档，只留最近 KEEP 个
_ls=$(ls -1t ../logs/watchdog-20*.log 2>/dev/null | tail -n +$((KEEP+1)))
if [ -n "$_ls" ]; then
  echo "$_ls" | while read -r f; do
    [ -n "$f" ] && rm -f "$f" && echo "    已清理旧归档: $(basename "$f")"
  done
fi
