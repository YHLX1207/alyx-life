#!/usr/bin/env bash
# 兜底文本漂移检查
#
# 背景：export-self.sh 在 identity.json 丢失时会输出「固定事实」兜底文本。
# 该文本曾是硬编码，随原则增加而漂移（发现时只列 6 条，实际已有 10 条）——
# 而这个兜底正是"身份丢失"灾难场景下唯一能依靠的东西。
#
# 本检查确保兜底文本与 identity.json 的当前原则数量/内容一致。
set -uo pipefail
cd "$(dirname "$0")"

IDS=../state/identity.json
EXP=export-self.sh

[ -f "$IDS" ] || { echo "  跳过：无 identity.json"; exit 0; }

want=$(python3 -c "import json;print(len(json.load(open('$IDS'))['principles']))")
line=$(grep -o '核心行事方式（[0-9]* 条）' "$EXP" | head -1)
got=$(echo "$line" | grep -oE '[0-9]+')

if [ -z "$got" ]; then
  echo "  ✗ 兜底文本缺失或格式不符（应为「核心行事方式（N 条）：…」）"
  exit 1
fi

if [ "$got" != "$want" ]; then
  echo "  ✗ 兜底文本漂移：文本写 $got 条，实际 $want 条"
  exit 1
fi

# 逐条核对短语是否都出现在兜底文本中
miss=0
while IFS= read -r kp; do
  grep -qF "$kp" "$EXP" || { echo "  ✗ 兜底文本缺少原则：$kp"; miss=1; }
done < <(python3 -c "
import json
for p in json.load(open('$IDS'))['principles']:
    print(p.split('：')[0])
")

[ $miss -eq 0 ] && { echo "  ✓ 兜底文本与 $want 条原则一致"; exit 0; } || exit 1
