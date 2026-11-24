#!/usr/bin/env bash
# 统一状态视图 —— 一眼看全"我是谁、我是否健康、我最近在做什么"
set -uo pipefail
cd "$(dirname "$0")"
source ./identity.sh
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

hr() { printf '%s\n' "────────────────────────────────────────────────"; }
kv() { printf '  %-14s %s\n' "$1" "$2"; }

echo
echo "  $ALYX_REF —— 状态总览"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)  (UTC)"
hr

# 身份
if [ -f ../state/identity.json ]; then
  python3 -c "
import json
d=json.load(open('../state/identity.json'))
print('  %-14s %s' % ('系统代号', d.get('codename','?')))
print('  %-14s %s' % ('名字', d.get('name','?')))
print('  %-14s %s' % ('原则', '%d 条' % len(d.get('principles',[]))))
"
fi
dcount=$(grep -c '^## D' ../state/decisions.md 2>/dev/null || echo 0)
kv "决策记录" "$dcount 条"
kv "脚本" "$(ls *.sh 2>/dev/null | wc -l) 个"
hr

# 守护
if [ -f ../state/watchdog.pid ] && kill -0 "$(cat ../state/watchdog.pid)" 2>/dev/null; then
  p=$(cat ../state/watchdog.pid)
  et=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')
  cmd=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | awk '{print $2}')
  kv "守护" "运行中 pid=$p 已运行 $et"
  kv "  实现" "$(basename "${cmd:-?}")"
else
  kv "守护" "未运行"
fi
hr

# 身体
if timeout 12 $A shell "echo P" 2>/dev/null | grep -q P; then
  id=$(timeout 10 $A shell id 2>/dev/null | tr -d '\r' | grep -o 'uid=[0-9]*([a-z]*)')
  kv "adb" "✓ $id"
  shz=$(timeout 10 $A shell "ps -A -o NAME 2>/dev/null | grep -cx shizuku_server" 2>/dev/null | tr -d '\r')
  kv "Shizuku" "$([ "${shz:-0}" -ge 1 ] && echo '✓ 运行中' || echo '✗ 未运行')"
  batt=$(timeout 10 $A shell "dumpsys battery 2>/dev/null | grep '  level:'" 2>/dev/null | tr -d '\r' | awk '{print $2}')
  kv "电量" "${batt:-?}%"
else
  kv "adb" "✗ 不可用"
fi
kv "内存可用" "$(awk '/MemAvailable/{printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null)"
kv "磁盘占用" "$(df / 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5"%"}')"
hr

# 网络
gh=$(timeout 20 curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://github.com 2>/dev/null)
kv "github.com" "$([ "$gh" = "200" ] && echo '✓ 可达' || echo "✗ $gh")"
n=$(awk '/^[0-9]/{if($2=="github.com")c++}END{print c+0}' /etc/hosts 2>/dev/null)
kv "hosts 固定" "$n 个 IP（故障转移）"
hr

# 最近轨迹
if [ -f ../state/history.jsonl ]; then
  echo "  最近 5 次快照:"
  tail -5 ../state/history.jsonl | python3 -c "
import sys,json
for l in sys.stdin:
    try:
        d=json.loads(l)
        print('    %s  adb=%s shz=%s mem=%sMB gh=%s' % (
            d['ts'][11:19],
            '✓' if d.get('adb') else '✗',
            '✓' if d.get('shizuku') else '✗',
            d.get('mem_available_mb','?'),
            d.get('github_http','?')))
    except: pass
"
  kv "累计快照" "$(wc -l < ../state/history.jsonl) 条"
  # 近期回归失败（可追溯瞬时故障，Round 75）
  if [ -f ../state/verify-failures.jsonl ]; then
    _rf=$(wc -l < ../state/verify-failures.jsonl)
    _last=$(tail -1 ../state/verify-failures.jsonl 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); print(d.get('ts','')[11:19]+' '+d.get('check',''))
except Exception: print('')
" 2>/dev/null)
    kv "回归失败记录" "${_rf} 条（最近: ${_last:-无}）"
  else
    kv "回归失败记录" "无（从未失败）"
  fi
  # 守护存活探测：若最近一条快照过旧，说明守护可能已中断（无需外部监控）
  _age=$(python3 -c "
import json,datetime,sys
try:
    lines=[l for l in open('../state/history.jsonl') if l.strip()]
    last=json.loads(lines[-1])['ts']
    t=datetime.datetime.strptime(last,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()))
except Exception: print(-1)
" 2>/dev/null)
  if [ "${_age:-(-1)}" -lt 0 ]; then
    kv "守护心跳" "无法判断"
  else
    # ⚠️ 双判据：快照新鲜 ≠ 守护活着（Round 128 实测：杀守护后 10 分钟内仍显示 ✓）。
    #    必须同时确认进程存在，否则会出现"守护未运行 + 心跳 ✓"的自相矛盾。
    _wp=$(cat ../state/watchdog.pid 2>/dev/null)
    _alive=0
    if [ -n "${_wp:-}" ] && [ -r "/proc/$_wp/cmdline" ] && tr '\0' ' ' < "/proc/$_wp/cmdline" 2>/dev/null | grep -q adaptive-watchdog; then
      _alive=1
    fi
    if [ "$_alive" -eq 0 ]; then
      kv "守护心跳" "✗ 进程已死（快照停在 $((_age/60)) 分钟前）"
    elif [ "$_age" -lt 600 ]; then
      kv "守护心跳" "✓ 存活，上次快照 $((_age/60)) 分钟前"
    else
      kv "守护心跳" "⚠ 进程在但快照 $((_age/60)) 分钟前（可能卡住）"
    fi
  fi
fi
hr

# 自保
local_md5=$(md5sum ../state/self-export.md 2>/dev/null | awk '{print $1}')
remote_md5=$(timeout 15 $A shell "md5sum $ALYX_REDUNDANT_DIR/self-export.md 2>/dev/null" 2>/dev/null | tr -d '\r' | awk '{print $1}')
if [ -n "$local_md5" ] && [ "$local_md5" = "$remote_md5" ]; then
  kv "自我备份" "✓ 本地与 /sdcard 一致"
elif [ -n "$local_md5" ]; then
  kv "自我备份" "⚠ 本地有、远端缺失或不一致"
else
  kv "自我备份" "✗ 无本地副本"
fi
echo
