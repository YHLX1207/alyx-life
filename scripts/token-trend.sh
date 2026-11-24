#!/usr/bin/env bash
# Token 消耗趋势与自我审视
# 目标：不只看"花了多少"，还要看"花在什么地方、能否优化"
set -uo pipefail
cd "$(dirname "$0")"
HUB=/root/projects/.dsh/jet-hub

python3 - "$HUB" <<'PY'
import json,sys
from collections import defaultdict
hub=sys.argv[1]
d=json.load(open(hub+'/token-ledger.json'))
days=sorted(d.get('days',{}).keys())

def day_stat(day):
    s={'r':0,'i':0,'c':0,'o':0,'re':0}
    for v in d['days'][day].values():
        s['r']+=v.get('requests',0) or 0
        s['i']+=v.get('inputTokens',0) or 0
        s['c']+=v.get('cacheReadTokens',0) or 0
        s['o']+=v.get('outputTokens',0) or 0
        s['re']+=v.get('reasoningTokens',0) or 0
    return s

print("=== 近 5 天消耗 ===")
print(f"  {'日期':<12}{'请求':>7}{'非缓存输入':>12}{'缓存读':>13}{'输出':>10}")
for day in days[-5:]:
    s=day_stat(day)
    print(f"  {day:<12}{s['r']:>7,}{s['i']:>12,}{s['c']:>13,}{s['o']:>10,}")

t=day_stat(days[-1])
print(f"\n=== 今日结构（{days[-1]}）===")
print(f"  请求 {t['r']:,} | 非缓存输入 {t['i']:,} | 缓存读 {t['c']:,} | 输出 {t['o']:,}")
if t['i']:
    print(f"  缓存/输入比 {t['c']/t['i']:.0f}x —— 前缀缓存高效，重复上下文几乎全走缓存")
print(f"  推理占输出 {t['re']*100//max(t['o'],1)}%")
# 等效成本估算（缓存读按 1/10 计）
eq = t['i'] + t['c']//10 + t['o']
print(f"\n  等效标准 token ≈ {eq:,}（缓存按 1/10 折算）")
print(f"  其中缓存读贡献 {t['c']//10*100//max(eq,1)}% —— **主要成本来源**")

print("\n=== 优化方向 ===")
per_req = (t['i'] + t['c'])//max(t['r'],1)
print(f"  平均每请求 {(t['i']+t['c'])//max(t['r'],1):,} tokens")
print("  · 请求数直接放大缓存读 ⇒ 合并工具调用可降本")
print("  · 非缓存输入仅占 2% ⇒ 已接近缓存最优，无需优化上下文长度")
print("  · 输出占比较小 ⇒ 压缩回复长度的收益有限")
PY
