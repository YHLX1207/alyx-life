#!/usr/bin/env bash
# 签到精细化管理视图
#
# 知识来源（实测 + plugin 源码 auto-checkin.js 注释）：
#  - 每日 09:00 / 21:00 两轮，jitter 0
#  - "不支持签到"名单一直在缩小：raccoon/workbuddy 于 2026-11-15 查清有签到并移出，
#    当前真正无接口的只剩 cline
#  - zcode 有签到但被**故意排除**自动：需当场产阿里云 captcha、会拉起
#    headful Chromium（200-400MB），阿里云按设备限流 150 次/小时。
#    手动点“一键领取”是有意行为。
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" <<'PY'
import json,sys,datetime
hub=sys.argv[1]
try:
    d=json.load(open(hub+'/auto-checkin.json'))
except Exception as e:
    print("读失败:",e); raise SystemExit

print("=== 签到调度 ===")
print(f"  启用: {d.get('enabled')} | 时段: {','.join(d.get('times',[]))} | jitter: {d.get('jitterMinutes')} 分")
print(f"  最近执行: {d.get('lastSlot')}  ({datetime.datetime.fromtimestamp(d.get('lastAt',0)/1000,datetime.timezone.utc).strftime('%m-%d %H:%M UTC')})")
print(f"  结果: {d.get('lastResult')}")
print()

ch=d.get('channels',[])
ok=[]; err=[]; noapi=[]; inactive=[]; manual=[]
for c in ch:
    t=c.get('text',''); p=c.get('provider','')
    if '已处理' in t: ok.append(p)
    elif '出错' in t or '失败' in t: err.append((p,t))
    elif '无签到' in t or '不支持' in t: noapi.append(p)
    elif '未开启' in t: inactive.append((p,t))
    elif '手动' in t: manual.append(p)

print(f"=== 分渠道（共 {len(ch)} 个）===")
print(f"  ✓ 本轮已处理 {len(ok)}: {', '.join(ok)}")
if err:
    print(f"  ✗ 出错 {len(err)}:")
    for p,t in err: print(f"      {p}: {t}")
if noapi:
    print(f"  - 无签到接口 {len(noapi)}: {', '.join(noapi)}   （注意：该名单会随厂商更新缩小）")
if inactive:
    print(f"  ⚠ 未开启 {len(inactive)}:")
    for p,t in inactive: print(f"      {p}: {t}")
if manual:
    print(f"  ✋ 需手动 {len(manual)}: {', '.join(manual)}")
    print("      → zcode 设计上不做自动签到（captcha+浏览器 200-400MB+设备级限流 150/h）")

print()
print("=== 分时段台账 ===")
ps=d.get('providerSlots',{})
pend=[p for p,v in ps.items() if v and v!=d.get('lastSlot')]
print(f"  {len(ps)} 个渠道有记录；落后于当前时段: {', '.join(pend) if pend else '无'}")
print()
print("=== 可优化项 ===")
if err: print("  1. 修复出错渠道:", ", ".join(p for p,_ in err))
if inactive: print("  2. 确认未开启渠道是否有可用签到:", ", ".join(p for p,_ in inactive))
if noapi: print("  3. 复核无接口名单（历史上持续缩小）:", ", ".join(noapi))
print("  4. 考虑加 jitter（当前 0，多轮同时发请求）")
PY
