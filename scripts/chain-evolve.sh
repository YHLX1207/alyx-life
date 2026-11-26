#!/usr/bin/env bash
# 规则自增：从自身决策历史中发现反复模式，提议新规则
#
# 为什么需要（Round 235）：
#   目标要求"自我进化"。但链-decide 的规则全部预写死，
#   系统只能应用规则，不能根据自己的经验新增规则。
#   ⇒ 这不是"进化"，是"执行"。
#
# 本脚本实现真正的自我进化第一步：
#   1. 读取自身决策历史（chain-decisions.jsonl）
#   2. 统计反复出现的 finding 模式（同一问题出现多次）
#   3. 对反复出现的模式，提议一条新规则
#   4. 写入 state/rule-proposals.jsonl
#
# 设计原则：
#   · 只提议**可验证的模式**（基于历史数据），不编造
#   · 提议的规则是数据（条件/级别/说明），不是可执行代码
#   · chain-decide.sh 会动态加载并应用这些规则
#   · 防止重复提议：已有相同规则则跳过
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
PROPOSALS="$STATE/rule-proposals.jsonl"

python3 - "$STATE" "$PROPOSALS" <<'PY'
import sys, os, json, datetime
from collections import Counter

state, prop_path = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# 读决策历史
decs = []
try:
    for line in open(os.path.join(state, "chain-decisions.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            decs.append(json.loads(line))
        except Exception:
            pass
except FileNotFoundError:
    pass

# 已提议的规则（防止重复）
existing = set()
try:
    for line in open(prop_path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
            existing.add(r.get("rule_id", ""))
        except Exception:
            pass
except FileNotFoundError:
    pass

# 统计 finding 模式
# finding 格式：[severity] text
finding_counts = Counter()
finding_examples = {}
for d in decs:
    for f in d.get("findings") or []:
        sev = f.get("severity", "?")
        text = f.get("finding", "").strip()
        if not text:
            continue
        # 归一化：去掉数字和具体值，保留模式
        import re
        norm = re.sub(r"\d+", "N", text)[:40]
        key = (sev, norm)
        finding_counts[key] += 1
        if key not in finding_examples:
            finding_examples[key] = {
                "severity": sev,
                "text": text,
                "count": 0,
                "first_ts": d.get("ts", ""),
                "last_ts": d.get("ts", ""),
            }
        finding_examples[key]["count"] += 1
        finding_examples[key]["last_ts"] = d.get("ts", finding_examples[key]["last_ts"])

# ⚠️ 只对**问题**模式提议规则（Round 235）：
#    实测首次运行时只抓到"决策在增长"（ok 级，良性确认），
#    这不是需要检测的问题，固化为规则没有意义。
#    自我进化的目标是：反复出现的**问题**应该变成规则，提前发现。
PROBLEM_SEVERITIES = {"high", "critical"}

# 阈值：同一模式出现 >= 3 次 ⇒ 提议规则
THRESHOLD = 3
proposals = []
for (sev, norm), count in finding_counts.most_common():
    if count < THRESHOLD:
        continue
    if sev not in PROBLEM_SEVERITIES:
        continue  # 只关注问题模式，良性确认不提议
    ex = finding_examples[(sev, norm)]
    rule_id = f"auto-{norm.replace(' ', '-').replace('N', 'x')[:20]}"
    if rule_id in existing:
        continue
    # ⚠️ 跳过已有规则覆盖的模式：如果 pattern 文本出现在 chain-decide.sh 中，
    #    说明已有规则在检测它，无需重复提议。
    try:
        _decide_src = open("./chain-decide.sh", encoding="utf-8").read()
        if norm.split("N")[0].strip() and norm.split("N")[0].strip() in _decide_src:
            continue
    except Exception:
        pass
    proposals.append({
        "ts": ts,
        "rule_id": rule_id,
        "trigger": "recurring-finding",
        "severity": sev,
        "pattern": norm,
        "occurrences": count,
        "example": ex["text"],
        "first_seen": ex["first_ts"],
        "last_seen": ex["last_ts"],
        "reason": f"该模式在决策历史中出现 {count} 次，建议固化为规则以提前检测",
    })

if not proposals:
    print("  · 未发现需要提议规则的反复模式")
# ⚠️ 不在此 exit：行动提议在规则提议之后，需要独立判断（Round 238）

# 写入
os.makedirs(state, exist_ok=True)
with open(prop_path, "a", encoding="utf-8") as f:
    for p in proposals:
        f.write(json.dumps(p, ensure_ascii=False) + "\n")

# 控制体积
rows = []
try:
    for line in open(prop_path, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
except FileNotFoundError:
    pass
if len(rows) > 100:
    with open(prop_path, "w", encoding="utf-8") as f:
        for r in rows[-100:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

for p in proposals:
    print(f"  ＋ 提议规则 [{p['rule_id']}]")
    print(f"    模式: {p['pattern']}")
    print(f"    出现 {p['occurrences']} 次，级别 {p['severity']}")
    print(f"    示例: {p['example'][:60]}")
print(f"  ✓ 已写入 {len(proposals)} 条规则提议")

# --- 行动映射提议（Round 237）---
# ⚠️ 此前自进化只覆盖"检测规则"，不覆盖"行动映射"。
#    chain-act 的动作映射是静态预定义的，系统不能自己进化行动能力。
#    现在扩展：从行动历史中学习"什么发现对应什么行动"，提议行动映射。
_act_proposals = []
_act_path = os.path.join(state, "chain-actions.jsonl")
if os.path.exists(_act_path):
    _act_history = []
    try:
        for line in open(_act_path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                _act_history.append(json.loads(line))
            except Exception:
                pass
    except Exception:
        pass
    if _act_history:
        # 按 finding 聚合：同一 finding 用过哪些行动
        from collections import defaultdict
        _finding_actions = defaultdict(lambda: defaultdict(int))
        for a in _act_history:
            _f = a.get("finding", "")
            _act = a.get("action", "")
            if _f and _act and a.get("status") == "ok":
                _finding_actions[_f][_act] += 1
        # 只对出现 >= 3 次的 finding 提议行动映射
        for _f, _acts in _finding_actions.items():
            total = sum(_acts.values())
            if total < 3:
                continue
            # 选最常用的行动
            _best_act, _best_count = max(_acts.items(), key=lambda x: x[1])
            _pat = _f  # 用原始 finding 文本作为模式
            _act_id = "auto-action-" + _f.replace(" ", "-")[:20]
            # 检查是否已提议
            _existing_act = set()
            try:
                for line in open(os.path.join(state, "action-proposals.jsonl"), encoding="utf-8"):
                    line = line.strip()
                    if line:
                        try:
                            _existing_act.add(json.loads(line).get("action_id", ""))
                        except Exception:
                            pass
            except Exception:
                pass
            if _act_id in _existing_act:
                continue
            _act_proposals.append({
                "ts": ts,
                "action_id": _act_id,
                "finding": _f,
                "action": _best_act,
                "occurrences": total,
                "effective_count": _best_count,
                "reason": f"发现「{_f}」出现 {total} 次，行动「{_best_act}」成功 {_best_count} 次，建议固化",
            })

if _act_proposals:
    _act_prop_path = os.path.join(state, "action-proposals.jsonl")
    with open(_act_prop_path, "a", encoding="utf-8") as f:
        for p in _act_proposals:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    for p in _act_proposals:
        print(f"  ＋ 提议行动 [{p['action_id']}]")
        print(f"    发现: {p['finding']} → 行动: {p['action']}")
        print(f"    出现 {p['occurrences']} 次，成功 {p['effective_count']} 次")
    print(f"  ✓ 已写入 {len(_act_proposals)} 条行动提议")
PY
