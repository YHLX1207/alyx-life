#!/usr/bin/env bash
# 入口一致性检查
#
# 背景：曾出现 daemon.sh 启动 watchdog.sh（旧版）、
# daemon-ctl.sh 启动 adaptive-watchdog.sh（新版）的缺陷 ——
# 两个入口、两套实现，走错入口就拿到缺少修复的版本。
#
# 本检查确保所有启动入口指向同一个实现文件，且该文件存在。
set -uo pipefail
cd "$(dirname "$0")"

# 收集所有 setsid/nohup 启动的脚本名
impls=$(grep -hoE 'nohup \./[a-z-]+\.sh' *.sh 2>/dev/null | sed 's/nohup \.\///' | sort -u)
count=$(echo "$impls" | grep -c . || true)

echo "  启动实现: $(echo $impls | tr '\n' ' ')"
fail=0

if [ "$count" -eq 0 ]; then
  echo "  ✗ 未找到任何守护启动入口"
  fail=1
elif [ "$count" -gt 1 ]; then
  echo "  ✗ 存在多个不同实现（$count 个）：入口不一致"
  fail=1
else
  echo "  ✓ 所有入口指向同一实现"
fi

# 实现文件必须存在
for i in $impls; do
  if [ ! -f "$i" ]; then
    echo "  ✗ 入口引用的 $i 不存在"
    fail=1
  fi
done

exit $fail
