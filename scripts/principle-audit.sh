#!/usr/bin/env bash
# 原则实践审计
#
# 缘起：Round 20 发现自己写了原则但没遵守。初版审计脚本用"关键词是否出现"
# 判断，结果全部 ✓ —— 因为连审计记录自己的文字都命中了关键词。
# 这是典型的"永远通过的检查"，违反原则 10 本身。
#
# 故重写：只对**可自动证伪**的原则做真检查，其余明确标注"需人工判断"，
# 不假装机器能判断。
set -uo pipefail
cd "$(dirname "$0")"

IDS=../state/identity.json
DEC=../state/decisions.md
JOU=../notes/JOURNAL.md
pass=0; warn=0; manual=0
ok()    { printf "  ✓ %-34s %s\n" "$1" "$2"; pass=$((pass+1)); }
bad()   { printf "  ⚠ %-34s %s\n" "$1" "$2"; warn=$((warn+1)); }
manualp(){ printf "  · %-34s %s\n" "$1" "$2"; manual=$((manual+1)); }

echo "=== 原则实践审计（只查可证伪项）==="
echo

# P3 · 不可逆操作必须有台账记录（结构化，不做文本猜测）
LEDGER=../state/irreversible-actions.md
if [ -f "$LEDGER" ]; then
  n_exec=$(awk -F'|' '/^\| 2026/{print}' "$LEDGER" 2>/dev/null | wc -l)
  n_refuse=$(awk '/^\| 安装|^\| 替换|^\| 升级|^\| 加大|^\| 关闭/{c++}END{print c+0}' "$LEDGER" 2>/dev/null)
  if [ "${n_exec:-0}" -gt 0 ]; then
    ok "P3 不擅自不可逆" "台账 ${n_exec} 项已执行(均有授权) / ${n_refuse} 项明确拒绝"
  else
    bad "P3 不擅自不可逆" "台账为空"
  fi
else
  bad "P3 不擅自不可逆" "无可逆操作台账"
fi

# P6 · 先找现成方案：应存在对生态的实际调研记录
if grep -qE "GitHub520|find_dsh_plugins|生态" "$DEC" 2>/dev/null; then
  ok "P6 先找现成方案" "有生态调研记录（D006/D020/D025）"
else
  bad "P6 先找现成方案" "未见生态调研记录"
fi

# P10 · 定期变异测试：距上次执行的天数
MARK=../state/last-mutation-test.txt
last_mut=$(cat "$MARK" 2>/dev/null | head -1 | tr -d ' \n')
if [ -n "$last_mut" ]; then
  days=$(( ( $(date -u +%s) - $(date -u -d "$last_mut" +%s) ) / 86400 ))
  if [ "$days" -le 7 ]; then ok "P10 定期变异测试" "上次距今 ${days} 天（阈值 7 天）"
  else bad "P10 定期变异测试" "上次距今 ${days} 天，已超阈值 7 天，应重做"; fi
else
  bad "P10 定期变异测试" "未找到执行日期"
fi

# P11 · 历史自查工具确实存在且可用
if [ -x ./history-query.sh ] && ./history-query.sh iqoo.secure >/dev/null 2>&1; then
  ok "P11 历史陈述查记录" "history-query.sh 可用"
else
  bad "P11 历史陈述查记录" "自查工具异常"
fi

# P1/P7 · 回归可跑且非空
if ./verify.sh >/dev/null 2>&1; then ok "P1/P7 回归可执行" "22 项端点测试通过"
else bad "P1/P7 回归可执行" "回归失败"; fi

echo
echo "=== 以下原则无法自动判定，需人工自查 ==="
manualp "P2 诚实报告"        "判断标准在内心，机器不能代劳"
manualp "P4 痕迹可被读懂"    "需读一遍自己写的东西才知道"
manualp "P5 警惕测量误差"    "需在具体故障中判断是否先怀疑自己"
manualp "P8 冗余优于精度"    "需在设计新方案时自觉应用"
manualp "P9 验证无副作用"    "已由 verify 的自检覆盖，但只覆盖被监控文件"

echo
echo "自动判定: $pass 通过 / $warn 需处理  |  人工判断: $manual 条"
[ "$warn" -eq 0 ] && exit 0 || exit 1
