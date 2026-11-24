#!/usr/bin/env bash
# 探针质量检查：只报**高置信度**的测量缺陷模式
#
# 设计原则（源自 D032/D103 的告警噪音教训）：
#   **宁可漏报，不可误报** —— 误报会让检查被忽略，那时真问题也会被忽略。
#
# 已排除的假阳性（Round 130 实测）：
#   · `'x' in var.lower()`  —— 模糊筛选的正当用法
#   · `ps -A -o NAME | grep -cx name` —— -x 整行匹配 + NAME 只含进程名，无自匹配
#   · `ps | grep -v grep`  —— 已自带排除
#
# 只查这两类：
#   1) `ps aux|args` 接 grep 且**没有** -v grep / -x 保护
#   2) Python 里对**已知否定词**做 `in` 判断（如 'running' in status）
set -uo pipefail
cd "$(dirname "$0")"
BAD=0

# 1) ps 全量输出（含命令行）直接 grep，且无任何保护
_ps=$(grep -nE "ps +(aux|-A +-o +[A-Z,]*(ARGS|CMD))" *.sh 2>/dev/null \
  | grep "|" | grep -vE "grep -v grep|grep -cx|grep -qx|grep -x|proc-find|lint-probe" || true)
if [ -n "$_ps" ]; then
  echo "  ✗ ps 全量输出直接 grep 且无保护（会匹配到查询命令自身）:"
  echo "$_ps" | sed 's/^/      /'
  BAD=$((BAD+1))
fi

# 2) 对否定词做 in 判断
_neg=$(grep -nE "['\"](running|ok|success|enabled|active)['\"] +(not )?in " *.sh 2>/dev/null \
  | grep -vE "lint-probe|startswith|endswith" \
  | grep -vE ":[0-9]+:[[:space:]]*#" || true)   # 排除注释行
if [ -n "$_neg" ]; then
  echo "  ✗ 对状态词做裸子串判断（'not running' 也含 'running'）:"
  echo "$_neg" | sed 's/^/      /'
  BAD=$((BAD+1))
fi

if [ "$BAD" -eq 0 ]; then
  echo "  ✓ 未发现高置信度探针缺陷"
  exit 0
else
  echo "  ✗ $BAD 类缺陷"
  exit 1
fi
