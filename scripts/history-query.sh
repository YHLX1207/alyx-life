#!/usr/bin/env bash
# 自查历史：把「关于自己过去的陈述」从回忆变成查证
#
# 缘起：Round 19 我声称"i管家是我停用的应用之一"，
# 实测它根本不在停用列表 —— 错误的自述比错误的技术判断更危险，
# 因为它披着"如实交代"的外衣。
#
# 用法: history-query.sh <关键词>
#   例: history-query.sh iqoo.secure
#   例: history-query.sh 停用
set -uo pipefail
cd "$(dirname "$0")"

KEY=${1:-}
if [ -z "$KEY" ]; then
  echo "usage: history-query.sh <关键词>"; exit 1
fi

echo "=== 决策库中提及「$KEY」 ==="
if grep -n -- "$KEY" ../state/decisions.md 2>/dev/null | head -8; then :; else echo "  （无记录）"; fi

echo
echo "=== 日志中提及「$KEY」 ==="
if grep -n -- "$KEY" ../notes/JOURNAL.md 2>/dev/null | head -8; then :; else echo "  （无记录）"; fi

echo
echo "=== 提醒 ==="
echo "  记录里没有 = 很可能没发生过。不要仅凭回忆下结论。"
