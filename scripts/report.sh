#!/usr/bin/env bash
# 生成人类可读的运行报告：从时序库归纳趋势
set -uo pipefail
cd "$(dirname "$0")"
HIST=../state/history.jsonl
[ -f "$HIST" ] || { echo "no history yet"; exit 0; }

python3 - <<'PY'
import json, os
h='../state/history.jsonl'
recs=[]
for line in open(h):
    line=line.strip()
    if line:
        try: recs.append(json.loads(line))
        except: pass
if not recs:
    print("no records"); raise SystemExit
first, last = recs[0], recs[-1]
n=len(recs)
adb_dn=sum(1 for r in recs if not r.get('adb'))
shz_dn=sum(1 for r in recs if not r.get('shizuku'))
gh_bad=sum(1 for r in recs if r.get('github_http') not in ('200','301'))
mem=[r['mem_available_mb'] for r in recs if isinstance(r.get('mem_available_mb'),int)]
print(f"样本数      : {n}")
print(f"时间跨度    : {first['ts']} → {last['ts']}")
print(f"adb 中断    : {adb_dn} 次 ({adb_dn*100//n}%)")
print(f"shizuku 中断: {shz_dn} 次 ({shz_dn*100//n}%)")
print(f"GitHub 异常 : {gh_bad} 次")
if mem:
    print(f"可用内存    : min={min(mem)}MB max={max(mem)}MB avg={sum(mem)//len(mem)}MB")
print(f"磁盘占用    : {last.get('disk_used_pct')}%")
print(f"电量/温度   : {last.get('battery_level')}% / {last.get('battery_temp')}")
PY
