#!/usr/bin/env bash
# 策略单元测试（回归用）
set -uo pipefail
cd "$(dirname "$0")"
source ./policy.sh

pass=0; fail=0
check() {
  local desc="$1" want="$2"; shift 2
  local got iv
  got=$(decide_interval "$@")
  iv=$(echo "$got" | awk '{print $1}')
  if [ "$iv" = "$want" ]; then pass=$((pass+1));
  else fail=$((fail+1)); printf "  FAIL %-24s 期望 %s 实际 %s\n" "$desc" "$want" "$iv"; fi
}

check "健康"               180 180 true  true  90 2900 1.0
# adb 短断：快速轮询（base/3）
check "adb故障提速"         60 180 false true  90 2900
# adb 长断：放慢（base*2），Round 185 新增
# ⚠️ 必须在 check 之前 export，否则环境变量只作用于 check 函数本身，
#    内部的 decide_interval 读不到（Round 185 踩到）。
export ALYX_ADB_STREAK=200; check "adb长断降频"  360 180 false true  90 2900
export ALYX_ADB_STREAK=10;  check "adb短断提速"   60 180 false true  90 2900
export ALYX_ADB_STREAK=120; check "adb边界120(等于)" 60 180 false true  90 2900
export ALYX_ADB_STREAK=121; check "adb边界121(超过)" 360 180 false true  90 2900
export ALYX_ADB_STREAK=119; check "adb边界119"    60 180 false true  90 2900
unset ALYX_ADB_STREAK
check "shizuku故障提速"     90 180 true  false 90 2900
check "低电量降频"         360 180 true  true  15 2900
check "低内存降频"         270 180 true  true  90 400
check "低电优先"           360 180 true  true  15 400
check "边界电量20"         180 180 true  true  20 2900
check "边界电量19"         360 180 true  true  19 2900
check "空电量容错"         180 180 true  true  "" 2900 1.0
# ⚠️ 边界必须**按实际核数动态计算**：硬编码 16.0/15.9 只在 8 核时成立。
# 实测本机 nproc 会在 6/8 间波动（cgroup quota 变化），硬编码会导致随机失败（Round 105）。
_NP=$(nproc 2>/dev/null || echo 8)
_HI=$(( _NP * 2 ))
_LO=$(awk -v h="$_HI" 'BEGIN{printf "%.1f", h-0.1}')
_HIR=$(awk -v h="$_HI" 'BEGIN{printf "%.1f", h}')
check "高负载降频"         270 180 true  true  90 2900 28.0
check "负载边界=2x核数"    270 180 true  true  90 2900 "$_HIR"
check "非过载"             180 180 true  true  90 2900 "$_LO"

echo "策略测试: $pass 通过 / $fail 失败"
[ $fail -eq 0 ]
