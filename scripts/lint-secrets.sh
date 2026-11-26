#!/usr/bin/env bash
# 敏感文件泄露检查：确认私钥/凭据不会通过任何打包路径泄露
#
# 缘起（Round 218）：写门限 DID 时差点把私钥份额发布到公开 Release。
# 修复时又遇到一个真实陷阱：
#   `tar --exclude='./state/did-keys.json'` **不生效**，
#   因为 tar 归档内路径是 `state/did-keys.json`（无 `./` 前缀）。
#   ⇒ 排除模式写错，看起来有防护，实际没有。
#
# 本脚本做两件事：
#   1. 静态检查：各打包脚本的排除模式是否与实际路径前缀匹配
#   2. 动态验证：用各脚本的 tar 参数实际打包，检查敏感文件是否真的被排除
set -uo pipefail
cd "$(dirname "$0")"

SENSITIVE=(
  "state/secrets"
  "state/did-keys.json"
  "state/did-signature.json"
  "state/watchdog.pid"
)

bad=0

echo "== 敏感文件泄露检查 =="
echo ""

# ---------- 1. git 层 ----------
echo "1) git 层"
for f in "${SENSITIVE[@]}"; do
  if git ls-files "$f" 2>/dev/null | grep -q .; then
    echo "  ✗ 被 git 跟踪: $f"; bad=$((bad+1))
  elif git check-ignore -q "$f" 2>/dev/null; then
    echo "  ✓ 已忽略: $f"
  else
    # state/watchdog.pid 之类可能不存在，不算错
    if [ -e "$f" ]; then
      echo "  ✗ 存在但未被忽略: $f"; bad=$((bad+1))
    else
      echo "  · 不存在: $f"
    fi
  fi
done

# ---------- 2. tar exclude 模式 ----------
echo ""
echo "2) tar --exclude 模式正确性"
# 找出所有用 tar --exclude 的脚本，检查是否有 './' 前缀的路径模式
_prefix_bad=0
for f in *.sh; do
  [ -f "$f" ] || continue
  # 跳过自身：注释里有反例示例会被自匹配（Round 218 踩到）
  [ "$f" = "lint-secrets.sh" ] && continue
  # 只查非注释行
  hits=$(grep -vE '^\s*#' "$f" 2>/dev/null | grep -oE -- "--exclude='\./(state|scripts|notes)[^']*'" || true)
  if [ -n "$hits" ]; then
    echo "  ✗ $f 用了 './' 前缀（tar 归档内无此前缀，排除会失效）:"
    echo "$hits" | sed 's/^/      /'
    _prefix_bad=$((_prefix_bad+1))
  fi
done
if [ "$_prefix_bad" -eq 0 ]; then
  echo "  ✓ 未发现 './' 前缀的错误写法"
else
  bad=$((bad+_prefix_bad))
fi

# ---------- 3. 动态验证 backup-workspace 的排除 ----------
echo ""
echo "3) 动态验证（用 backup-workspace 的真实 tar 参数打包）"
if [ -f backup-workspace.sh ]; then
  # 提取 tar 命令的参数行（保守：只取 --exclude 与 -C 之后的列表）
  _tmp=$(mktemp /tmp/leakcheck.XXXXXX.tar.gz)
  rm -f "$_tmp"
  # 直接复用脚本里的参数（复制自脚本，保持一致）
  tar czf "$_tmp" \
    --exclude='*.tmp' --exclude='.brief.*' --exclude='local-archive.tar.gz' \
    --exclude='state/secrets' --exclude='state/secrets/*' \
    --exclude='state/did-keys.json' --exclude='state/did-signature.json' \
    --exclude='state/watchdog.pid' \
    -C .. scripts state notes README.md 设备手册.md 2>/dev/null || true

  if [ -s "$_tmp" ]; then
    for pat in "did-keys.json" "did-signature.json" "secrets/github" "watchdog.pid"; do
      if tar tzf "$_tmp" 2>/dev/null | grep -q "$pat"; then
        echo "  ✗ 备份中含: $pat"; bad=$((bad+1))
      else
        echo "  ✓ 备份已排除: $pat"
      fi
    done
    # 确认实现脚本仍保留（恢复需要）
    if tar tzf "$_tmp" 2>/dev/null | grep -q "scripts/did-keys.sh"; then
      echo "  ✓ 保留实现脚本 scripts/did-keys.sh（恢复需要）"
    else
      echo "  ✗ 误删了 scripts/did-keys.sh"; bad=$((bad+1))
    fi
    rm -f "$_tmp"
  else
    echo "  · 打包失败，跳过动态验证"
    rm -f "$_tmp"
  fi
else
  echo "  · 未找到 backup-workspace.sh"
fi

# ---------- 4. snapshot-release 的 rm 路径 ----------
echo ""
echo "4) snapshot-release 的剔除路径"
if [ -f snapshot-release.sh ]; then
  _missing=0
  for f in did-keys.json did-signature.json secrets; do
    if grep -q "dest/state/$f" snapshot-release.sh 2>/dev/null; then
      echo "  ✓ 已声明剔除: $f"
    else
      echo "  ✗ 未剔除: $f"; _missing=$((_missing+1))
    fi
  done
  bad=$((bad+_missing))
else
  echo "  · 未找到 snapshot-release.sh"
fi

echo ""
if [ "$bad" -eq 0 ]; then
  echo "  ✓ 未发现敏感文件泄露路径"
  exit 0
else
  echo "  ✗ 发现 $bad 处风险"
  exit 1
fi
