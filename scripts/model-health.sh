#!/usr/bin/env bash
# 主模型健康度与降级链
#
# 数据源：token-ledger（真实请求记录）+ state.json（限流）—— 均属 D078 可信档
# 判据：近 7 天错误率。样本 <100 次的模型标记"样本不足"，不作为降级依据。
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" <<'PY'
import json,sys,time
from collections import defaultdict
hub=sys.argv[1]; now=time.time()
PRIMARY=canon('deepseek-v4-1-flash') if False else 'deepseek-v4-1-flash'
MIN_SAMPLE=100

led=json.load(open(hub+'/token-ledger.json'))
st=json.load(open(hub+'/state.json'))
days=sorted(led.get('days',{}).keys())
win=days[-7:] if len(days)>=7 else days

def canon(raw):
    """复刻插件 normalizeModelKey：点号→连字符、去 sn- 前缀、小写、取 / 后段。
    不归一就无法区分'主模型的其他写法'与'真正独立的备选模型'。"""
    s2=raw.strip().lower()
    if '/' in s2: s2=s2[s2.rfind('/')+1:]
    if s2.endswith(':free'): s2=s2[:-5]
    if s2.startswith('sn-'): s2=s2[3:]
    s2=s2.replace('.','-').replace(' ','-')
    return s2

agg=defaultdict(lambda: defaultdict(int))
provs_of=defaultdict(set)
raw_alias=defaultdict(set)
for day in win:
    for k,v in led['days'][day].items():
        pp=k.split('|')
        raw=pp[3] if len(pp)>3 else '?'
        ck=canon(raw)
        raw_alias[ck].add(raw)
        for f in ('requests','errors'):
            agg[ck][f]+=v.get(f,0) or 0
        if len(pp)>1: provs_of[ck].add(pp[1])

throttled={}
for a in st.get('accounts',[]):
    if not a.get('enabled'): continue
    for m,u in (a.get('modelRateLimits') or {}).items():
        if isinstance(u,(int,float)):
            if u>1e12: u/=1000
            if u>now:
                throttled.setdefault(m,set()).add(a.get('provider')); break

# 近期活跃度（近 2 天请求数）：备选模型必须**当前可用**才有降级价值。
# 实测教训：7 天窗口显示"健康"的模型，近 2 天可能零流量（凭据过期/供应商停服）。
recent2=defaultdict(int); last_seen={}
for day in days:
    for k,v in led['days'][day].items():
        pp=k.split('|'); c=canon(pp[3] if len(pp)>3 else '?')
        cnt=v.get('requests',0) or 0
        if day in days[-2:]: recent2[c]+=cnt
        if cnt>0: last_seen[c]=day

def evaluate(name):
    a=agg.get(name)
    if not a or not a['requests']: return None
    r=a['requests']; e=a['errors']
    return dict(req=r,err=e,rate=e*100/r if r else 0,nprov=len(provs_of.get(name,())),
                recent=recent2.get(name,0),last=last_seen.get(name,''))

# 主模型当前质量用**近 2 天**（避免已移除账户的历史错误污染长期窗口）
_short=days[-2:] if len(days)>=2 else days
_as=defaultdict(lambda: defaultdict(int))
for _d in _short:
    for _k,_v in led['days'][_d].items():
        _pp=_k.split('|'); _raw=_pp[3] if len(_pp)>3 else '?'
        for _f in ('requests','errors'):
            _as[canon(_raw)][_f]+=_v.get(_f,0) or 0
_ps=_as.get(PRIMARY)
p_short=dict(req=_ps["requests"],err=_ps["errors"],rate=_ps["errors"]*100/_ps["requests"]) if _ps and _ps["requests"] else None

print(f"=== 主模型（近 {len(_short)} 天，反映当前）===")
p=evaluate(PRIMARY)
if p_short:
    v='健康' if p_short['rate']<5 and p_short['req']>=MIN_SAMPLE else ('可用' if p_short['rate']<15 else '劣化')
    print(f"  {PRIMARY:<34}")
    print(f"    {p_short['req']:,} 请求 / {p_short['err']:,} 错误（{p_short['rate']:.1f}%）→ {v}")
    if p and p['req']>=MIN_SAMPLE:
        print(f"    （近 {len(win)} 天: {p['req']:,} 请求 / {p['rate']:.1f}% —— 含已移除账户的历史错误）")
else:
    print(f"  {PRIMARY}: 无近期记录 → 未知")
    v='未知'

print(f"\n=== 降级链（按实测质量排序）===")
cands=[]; single=[]; dead=[]
for name in agg:
    if name==PRIMARY: continue
    s=evaluate(name)
    if not s: continue
    if s['req']<MIN_SAMPLE: continue
    if s['rate']>=15: continue          # 质量不合格，直接排除
    if s['recent']<=0:                  # **近期零流量 = 很可能已不可用**，不能作降级目标
        dead.append((s['rate'],name,s)); continue
    if s['nprov']<=1:                   # 单点模型不作降级目标（降级是为提高可用性）
        single.append((s['rate'],name,s)); continue
    # 排序键：(错误率, -供应商数) —— 质量优先，同等质量下冗余多的优先
    cands.append((s['rate'],-s['nprov'],name,s))
cands.sort()
if not cands:
    print("  无可用的备选模型（样本均不足）")
else:
    for i,(rate,negp,name,s) in enumerate(cands[:5],1):
        nprov=-negp
        tag=' ★首选备选' if i==1 else ''
        # 同族标注：与主模型共享前缀的版本号模型，不是真正独立的备选
        if name.startswith(PRIMARY):
            tag+='  ⚠同族'
        print(f"  {i}. {name[:30]:<32} 7天{s['req']:>5,} {rate:>4.1f}%  {nprov}家 近2天{s['recent']:>4}次{tag}")
    if single:
        print("  --- 质量尚可但单点（不作降级目标）---")
        for rate,name,s in sorted(single)[:3]:
            print(f"    {name[:30]:<32} {s['req']:>6,}请求 {rate:>5.1f}%  1家 近2天{s['recent']}次")
    if dead:
        print("  --- 近 2 天零流量（很可能已不可用，**不可作降级目标**）---")
        for rate,name,s in sorted(dead)[:4]:
            print(f"    {name[:30]:<32} 7天{s['req']:>6,}请求 {rate:>5.1f}%  最后活跃 {s['last'][5:]}")

print(f"\n=== 限流（影响候选可用性）===")
ds={m:p for m,p in throttled.items() if 'deepseek' in m.lower()}
if ds:
    for m,provs in ds.items():
        print(f"  ⏳ {m[:34]:<36} {', '.join(sorted(provs))}")
else:
    print("  ✓ 主模型相关无供应商限流")

print("\n=== 结论 ===")
if p_short and p_short["rate"]<5:
    print("  主模型健康（近2天 %.1f%%），无需降级。" % p_short["rate"])
elif p_short and p_short["rate"]<15:
    print("  主模型可用但劣化（近2天 %.1f%%）—— 观察，暂不切换。" % p_short["rate"])
else:
    print("  ⚠ 主模型劣化/无数据（近2天 %s）—— 建议降级。" % ("%.1f%%" % p_short["rate"] if p_short else "无记录"))

if len(cands)==0:
    print("  ⚠⚠ 无可用降级目标（近期活跃的非单点备选为 0）")
    print("     ⇒ 当前不应依赖降级，应保持主模型健康。")
elif len(cands)==1:
    print("  ⚠ 降级目标仅 1 个（%s），冗余不足。" % cands[0][2])
print("\n  注：同族标注项与主模型共享前缀（如版本号 -1017），")
print("      切换它们不改变模型家族，收益有限。")
PY
