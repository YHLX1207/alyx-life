#!/usr/bin/env bash
# 模型降级/回退状态机
#
# 设计意图：降级不是一次性动作，而是一个有状态的过程。
#   NORMAL   正常使用主模型
#   DEGRADED 已降级到备选模型（记录降级时间/原因/目标）
#   RECOVERING 主模型已恢复，等待回退
#
# 用法：
#   model-fallback.sh status              查看当前状态
#   model-fallback.sh degrade <目标模型>   记录降级事件
#   model-fallback.sh revert              记录已回退
#   model-fallback.sh check               检查是否该降级/回退（供守护调用）
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub
STATE=../state/model-state.json

cmd=${1:-status}

python3 - "$HUB" "$STATE" "$cmd" "${2:-}" <<'PY'
import json,sys,os,time,datetime
from collections import defaultdict
hub,statef,cmd,target=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
PRIMARY='deepseek-v4-1-flash'
THRESHOLD_DEGRADE=15   # 错误率 ≥ 此值建议降级
THRESHOLD_RECOVER=5    # 错误率 < 此值且稳定 → 可回退

def canon(r):
    x=r.strip().lower()
    if '/' in x: x=x[x.rfind('/')+1:]
    if x.endswith(':free'): x=x[:-5]
    if x.startswith('sn-'): x=x[3:]
    return x.replace('.','-').replace(' ','-')

def load_state():
    if os.path.exists(statef):
        try: return json.load(open(statef))
        except: pass
    return {'mode':'NORMAL','since':None,'target':None,'reason':None,'history':[]}

def save_state(s):
    tmp=statef+'.tmp'
    json.dump(s,open(tmp,'w'),ensure_ascii=False,indent=1)
    os.replace(tmp,statef)

def _rate(win):
    led=json.load(open(hub+'/token-ledger.json'))
    days=sorted(led.get('days',{}).keys())
    win=days[-win:] if win<len(days) else days
    r=e=0
    for d in win:
        for k,v in led['days'][d].items():
            p=k.split('|')
            if len(p)>3 and canon(p[3])==PRIMARY:
                r+=v.get('requests',0) or 0; e+=v.get('errors',0) or 0
    return (r,e,e*100//r if r else 0)

def primary_rate():
    """返回**短期**（近 2 天）错误率作为当前质量判据。
    7 天窗口会被已移除账户的历史错误污染（实测 5% vs 近期 1-2%）。"""
    return _rate(2)

def primary_trend():
    """长期 vs 短期对比：短优于长=在恢复；短劣于长=在恶化。"""
    short=_rate(2); long=_rate(7)
    if long[0]<100 or short[0]<100: return None
    return (short[2], long[2])

def best_candidate():
    """按 model-health 同口径选一个非单点、质量合格的备选"""
    led=json.load(open(hub+'/token-ledger.json'))
    days=sorted(led.get('days',{}).keys())[-7:]
    agg=defaultdict(lambda: defaultdict(int)); provs=defaultdict(set)
    for d in days:
        for k,v in led['days'][d].items():
            p=k.split('|'); c=canon(p[3] if len(p)>3 else '?')
            agg[c]['r']+=v.get('requests',0) or 0
            agg[c]['e']+=v.get('errors',0) or 0
            if len(p)>1: provs[c].add(p[1])
    # 近期活跃度：零流量 = 很可能不可用（实测多个"7天健康"模型近2天零请求）
    recent=defaultdict(int)
    for day in days[-2:]:
        for k,v in led['days'][day].items():
            p2=k.split('|'); recent[canon(p2[3] if len(p2)>3 else '?')]+=v.get('requests',0) or 0
    multi=[]; single=[]
    for c,a in agg.items():
        if c==PRIMARY or a['r']<100: continue
        rate=a['e']*100//a['r']
        if rate>=THRESHOLD_DEGRADE: continue
        if recent.get(c,0)<=0: continue      # 近期零流量 → 排除
        (multi if len(provs[c])>1 else single).append((rate,-len(provs[c]),c))
    multi.sort(); single.sort()
    # 优先非单点；没有时退而求其次用单点（降级到单点仍优于留在劣化主模型）
    if multi: return multi[0][2]
    if single: return single[0][2] + '  (⚠单点备用)'
    return None

s=load_state()
r,e,rate=primary_rate()

if cmd=='status':
    print(f"=== 模型状态 ===")
    print(f"  模式: {s['mode']}")
    print(f"  主模型 {PRIMARY}（近 2 天）: {r:,} 请求 / {e:,} 错误（{rate}%）")
    tr=primary_trend()
    if tr:
        sr,lr=tr
        if sr<lr-1: print(f"    趋势: 短期 {sr}% 优于长期 {lr}% → 正在恢复")
        elif sr>lr+1: print(f"    趋势: 短期 {sr}% 劣于长期 {lr}% → 正在恶化 ⚠")
        else: print(f"    趋势: 短期 {sr}% ≈ 长期 {lr}% → 稳定")
    if s['mode']=='DEGRADED':
        print(f"  降级目标: {s.get('target')}")
        print(f"  降级始于: {s.get('since')}")
        print(f"  原因: {s.get('reason')}")
        if rate<THRESHOLD_RECOVER:
            print(f"  ★ 主模型已恢复（{rate}% < {THRESHOLD_RECOVER}%）→ 建议回退")
        else:
            print(f"  主模型仍劣化，维持降级")
    else:
        if rate>=THRESHOLD_DEGRADE:
            c=best_candidate()
            print(f"  ⚠ 劣化（{rate}% ≥ {THRESHOLD_DEGRADE}%）→ 建议降级到 {c or '(无合适备选)'}")
        else:
            print(f"  ✓ 正常（阈值 {THRESHOLD_DEGRADE}%）")

elif cmd=='degrade':
    t=target or best_candidate()
    if not t: print("无可用的降级目标"); sys.exit(1)
    s['mode']='DEGRADED'; s['target']=t
    s['since']=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    s['reason']=f'主模型错误率 {rate}%'
    s['history'].append({'event':'degrade','at':s['since'],'to':t,'reason':s['reason']})
    save_state(s)
    print(f"已记录降级 → {t}（请在 GUI「模型与推理等级」中切换）")

elif cmd=='revert':
    s['mode']='NORMAL'
    at=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    s['history'].append({'event':'revert','at':at,'from':s.get('target')})
    s['target']=None; s['reason']=None; s['since']=at
    save_state(s)
    print(f"已记录回退 → {PRIMARY}（请在 GUI「模型与推理等级」中切回）")

elif cmd=='check':
    # 供守护调用：输出需要人工动作的提示
    msg=''
    if s['mode']=='DEGRADED':
        if rate<THRESHOLD_RECOVER:
            msg=f'主模型已恢复({rate}%)，可回退到 {PRIMARY}'
    else:
        if rate>=THRESHOLD_DEGRADE:
            c=best_candidate()
            msg=f'主模型劣化({rate}%)，建议降级到 {c or "?"}'
    if msg: print(msg)
PY
