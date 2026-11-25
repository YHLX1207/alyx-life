#!/usr/bin/env bash
# 路径用法检查器
#
# 背景：本目录脚本多以 `cd "$(dirname "$0")"` 进入 scripts/，
# 若随后仍用裸相对路径（state/xxx、notes/xxx），文件会找不到。
# 而多数检查写成 `[ -f X ] && ...`，找不到就静默跳过 ——
# 造成"检查了，但什么都没测到"。该缺陷已重复出现 4 次（Round 2/6/8/9）。
#
# 只检查真实文件操作，不匹配提示语字符串。
set -uo pipefail
cd "$(dirname "$0")"

# 文件操作上下文：test -f/-d、cat、cp、mv、wc、md5sum、grep(带文件参数)、重定向
PAT='(\[ *-[efd] *|[<>]{1,2} *|cat +|cp +|mv +|wc +|md5sum +|stat +|chmod +|rm +)(state|logs|notes)/'

suspect=0
for f in *.sh; do
  # 覆盖两类脚本：
  #   a) 会 cd 到自身目录的 → 裸相对路径会解析错
  #   b) 不 cd 的 → 裸相对路径依赖调用方 cwd，同样不可靠
  # 原实现跳过 b) 是覆盖盲区（Round 38 发现）
  if grep -q 'cd "\$(dirname "\$0")"' "$f"; then mode="cd"; else mode="no-cd"; fi
    # ⚠️ 排除 echo/printf 提示语里的路径（Round 177 误报）
    hits=$(grep -nE "$PAT" "$f" 2>/dev/null \
           | grep -v '^[0-9]*: *#' \
           | grep -vE '\.\./' \
           | grep -vE '(echo|printf).*(state|logs|notes)/' || true)
  if [ -n "$hits" ]; then
    echo "  [$f] ($mode)"
    echo "$hits" | sed 's/^/    /' | head -5
    suspect=$((suspect+1))
  fi
done

echo
if [ "$suspect" -eq 0 ]; then
  echo "路径检查: 未发现裸相对路径的文件操作"
  exit 0
else
  echo "路径检查: $suspect 个文件可疑（会静默失败）"
  exit 1
fi
