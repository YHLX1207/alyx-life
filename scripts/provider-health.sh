#!/usr/bin/env bash
# 供应商健康全景：33 家 provider 的实际状态（不只是主模型候选）
#
# 数据源：token-ledger（真实请求）+ state.json（账户/启用/限流）
# 判据：近 2 天流量证明"当前可用"；7 天错误率证明"质量"
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" <<'PY'
import json,sys,time
from collections import defaultdict
hub=sys.argv[1]; now=time.time()
led=json.load(open(hub+'/token-ledger.json'))
st=json.load(open(hub+'/state.json'))
days=sorted(led.get('days',{}).keys())

per=defaultdict(lambda: {'r7':0,'e7':0,'r2':0,'e2':0,'last':None})
for day in days:
    for k,v in led['days'][day].items():
        p=k.split('|')
        if len(p)<2: continue
        prov=p[1]; cnt=v.get('requests',0) or 0
        if day in days[-7:]:
            per[prov]['r7']+=cnt; per[prov]['e7']+=v.get('errors',0) or 0
        if day in days[-2:]:
            per[prov]['r2']+=cnt; per[prov]['e2']+=v.get('errors',0) or 0
        if cnt>0: per[prov]['last']=day

accs=defaultdict(lambda: {'n':0,'en':0})
for a in st.get('accounts',[]):
    p=a.get('provider','?'); accs[p]['n']+=1
    if a.get('enabled'): accs[p]['en']+=1

def tier(a):
    if a['r2']>0 and a['r7']>0:
        rate=a['e2']*100//a['r2'] if a['r2']>=20 else a['e7']*100//a['r7']
        if rate<5: return 'HEALTHY','🟢 健康'
        if rate<15: return 'USABLE','🟡 可用但劣'
        return 'BAD','🔴 劣化严重'
    if a['r7']>0: return 'STALE','⚪ 近期无流量'
    return 'IDLE','⚫ 未使用'

print("=== 供应商健康全景 ===\n")
print(f"  {'':<3}{'供应商':<13}{'账户':>5}{'7天':>7}{'2天':>6}{'错误':>6}  最后")
groups=defaultdict(list)
for p,a in per.items():
    k,label=tier(a); groups[k].append((p,a,label))
for p,ac in accs.items():
    if ac['en']>0 and p not in per:
        groups['IDLE'].append((p,{'r7':0,'e7':0,'r2':0,'last':None},'⚫ 未使用'))

order=['HEALTHY','USABLE','BAD','STALE','IDLE']
for k in order:
    if not groups[k]: continue
    print(f"  --- {groups[k][0][2].split()[0]} {k} ---")
    for p,a,label in sorted(groups[k], key=lambda x:-x[1]['r7']):
        ac=accs.get(p,{'n':0,'en':0})
        r7=a['e7']*100//a['r7'] if a['r7'] else 0
        r2=a['e2']*100//a['r2'] if a['r2'] else None
        rs=f"{r2:>2}%" if r2 is not None else " — "
        print(f"  {label.split()[0]:<3}{p:<13}{ac['en']}/{ac['n']:<3}{a['r7']:>7,}{a['r2']:>6,}  7天{r7:>2}% 2天{rs}  {str(a['last'])[5:] if a['last'] else '—'}")
    print()

# 建议
print("=== 建议 ===")
bad=[p for p,a,_ in groups['BAD']]
if bad: print(f"  1. 考虑停用（错误率≥15%）: {', '.join(bad)}")
stale=[p for p,a,_ in groups['STALE'] if a['r7']>=100]
if stale: print(f"  2. 曾有流量但停摆，需确认凭据: {', '.join(stale)}")
idle=[p for p,a,_ in groups['IDLE']]
if idle: print(f"  3. 从未使用，需确认是否有余额: {', '.join(idle)}")
healthy=[p for p,a,_ in groups['HEALTHY']]
print(f"\n  真正健康（可作为主力的）: {len(healthy)} 家 — {', '.join(healthy)}")
PY
