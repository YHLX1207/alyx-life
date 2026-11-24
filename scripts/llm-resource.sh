#!/usr/bin/env bash
# LLM API 资源看板
# 数据源（均为结构化，不解析凭据文件）：jet-hub/{token-ledger,state,dead-models,refresh-journal}.json
# 安全：绝不输出任何 token / key / secret
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" <<'PY'
import json,sys,time,datetime
from collections import Counter,defaultdict
hub=sys.argv[1]
now=time.time()
def ts(ms):
    try: return datetime.datetime.fromtimestamp(ms/1000,datetime.timezone.utc)
    except: return None

print("=== 账户池（state.json）===")
try:
    st=json.load(open(hub+'/state.json'))
    accs=st.get('accounts',[])
    en=sum(1 for a in accs if a.get('enabled'))
    prov=Counter(a.get('provider','?') for a in accs)
    print(f"  账户 {len(accs)} 个（启用 {en}） / 供应商 {len(prov)} 家")
    soon=[]
    for a in accs:
        e=a.get('expiresAt')
        if e:
            d=(e/1000-now)/86400
            if d<=7: soon.append((d,a.get('provider'),a.get('nickname','')))
    if soon:
        print("  到期预警（≤7天）:")
        for d,p,n in sorted(soon):
            print(f"    {'✗已过期' if d<0 else '⚠'} {p:<12} {d:>5.1f}天  {n}")
    else: print("  到期预警: 无")
except Exception as e: print("  读失败:",e)

print("\n=== Token 账本（token-ledger.json）===")
try:
    d=json.load(open(hub+'/token-ledger.json'))
    days=d.get('days',{})
    tot=Counter(); per=defaultdict(Counter); perday=[]
    for day,rec in days.items():
        ds=Counter()
        for k,v in rec.items():
            p=k.split('|')[1] if k.count('|')>=1 else '?'
            for f in ('requests','inputTokens','outputTokens','cacheReadTokens','reasoningTokens','errors'):
                n=v.get(f,0) or 0
                tot[f]+=n; per[p][f]+=n; ds[f]+=n
        perday.append((day,ds))
    ks=sorted(days)
    print(f"  记录 {len(days)} 天（{ks[0]} ~ {ks[-1]}）" if ks else "  无记录")
    print(f"  累计请求 {tot['requests']:,} | 输入 {tot['inputTokens']:,} | 输出 {tot['outputTokens']:,}")
    print(f"  缓存读 {tot['cacheReadTokens']:,} | 推理 {tot['reasoningTokens']:,} | 错误 {tot['errors']:,} ({tot['errors']*100//max(tot['requests'],1)}%)")
    if tot['inputTokens']:
        cr=tot['cacheReadTokens']; it=tot['inputTokens']
        print(f"  缓存/输入比 {cr/it:.1f}x  → 前缀缓存命中率高，实际计费大幅降低")
    print("  按供应商（请求数降序）:")
    for p,c in sorted(per.items(), key=lambda x:-x[1]['requests'])[:8]:
        r=c['requests']; e=c['errors']
        rate=e*100//max(r,1)
        flag=' ⚠' if rate>=5 else ''
        print(f"    {p:<12} {r:>6,} 请求  错误 {e:>4,} ({rate:>2}%){flag}")
except Exception as e: print("  读失败:",e)

print("\n=== 续期健康度 ===")
try:
    res=Counter(); per2=defaultdict(Counter); newest=None; nts=0
    for line in open(hub+'/refresh-journal.jsonl'):
        line=line.strip()
        if not line: continue
        try: e=json.loads(line)
        except: continue
        res[e.get('result','?')]+=1; per2[e.get('provider','?')][e.get('result','?')]+=1
        t=e.get('ts',0)
        if t>nts: nts=t; newest=e
    t=sum(res.values()); ok=res.get('ok',0)
    print(f"  总计 {t} 次  成功 {ok} / 失败 {res.get('error',0)} → {ok*100//t if t else 0}%")
    for p,c in sorted(per2.items()):
        tt=sum(c.values()); o=c.get('ok',0)
        flag=' ⚠' if tt and o*100//tt<50 else ''
        print(f"    {p:<12} {o}/{tt} ({o*100//tt if tt else 0}%){flag}")
except FileNotFoundError: print("  无日志")

print("\n=== 模型冗余度（近 7 天实际支撑供应商数）===")
try:
    from collections import defaultdict as _dd
    _d=json.load(open(hub+'/token-ledger.json'))
    _days=sorted(_d.get('days',{}).keys())[-7:]
    _m2p=_dd(lambda:_dd(int))
    for _day in _days:
        for _k,_v in _d['days'][_day].items():
            _p=_k.split('|')
            _prov=_p[1] if len(_p)>1 else '?'
            _model=_p[3] if len(_p)>3 else '?'
            _m2p[_model][_prov]+=_v.get('requests',0) or 0
    for _model,_provs in sorted(_m2p.items(), key=lambda x:-sum(x[1].values()))[:5]:
        _tot=sum(_provs.values())
        _ns=len(_provs)
        _top=max(_provs.values()) if _provs else 0
        _tag='✓ 冗余充足' if _ns>=3 else ('⚠ 单点风险' if _ns<=1 else '· 冗余偏少')
        print(f"  {_model[:40]:<40} {_ns} 家 / {_tot:>6,} 请求  最大占比 {_top*100//max(_tot,1):>2}%  {_tag}")
except Exception as e: print("  读失败:",e)

print("\n=== 容量：当前限流状态 ===")
try:
    st2=json.load(open(hub+'/state.json')); now2=time.time()
    lim={}
    for a in st2.get('accounts',[]):
        if not a.get('enabled'): continue
        for m,u in (a.get('modelRateLimits') or {}).items():
            if isinstance(u,(int,float)):
                if u>1e12: u/=1000
                if u>now2: lim.setdefault(m,[]).append(a.get('provider'))
    if lim:
        for m,lst in sorted(lim.items(), key=lambda x:-len(x[1])):
            print(f"  ⏳ {m[:38]:<38} {len(lst)} 账户限流 ({','.join(lst)})")
    else:
        print("  无账户处于限流")
    # 额度重置时间（推断周期）
    from collections import Counter
    c=Counter()
    for a in st2.get('accounts',[]):
        for m,u in (a.get('modelRateLimits') or {}).items():
            if isinstance(u,(int,float)):
                if u>1e12: u/=1000
                if u>now2:
                    c[datetime.datetime.fromtimestamp(u,datetime.timezone.utc).strftime('%H:%M')]+=1
    for t,n in c.most_common(3):
        bj=(int(t[:2])+8)%24
        print(f"  额度重置 {t} UTC = 北京 {bj:02d}:{t[3:]}  ({n} 个账户)")
except Exception as e: print("  读失败:",e)

print("\n=== 失效模型 ===")
try:
    dd=json.load(open(hub+'/dead-models.json')); n=0
    for p,ms in (dd.get('providers') or {}).items():
        for m,i in ms.items():
            n+=1; print(f"  {p}/{m}: {str(i.get('reason',''))[:50]}")
    if not n: print("  无")
except Exception as e: print("  读失败:",e)

print("\n=== 自动签到 ===")
try:
    a=json.load(open(hub+'/auto-checkin.json'))
    print(f"  启用 {a.get('enabled')} | 时段 {','.join(a.get('times',[]))} | 最近 {a.get('lastSlot')}")
except Exception as e: print("  读失败:",e)
PY
