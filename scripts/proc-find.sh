#!/usr/bin/env bash
# 进程查询（避免 grep 自匹配污染）
#
# 缘起 Round 89：用 `ps | grep vivo.browser` 查询时，
# 结果返回了**自己那条查询命令**（命令行含关键词）⇒ 探针污染。
# 本工具改为直接读 /proc/<pid>/cmdline，并显式排除自身 PID 与父链。
#
# 用法: proc-find.sh <关键词>
set -uo pipefail
cd "$(dirname "$0")"
KEY=${1:-}
[ -n "$KEY" ] || { echo "usage: proc-find.sh <关键词>"; exit 1; }

export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

# 在设备侧执行：遍历 /proc，跳过 shell 自身与其子进程
_run() {
timeout 30 $A shell "
SELF=\$\$
for p in /proc/[0-9]*; do
  pid=\$(basename \$p)
  [ \"\$pid\" = \"\$SELF\" ] && continue
  cmd=\$(tr '\0' ' ' < \$p/cmdline 2>/dev/null)
  case \"\$cmd\" in
    *$KEY*)
      # 排除本身就是查询命令的进程（含 grep/proc-find 特征）
      case \"\$cmd\" in *grep*|*proc-find*) continue;; esac
      echo \"\$pid \$cmd\"
      ;;
  esac
done 2>/dev/null | head -10
" 2>/dev/null | tr -d '\r'
}
_out=$(_run)
# adb 瞬时失败时重试一次（D060 同类：不稳定源用重试换确定性）
if [ -z "$_out" ]; then sleep 2; _out=$(_run); fi
printf '%s\n' "$_out"
