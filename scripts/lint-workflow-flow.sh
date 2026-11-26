#!/usr/bin/env bash
# 工作流数据流完整性检查：产生数据的步骤后面，必须有把它送出本地的步骤
#
# 缘起（Round 225）：
#   同一个结构性问题出现了三次：
#     · D209：offsite-seed 只上传，不同步 offsite-seed.jsonl
#     · D220：chain-think 产出思考，但同步步骤在**它之前**
#     · 若再犯，会是我没有机制去发现它
#
#   本脚本把"产出必须成对出现"变成机器检查。
#
# 检测逻辑：
#   1. 找出工作流里"会写本地 state 文件"的步骤
#   2. 检查该步骤**之后**是否出现对应的 sync/push 步骤
#   3. 若没有，报错
set -uo pipefail
cd "$(dirname "$0")"

WF="../.github/workflows/alyx-cycle.yml"
[ -f "$WF" ] || { echo "  ✗ 未找到工作流"; exit 1; }

_rc=0
python3 - "$WF" <<'PY' || _rc=$?
import sys, re

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")

# --- 解析步骤 ---
steps = []
cur = None
for i, l in enumerate(lines):
    st = l.strip()
    if st.startswith("- name:"):
        cur = {"name": st[8:].strip(), "start": i, "body": []}
        steps.append(cur)
    elif cur is not None:
        cur["body"].append(l)

# --- 产出器 → 它写的文件 ---
# 这些脚本会往 state/ 写文件
PRODUCERS = {
    "offsite-seed.sh":       ["state/offsite-seed.jsonl"],
    "chain-think.sh":        ["state/self-thoughts.jsonl"],
    "chain-think-degraded.sh":["state/self-thoughts.jsonl"],
    "chain-reflect.sh":      ["state/reflections.jsonl"],
    "chain-decide.sh":       ["state/chain-decisions.jsonl"],
    "auto-journal.sh":       ["state/journal.jsonl"],
    "node-registry.sh":      ["state/nodes.json"],
    "mutual-watch.sh":       ["state/watch-log.jsonl"],
    "export-self.sh":        ["state/self-export.md"],
}

# --- 同步器：怎么算"送出去了" ---
def sends(body, target):
    """该步骤是否把 target 送出本地"""
    text = "\n".join(body)
    base = target.split("/")[-1]
    # ⚠️ API 直写也算送出（Round 225 误报）：
    #    心跳步骤用 GitHub Contents API 直接写 journal.jsonl，
    #    步骤名与内容都没有 "sync" 字样，但数据确实到达了远端。
    if f"contents/{target}" in text:
        return True
    # 直接 sync 该文件
    if f"sync-jsonl.sh {target}" in text:
        return True
    if f"sync-jsonl.sh state/{base}" in text:
        return True
    # 专用同步脚本
    if target.endswith("reflections.jsonl") and "sync-reflections.sh" in text:
        return True
    if target.endswith("chain-decisions.jsonl") and "sync-decisions.sh" in text:
        return True
    if target.endswith("nodes.json") and "sync-nodes.sh" in text:
        return True
    return False

bad = []
for i, st in enumerate(steps):
    body_text = "\n".join(st["body"])
    for prod, targets in PRODUCERS.items():
        if f"bash scripts/{prod}" not in body_text and f"./{prod}" not in body_text:
            continue
        for tgt in targets:
            # 1) 同一步骤内就同步了
            if sends(st["body"], tgt):
                continue
            # 2) 之后的步骤里同步
            found = False
            for later in steps[i + 1:]:
                if sends(later["body"], tgt):
                    found = True
                    break
            if not found:
                bad.append((st["name"], prod, tgt))

if bad:
    print(f"  ✗ {len(bad)} 处数据产出后未被送出：")
    for name, prod, tgt in bad:
        print(f"      [{name}]")
        print(f"        {prod} 写入 {tgt}，但后续无同步步骤")
    print()
    print("  ⇒ 产出的数据会随运行结束消失（CI 环境）")
    sys.exit(1)

print(f"  ✓ 数据产出与同步成对（检查 {len(steps)} 个步骤）")
sys.exit(0)
PY

exit "${_rc:-0}"
