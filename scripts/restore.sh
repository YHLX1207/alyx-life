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

# ⚠️ 自保护（Round 191）：恢复过程会用快照里的文件覆盖 scripts/，
#    包括本脚本自身。bash 是边读边解析的，文件被替换后后续行会错乱
#    （实测报 "syntax error near unexpected token `then'"）。
#    ⇒ 把自己复制到临时目录，改为从副本继续执行。
if [ "${ALYX_RESTORE_GUARDED:-0}" != "1" ]; then
  _SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  _GUARD="/tmp/.restore-guard-$$.sh"
  if [ -f "$_SELF" ] && cp "$_SELF" "$_GUARD" 2>/dev/null; then
    ALYX_RESTORE_GUARDED=1 ALYX_RESTORE_CTX="$(pwd)" exec bash "$_GUARD" "$@"
  fi
fi
[ "${ALYX_RESTORE_GUARDED:-0}" = "1" ] && [ -n "${ALYX_RESTORE_CTX:-}" ] && cd "$ALYX_RESTORE_CTX"


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
# ⚠️ 不能硬编码 tag：snapshot-release.sh 每天生成 snapshot-YYYYMMDD，
#    硬编码会永远指向某一天的旧快照（Round 190 实测：指向 11-24 而实际是 11-25，
#    少了 30 条决策、12 个脚本）。
#    ⇒ 用 GitHub API 查询**最新** release 的下载地址。
# 优先用固定 URL（latest tag 永不变化，且每轮覆盖）
# 回退到 API 查询（兼容可能存在的日期 tag）
A_URL=${ALYX_SNAPSHOT_URL:-https://github.com/YHLX1207/alyx-life/releases/download/latest/alyx-full.tar.xz}

# 若固定 URL 不可用，再查 API
if ! timeout 20 curl -sfL -o /dev/null -I "$A_URL" 2>/dev/null; then
  A_URL=""
fi

if [ -z "$A_URL" ]; then
  echo "  查询最新快照地址…"
  A_URL=$(python3 - <<'PYURL'
import json, urllib.request, sys
try:
    req = urllib.request.Request(
        "https://api.github.com/repos/YHLX1207/alyx-life/releases?per_page=5",
        headers={"User-Agent": "alyx", "Accept": "application/vnd.github+json",
                 "Connection": "close"})
    rels = json.loads(urllib.request.urlopen(req, timeout=20).read())
    best = None
    for r in rels:
        for a in r.get("assets") or []:
            if a.get("name") == "alyx-full.tar.xz":
                cand = (a.get("created_at", ""), a.get("browser_download_url"))
                if best is None or cand[0] > best[0]:
                    best = cand
    print(best[1] if best else "")
except Exception:
    print("")
PYURL
)
fi

if [ -z "$A_URL" ]; then
  echo "  ✗ 无法获取最新快照地址（网络或 API 问题）"
  return 1
fi
echo "  使用: $(basename "$(dirname "$A_URL")")/$(basename "$A_URL")"
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
    # ⚠️ 必须包含"设备手册.md"——用户手册是恢复的一部分（Round 195 实测发现漏了）
    cp -r "$TMP/a/dest/scripts" "$TMP/a/dest/state" "$TMP/a/dest/README.md" \
          "$TMP/a/dest/notes" "$TMP/a/dest/设备手册.md" .. 2>/dev/null
  elif [ -d "$TMP/a/scripts" ]; then
    cp -r "$TMP/a/scripts" "$TMP/a/state" "$TMP/a/README.md" "$TMP/a/设备手册.md" .. 2>/dev/null
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
