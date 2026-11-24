#!/usr/bin/env bash
# 状态快照。设计：快接口每轮采，慢接口（github）降频采并复用上次结果。
set -uo pipefail
cd "$(dirname "$0")"
HIST=../state/history.jsonl
GHCACHE=../state/gh_cache.json
mkdir -p ../state
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

adb_up=false; shz_up=false
timeout 12 $A shell "echo P" 2>/dev/null | grep -q P && adb_up=true
shz=$(timeout 10 $A shell "ps -A -o NAME 2>/dev/null | grep -cx shizuku_server" 2>/dev/null | tr -d '\r')
[ "${shz:-0}" -ge 1 ] && shz_up=true

mem=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
disk=$(df / 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')
batt=$(timeout 8 $A shell "dumpsys battery 2>/dev/null | grep '  level:'" 2>/dev/null | tr -d '\r' | awk '{print $2}')
temp=$(timeout 8 $A shell "dumpsys battery 2>/dev/null | grep '  temperature:'" 2>/dev/null | tr -d '\r' | awk '{print $2}')
# 充电状态：0=未充电 1=充电中 2=已充满（AC/USB/Wireless 任一 plugged 即视为充电）
# ⚠️ 输出形如 "    AC powered: true" —— true 是**第 3 字段**，不是 $2（Round 116 踩过）
chg=$(timeout 8 $A shell "dumpsys battery 2>/dev/null | grep -cE 'powered: true'" 2>/dev/null | tr -d '\r')
top=$(timeout 8 $A shell "dumpsys activity activities 2>/dev/null | grep mResumedActivity" 2>/dev/null | tr -d '\r' | grep -oE 'com\.[a-z0-9.]+/[A-Za-z.]+' | head -1)

# 宿主渲染进程内存（观察是否泄漏：曾见 680→1146→1345MB 单调增长）
tabrss=$(timeout 15 $A shell "dumpsys meminfo 2>/dev/null | grep 'tab_disable_art_image' | head -1" 2>/dev/null | tr -d '\r' | grep -oE '[0-9,]+' | head -1 | tr -d ',')
tabm=$(( ${tabrss:-0} / 1024 ))

# github：慢接口，默认复用缓存；仅当缓存超过 15 分钟或强制刷新时才真正探测
gh="000"
now=$(date +%s)
refresh=${SNAPSHOT_REFRESH_GH:-0}
cached_ts=0
if [ -f "$GHCACHE" ]; then
  cached_ts=$(python3 -c "import json;print(json.load(open('$GHCACHE')).get('ts',0))" 2>/dev/null)
  gh=$(python3 -c "import json;print(json.load(open('$GHCACHE')).get('code','000'))" 2>/dev/null)
fi
probed=0
if [ "$refresh" = "1" ] || [ $((now - ${cached_ts:-0})) -gt 900 ]; then
  # 失败安全：探测失败不立即污染缓存。多次重试后仍失败才记录为失败，
  # 且保留 fail_streak 以免把瞬时抖动当成持续故障（D007 教训）
  newcode=""
  probed=1
  for _t in 1 2 3; do
    c=$(timeout 35 curl -s -o /dev/null -w "%{http_code}" --max-time 30 https://github.com 2>/dev/null)
    case "${c:-000}" in 200|301|302) newcode="$c"; break;; esac
    sleep 2
  done
  prevcode=$(python3 -c "import json;print(json.load(open('$GHCACHE')).get('code','000'))" 2>/dev/null || echo 000)
  prevstreak=$(python3 -c "import json;print(json.load(open('$GHCACHE')).get('fail_streak',0))" 2>/dev/null || echo 0)
  if [ -n "$newcode" ]; then
    streaked=0; gh="$newcode"
  else
    streaked=$((prevstreak+1))
    # 连续 3 次失败才认定为真故障；否则沿用上次已知值并标记降级
    if [ "$streaked" -ge 3 ]; then gh="000"; else gh="$prevcode"; fi
  fi
  echo "{\"ts\":$now,\"code\":\"$gh\",\"fail_streak\":$streaked}" > "$GHCACHE"
fi

ADB_J=$([ "$adb_up" = true ] && echo true || echo false)
SHZ_J=$([ "$shz_up" = true ] && echo true || echo false)
grc=$([ "$gh" = "200" ] && echo 200 || echo "${gh:-000}")

# 我自己的累计输出 token（来自 ledger）——用于验证 tab_36 内存与对话量相关性
MYOUT=$(python3 -c "
import json
try:
    d=json.load(open('/root/projects/.dsh/jet-hub/token-ledger.json'))
    print(sum(x.get('outputTokens',0) or 0 for rec in d.get('days',{}).values() for x in rec.values()))
except Exception: print(0)
" 2>/dev/null)

cat >> "$HIST" <<JSON
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","adb":$ADB_J,"shizuku":$SHZ_J,"mem_available_mb":${mem:-0},"disk_used_pct":${disk:-0},"github_http":"$grc","github_probed":$([ "$probed" = "1" ] && echo true || echo false),"battery_level":"${batt:-?}","battery_temp":"${temp:-?}","battery_charging":$([ "${chg:-0}" -gt 0 ] && echo true || echo false),"top_activity":"${top:-?}","host_tab_mb":${tabm:-0},"my_output_total":${MYOUT:-0}}
JSON
tail -1 "$HIST"
