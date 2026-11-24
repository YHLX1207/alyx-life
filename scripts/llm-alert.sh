#!/usr/bin/env bash
# LLM 资源告警 —— 只报【真风险】
#
# 关键区分（Round 25 实测）：
#   refreshable=true 的账户到期是**正常续期周期**，会自动续上 → 不该告警（纯噪音）
#   refreshable=false 的账户到期 = **真的会失效**，需要人工重新登录 → 必须告警
#
# 曾经的问题：告警盯着"6h 内到期"，结果 6 个全是可续期的，
# 而真正危险的 loomy（不可续期、1.1 天后过期）反而没突出。
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

MSG=$(python3 - "$HUB" <<'PY'
import json,sys,time
hub=sys.argv[1]; now=time.time()
alerts=[]
try:
    st=json.load(open(hub+'/state.json'))
    crit=[]
    for a in st.get('accounts',[]):
        if not a.get('enabled'): continue
        if a.get('refreshable'): continue          # 可续期 → 不报
        e=a.get('expiresAt')
        if not e: continue                          # 无到期 → 长期有效
        d=(e/1000-now)/86400
        if d<=7:
            crit.append((d,a.get('provider'),a.get('nickname','')[:12]))
    if crit:
        crit.sort()
        desc=", ".join(f"{p}/{n}={d:.1f}d" for d,p,n in crit[:5])
        alerts.append(f"不可续期账户 {len(crit)} 个将失效: {desc}")
except Exception as e:
    alerts.append(f"state.json 读取异常:{e}")

try:
    ok=err=0
    for line in open(hub+'/refresh-journal.jsonl'):
        line=line.strip()
        if not line: continue
        try: r=json.loads(line).get('result')
        except: continue
        if r=='ok': ok+=1
        elif r=='error': err+=1
    tot=ok+err
    if tot>=20 and ok*100//tot < 40:
        alerts.append(f"续期成功率过低 {ok*100//tot}% ({ok}/{tot})")
except Exception: pass

try:
    dd=json.load(open(hub+'/dead-models.json'))
    n=sum(len(m) for m in (dd.get('providers') or {}).values())
    if n: alerts.append(f"失效模型 {n} 个")
except Exception: pass

# 签到漏跑检测：时段到点后超 3 小时仍未处理 ⇒ 该轮额度已作废
# 供应商级劣化/停摆检测（D085 家底观测的自动化）
try:
    from collections import defaultdict as _dd2
    _l=json.load(open(hub+'/token-ledger.json'))
    _ds=sorted(_l.get('days',{}).keys())
    _pp=_dd2(lambda: {'r7':0,'e7':0,'r2':0,'e2':0})
    for _d in _ds:
        for _k,_v in _l['days'][_d].items():
            _q=_k.split('|')
            if len(_q)<2: continue
            _pv=_q[1]; _c=_v.get('requests',0) or 0
            if _d in _ds[-7:]:
                _pp[_pv]['r7']+=_c; _pp[_pv]['e7']+=_v.get('errors',0) or 0
            if _d in _ds[-2:]:
                _pp[_pv]['r2']+=_c; _pp[_pv]['e2']+=_v.get('errors',0) or 0
    # 只报**仍有启用账户**的 provider（已移除的如 magicrew 不报，那是历史）
    _en0={a.get('provider') for a in st.get('accounts',[]) if a.get('enabled')}
    # 判据用**近 2 天**（有样本时）：loomy 7天15% 但 2天45%，用 7 天会漏报
    def _rate2(a):
        if a['r2']>=20: return a['e2']*100//a['r2']
        return a['e7']*100//a['r7'] if a['r7']>=100 else 0
    _bad=[(p2,_rate2(a)) for p2,a in _pp.items()
          if a['r7']>=100 and _rate2(a)>=25 and p2 in _en0]
    if _bad:
        alerts.append("供应商严重劣化: " + ", ".join(f"{p2}({r}%)" for p2,r in sorted(_bad,key=lambda x:-x[1])))
    _en={a.get('provider') for a in st.get('accounts',[]) if a.get('enabled')}
    _stl=[p2 for p2,a in _pp.items() if a['r7']>=100 and a['r2']==0 and p2 in _en]
    if _stl:
        alerts.append("曾好用但近2天停摆: " + ", ".join(sorted(_stl)))
except Exception: pass

# 降级/回退状态机提示（有状态，能区分"该降级"与"可回退"）
try:
    import subprocess
    _mf=subprocess.run(['./model-fallback.sh','check'],capture_output=True,text=True,timeout=20)
    _o=(_mf.stdout or '').strip()
    if _o: alerts.append(_o)
except Exception: pass

# 主模型劣化告警：与 model-health 同判据（近 7 天错误率 >= 15%）
try:
    from collections import defaultdict as _dd
    _led=json.load(open(hub+'/token-ledger.json'))
    _days=sorted(_led.get('days',{}).keys())[-2:]   # 近2天：避免已移除账户的历史错误污染
    _agg=_dd(lambda: _dd(int))
    def _canon(r):
        x=r.strip().lower()
        if '/' in x: x=x[x.rfind('/')+1:]
        if x.endswith(':free'): x=x[:-5]
        if x.startswith('sn-'): x=x[3:]
        return x.replace('.','-').replace(' ','-')
    for _d in _days:
        for _k,_v in _led['days'][_d].items():
            _p=_k.split('|'); _m=_canon(_p[3] if len(_p)>3 else '?')
            _agg[_m]['r']+=_v.get('requests',0) or 0
            _agg[_m]['e']+=_v.get('errors',0) or 0
    _pm=_agg.get('deepseek-v4-1-flash')
    if _pm and _pm['r']>=100:
        _rate=_pm['e']*100//_pm['r']
        if _rate>=15:
            alerts.append(f"主模型错误率 {_rate}%（≥15%，建议降级到 minimax-m3-1-flash）")
except Exception: pass

try:
    import datetime
    ck=json.load(open(hub+'/auto-checkin.json'))
    if ck.get('enabled'):
        BJ=datetime.timezone(datetime.timedelta(hours=8))
        nowbj=datetime.datetime.now(BJ)
        slots=ck.get('times') or []
        last=ck.get('lastSlot') or ''
        cands=[]
        for dlt in (0,-1):
            d0=(nowbj+datetime.timedelta(days=dlt)).strftime('%Y-%m-%d')
            for sl in slots:
                sdt=datetime.datetime.strptime(d0+' '+sl,'%Y-%m-%d %H:%M').replace(tzinfo=BJ)
                if sdt<=nowbj: cands.append((sdt,d0+'#'+sl))
        cands.sort()
        if cands:
            latest,key=cands[-1]
            age_h=(nowbj-latest).total_seconds()/3600
            if last!=key and age_h>3:
                alerts.append(f"签到已错过 {key}（超3h窗口，额度作废）")
except Exception: pass
print("; ".join(alerts) if alerts else "")
PY
)

if [ -z "$MSG" ]; then
  ./alert.sh "" 2>/dev/null
  exit 0
fi
echo "$MSG"
./alert.sh "LLM资源预警：$MSG" 2>/dev/null
