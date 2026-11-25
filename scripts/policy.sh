#!/usr/bin/env bash
# 调度策略：纯函数，可独立测试，不依赖 adb/网络
# decide_interval <base> <adb_ok> <shz_ok> <battery> <mem_mb> [loadavg]
# 输出: <间隔秒数> <原因>
decide_interval() {
  local base=$1 adb_ok=$2 shz_ok=$3 batt=$4 mem=$5 load=${6:-}
  if [ "$adb_ok" != "true" ]; then
    # ⚠️ 区分"短暂断开"与"长期断开"（Round 185）：
    #    短断（刚断）用 base/3 快速轮询，争取尽快发现恢复；
    #    长断（>1 小时）几乎肯定是物理断开，快速轮询毫无意义且耗电，
    #    改为 base*2 放慢。
    #    判定依据：adb_down 持续轮数（环境变量 ALYX_ADB_STREAK，由守护传入）。
    local st=${ALYX_ADB_STREAK:-0}
    if [ "${st:-0}" -gt 120 ] 2>/dev/null; then
      echo "$((base*2)) adb_down_long"; return
    fi
    echo "$((base/3)) adb_down"; return
  fi
  if [ "$shz_ok" != "true" ]; then
    echo "$((base/2)) shizuku_down"; return
  fi
  if [ -n "$batt" ] && [ "$batt" -lt 20 ] 2>/dev/null; then
    echo "$((base*2)) low_battery"; return
  fi
  if [ -n "$mem" ] && [ "$mem" -lt 500 ] 2>/dev/null; then
    echo "$((base*3/2)) low_memory"; return
  fi
  # 系统负载感知：负载高时降频，避免自己的轮询加剧 I/O 压力
  # （实测：本机长期 load 28、24 个 D 状态进程，轮询会与渲染/回收争 I/O）
  if [ -n "$load" ]; then
    local nproc; nproc=$(nproc 2>/dev/null || echo 8)
    local hi=$(( nproc * 2 ))     # 达到 2×核数即视为过载
    # shellcheck disable=SC2086
    if [ "$(echo "$load $hi" | awk '{print ($1>=$2)?1:0}')" = "1" ]; then
      echo "$((base*3/2)) high_load"; return
    fi
  fi
  echo "$base healthy"
}
