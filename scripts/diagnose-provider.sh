#!/usr/bin/env bash
# 供应商根因诊断：把多个独立信号交叉起来找共同原因
#
# 缘起 Round 94：minimax/minimaxintl/marvis 三家的
#   ① 续期失败率高  ② 近2天零流量  ③ 签到失败
# 被当成三个独立问题记录，分开看永远找不到根因。
# 统一起来看：**同一份失效凭据的三个投影**。
#
# 本工具把五个信号放在一起看，给出单一结论。
#
# 用法: diagnose-provider.sh [provider...]   （省略则诊断所有异常者）
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" "$@" <<'PY'
import json,sys,time,datetime
from collections import defaultdict, Counter
hub=sys.argv[1]; only=sys.argv[2:]
now=time.time(); BJ=datetime.timezone(datetime.timedelta(hours=8))

led=json.load(open(hub+'/token-ledger.json'))
st=json.load(open(hub+'/state.json'))
days=sorted(led.get('days',{}).keys())

# 信号1: 近7天/2天请求与错误
per=defaultdict(lambda:{'r7':0,'e7':0,'r2':0,'last':None})
for d in days:
    for k,v in led['days'][d].items():
        p=k.split('|')
        if len(p)<2: continue
        pv=p[1]; c=v.get('requests',0) or 0
        if d in days[-7:]:
            per[pv]['r7']+=c; per[pv]['e7']+=v.get('errors',0) or 0
        if d in days[-2:]: per[pv]['r2']+=c
        if c>0: per[pv]['last']=d

# 信号2: 续期成功率
ref=defaultdict(lambda: defaultdict(int))
try:
    for line in open(hub+'/refresh-journal.jsonl'):
        line=line.strip()
        if not line: continue
        try: e=json.loads(line)
        except: continue
        ref[e.get('provider','?')][e.get('result','?')]+=1
except FileNotFoundError: pass

# 信号3: 签到时状态
ck={}
try:
    c=json.load(open(hub+'/auto-checkin.json'))
    for x in c.get('channels') or []: ck[x.get('provider')]=x.get('text','')
    ps=c.get('providerSlots') or {}
    pending=c.get('pendingSlot') or ''
except Exception:
    ps={}; pending=''

# 信号4: 账户启用/过期
acc=defaultdict(lambda:{'en':0,'tot':0,'exp':[]})
for a in st.get('accounts',[]):
    pv=a.get('provider','?'); acc[pv]['tot']+=1
    if a.get('enabled'): acc[pv]['en']+=1
    e=a.get('expiresAt')
    if e: acc[pv]['exp'].append((e/1000-now)/86400)

# 信号4b: 历史活跃度与连续零流量天数（区分"曾经活跃后停摆" vs "一直未使用"）
daily=defaultdict(lambda: defaultdict(int))
for d in days:
    for k,v in led['days'][d].items():
        p2=k.split('|')
        if len(p2)<2: continue
        daily[p2[1]][d]+=v.get('requests',0) or 0

def activity_profile(pv):
    seq=[daily[pv].get(d,0) for d in days]
    # 连续零流量天数（从末尾数）
    gap=0
    for x in reversed(seq):
        if x==0: gap+=1
        else: break
    # 归零之前的活跃水平（取前 5 天均值）
    before=[x for x in seq[:-gap] if x>0][-5:] if gap else []
    avg=sum(before)//len(before) if before else 0
    return gap, avg

# 信号5: 限流
thr=defaultdict(int)
for a in st.get('accounts',[]):
    if not a.get('enabled'): continue
    for m,u in (a.get('modelRateLimits') or {}).items():
        if isinstance(u,(int,float)):
            if u>1e12: u/=1000
            if u>now: thr[a.get('provider','?')]+=1; break

cands=only if only else sorted(set(list(per)+list(ref)+list(acc)))

def diag(pv):
    a=per.get(pv,{'r7':0,'e7':0,'r2':0,'last':None})
    r=ref.get(pv,{}); ok=r.get('ok',0); err=r.get('error',0); tot=ok+err
    accs=acc.get(pv,{'en':0,'tot':0,'exp':[]})
    chk=ck.get(pv,'(无记录)')
    rate7=a['e7']*100//a['r7'] if a['r7'] else 0
    signs=[]
    gap,avg=activity_profile(pv)
    if gap>=3 and avg>=100:
        signs.append(f'曾活跃({avg}次/天)但已连续 {gap} 天零流量')
    elif gap>=3:
        signs.append(f'连续 {gap} 天零流量（历史均值仅 {avg} 次/天，可能本就低频）')
    elif a['r2']==0 and a['r7']>0:
        signs.append('近2天零流量（不足3天，观察中）')
    if tot>0 and ok*100//tot < 60: signs.append(f'续期成功率低 {ok*100//tot}%')
    if '失败' in chk or '出错' in chk: signs.append(f'签到异常({chk})')
    if rate7>=25: signs.append(f'错误率高 {rate7}%')
    if accs['en']==0 and accs['tot']>0: signs.append('无启用账户')
    return signs, a, (ok,tot), chk

rows=[]
for pv in cands:
    signs,a,refs,chk=diag(pv)
    if len(signs)>=2: rows.append((len(signs),pv,signs,a,refs,chk))

print("=== 供应商根因诊断 ===\n")
if not rows:
    print("  未发现多维异常者。\n"); raise SystemExit
rows.sort(reverse=True)
for n,pv,signs,a,refs,chk in rows:
    print(f"  ▸ {pv}  ({n} 个异常信号)")
    print(f"      7天 {a['r7']:,}请求/{a['e7']:,}错({a['e7']*100//a['r7'] if a['r7'] else 0}%)  近2天 {a['r2']:,}  最后 {str(a['last'])[5:] if a['last'] else '—'}")
    if refs[1]: print(f"      续期 {refs[0]}/{refs[1]}")
    print(f"      签到: {chk}")
    for s in signs: print(f"      · {s}")
    print()
    # 给出单一结论
    _sig=' '.join(signs)
    _persistent = ('曾活跃' in _sig and '连续' in _sig)
    # 判据：曾活跃（≥100次/天）且连续 ≥3 天零流量 ⇒ 视为持续失效
    #       短期或本就低频 ⇒ 只提示观察（D119：minimax 曾被误判，实际自愈）
    if _persistent:
        _why=' + '.join(x for x in signs if '曾活跃' in x or '续期' in x or '签到' in x)
        print(f'      ⇒ 结论：**持续失效**（{_why}）')
        print(f'         处置：先确认该渠道状态；持续多日无改善则重新登录 {pv}')
    elif any('签到' in s for s in signs) and a['r2']==0:
        print(f"      ⇒ 结论：**暂时性失败**（零流量 <3 天或本就低频）—— 先观察，不急于重登")
        print(f"         依据：D119 教训，minimax 曾被误判为凭据失效，实际补领时自己恢复了")
    print()
PY
