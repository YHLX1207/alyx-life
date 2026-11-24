#!/usr/bin/env bash
# 数据源可信度检查：防止脚本依赖已知不可靠的系统统计接口
#
# 缘起（D077/D078）：
#   - dumpsys diskstats 的 per-app 体积不随卸载更新（累加 22GB vs df 15.2GB）
#   - dumpsys batterystats 估算与实际差 5 倍（118 vs 500-600 mAh）
#   - dumpsys cpuinfo 采样可能滞后约 100 秒
#
# 本 lint 只在脚本**真正调用**这些接口时报错；注释与文档里提到不算。
set -uo pipefail
cd "$(dirname "$0")"

BAD=0

check() {
  local pattern="$1" why="$2"
  # 排除注释行与文档 echo 行
  local hits
  hits=$(grep -nE "$pattern" *.sh 2>/dev/null \
    | grep -vE '^\s*[A-Za-z0-9_.-]+\.sh:[0-9]+:\s*#' \
    | grep -vE 'lint-datasource|export-self|echo "|echo -\s' || true)
  if [ -n "$hits" ]; then
    echo "  ✗ 依赖不可靠数据源：$why"
    echo "$hits" | sed 's/^/      /'
    BAD=1
  fi
}

check 'dumpsys[^|]*diskstats'   'dumpsys diskstats 的 per-app 体积不随卸载更新'
check 'dumpsys[^|]*batterystats' 'dumpsys batterystats 估算与实际差 5 倍'
check 'dumpsys[^|]*cpuinfo'      'dumpsys cpuinfo 采样可能滞后约 100 秒'

if [ $BAD -eq 0 ]; then
  echo "  ✓ 未依赖不可信数据源（diskstats/batterystats/cpuinfo）"
  exit 0
else
  echo "  → 判定真实占用请用 df；内存用 /proc/meminfo；负载用 /proc/loadavg"
  exit 1
fi
