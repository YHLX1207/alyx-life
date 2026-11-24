#!/usr/bin/env bash
# 生成"可行动"的资源简报（实时数据，非静态快照）
# 输出：state/resource-brief.md —— 按【要不要动手】组织，先给行动再说数字
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

# 先写临时文件，成功后才替换：避免生成失败留下空文件（Round 70 实际踩到）
_TMP=$(mktemp ../state/.brief.XXXXXX) || exit 1
trap 'rm -f "$_TMP"' EXIT

python3 - "$HUB" > "$_TMP" <<'PY'
import json,sys,time,datetime
from collections import defaultdict
hub=sys.argv[1]; now=time.time()
BJ=datetime.timezone(datetime.timedelta(hours=8))
def bj(ts): return datetime.datetime.fromtimestamp(ts,BJ).strftime('%m-%d %H:%M')

st=json.load(open(hub+'/state.json'))
led=json.load(open(hub+'/token-ledger.json'))
accounts=st.get('accounts',[]); en=[a for a in accounts if a.get('enabled')]

# 用量
use=defaultdict(int); days=sorted(led.get('days',{}).keys())
for day in days:
    for k,v in led['days'][day].items():
        parts=k.split('|')
        aid=parts[2] if len(parts)>2 and parts[2] else parts[1]
        use[aid]+=v.get('requests',0) or 0
active=sum(1 for a in en if use.get(a.get('id',''),0)>=20)

# 限流
lim=0; reset=[]
for a in en:
    for m,u in (a.get('modelRateLimits') or {}).items():
        if isinstance(u,(int,float)):
            if u>1e12: u/=1000
            if u>now: lim+=1; reset.append(u); break

# 真风险
crit=[]
for a in en:
    e=a.get('expiresAt')
    if not e or a.get('refreshable'): continue
    d=(e/1000-now)/86400
    if d<=7: crit.append((d,a.get('provider'),a.get('nickname','')[:12],e))

# 今日质量
t=days[-1] if days else None
req=err=0
if t:
    for v in led['days'][t].values():
        req+=v.get('requests',0) or 0; err+=v.get('errors',0) or 0

print("# 资源风险简报\n")
print(f"生成：{datetime.datetime.now(BJ).strftime('%Y-%m-%d %H:%M')}（北京）\n")
print("---\n")
print("## 一、需要你行动的\n")
if crit:
    print("### P0 · 不可续期账户将失效\n")
    for d,p,n,e in sorted(crit):
        print(f"- **{p}/{n}** — 北京 {bj(e/1000)}（剩 {d:.1f} 天）")
        print(f"  - 做法：短信验证码或微信重新登录")
        print(f"  - 不做：失去该账户额度，其余 {len(en)-len(crit)} 个仍可服务\n")
else:
    print("### P0 · 无\n\n当前没有即将失效的不可续期账户。\n")

print("### P1 · 签到状态\n")
try:
    ck=json.load(open(hub+'/auto-checkin.json'))
    slots=ck.get('times') or []
    last=ck.get('lastSlot') or ''
    nowbj=datetime.datetime.now(BJ)
    # 计算"最近一个已到点的时段"
    cands=[]
    for dlt in (0,-1):
        d=(nowbj+datetime.timedelta(days=dlt)).strftime('%Y-%m-%d')
        for _slot in slots:
            hh,mm=_slot.split(':')
            sdt=datetime.datetime.strptime(d+' '+_slot,'%Y-%m-%d %H:%M').replace(tzinfo=BJ)
            if sdt<=nowbj: cands.append((sdt,d+'#'+_slot))
    cands.sort()
    if cands:
        latest_sdt,latest_key=cands[-1]
        age_h=(nowbj-latest_sdt).total_seconds()/3600
        if last==latest_key:
            print(f"- 最新时段 `{latest_key}` 已处理 ✓（{age_h:.1f}h 前）")
        elif age_h<=3:
            print(f"- ⚠ 最新时段 `{latest_key}` **尚未处理**（已过 {age_h:.1f}h，窗口 3h，还剩 {3-age_h:.1f}h）")
            print(f"  - 需要设备在窗口内运行过 DSH")
        else:
            print(f"- ✗ 最新时段 `{latest_key}` **已错过**（超 3h 窗口）→ 该轮额度作废")
        print(f"- 上一处理记录: `{last}`")
    print()
except Exception as e:
    print(f"- 读取签到状态失败: {e}\n")
print("---\n")
print("## 二、系统当前状态（无需行动）\n")
print("```")
print(f"启用账户 {len(en)}/{len(accounts)}   活跃(≥20次) {active}")
print(f"当前限流 {lim} 个" + (f"   最早恢复 北京 {bj(min(reset))}" if reset else ""))
print(f"今日 {t}: {req:,} 请求 / {err:,} 错误 ({err*100//max(req,1)}%)")
print("```\n")
print("---\n")
print("## 三、我无法知道的事\n")
print("- **各账户余额**：余额查询是 providers-hub 面板专用的内部 RPC，")
print("  未注册为 agent tool，GUI 端点需鉴权（401）。")
print("  → 想知道哪些账户【有额度但没被用】，请自行查看面板的积分列。")
print("- 这不影响判断：主路由 `aggregate` 聚合了 6 家供应商，")
print("  单账户余额不足会自动切换。\n")
print("---\n")
print("## 四、自动化程度\n")
print("守护每 20 轮（约 1 小时）自动：真风险告警（去重）+ 资源时序记录。")
print("**零 token 成本。** 本简报按需运行 `./scripts/resource-brief.sh` 重新生成。")
PY
_rc=$?

if [ $_rc -ne 0 ] || [ ! -s "$_TMP" ]; then
  echo "生成失败（rc=$_rc）—— 保留旧文件未改动" >&2
  exit 1
fi
mv "$_TMP" ../state/resource-brief.md
trap - EXIT
echo "已生成 ../state/resource-brief.md ($(wc -l < ../state/resource-brief.md) 行)"
