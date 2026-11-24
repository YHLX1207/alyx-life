#!/usr/bin/env bash
# 测试隔离自检：在跑"隔离副本测试"之前，确认副本真的被隔离了
#
# 缘起：Round 59-60 连续 5 次测试无效，全是同一个原因——
# 以为在测副本，实际仍在测真实环境。典型形式：
#   1) 脚本内写死绝对路径（/root/projects/.dsh/...）→ 副本读真实数据
#   2) 脚本内 export PATH=/opt/elevation/bin:$PATH → 桩命令被真命令覆盖
#   3) BASE 等参数使逻辑走 fallback → 被测分支根本没执行
#
# 用法: test-isolation-check.sh <副本目录>
# 退出码 0 = 可安全测试；1 = 存在泄漏，必须先修
set -uo pipefail

T=${1:-}
[ -n "$T" ] && [ -d "$T" ] || { echo "usage: test-isolation-check.sh <副本目录>"; exit 1; }

# 分级：
#   FATAL  = 数据源路径，出现即意味着"在读真实数据" → 测试结果不可信
#   WARN   = 工具/二进制路径，只读调用通常无害，但会引入真实环境依赖
FATAL_PATHS="/root/projects/.dsh /sdcard"
WARN_PATHS="/opt/elevation /opt/pilot"
LEAK=0

echo "=== 隔离自检: $T ==="

# 1) 致命泄漏（数据源）
for rp in $FATAL_PATHS; do
  hits=$(grep -rl -- "$rp" "$T/scripts" 2>/dev/null | head -5)
  if [ -n "$hits" ]; then
    echo "  ✗ [致命] 副本仍读真实数据源 $rp:"
    echo "$hits" | sed 's/^/      /'
    LEAK=1
  fi
done
[ $LEAK -eq 0 ] && echo "  ✓ 无致命路径泄漏"

# 1b) 警告级（工具路径）
for rp in $WARN_PATHS; do
  hits=$(grep -rl -- "$rp" "$T/scripts" 2>/dev/null | head -3)
  [ -n "$hits" ] && { echo "  ⚠ [警告] 引用真实工具路径 $rp（只读调用可接受）:"; echo "$hits" | sed 's/^/      /'; }
done

# 2) PATH 覆盖 —— ⚠️ 仅在"该脚本本应被桩替换"时才是问题。
#    只读巡检脚本（如 daily-check）本就要访问真实环境，PATH 覆盖属正常。
#    Round 103 修正：原实现一律判致命，对 daily-check 误报。
_pathhit=$(grep -rl "export PATH=.*/opt/elevation" "$T/scripts" 2>/dev/null | head -3)
if [ -n "$_pathhit" ]; then
  echo "  ⚠ [警告] 存在 export PATH 覆盖（若该脚本需桩替身才会失效）:"
  echo "$_pathhit" | sed 's/^/      /'
  echo "      → 只读巡检类脚本可忽略；会改状态的脚本需注意"
else
  echo "  ✓ 无 PATH 覆盖"
fi

# 3) 桩命令是否真的会被调用（存在性 + 可执行）
for stub in adb pilot snapshot ensure-adb ensure-shizuku policy; do
  f=$(ls "$T"/**/"$stub" "$T"/scripts/"$stub".sh 2>/dev/null | head -1)
  [ -n "$f" ] && [ ! -x "$f" ] && { echo "  ✗ 桩不可执行: $f"; LEAK=1; }
done

# 4) 提醒：参数是否会导致走 fallback
echo "  · 提醒：确认 BASE 足够大（adb_down 的 interval = BASE/3，须 >=1 才有意义）"
echo "  · 提醒：跑完检查桩的标记文件（如 actions/marker）确认真被调用"

echo
if [ $LEAK -eq 0 ]; then echo "结论: 可安全测试"; exit 0
else echo "结论: 存在隔离泄漏，测试结果不可信"; exit 1; fi
