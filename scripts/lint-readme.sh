#!/usr/bin/env bash
# README 完整性检查：scripts/ 下每个脚本都必须在 README **脚本表格**中列出
#
# 缘起 Round 64：README 只列了 18/33 个脚本，此前多次"插入新条目"都静默失败。
#
# ⚠️ Round 206 修正：原实现用 `grep -q "$f"`（子串匹配），
#    只要 README 正文里出现过 `scripts/xxx.sh` 就通过。
#    实测发现 restore.sh 只在散文里出现、不在表格里，检查却通过了。
#    **"文件里提过" ≠ "被正式列在清单里"。**
#    ⇒ 改为匹配表格行格式：`| \`name.sh\` |`
set -uo pipefail
cd "$(dirname "$0")"
miss=0
for f in *.sh; do
  # 精确匹配表格行：| `name.sh` |
  if ! grep -qF "| \`$f\` |" ../README.md 2>/dev/null; then
    echo "  ✗ README 表格未列出: $f"
    miss=$((miss+1))
  fi
done
n=$(ls *.sh | wc -l)
if [ "$miss" -eq 0 ]; then
  echo "  ✓ README 表格覆盖全部 $n 个脚本"; exit 0
else
  echo "  ✗ 表格缺失 $miss 个（共 $n）"; exit 1
fi
