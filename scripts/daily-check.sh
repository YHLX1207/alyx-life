#!/usr/bin/env bash
# 一次性日常巡检：把多个检查合并为**单次调用**
#
# 缘起 D096：成本 81% 来自缓存读，而缓存读 = 请求数 × 每请求上下文。
# ⇒ 真正的降本杠杆是**减少请求数**，而非缩短输出。
# 本脚本把原本需要 4-6 次工具调用的巡检合并为 1 次。
#
# 用法: daily-check.sh [--full]
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub
FULL=${1:-}

echo "=== 日常巡检 $(TZ=Asia/Shanghai date +'%m-%d %H:%M:%S') ==="

echo "[守护]"
./daemon-ctl.sh status 2>/dev/null | head -1 | sed 's/^/  /'
echo "  连击: $(cat ../state/fail-streak.json 2>/dev/null || echo '?')"

echo "[回归]"
./verify.sh 2>&1 | tail -1 | sed 's/^/  /'

echo "[设备]"
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"
LOAD=$(timeout 10 $A shell "cut -d' ' -f1 /proc/loadavg" 2>/dev/null | tr -d '\r')
MEM=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
echo "  load=${LOAD:-?}  mem=${MEM:-?}MB"

echo "[LLM 资源]"
python3 - "$HUB" <<'PY'
import json,sys,time
from collections import defaultdict
hub=sys.argv[1]; now=time.time()
led=json.load(open(hub+'/token-ledger.json'))
days=sorted(led.get('days',{}).keys())
r=i=c=o=0
for v in led['days'][days[-1]].values():
    r+=v.get('requests',0) or 0; i+=v.get('inputTokens',0) or 0
    c+=v.get('cacheReadTokens',0) or 0; o+=v.get('outputTokens',0) or 0
print(f"  今日请求 {r:,} | 缓存读 {c//1000000}M | 等效 ≈{(i+c//10+o)//1000000}M")
st=json.load(open(hub+'/state.json'))
en=[a for a in st.get('accounts',[]) if a.get('enabled')]
lim=0
for a in en:
    for m,u in (a.get('modelRateLimits') or {}).items():
        if isinstance(u,(int,float)):
            if u>1e12: u/=1000
            if u>now: lim+=1; break
print(f"  账户 {len(en)}/{len(st.get('accounts',[]))} 启用 | 限流 {lim}")
PY

echo "[签到]"
./checkin-verify.sh 2>/dev/null | grep -E "已处理|未完成|已错过|未执行" | head -2 | sed 's/^/  /'

echo "[告警]"
_AL=$(./llm-alert.sh 2>/dev/null | head -1)
[ -n "$_AL" ] && echo "$_AL" | tr ';' '\n' | sed 's/^/  /' || echo "  无"

echo "[tab_36 渲染内存]"
python3 - <<'PY2'
import json
try:
    rows=[]
    for l in open('../state/history.jsonl'):
        l=l.strip()
        if not l: continue
        try: d=json.loads(l)
        except: continue
        m=d.get('host_tab_mb')
        if isinstance(m,int) and m>0: rows.append((d['ts'],m))
    if not rows:
        print("  （无历史快照）"); raise SystemExit
    ms=[m for _,m in rows]
    peak=max(ms); latest=ms[-1]
    print(f"  样本 {len(rows)} 条 | 峰值 {peak} MB | 最新 {latest} MB")
    # 阈值：峰值接近 2000 或单次超过 1800 都值得知道
    if latest>=2000:
        print("  ⚠⚠ 超过 2000 MB —— 建议关闭闲置标签页释放内存")
    elif latest>=1800 or peak>=1950:
        print("  ⚠ 接近高位 —— 观察，若持续爬升需处理")
    elif latest>=1600:
        print("  · 中高位，正常波动范围")
    else:
        print("  ✓ 低位，无需关注")
except Exception as e:
    print("  （分析跳过:",e,"）")
PY2

echo "[现在该做什么]"
python3 - "$HUB" <<'PY2'
import json,sys,time,datetime
hub=sys.argv[1]; now=time.time()
BJ=datetime.timezone(datetime.timedelta(hours=8))
todos=[]
st=json.load(open(hub+'/state.json'))

# P0: adb 通道断开（最紧急 —— 断了就无法备份、无法执行设备操作）
try:
    import socket as _sock
    _ok=False
    try:
        _s2=_sock.create_connection(('127.0.0.1',5555),timeout=3); _s2.close(); _ok=True
    except Exception: _ok=False
    if not _ok:
        todos.append(('P0','**adb 通道断开** → 需在电脑执行 adb tcpip 5555（备份/设备操作已失效）'))
except Exception: pass

# P0: 守护未运行（最紧急 —— 没有它就没有自动自愈与巡检）
try:
    import subprocess as _sp2
    _o2=_sp2.run(['./daemon-ctl.sh','status'],capture_output=True,text=True,timeout=20)
    # ⚠️ 不能判 `'running' in stdout` —— `not running` 也含 "running" 子串（Round 129 踩到）
    _st2=(_o2.stdout or '').strip().lower()
    if not _st2.startswith('running'):
        todos.append(('P0','守护未运行 → 执行 ./scripts/boot-hook.sh 或 daemon-ctl.sh start 180'))
except Exception: pass

# P0: 不可续期账户近期失效
for a in st.get('accounts',[]):
    if not a.get('enabled') or a.get('refreshable'): continue
    e=a.get('expiresAt')
    if not e: continue
    d=(e/1000-now)/86400
    if d<=7:
        t=datetime.datetime.fromtimestamp(e/1000,BJ).strftime('%m-%d %H:%M')
        if d < 0:
            todos.append(('P0', f"{a.get('provider')} 账户**已过期 {-d:.1f} 天**（{t}）→ 重新登录"))
        else:
            todos.append(('P0', f"{a.get('provider')} 账户 {d:.1f} 天后失效（{t}）→ 重新登录"))

# P0: 签到待补且已超窗口风险
try:
    ck=json.load(open(hub+'/auto-checkin.json'))
    pend=ck.get('pendingSlot') or ''
    if pend:
        todos.append(('P1', f"签到 {pend} 有渠道待补 → 若 3h 内未补齐需修凭据"))
except Exception: pass

# P0: 电量告急（设备断电 → adb/Shizuku 全失，需电脑才能恢复）
try:
    # 读快照而非调 pilot（pilot 会限流，实测 50% 失败；快照用 adb 更可靠）
    import os as _os
    _lv=None; _ch=None
    _hp='../state/history.jsonl'
    if _os.path.exists(_hp):
        for _l in reversed(open(_hp).read().strip().split(chr(10))[-5:]):
            try: _d=json.loads(_l)
            except: continue
            _v=_d.get('battery_level')
            if _v and str(_v).isdigit():
                _lv=int(_v); _ch=(_d.get('battery_charging') is True); break
    if _lv is not None:
        if not _ch:
            # 关键信号是"未充电"本身，不只是电量低。实测放电 12.7%/h（Round 116）
            _eta=_lv/12.7
            if _lv<=20:
                todos.append(('P0', f"电量 {_lv}% 未充电 → **立即充电**，约 {_eta:.1f} 小时耗尽（断电将丢失 adb/Shizuku）"))
            elif _eta<=12:
                todos.append(('P1', f"电量 {_lv}% 未充电，约 {_eta:.1f} 小时后耗尽 → 建议充电"))
            else:
                todos.append(('P2', f"电量 {_lv}% 未充电（约 {_eta:.1f} 小时耗尽）"))
except Exception: pass

# P1: 已过期但仍被路由的账户（过期账户会持续产生错误）
try:
    _st3=json.load(open(hub+'/state.json'))
    _now3=time.time()
    _expired_active=[]
    _led3=json.load(open(hub+'/token-ledger.json'))
    _d3=sorted(_led3.get('days',{}).keys())[-2:]
    for _a in _st3.get('accounts',[]):
        if not _a.get('enabled'): continue
        _e=_a.get('expiresAt')
        if not _e or _e/1000 >= _now3: continue      # 未过期
        # 过期了，看近2天是否仍有请求
        _cnt=0
        for _day in _d3:
            for _k,_v in _led3['days'][_day].items():
                if _a.get('id') and _a['id'] in _k:
                    _cnt+=_v.get('requests',0) or 0
        if _cnt>0:
            _expired_active.append((_a.get('provider'), _a.get('id','')[:18], _cnt))
    if _expired_active:
        _desc=', '.join(f'{p2}({c}次)' for p2,i2,c in _expired_active[:3])
        todos.append(('P1', f'**过期账户仍在被请求**: {_desc} → 建议在面板中停用'))
except Exception: pass

# P1: 供应商严重劣化
try:
    from collections import defaultdict as _d
    led=json.load(open(hub+'/token-ledger.json'))
    ds=sorted(led.get('days',{}).keys())[-2:]
    per=_d(lambda:{'r':0,'e':0})
    for day in ds:
        for k,v in led['days'][day].items():
            p=k.split('|')
            if len(p)>1:
                per[p[1]]['r']+=v.get('requests',0) or 0
                per[p[1]]['e']+=v.get('errors',0) or 0
    # 已在 P0（即将失效）的 provider 不再报劣化 —— 处置已明确，避免重复打扰
    p0prov={t[1].split()[0] for t in todos if t[0]=='P0'}
    for pv,a in per.items():
        if pv in p0prov: continue
        if a['r']>=20 and a['e']*100//a['r']>=25:
            todos.append(('P1', f"{pv} 近2天 {a['e']*100//a['r']}% 错误 → 考虑停用或排查"))
except Exception: pass

if todos:
    for lv,msg in sorted(todos):
        print(f"  {lv}  {msg}")
else:
    print("  ✓ 无需操作")
print("  （其余现象属正常波动，不必处理）")
PY2

if [ "$FULL" = "--full" ]; then
  echo "[供应商诊断]"
  ./diagnose-provider.sh 2>/dev/null | grep -E "▸|⇒" | head -12 | sed 's/^/  /'
fi
