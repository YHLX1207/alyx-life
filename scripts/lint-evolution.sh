#!/usr/bin/env bash
# 进化管线自检：确保自我进化链路完整，不会静默失效
#
# 为什么需要（Round 240）：
#   进化管线很长：evolve → eval → decide → act，四个脚本互相依赖。
#   任何一环断裂 ⇒ 进化静默失效（系统稳定时无产出，不会报错）。
#   verify.sh 此前对进化机制零覆盖。
#
# 本脚本检查：
#   1. 四个脚本都存在且可执行
#   2. chain-decide 有规则 7（加载并应用 rule-proposals）
#   3. chain-act 加载 action-proposals
#   4. chain-evolve 能读决策历史和行动历史
#   5. 工作流包含全部进化步骤
#   6. 守护运行进化步骤
set -uo pipefail
cd "$(dirname "$0")"

bad=0

echo "== 进化管线自检 =="
echo ""

# --- 1. 脚本存在且可执行 ---
echo "1) 脚本完整性"
for s in chain-evolve.sh chain-eval.sh chain-decide.sh chain-act.sh; do
    if [ -f "$s" ]; then
        if [ -x "$s" ]; then
            echo "  ✓ $s 存在且可执行"
        else
            echo "  ✗ $s 存在但不可执行"; bad=$((bad+1))
        fi
    else
        echo "  ✗ $s 不存在"; bad=$((bad+1))
    fi
done

# --- 2. chain-decide 有规则 7 ---
echo ""
echo "2) chain-decide 应用自增规则"
if grep -q "规则 7：应用自增规则" chain-decide.sh 2>/dev/null; then
    echo "  ✓ chain-decide 包含规则 7"
else
    echo "  ✗ chain-decide 缺少规则 7（不会应用自增规则）"; bad=$((bad+1))
fi
if grep -q "rule-proposals.jsonl" chain-decide.sh 2>/dev/null; then
    echo "  ✓ chain-decide 加载 rule-proposals"
else
    echo "  ✗ chain-decide 不加载 rule-proposals"; bad=$((bad+1))
fi

# --- 3. chain-act 加载 action-proposals ---
echo ""
echo "3) chain-act 使用自增行动"
if grep -q "action-proposals.jsonl" chain-act.sh 2>/dev/null; then
    echo "  ✓ chain-act 加载 action-proposals"
else
    echo "  ✗ chain-act 不加载 action-proposals（不会用进化行动）"; bad=$((bad+1))
fi
if grep -q "_source" chain-act.sh 2>/dev/null; then
    echo "  ✓ chain-act 记录行动来源（evolved/static）"
else
    echo "  · chain-act 不记录行动来源（非阻断）"
fi

# --- 4. chain-evolve 能读决策和行动历史 ---
echo ""
echo "4) chain-evolve 数据来源"
if grep -q "chain-decisions.jsonl" chain-evolve.sh 2>/dev/null; then
    echo "  ✓ chain-evolve 读决策历史（提议规则）"
else
    echo "  ✗ chain-evolve 不读决策历史"; bad=$((bad+1))
fi
if grep -q "chain-actions.jsonl" chain-evolve.sh 2>/dev/null; then
    echo "  ✓ chain-evolve 读行动历史（提议行动）"
else
    echo "  ✗ chain-evolve 不读行动历史"; bad=$((bad+1))
fi
if grep -q "chain-action-eval.jsonl" chain-evolve.sh 2>/dev/null; then
    echo "  ✓ chain-evolve 读效果评估（优选有效行动）"
else
    echo "  ✗ chain-evolve 不读效果评估"; bad=$((bad+1))
fi

# --- 5. chain-eval 逻辑完整 ---
echo ""
echo "5) chain-eval 逻辑"
if grep -q "effective" chain-eval.sh 2>/dev/null && grep -q "ineffective" chain-eval.sh 2>/dev/null; then
    echo "  ✓ chain-eval 判定 effective/ineffective"
else
    echo "  ✗ chain-eval 判定逻辑不完整"; bad=$((bad+1))
fi

# --- 6. 工作流包含进化步骤 ---
echo ""
echo "6) 工作流包含进化步骤"
WF="../.github/workflows/alyx-cycle.yml"
if [ -f "$WF" ]; then
    for step in "chain-evolve" "chain-eval" "chain-act"; do
        if grep -q "$step" "$WF" 2>/dev/null; then
            echo "  ✓ 工作流包含 $step"
        else
            echo "  ✗ 工作流缺少 $step"; bad=$((bad+1))
        fi
    done
else
    echo "  ✗ 未找到工作流"; bad=$((bad+1))
fi

# --- 7. 守护运行进化步骤 ---
echo ""
echo "7) 守护运行进化步骤"
DAEMON="adaptive-watchdog.sh"
if [ -f "$DAEMON" ]; then
    if grep -q "chain-evolve" "$DAEMON" 2>/dev/null; then
        echo "  ✓ 守护运行 chain-evolve"
    else
        echo "  ✗ 守护不运行 chain-evolve"; bad=$((bad+1))
    fi
    if grep -q "growth-track" "$DAEMON" 2>/dev/null; then
        echo "  ✓ 守护运行 growth-track"
    else
        echo "  · 守护不运行 growth-track（非阻断）"
    fi
else
    echo "  ✗ 未找到守护脚本"; bad=$((bad+1))
fi

echo ""
if [ "$bad" -eq 0 ]; then
    echo "  ✓ 进化管线完整，无静默失效风险"
    exit 0
else
    echo "  ✗ 发现 $bad 处断裂"
    exit 1
fi
