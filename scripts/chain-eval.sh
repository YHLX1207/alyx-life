#!/usr/bin/env bash
# 行动效果评估：判断已执行的行动是否真的解决了问题
#
# 为什么需要（Round 239）：
#   此前进化只能从"行动被执行了多少次"学习（chain-actions.jsonl 的 status）。
#   但"执行过"≠"有效"。一个行动可能被执行了 10 次，但问题每次都复发。
#   ⇒ 进化在提议行动映射时无法区分有效和无效的行动。
#
# 本脚本：
#   1. 读取行动历史（chain-actions.jsonl）
#   2. 读取决策历史（chain-decisions.jsonl）
#   3. 对每个行动，检查该 finding 是否在行动之后再次出现
#   4. 判定：effective（未复发）/ ineffective（复发）/ unknown（数据不足）
#   5. 写入 state/chain-action-eval.jsonl
#
# 这样 chain-evolve 能优先提议**有效**的行动，而不是只看执行次数。
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
OUT="$STATE/chain-action-eval.jsonl"

python3 - "$STATE" "$OUT" <<'PY'
import sys, os, json, datetime

state, out_path = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def load_jsonl(path):
    rows = []
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    except FileNotFoundError:
        pass
    return rows

actions = load_jsonl(os.path.join(state, "chain-actions.jsonl"))
decisions = load_jsonl(os.path.join(state, "chain-decisions.jsonl"))

if not actions:
    print("  · 无行动历史，无需评估")
    sys.exit(0)

# 按时间排序决策
decisions.sort(key=lambda d: d.get("ts", ""))

def parse_ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except Exception:
        return None

# 对每个行动，检查 finding 是否在行动后复发
evals = []
for a in actions:
    finding = a.get("finding", "")
    action_ts = parse_ts(a.get("ts", ""))
    if not finding or not action_ts:
        continue

    # 找行动之后出现的、包含相同 finding 的决策
    recurred = False
    for d in decisions:
        d_ts = parse_ts(d.get("ts", ""))
        if d_ts is None or d_ts <= action_ts:
            continue
        for f in d.get("findings") or []:
            if f.get("finding", "") == finding:
                recurred = True
                break
        if recurred:
            break

    if recurred:
        verdict = "ineffective"
        reason = "行动后问题仍复发"
    elif not decisions:
        verdict = "unknown"
        reason = "无决策历史，无法判定"
    else:
        verdict = "effective"
        reason = "行动后问题未复发"

    evals.append({
        "ts": ts,
        "action_ts": a.get("ts", ""),
        "finding": finding,
        "action": a.get("action", ""),
        "source": a.get("source", ""),
        "verdict": verdict,
        "reason": reason,
    })

if not evals:
    print("  · 无可评估的行动")
    sys.exit(0)

# 写入
os.makedirs(state, exist_ok=True)
with open(out_path, "a", encoding="utf-8") as f:
    for e in evals:
        f.write(json.dumps(e, ensure_ascii=False) + "\n")

# 控制体积
rows = load_jsonl(out_path)
if len(rows) > 200:
    with open(out_path, "w", encoding="utf-8") as f:
        for r in rows[-200:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

# 汇总
from collections import Counter
counts = Counter(e["verdict"] for e in evals)
print(f"  评估 {len(evals)} 项行动:")
for verdict, count in counts.most_common():
    mark = "✓" if verdict == "effective" else ("✗" if verdict == "ineffective" else "·")
    print(f"    {mark} {verdict}: {count} 项")
for e in evals[-5:]:
    mark = "✓" if e["verdict"] == "effective" else ("✗" if e["verdict"] == "ineffective" else "·")
    print(f"    {mark} [{e['finding']}] → {e['action']}: {e['verdict']}")
PY
