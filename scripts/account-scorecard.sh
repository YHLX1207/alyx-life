#!/usr/bin/env bash
# 账户记分卡：综合错误率 / 可续期性 / 到期时间 / 承载量，给出降权建议
# 目标：从"监控状态"升级到"可执行的取舍"
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" <<'PY'
import json,sys,time
from collections import defaultdict
hub=sys.argv[1]; now=time.time()
st=json.load(open(hub+'/state.json'))
led=json.load(open(hub+'/token-ledger.json'))
days=sorted(led.get('days',{}).keys())[-3:]
acc=defaultdict(lambda:{'req':0,'err':0,'out':0})
for day in days:
    for key,v in led['days'].get(day,{}).items():
        parts=key.split('|')
        aid=parts[2] if len(parts)>2 and parts[2] else parts[1]
        a=acc[aid]
        a['req']+=v.get('requests',0) or 0
        a['err']+=v.get('errors',0) or 0
        a['out']+=v.get('outputTokens',0) or 0

rows=[]
for a in st.get('accounts',[]):
    if not a.get('enabled'): continue
    aid=a.get('id','')
    m=acc.get(aid) or acc.get(a.get('provider'),{})
    req=m.get('req',0); err=m.get('err',0)
    # 样本充足性：<10 次请求的错误率不可靠（原则 5：警惕测量误差）
    MINN=10
    erate=err*100//req if req>=MINN else -1
    e=a.get('expiresAt')
    dleft=(e/1000-now)/86400 if e else None
    refreshable=bool(a.get('refreshable'))
    # 风险评分
    score=0
    if erate>=50: score+=3
    elif erate>=20: score+=2
    elif erate>=10: score+=1
    # erate==-1 表示样本不足，不参与风险评分
    if not refreshable and dleft is not None and dleft<=7: score+=3
    rows.append((score,erate,req,a.get('provider'),aid,refreshable,dleft))

rows.sort(key=lambda x:(-x[0],-x[1]))
print(f"近 {len(days)} 天数据 · {len(rows)} 个启用账户")
print()
print(f"{'风险':<4}{'错误率':<8}{'请求':<8}{'供应商':<12}{'可续期':<7}{'到期':<9}账户")
print("-"*72)
for score,erate,req,prov,aid,rf,dleft in rows:
    er=f"{erate}%" if erate>=0 else "样本<10"
    dl=f"{dleft:.1f}天" if dleft is not None else "长期"
    flag='🔴' if score>=5 else '🟡' if score>=2 else '🟢'
    print(f"{flag:<4}{er:<8}{req:<8}{prov:<12}{'是' if rf else '否':<7}{dl:<9}{aid[:24]}")
print()
print("建议：🔴 降权或停用；🟡 观察；🟢 可承载主流量")
PY
