#!/usr/bin/env bash
# 检查器质量检查：找出"结构上不可能失败"的回归项
#
# 为什么需要（Round 182）：
#   我先后 4 次写出"永远通过"的检查（D112/D114/D177 等）。
#   每次都是自己写完、自己验收，没人质疑，直到偶然发现。
#   本脚本把那个"质疑"自动化。
#
# 检测三类：
#   A. 同一分支里既有 pass++ 又有 fail++ —— 逻辑冗余
#   B. `⚠ ... pass++` 且该分支无 fail —— 警告级但永远通过
#   C. if [ ... ]; then ... pass++ ; fi 且无 else —— 条件为假时静默跳过
set -uo pipefail
cd "$(dirname "$0")"

F=verify.sh
[ -f "$F" ] || { echo "  未找到 $F"; exit 1; }

_rc=0
python3 - "$F" <<'PY' || _rc=$?
import sys, re

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")

findings = []

# --- 类 B：⚠ 且 pass++ 且同一行/同一分支无 fail ---
for i, l in enumerate(lines, 1):
    if "⚠" in l and "pass=$((pass+1))" in l and "fail=" not in l:
        # 允许：明确标注为"跳过"的外部依赖
        if "跳过" in l or "adb 不可用" in l or "pilot" in l:
            continue
        # 提取提示文本
        m = re.search(r'\u26a0\s*([^\\"]{0,40})', l)
        findings.append(("B", i, (m.group(1) if m else l.strip()[:40]).strip()))

# --- 类 C：if ... then printf 成功 ... fi 且无 else（会静默跳过）---
# 简化：找出形如 `if X; then printf "  ✓ ..." ; pass++ ; fi` 且下一行不是 else
for i, l in enumerate(lines):
    s = l.strip()
    if s.startswith("if ") and "then printf" in s and "\u2713" in s and "pass=$((pass+1))" in s:
        if s.rstrip().endswith("fi"):
            # 同行闭合且无 else
            findings.append(("C", i+1, s[:60]))
        else:
            # 检查下一行是否 else
            nxt = lines[i+1].strip() if i+1 < len(lines) else ""
            if not nxt.startswith("else"):
                findings.append(("C", i+1, s[:60]))

# --- 类 A：pass 和 fail 在同一个 printf 里 ---
for i, l in enumerate(lines, 1):
    if "pass=$((pass+1))" in l and "fail=$((fail+1))" in l:
        findings.append(("A", i, l.strip()[:60]))

print(f"  扫描 {len(lines)} 行，发现 {len(findings)} 处可疑：")
print()
if not findings:
    print("  ✓ 未发现结构上必然通过的检查")
    sys.exit(0)

kind_name = {"A": "pass+fail 同行", "B": "⚠ 但永不失败", "C": "无 else 分支"}
for k, ln, desc in findings:
    print(f"    [{k}] 行{ln}: {kind_name[k]}")
    print(f"          {desc}")
print()
print("  说明：")
print("    B 类若是外部依赖（adb/网络），可保留，但应有独立告警渠道")
print("    C 类在条件为假时静默跳过，可能掩盖问题")
sys.exit(1 if findings else 0)
PY

exit "${_rc:-0}"
