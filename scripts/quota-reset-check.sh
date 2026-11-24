#!/usr/bin/env bash
# 额度重置验证：核对"每日 00:00 重置"这个假设
#
# 依据 D033：4-5 个账户同时在 16:00 UTC（北京 00:00）重置 ⇒ 推断为自然日额度周期。
# 本脚本在运行时刻对比「上次基线」与当前状态，回答：
#   限流账户数是否真的在 00:00 后归零？
#
# 用法:
#   quota-reset-check.sh baseline   记录基线
#   quota-reset-check.sh check      对比基线（默认）
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub
BF=../state/quota-baseline.json
MODE=${1:-check}

python3 - "$HUB" "$BF" "$MODE" <<'PY'
import json,sys,time,datetime,os
hub,bf,mode=sys.argv[1],sys.argv[2],sys.argv[3]
BJ=datetime.timezone(datetime.timedelta(hours=8))
now=time.time()

st=json.load(open(hub+'/state.json'))
en=[a for a in st.get('accounts',[]) if a.get('enabled')]
thr=[]
for a in en:
    for m,u in (a.get('modelRateLimits') or {}).items():
        if isinstance(u,(int,float)):
            if u>1e12: u/=1000
            if u>now:
                thr.append({'provider':a.get('provider'),'model':m,
                            'reset':datetime.datetime.fromtimestamp(u,BJ).strftime('%m-%d %H:%M')})
                break
cur={'at':datetime.datetime.now(BJ).strftime('%m-%d %H:%M:%S'),
     'throttled':len(thr),'items':thr}

if mode=='baseline':
    json.dump(cur,open(bf,'w'),ensure_ascii=False,indent=1)
    print(f"  基线已记录: {cur['at']}  限流 {cur['throttled']} 个")
    for t in thr[:12]:
        print(f"    {t['provider']:<12} {t['model'][:24]:<26} {t['reset']} 恢复")
    raise SystemExit

# check
print(f"=== 额度重置验证 ===\n  当前: {cur['at']}  限流 {cur['throttled']} 个")
base=None
if os.path.exists(bf):
    base=json.load(open(bf))
if not base:
    print("  （无基线，先运行 baseline）"); raise SystemExit

print(f"  基线: {base['at']}      限流 {base['throttled']} 个")
d=cur['throttled']-base['throttled']
print(f"\n  变化: {base['throttled']} → {cur['throttled']} ({d:+d})")

try:
    bt=datetime.datetime.strptime('2026-'+base['at'],'%Y-%m-%d %H:%M:%S')
    ct=datetime.datetime.strptime('2026-'+cur['at'],'%Y-%m-%d %H:%M:%S')
    crossed = bt.date()!=ct.date()
except Exception:
    crossed=False

if cur['throttled']==0 and base['throttled']>0:
    print("  ✓✓ 限流已全部解除 —— **额度重置假设成立**")
elif crossed and cur['throttled']<base['throttled']:
    print(f"  ✓ 跨日后限流减少 {abs(d)} 个 —— 重置假设成立")
elif crossed and cur['throttled']>=base['throttled']:
    print(f"  ✗ 已跨日但限流未减（{cur['throttled']} 个）—— **重置假设可能不成立**，需重新归因")
else:
    print("  · 同日对比，尚不能验证跨日重置")
print(f"\n  当前限流明细:")
for t in cur['items'][:12]:
    print(f"    {t['provider']:<12} {t['model'][:24]:<26} {t['reset']} 恢复")
PY
