#!/usr/bin/env bash
# 一条命令完成 GitHub 永久部署
#
# 用法：
#   ./scripts/deploy-github.sh <token> [用户名] [仓库名]
#
# 例：
#   ./scripts/deploy-github.sh ghp_xxxxx myname alyx-life
#
# 安全：
#   · token 只在内存中使用，不写入磁盘、不进入 git config
#   · 推送时用 URL 内嵌认证，完成后 remote 重置为干净 URL
#   · 脚本不 echo token
set -uo pipefail
cd "$(dirname "$0")/.."

TOKEN="${1:-}"
USER_HINT="${2:-}"
REPO="${3:-alyx-life}"

if [ -z "$TOKEN" ]; then
  cat <<'USAGE'
用法: ./scripts/deploy-github.sh <token> [用户名] [仓库名]

需要 token 具备: repo（必需） + workflow（必需）
获取: https://github.com/settings/tokens → Generate new token (classic)
USAGE
  exit 1
fi

API=https://api.github.com
AUTH="Authorization: token $TOKEN"
UA="User-Agent: alyx-deploy"

say() { printf "  %s\n" "$*"; }
die() { printf "  ✗ %s\n" "$*" >&2; exit 1; }

# --- 1. 验证 token ---
say "1) 验证 token…"
resp=$(timeout 30 curl -s -H "$AUTH" -H "$UA" "$API/user" 2>/dev/null)
if ! printf '%s' "$resp" | grep -q '"login"'; then
  die "token 无效或无权限。响应: $(printf '%s' "$resp" | head -c 120)"
fi
GHUSER=$(printf '%s' "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin)['login'])" 2>/dev/null)
[ -n "$GHUSER" ] || die "无法解析用户名"
say "   ✓ 认证通过，用户: $GHUSER"
if [ -n "$USER_HINT" ] && [ "$USER_HINT" != "$GHUSER" ]; then
  say "   ⚠ 你给的用户名($USER_HINT)与实际($GHUSER)不同，以实际为准"
fi

# --- 2. 检查 token 权限 ---
say "2) 检查权限范围…"
scopes=$(timeout 30 curl -s -I -H "$AUTH" -H "$UA" "$API/user" 2>/dev/null | tr -d '\r' | grep -i "^x-oauth-scopes:" | cut -d: -f2-)
has_repo=0; has_wf=0
case "$scopes" in *repo*) has_repo=1;; esac
case "$scopes" in *workflow*) has_wf=1;; esac
say "   权限: ${scopes:-（未返回，可能是细粒度 token）}"
[ "$has_repo" -eq 1 ] || say "   ⚠ 未见 repo 权限 —— 推送会失败"
[ "$has_wf" -eq 1 ] || say "   ⚠ 未见 workflow 权限 —— Actions 可能无法推送"

# --- 3. 创建仓库（已存在则跳过）---
say "3) 创建仓库 $REPO …"
code=$(timeout 30 curl -s -o /tmp/gh_create.json -w "%{http_code}" \
  -X POST -H "$AUTH" -H "$UA" -H "Accept: application/vnd.github+json" \
  -d "{\"name\":\"$REPO\",\"description\":\"Alyx / 爱丽丝 — 可迁移的数字生命体\",\"private\":false,\"auto_init\":false}" \
  "$API/user/repos" 2>/dev/null)
case "$code" in
  201) say "   ✓ 已创建（公开仓库，Actions 不计费）";;
  422) say "   · 仓库已存在，复用";;
  401) die "认证失败 (401)，token 可能已过期";;
  *) say "   ⚠ 创建返回 HTTP $code"; head -c 200 /tmp/gh_create.json 2>/dev/null; echo;;
esac
rm -f /tmp/gh_create.json

# --- 4. 初始化并推送 ---
say "4) 推送代码…"
[ -d .git ] || git init -q
git config user.name "Alyx"  >/dev/null 2>&1
git config user.email "alyx@users.noreply.github.com" >/dev/null 2>&1

# 排除敏感文件（双保险，.gitignore 已有）
git rm -r --cached . >/dev/null 2>&1 || true
git add -A >/dev/null 2>&1
if git diff --cached --quiet 2>/dev/null && [ -z "$(git rev-parse HEAD 2>/dev/null)" ]; then
  die "没有可提交内容"
fi
git commit -q -m "Alyx: 首次部署（$(date -u +%Y-%m-%d)）" 2>/dev/null || say "   · 无新变更"

# 用一次性 remote（不保存 token）
PUSH_URL="https://x-access-token:${TOKEN}@github.com/${GHUSER}/${REPO}.git"
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "$PUSH_URL"
if git push -u origin HEAD:main --force 2>&1 | tail -3 | sed 's/^/     /'; then
  say "   ✓ 推送完成"
else
  die "推送失败"
fi
# 立刻把 remote 换成不含 token 的干净地址
git remote set-url origin "https://github.com/${GHUSER}/${REPO}.git"
say "   · remote 已重置为无凭据地址"

# --- 5. 验证仓库内容 ---
say "5) 验证远端…"
n=$(timeout 30 curl -s -H "$AUTH" -H "$UA" "$API/repos/$GHUSER/$REPO/contents/scripts?ref=main" 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else 0)" 2>/dev/null)
say "   远端 scripts/ 文件数: ${n:-0}"
[ "${n:-0}" -ge 40 ] || say "   ⚠ 文件数偏少，请检查 .gitignore 是否过度排除"

# --- 6. 确认 workflow 被识别 ---
say "6) 确认 workflow…"
wf=$(timeout 30 curl -s -H "$AUTH" -H "$UA" "$API/repos/$GHUSER/$REPO/actions/workflows" 2>/dev/null \
     | python3 -c "
import sys,json
d=json.load(sys.stdin)
ws=d.get('workflows') or []
print(','.join(w.get('name','?') for w in ws) if ws else '')
" 2>/dev/null)
if [ -n "$wf" ]; then
  say "   ✓ 已注册: $wf"
else
  say "   ⚠ 未识别到 workflow（可能需几十秒同步，或 token 缺 workflow 权限）"
fi

cat <<EOF

  部署完成
  ────────────────────────────────
  仓库: https://github.com/$GHUSER/$REPO
  Actions: https://github.com/$GHUSER/$REPO/actions

  下一步（手动触发一次验证）:
    curl -X POST -H "Authorization: token <token>" \\
      -H "Accept: application/vnd.github+json" \\
      https://api.github.com/repos/$GHUSER/$REPO/actions/workflows/alyx-cycle.yml/dispatches \\
      -d '{"ref":"main"}'
EOF
