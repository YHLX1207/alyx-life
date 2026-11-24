#!/usr/bin/env bash
# 环境健康自检 — 输出 JSON 摘要
set -uo pipefail
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

r_adb="down"; r_shizuku="down"; r_pilot="down"
adb_empty=$(timeout 8 adb devices 2>/dev/null | grep -c "127.0.0.1:5555.*device")
[ "$adb_empty" -ge 1 ] && r_adb="up"
adb_id=$(timeout 10 $A shell id 2>/dev/null | tr -d '\r' | head -1)
shz=$(timeout 10 $A shell "ps -A -o PID,NAME 2>/dev/null | grep -c shizuku_server" 2>/dev/null | tr -d '\r')
[ "${shz:-0}" -ge 1 ] && r_shizuku="up"
cap=$(timeout 15 /opt/pilot/bin/pilot capabilities 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);c=d.get('capabilities',[]);print(sum(1 for x in c if x.get('usable')))" 2>/dev/null)
[ -n "${cap:-}" ] && r_pilot="up"

memavail=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
dfpct=$(df -h / 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')
# github.com 实测中位 5-7s、峰值可达 20s。探测超时取 30s，
# 避免把「慢」误记为「断」（教训见 state/decisions.md D004）
gh=$(timeout 35 curl -s -o /dev/null -w "%{http_code}" --max-time 30 https://github.com 2>/dev/null)
gh=${gh:-000}

cat <<JSON
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "adb": {"status": "$r_adb", "identity": "${adb_id:-none}"},
  "shizuku": {"status": "$r_shizuku"},
  "pilot": {"status": "$r_pilot", "usable_capabilities": ${cap:-0}},
  "resources": {"mem_available_mb": ${memavail:-0}, "disk_used_pct": ${dfpct:-0}},
  "network": {"github_http": "${gh:-000}"}
}
JSON
