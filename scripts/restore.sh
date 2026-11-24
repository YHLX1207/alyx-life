#!/usr/bin/env bash
# 一键恢复：从任意一条备份链重建整个系统
#
# 两条独立链，任选其一（或自动尝试）：
#   A. GitHub Release —— 简单，一个文件
#   B. paste.rs 分段  —— 不依赖 GitHub，需要拼接
#
# 用法：
#   ./scripts/restore.sh              # 自动尝试 A，失败用 B
#   ./scripts/restore.sh a            # 只用 GitHub
#   ./scripts/restore.sh b            # 只用 paste.rs
#
# 目标：恢复到 ./ 下的 life 目录结构（scripts/ state/ README.md）
set -uo pipefail
# ⚠️ 目标：把内容恢复到**仓库根**（scripts/ 的父目录）。
# 因此 cwd 是 scripts/，所有对 state/ notes/ 的引用都要带 ../
cd "$(dirname "$0")"

DEST="${1:-auto}"
SHOULD_RESTORE_A=0; SHOULD_RESTORE_B=0
[ "$DEST" = "auto" ] && { SHOULD_RESTORE_A=1; SHOULD_RESTORE_B=1; }
[ "$DEST" = "a" ]  && SHOULD_RESTORE_A=1
[ "$DEST" = "b" ]  && SHOULD_RESTORE_B=1

TMP=$(mktemp -d /tmp/restore.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
ok(){ printf "  ✓ %s\n" "$*"; }
fail(){ printf "  ✗ %s\n" "$*"; }

# ---------- A. GitHub Release ----------
A_URL="https://github.com/YHLX1207/alyx-life/releases/download/snapshot-20261124/alyx-full.tar.xz"
restore_a() {
  echo "== 链 A：GitHub Release =="
  # ⚠️ 必须防缓存（D149 实测：否则拿到旧版本）
  timeout 180 curl -sL --max-time 170 -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
    -o "$TMP/a.tar.xz" "$A_URL?t=$(date +%s)" 2>/dev/null
  local sz; sz=$(wc -c < "$TMP/a.tar.xz" 2>/dev/null || echo 0)
  [ "$sz" -gt 100000 ] || { fail "下载失败或被缓存（$sz 字节）"; return 1; }
  ok "下载 $sz 字节"
  rm -rf "$TMP/a" && mkdir -p "$TMP/a"
  tar xJf "$TMP/a.tar.xz" -C "$TMP/a" 2>/dev/null || { fail "解压失败"; return 1; }
  # 快照内是 dest/ 目录
  if [ -d "$TMP/a/dest" ]; then
    cp -r "$TMP/a/dest/scripts" "$TMP/a/dest/state" "$TMP/a/dest/README.md" "$TMP/a/dest/notes" .. 2>/dev/null
  elif [ -d "$TMP/a/scripts" ]; then
    cp -r "$TMP/a/scripts" "$TMP/a/state" "$TMP/a/README.md" .. 2>/dev/null
  fi
  ok "已还原"
  return 0
}

# ---------- B. paste.rs 分段 ----------
restore_b() {
  echo "== 链 B：paste.rs 分段 =="
  # 从自述读取线索（若无自述，用内置已知 URL）
  local SEED CODE DEC
  SEED=$(grep "种子：" ../state/self-export.md 2>/dev/null | grep -oE "https://paste\.rs/[A-Za-z0-9]+" | head -1)
  CODE=$(grep "代码包" ../state/self-export.md 2>/dev/null | grep -oE "https://paste\.rs/[A-Za-z0-9]+" | tr '\n' ' ')
  DEC=$(grep "决策史" ../state/self-export.md 2>/dev/null | grep -oE "https://paste\.rs/[A-Za-z0-9]+" | tr '\n' ' ')

  [ -z "$SEED" ] && SEED="https://paste.rs/paste.rs/1eVjj"
  [ -z "$CODE" ] && CODE="https://paste.rs/paste.rs/MSMs5 paste.rs/RLAc1 "
  [ -z "$DEC" ] && DEC="https://paste.rs/paste.rs/jGGQr paste.rs/azHj8 "

  echo "  种子: $SEED"
  echo "  代码: $CODE"
  echo "  决策: $DEC"
  echo

  # 种子
  timeout 90 curl -s --max-time 80 "$SEED" | base64 -d > "$TMP/seed.tar.gz" 2>/dev/null
  tar xzf "$TMP/seed.tar.gz" -C .. 2>/dev/null || { fail "种子解压失败"; return 1; }
  ok "种子已恢复"

  # 代码包
  mkdir -p ../scripts
  for u in $CODE; do
    timeout 90 curl -s --max-time 80 "$u" | base64 -d | tar xJ -C .. 2>/dev/null
  done
  [ -d ../life/scripts ] && cp -r ../life/scripts/* ../scripts/ 2>/dev/null
  local nsh; nsh=$(ls *.sh 2>/dev/null | wc -l)
  [ "$nsh" -ge 40 ] || { fail "脚本数异常（$nsh），分段恢复可能不全"; }
  ok "脚本 $nsh 个"

  # 决策史
  : > ../state/decisions.md
  for u in $DEC; do
    timeout 90 curl -s --max-time 80 "$u" | base64 -d | tar xJ -O 2>/dev/null >> ../state/decisions.md
  done
  ok "决策史已恢复（$(grep -c '^## D' ../state/decisions.md) 条）"
  return 0
}

# ---------- 执行 ----------
USED=0
if [ "$SHOULD_RESTORE_A" -eq 1 ]; then
  if restore_a; then USED=1; fi
fi
if [ "$SHOULD_RESTORE_B" -eq 1 ] && [ "$USED" -eq 0 ]; then
  restore_b && USED=1
fi

if [ "$USED" -eq 0 ]; then
  fail "两条链都失败，请人工检查网络或 URL"
  exit 1
fi

# ---------- 收尾 ----------
chmod +x *.sh 2>/dev/null
echo
echo "== 验证 =="
if [ -x ./check-portable.sh ]; then
  if ./check-portable.sh >/dev/null 2>&1; then
    ok "可移植自检通过"
  else
    printf "  ! 自检有失败项（可能缺少部分文件，可继续使用）\n"
  fi
fi
echo
echo "  身份: $(python3 -c "import json;d=json.load(open('../state/identity.json'));print(d['codename'],'/',d['name'])" 2>/dev/null || echo '?')"
echo "  脚本: $(ls *.sh 2>/dev/null | wc -l)  决策: $(grep -c '^## D' ../state/decisions.md 2>/dev/null || echo 0)"
echo
echo "  下一步："
echo "    ../scripts/ensure-self.sh    # 回到仓库根执行，拉起守护 + 触发远端"
