#!/usr/bin/env bash
# README 完整性检查：scripts/ 下每个脚本都必须在 README 中列名
# 缘起 Round 64：README 只列了 18/33 个脚本，此前多次"插入新条目"都静默失败。
set -uo pipefail
cd "$(dirname "$0")"
miss=0
for f in *.sh; do
  grep -q "$f" ../README.md 2>/dev/null || { echo "  ✗ README 未列出: $f"; miss=$((miss+1)); }
done
n=$(ls *.sh | wc -l)
if [ "$miss" -eq 0 ]; then echo "  ✓ README 覆盖全部 $n 个脚本"; exit 0
else echo "  ✗ 缺失 $miss 个（共 $n）"; exit 1; fi
