#!/usr/bin/env bash
# 灾难恢复演练：验证"手机损毁后能否从 GitHub 重建"
#
# 为什么需要（Round 195）：
#   我一直说"可从 GitHub 恢复"，但从没完整演练过。
#   实测发现 restore.sh 漏了"设备手册.md"—— 文件在快照里，但没被复制出来。
#
# 本脚本做一次完整的隔离演练：
#   1. 全新空目录，只有 restore.sh
#   2. 执行恢复
#   3. 验证关键文件、脚本、自检
#   4. 报告通过/失败
set -uo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d /tmp/dr-drill.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ printf "  ✓ %s\n" "$*"; pass=$((pass+1)); }
no(){ printf "  ✗ %s\n" "$*"; fail=$((fail+1)); }

echo "== 灾难恢复演练 =="
echo "  工作目录: $WORK"

mkdir -p "$WORK/scripts"
cp ./restore.sh "$WORK/scripts/" 2>/dev/null || { no "复制 restore.sh 失败"; exit 1; }

# 执行恢复
( cd "$WORK/scripts" && timeout 300 bash ./restore.sh a >"$WORK/out.log" 2>&1 )
rc=$?

if [ "$rc" -eq 0 ]; then ok "恢复执行成功（rc=0）"
else no "恢复失败（rc=$rc）"; tail -5 "$WORK/out.log" | sed 's/^/      /'; fi

# 验证关键文件
for f in state/identity.json state/decisions.md README.md 设备手册.md; do
  if [ -f "$WORK/$f" ]; then ok "存在: $f"
  else no "缺失: $f"; fi
done

# 验证身份
if [ -f "$WORK/state/identity.json" ]; then
  _name=$(python3 -c "import json;d=json.load(open('$WORK/state/identity.json'));print(d.get('codename','')+'/'+d.get('name',''))" 2>/dev/null)
  if [ -n "$_name" ]; then ok "身份可读: $_name"
  else no "身份文件无法解析"; fi
fi

# 验证脚本数与可执行位
_nsh=$(ls "$WORK"/scripts/*.sh 2>/dev/null | wc -l)
if [ "$_nsh" -ge 60 ]; then ok "脚本数 $_nsh（>=60）"
else no "脚本数异常 $_nsh"; fi

_x=$(find "$WORK/scripts" -name '*.sh' -perm -u+x 2>/dev/null | wc -l)
if [ "$_x" -eq "$_nsh" ]; then ok "全部可执行 ($_x/$_nsh)"
else no "可执行位缺失 ($_x/$_nsh)"; fi

# 验证自检
if ( cd "$WORK/scripts" && timeout 180 ./check-portable.sh >/dev/null 2>&1 ); then
  ok "可移植自检通过"
else
  no "可移植自检失败"
fi

# 验证能生成自述
if ( cd "$WORK" && ALYX_NO_REDUNDANT=1 ./scripts/export-self.sh "$WORK/test-export.md" >/dev/null 2>&1 ) \
   && [ -s "$WORK/test-export.md" ]; then
  ok "能生成自述（$(wc -l < "$WORK/test-export.md") 行）"
else
  no "自述生成失败"
fi

echo
echo "  结果: $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]
