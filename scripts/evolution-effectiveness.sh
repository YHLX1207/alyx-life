#!/usr/bin/env bash
# 进化有效性评估：衡量自我进化是否真的在改善系统
#
# 为什么需要（Round 246）：
#   系统能提议规则和行动、应用规则、使用行动、评估单个行动的效果。
#   但**没有一个综合指标衡量进化整体是否在改善系统**。
#   
#   进化可能产生大量数据，却未必改善系统。
#   没有有效性评估，系统无法知道"我进化了"和"我变好了"之间的区别。
#
# 本脚本：
#   1. 读取所有进化数据（提议、应用、评估、行动）
#   2. 计算多维有效性指标
#   3. 给出综合评分（0-100）
#   4. 写入 state/evolution-effectiveness.json
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
OUT="$STATE/evolution-effectiveness.json"

python3 - "$STATE" "$OUT" <<'PY'
import sys, os, json, datetime

state, out_path = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def load_jsonl(path):
    rows = []
    try:
        for line in open(os.path.join(state, path), encoding="utf-8"):
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

# --- 读取进化数据 ---
rule_props = load_jsonl("rule-proposals.jsonl")
act_props = load_jsonl("action-proposals.jsonl")
action_evals = load_jsonl("chain-action-eval.jsonl")
executed = load_jsonl("chain-actions.jsonl")

# --- 计算有效性指标 ---
# 1. 提议覆盖：有多少提议被产出
proposal_count = len(rule_props) + len(act_props)

# 2. 应用覆盖：有多少提议被实际应用
#    规则被应用 = chain-decisions 中出现"反复模式再次出现"
#    行动被应用 = chain-actions 中有 source=evolved
applied_rules = 0
applied_actions = 0
for a in executed:
    if a.get("source") == "evolved":
        applied_actions += 1

# 3. 行动有效性：应用的行动中，多少是有效的
effective_actions = sum(1 for e in action_evals if e.get("verdict") == "effective")
ineffective_actions = sum(1 for e in action_evals if e.get("verdict") == "ineffective")

# 4. 综合评分（0-100）
#    权重：行动有效性 40%，应用覆盖 30%，提议覆盖 20%，规则应用 10%
score = 0

if executed:
    action_eff_rate = effective_actions / len(executed) if executed else 0
    score += action_eff_rate * 40
else:
    score += 0  # 无行动数据

if act_props:
    apply_rate = applied_actions / len(act_props) if act_props else 0
    score += min(apply_rate, 1.0) * 30
else:
    score += 0

if proposal_count > 0:
    score += min(proposal_count / 10, 1.0) * 20
else:
    score += 0

# 规则应用率（简化：有规则提议即算 10 分）
if rule_props:
    score += 10

score = round(min(score, 100), 1)

# --- 生成报告 ---
metrics = {
    "ts": ts,
    "proposals": {
        "rules": len(rule_props),
        "actions": len(act_props),
        "total": proposal_count,
    },
    "application": {
        "evolved_actions_used": applied_actions,
        "total_actions": len(executed),
    },
    "effectiveness": {
        "effective": effective_actions,
        "ineffective": ineffective_actions,
        "unknown": len(action_evals) - effective_actions - ineffective_actions,
    },
    "score": score,
}

# 状态判定
if proposal_count == 0 and len(executed) == 0:
    status = "idle"
    note = "系统稳定，进化机制就绪但尚未触发。无反复问题 ⇒ 无需进化。"
elif score >= 70:
    status = "effective"
    note = "进化正在有效改善系统。"
elif score >= 40:
    status = "partial"
    note = "进化部分有效，但还有改进空间。"
elif score > 0:
    status = "marginal"
    note = "进化产生了数据，但有效性有限。"
else:
    status = "no-data"
    note = "有进化活动但无法评估有效性。"

metrics["status"] = status
metrics["note"] = note

os.makedirs(state, exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(metrics, f, ensure_ascii=False, indent=1)

# 输出
print(f"  提议: 规则 {len(rule_props)} + 行动 {len(act_props)} = {proposal_count}")
print(f"  应用: 进化行动使用 {applied_actions} / 总行动 {len(executed)}")
print(f"  效果: 有效 {effective_actions} / 无效 {ineffective_actions}")
print(f"  评分: {score}/100  状态: {status}")
print(f"  说明: {note}")
print(f"  ✓ 已写入 {out_path}")
PY
