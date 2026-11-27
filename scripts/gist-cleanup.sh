#!/usr/bin/env bash
# Gist 清理：删除过期的站外备份 Gist，避免无限累积
#
# 为什么需要（Round 253）：
#   D250 把站外备份从 paste.rs 迁移到 dpaste + GitHub Gist。
#   但每次上传都新建一个 Gist ⇒ 无限累积。
#   实测已累积 17 个，长期运行会耗尽配额或难以管理。
#
# 策略：
#   · 只保留最近 N 个（默认 20）
#   · 按 created_at 排序，删除最旧的
#   · 只删除 description 含 "alyx" 的（避免误删用户的其它 Gist）
#   · 支持 dry-run
set -uo pipefail
cd "$(dirname "$0")"

KEEP="${1:-20}"
DRY="${2:-}"

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  ✗ 无 token"; exit 2; }

python3 - "$TOKEN" "$KEEP" "$DRY" <<'PY'
import sys, json, urllib.request, urllib.error, datetime

token, keep, dry = sys.argv[1], int(sys.argv[2]), (sys.argv[3] == "dry")
hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json", "Connection": "close"}

def api(url, method="GET"):
    req = urllib.request.Request(url, method=method, headers=hdr)
    return urllib.request.urlopen(req, timeout=30)

# 拉取全部 Gist（分页）
gists = []
page = 1
while page <= 5:
    try:
        d = json.loads(api(f"https://api.github.com/gists?per_page=100&page={page}").read())
    except Exception as e:
        print(f"  ✗ 拉取失败: {str(e)[:50]}")
        break
    if not isinstance(d, list) or not d:
        break
    gists.extend(d)
    if len(d) < 100:
        break
    page += 1

# 只处理 alyx 的 Gist
alyx = [g for g in gists if "alyx" in (g.get("description") or "").lower()]
print(f"  总共 {len(gists)} 个 Gist，其中 alyx {len(alyx)} 个")
print(f"  策略：保留最近 {keep} 个")

if len(alyx) <= keep:
    print(f"  ✓ 无需清理（{len(alyx)} ≤ {keep}）")
    sys.exit(0)

# 按创建时间排序（新的在前）
alyx.sort(key=lambda g: g.get("created_at", ""), reverse=True)
to_delete = alyx[keep:]

print(f"  将删除 {len(to_delete)} 个最旧的")
if dry:
    for g in to_delete[:10]:
        print(f"    [dry] {g.get('created_at','?')[:19]}  {g.get('id')}")
    print(f"  （dry-run，未实际删除）")
    sys.exit(0)

deleted = 0
failed = 0
for g in to_delete:
    gid = g.get("id")
    try:
        api(f"https://api.github.com/gists/{gid}", method="DELETE")
        deleted += 1
    except urllib.error.HTTPError as e:
        if e.code == 404:
            deleted += 1   # 已不存在
        else:
            failed += 1
    except Exception:
        failed += 1

print(f"  ✓ 已删除 {deleted} 个，失败 {failed} 个")
print(f"  剩余 alyx Gist: {len(alyx) - deleted}")
PY
