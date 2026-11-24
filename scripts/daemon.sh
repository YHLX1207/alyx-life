#!/usr/bin/env bash
# 守护启动入口 —— 委托给 daemon-ctl.sh，保持单一事实来源
#
# 历史：本脚本曾直接启动 watchdog.sh（旧版），
# 而 daemon-ctl.sh 启动 adaptive-watchdog.sh（当前版，含防空转/策略调速）。
# 两个入口启动不同实现，是真实缺陷。现统一为委托。
set -uo pipefail
cd "$(dirname "$0")"
exec ./daemon-ctl.sh start "${1:-180}"
