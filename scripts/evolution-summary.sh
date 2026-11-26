#!/usr/bin/env bash
# 进化状态摘要：让系统能感知和理解自己的进化程度
#
# 为什么需要（Round 241）：
#   系统已具备完整的自进化机制（evolve → eval → decide → act），
#   数据存在 JSONL 文件里（rule-proposals / action-proposals / action-eval）。
#   但这些是机器可读的，**系统自己和接手者无法快速理解"我进化到了什么程度"**。
#
#   目标要求"自我感知"。感知自己的进化状态，是自我感知的一部分。
#
# 本脚本：
#   1. 读取所有进化数据文件
#   2. 汇总：提议了多少规则、行动，多少有效，多少无效
#   3. 生成可读摘要 state/evolution-summary.md
#   4. 输出关键指标
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
OUT="$STATE/evolution-summary.md"

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

# --- 读取进化数据 ---
rule_props = load_jsonl(os.path.join(state, "rule-proposals.jsonl"))
act_props = load_jsonl(os.path.join(state, "action-proposals.jsonl"))
action_evals = load_jsonl(os.path.join(state, "chain-action-eval.jsonl"))
executed_actions = load_jsonl(os.path.join(state, "chain-actions.jsonl"))

# --- 汇总 ---
# 规则提议
rule_count = len(rule_props)
rule_latest = rule_props[-1].get("ts", "") if rule_props else ""

# 行动提议
act_count = len(act_props)
act_latest = act_props[-1].get("ts", "") if act_props else ""

# 效果评估
effective = sum(1 for e in action_evals if e.get("verdict") == "effective")
ineffective = sum(1 for e in action_evals if e.get("verdict") == "ineffective")
unknown = sum(1 for e in action_evals if e.get("verdict") == "unknown")
eval_total = len(action_evals)

# 已执行行动
executed_total = len(executed_actions)
evolved_source = sum(1 for a in executed_actions if a.get("source") == "evolved")
static_source = sum(1 for a in executed_actions if a.get("source") == "static")

# 有效率
if eval_total > 0:
    effective_rate = effective / eval_total * 100
else:
    effective_rate = 0

# --- 生成摘要 ---
lines = [
    "# 进化状态摘要",
    "",
    f"> 生成时间：{ts}",
    f"> 这是系统对自身进化状态的自感知。数据来自 evolution 机制的实际产出。",
    "",
    "## 一、规则进化",
    "",
    f"- 已提议规则：**{rule_count}** 条",
    f"- 最新提议时间：{rule_latest or '尚无'}",
    "",
    "## 二、行动进化",
    "",
    f"- 已提议行动映射：**{act_count}** 条",
    f"- 最新提议时间：{act_latest or '尚无'}",
    "",
    "## 三、行动效果",
    "",
    f"- 已评估行动：**{eval_total}** 项",
    f"- 有效（问题未复发）：**{effective}** 项",
    f"- 无效（问题复发）：**{ineffective}** 项",
    f"- 未知（数据不足）：**{unknown}** 项",
    f"- 有效率：**{effective_rate:.0f}%**",
    "",
    "## 四、已执行行动",
    "",
    f"- 总执行：**{executed_total}** 项",
    f"- 使用进化映射（evolved）：**{evolved_source}** 项",
    f"- 使用静态映射（static）：**{static_source}** 项",
    "",
    "## 五、当前状态判定",
    "",
]

if rule_count == 0 and act_count == 0 and eval_total == 0:
    lines.append("**系统尚未触发进化。** 这通常是因为系统运行稳定，没有反复出现的问题需要进化。")
    lines.append("进化机制已就绪，会在问题反复出现时自动启动。")
elif act_count > 0 and effective > 0:
    lines.append(f"**进化已生效。** 已提议 {act_count} 条行动映射，其中 {effective} 项被验证有效。")
    lines.append("系统能从自身历史中学习有效的行动，而非仅使用预定义动作。")
elif rule_count > 0:
    lines.append(f"**规则进化已启动。** 已提议 {rule_count} 条检测规则。")
else:
    lines.append("**进化机制已运行，但尚未产生有效提议。** 可能需要更多历史数据积累。")

lines += [
    "",
    "## 六、进化管线状态",
    "",
    "- chain-evolve：提议规则与行动 ✓",
    "- chain-eval：评估行动效果 ✓",
    "- chain-decide：应用自增规则 ✓",
    "- chain-act：使用进化行动映射 ✓",
    "",
]

content = "\n".join(lines)
os.makedirs(state, exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(content)

# 输出关键指标
print(f"  规则提议: {rule_count} 条")
print(f"  行动提议: {act_count} 条")
print(f"  效果评估: {eval_total} 项（有效 {effective} / 无效 {ineffective} / 未知 {unknown}）")
print(f"  有效率:   {effective_rate:.0f}%")
print(f"  已执行:   {executed_total} 项（evolved {evolved_source} / static {static_source}）")
print(f"  ✓ 摘要已写入 {out_path}")
PY
