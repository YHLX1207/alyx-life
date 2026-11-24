#!/usr/bin/env bash
# 签到结果验证：回答"刚才那轮签到到底成不成功"
#
# 背景：签到由 DSH 进程内 setTimeout 触发，我无法直接观察触发过程。
# 只能事后核对 auto-checkin.json 的 lastSlot / lastResult / channels。
#
# 用法: checkin-verify.sh [时段]   默认最新已到点时段
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" "${1:-}" <<'PY'
import json,sys,datetime
hub,arg=sys.argv[1],sys.argv[2]
BJ=datetime.timezone(datetime.timedelta(hours=8))
now=datetime.datetime.now(BJ)

try:
    d=json.load(open(hub+'/auto-checkin.json'))
except Exception as e:
    print("读取失败:",e); raise SystemExit(1)

slots=d.get('times') or ['09:00','21:00']
last=d.get('lastSlot') or ''
last_at=d.get('lastAt')

# 目标时段
if arg:
    target=arg
else:
    cands=[]
    for dlt in (0,-1):
        d0=(now+datetime.timedelta(days=dlt)).strftime('%Y-%m-%d')
        for sl in slots:
            sdt=datetime.datetime.strptime(d0+' '+sl,'%Y-%m-%d %H:%M').replace(tzinfo=BJ)
            if sdt<=now: cands.append((sdt,d0+'#'+sl))
    cands.sort()
    target=cands[-1][1] if cands else '(无)'
    tdt=cands[-1][0] if cands else None

print(f"=== 签到验证: {target} ===")
print(f"  现在: 北京 {now.strftime('%m-%d %H:%M')}")
if last_at:
    print(f"  最近执行: {datetime.datetime.fromtimestamp(last_at/1000,BJ).strftime('%m-%d %H:%M')}")

pending=d.get('pendingSlot') or ''
if last==target and not pending:
    age=(now-tdt).total_seconds()/3600 if not arg else 0
    print(f"  ✓ 该时段已处理（{'已过 '+format(age,'.1f')+' 小时' if age>0 else ''}）")
elif pending==target:
    # ⚠️ pendingSlot 非空 = 该轮**已执行但未完成**（有渠道待补），不是"未执行"
    _age=(now-tdt).total_seconds()/3600 if (not arg and tdt) else 0
    print(f"  ⏳ 该轮已执行但**未完成**（有渠道待补，pendingSlot={pending}）")
    if _age<3: print(f"     自动补领窗口还剩 {3-_age:.1f}h")
    else: print("     ⚠ 已超 3h 窗口，可能作废")
else:
    if not arg and tdt:
        age=(now-tdt).total_seconds()/3600
        if age<=3:
            print(f"  ⚠ 尚未处理（已过 {age:.1f}h，窗口 3h，剩 {3-age:.1f}h）")
        else:
            print(f"  ✗ 已错过（超 3h 窗口）")
    else:
        print(f"  ✗ 记录不匹配（lastSlot={last}）")

res=d.get('lastResult') or '(无记录)'
print(f"  结果摘要: {res}")

ch=d.get('channels') or []
ok=[c['provider'] for c in ch if '已处理' in c.get('text','')]
err=[(c['provider'],c.get('text')) for c in ch if '出错' in c.get('text','')]
noapi=[c['provider'] for c in ch if '无签到' in c.get('text','') or '不支持' in c.get('text','')]
inact=[(c['provider'],c.get('text')) for c in ch if '未开启' in c.get('text','')]
man=[c['provider'] for c in ch if '手动' in c.get('text','')]

print(f"\n  渠道明细（共 {len(ch)}）:")
print(f"    ✓ 已处理 {len(ok)}: {', '.join(ok) if ok else '-'}")
if err:
    print(f"    ✗ 出错 {len(err)}: " + ', '.join(p for p,_ in err))
if noapi: print(f"    - 无接口 {len(noapi)}: {', '.join(noapi)}")
if inact: print(f"    ⚠ 未开启 {len(inact)}: " + ', '.join(f'{p}({t})' for p,t in inact))
if man:   print(f"    ✋ 需手动 {len(man)}: {', '.join(man)}")

# 结论
if last==target and not pending:
    if err:
        print(f"\n  结论: 该轮已执行，但有 {len(err)} 个渠道出错 —— 可能漏领部分额度")
    else:
        print(f"\n  结论: 该轮已正常执行")
elif pending==target:
    print(f"\n  结论: 已执行但未完成（{len(ok)}/{len(ch)} 渠道成功，待补领）")
else:
    print(f"\n  结论: 该轮未执行 —— 设备在窗口内可能未运行 DSH")
PY
