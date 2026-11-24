#!/usr/bin/env bash
# 资源时序快照：把 LLM 资源关键指标追加到 state/resource-history.jsonl
# 目的：从"当前快照"升级为"趋势"，才能发现缓慢退化（如某账户错误率爬升）
# 安全：只读结构化 JSON，不碰凭据文件
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub
OUT=../state/resource-history.jsonl

python3 - "$HUB" "$OUT" <<'PY'
import json,sys,time
hub,out=sys.argv[1],sys.argv[2]
now=time.time()
rec={'ts':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(now))}

# 账户池与到期
try:
    st=json.load(open(hub+'/state.json'))
    accs=[a for a in st.get('accounts',[]) if a.get('enabled')]
    rec['accounts_enabled']=len(accs)
    rec['accounts_total']=len(st.get('accounts',[]))
    soon=0; crit=0
    for a in accs:
        e=a.get('expiresAt')
        if not e: continue
        d=(e/1000-now)/86400
        if d<=7: soon+=1
        if d<=7 and not a.get('refreshable'): crit+=1
    rec['expiring_7d']=soon
    rec['critical_expiring']=crit          # 不可续期且 7 天内到期的真风险数
    # 限流账户数
    lim=0
    for a in accs:
        for m,u in (a.get('modelRateLimits') or {}).items():
            if isinstance(u,(int,float)):
                if u>1e12: u/=1000
                if u>now: lim+=1; break
    rec['throttled_accounts']=lim
except Exception as e:
    rec['error_state']=str(e)[:80]

# 今日用量
try:
    led=json.load(open(hub+'/token-ledger.json'))
    days=sorted(led.get('days',{}).keys())
    if days:
        t=days[-1]; r=led['days'][t]
        rec['day']=t
        rec['requests']=sum(v.get('requests',0) or 0 for v in r.values())
        rec['errors']=sum(v.get('errors',0) or 0 for v in r.values())
        rec['output']=sum(v.get('outputTokens',0) or 0 for v in r.values())
        rec['reasoning']=sum(v.get('reasoningTokens',0) or 0 for v in r.values())
except Exception as e:
    rec['error_ledger']=str(e)[:80]

# 续期健康
try:
    ok=err=0
    for line in open(hub+'/refresh-journal.jsonl'):
        line=line.strip()
        if not line: continue
        try: x=json.loads(line).get('result')
        except: continue
        if x=='ok': ok+=1
        elif x=='error': err+=1
    rec['refresh_ok']=ok; rec['refresh_err']=err
except Exception: pass

with open(out,'a') as f:
    f.write(json.dumps(rec,ensure_ascii=False)+'\n')
print(json.dumps(rec,ensure_ascii=False))
PY
