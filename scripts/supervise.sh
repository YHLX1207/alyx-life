#!/usr/bin/env bash
# 统一守护：adb + shizuku 一次拉齐，输出结构化结果
set -uo pipefail
cd "$(dirname "$0")"
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
./ensure-adb.sh; rc_adb=$?
if [ $rc_adb -ne 0 ]; then
  echo "HALT: adb unavailable (rc=$rc_adb); shizuku cannot be started without it"
  exit $rc_adb
fi
./ensure-shizuku.sh; rc_shz=$?
./health-check.sh
exit $rc_shz
