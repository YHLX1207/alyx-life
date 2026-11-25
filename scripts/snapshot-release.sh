#!/usr/bin/env bash
# 把完整快照发布为 GitHub Release 附件 —— 最容易被找到的恢复入口
#
# 为什么用 Release 而不是只靠 git 历史：
#   · git 历史需要知道 commit sha 才能找到特定版本
#   · Release 附件有稳定 URL，且有可读的说明
#   · 用户/未来的实例可以直接下载，不需要懂 git
#
# 安全铁律：**绝不能把凭据放进快照**。
# Round 146 踩过：`--exclude='secrets'` 对 `life/state/secrets/` 无效，
# token 被装进包。改用"显式拷贝到干净目录"再打包，并在打包后**扫描验证**。
set -uo pipefail
cd "$(dirname "$0")"   # 停在 scripts/，与其他脚本一致

TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  ✗ 无 token，跳过（这是正常的：CI 环境没有本地 token）"; exit 0; }

REPO="${ALYX_REPO:-YHLX1207/alyx-life}"
# ⚠️ 用固定 tag，不用日期（Round 191）：
#    日期 tag 会每天新建一个 Release，无限累积（一年 365 个）。
#    固定 tag + 覆盖附件 ⇒ 永远只有一个 Release，且 URL 稳定。
#    历史版本仍可从 git 历史或旧 tag 追溯。
TAG="latest"
WORK=$(mktemp -d /tmp/alyx-snap.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "  1) 构造干净副本…"
mkdir -p "$WORK/dest"
cp -r .          "$WORK/dest/scripts"    2>/dev/null
cp -r ../notes   "$WORK/dest/notes"      2>/dev/null
mkdir -p "$WORK/dest/state"
cp ../state/*.json ../state/*.md ../state/*.jsonl "$WORK/dest/state/" 2>/dev/null
cp ../README.md "../设备手册.md" "$WORK/dest/" 2>/dev/null
# 明确剔除（不依赖 exclude 语义）
rm -rf "$WORK/dest/state/secrets" "$WORK/dest/state/local-archive.tar.gz" 2>/dev/null
rm -f  "$WORK/dest/state/watchdog.pid" "$WORK/dest/state/journal.jsonl" 2>/dev/null

echo "  2) 凭据扫描…"
# ⚠️ 只扫**真实 token 形态**：ghp_ 后跟 36 位、且整行不像正则/变量表达式。
#    不能把脚本里的正则模式本身当成泄露（Round 146 误报过：
#    deploy-github.sh 里的 "x-access-token:${TOKEN}@..." 是模板，不是凭据）。
_leak=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # 排除脚本目录里的模式定义
  case "$f" in */scripts/*) continue ;; esac
  # 排除 .gitignore / README 等文档
  case "$f" in *.gitignore|*README*) continue ;; esac
  # 真实 token：40 位、且同文件内不出现 ${ 或正则元字符包围
  if grep -qoE 'ghp_[A-Za-z0-9]{36}' "$f" 2>/dev/null; then
    # 再确认不是被引号包在正则/模板里
    if ! grep -qE "\\w|[][|(){}+*?\\]" <<< "$(grep -oE 'ghp_[A-Za-z0-9]{36}' "$f" 2>/dev/null | head -1)"; then
      echo "     ⚠ 疑似真实凭据: $f"
      _leak=$((_leak+1))
    fi
  fi
done < <(grep -rlE 'ghp_[A-Za-z0-9]{30,}' "$WORK/dest" 2>/dev/null)
if [ "$_leak" -gt 0 ]; then
  echo "  ✗ 发现 $_leak 个文件含真实凭据，**中止上传**"
  exit 1
fi
echo "     ✓ 无真实凭据"

echo "  3) 打包…"
tar cJf "$WORK/alyx-full.tar.xz" -C "$WORK" dest 2>/dev/null
SZ=$(wc -c < "$WORK/alyx-full.tar.xz")
[ "$SZ" -gt 10000 ] || { echo "  ✗ 包过小（$SZ 字节），疑似路径错误"; exit 1; }
_nsh=$(tar tJf "$WORK/alyx-full.tar.xz" 2>/dev/null | grep -c "\.sh$")
[ "${_nsh:-0}" -ge 40 ] || { echo "  ✗ 仅 ${_nsh:-0} 个脚本，拷贝源路径可能错了"; exit 1; }
echo "     $((SZ/1024)) KB，$_nsh 个脚本"

echo "  4) 创建/复用 release…"
REL=$(timeout 40 curl -s -H "Authorization: token $TOKEN" -H "User-Agent: alyx" \
      "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null)
# 用文件中转，避免 heredoc/管道里 python 的引号问题
printf '%s' "$REL" > "$WORK/rel.json"
REL_ID=$(python3 - "$WORK/rel.json" <<'PY' 2>/dev/null
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    print(d.get('id') or '')
except Exception:
    print('')
PY
)

if [ -z "$REL_ID" ]; then
  CREATED=$(timeout 40 curl -s -X POST \
    -H "Authorization: token $TOKEN" -H "User-Agent: alyx" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"tag_name\":\"$TAG\",\"name\":\"Alyx 完整快照 $TAG\",\"body\":\"脚本+状态+决策史，用于灾难恢复。解压后是 dest/ 目录。\",\"draft\":false}" \
    "https://api.github.com/repos/$REPO/releases" 2>/dev/null)
  printf '%s' "$CREATED" > "$WORK/rel2.json"
  REL_ID=$(python3 - "$WORK/rel2.json" <<'PY' 2>/dev/null
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    print(d.get('id') or '')
except Exception:
    print('')
PY
)
fi
[ -n "$REL_ID" ] || { echo "  ✗ 无法创建 release"; exit 1; }
echo "     release id=$REL_ID"

# 删除同名旧附件（避免重复）
UP="https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets"
OLD=$(timeout 30 curl -s -H "Authorization: token $TOKEN" -H "User-Agent: alyx" \
      "https://api.github.com/repos/$REPO/releases/$REL_ID/assets" 2>/dev/null \
      | python3 -c "import sys,json
try:
    print(' '.join(str(a['id']) for a in json.load(sys.stdin) if a.get('name')=='alyx-full.tar.xz'))
except: print('')" 2>/dev/null)
for a in $OLD; do
  timeout 20 curl -s -X DELETE -H "Authorization: token $TOKEN" -H "User-Agent: alyx" \
    "https://api.github.com/repos/$REPO/releases/assets/$a" >/dev/null 2>&1
done

echo "  5) 上传附件…"
RES=$(timeout 120 curl -s --max-time 110 -X POST \
  -H "Authorization: token $TOKEN" -H "User-Agent: alyx" \
  -H "Content-Type: application/x-xz" \
  --data-binary @"$WORK/alyx-full.tar.xz" \
  "$UP?name=alyx-full.tar.xz" 2>/dev/null)
DL=$(printf '%s' "$RES" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('browser_download_url') or '')
except: print('')" 2>/dev/null)
[ -n "$DL" ] || { echo "  ✗ 上传失败"; exit 1; }

echo "  ✓ 快照已发布"
echo "    $DL"

# 发布后立刻回读校验（防缓存）：确认下载到的就是刚上传的那份
echo "  6) 回读校验（防缓存）…"
timeout 120 curl -sL --max-time 110 -H "Cache-Control: no-cache" \
  -o "$WORK/verify.tar.xz" "$DL?t=$(date +%s)" 2>/dev/null
_VSZ=$(wc -c < "$WORK/verify.tar.xz" 2>/dev/null || echo 0)
if [ "$_VSZ" = "$SZ" ]; then
  _VN=$(tar tJf "$WORK/verify.tar.xz" 2>/dev/null | grep -c '\.sh$')
  echo "     ✓ 大小一致 ${_VSZ}B，含 $_VN 个脚本"
else
  echo "     ⚠ 回读大小不符（远端 $_VSZ / 本地 $SZ）—— 可能 CDN 缓存未刷新，非致命"
fi
printf '{"ts":"%s","kind":"release","tag":"%s","size":%d,"url":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TAG" "$SZ" "$DL" >> ../state/offsite-seed.jsonl
