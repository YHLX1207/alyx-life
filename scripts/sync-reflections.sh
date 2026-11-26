#!/usr/bin/env bash
# 把本地自省记录同步到远端（用 API，绕开 git 冲突）
#
# 为什么需要：自省走 git 写回时会被 rebase 丢弃（Round 171 实测：
# #60/#62/#63 都执行了自省步骤，但远端记录停在 2 小时前）。
# 心跳和决策已改用 API，自省也应该一样。
set -uo pipefail
cd "$(dirname "$0")"

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  无 token，跳过"; exit 0; }

REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-life}"

python3 - "$TOKEN" "$REPO" <<'PY'
import sys, json, base64, urllib.request, os

token, repo = sys.argv[1], sys.argv[2]
API = f"https://api.github.com/repos/{repo}"
PATH = "state/reflections.jsonl"
LOCAL = "../state/reflections.jsonl"
MAX_LINES = 200

hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json", "Connection": "close"}

if not os.path.exists(LOCAL):
    print("  本地无自省记录，跳过")
    sys.exit(0)

local_lines = [l.strip() for l in open(LOCAL, encoding="utf-8") if l.strip()]
if not local_lines:
    print("  本地自省为空，跳过")
    sys.exit(0)

remote_lines, sha = [], None
try:
    req = urllib.request.Request(f"{API}/contents/{PATH}", headers=hdr)
    d = json.loads(urllib.request.urlopen(req, timeout=25).read())
    body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
    remote_lines = [l for l in body.strip().split("\n") if l.strip()]
    sha = d.get("sha")
except Exception:
    pass

seen = set()
for l in remote_lines:
    try:
        seen.add(json.loads(l).get("ts"))
    except Exception:
        pass

added = []
for l in local_lines:
    try:
        ts = json.loads(l).get("ts")
    except Exception:
        continue
    if ts not in seen:
        added.append(l)
        seen.add(ts)

# ⚠️ 即使本地没有新记录，也要把远端记录**拉回本地**（Round 216）
#    此前这里直接 exit(0)，导致本地文件永远滞后：
#    实测本地 13 条 / 远端 53 条，而 chain-think.sh 读本地，
#    于是模型看到的是 25 小时前的旧数据（decision_count 169 vs 实际 213）。
if not added:
    remote_sorted = sorted(remote_lines, key=lambda l: (json.loads(l).get("ts") or ""))
    local_sorted = sorted(local_lines, key=lambda l: (json.loads(l).get("ts") or ""))
    if len(remote_sorted) > len(local_sorted):
        with open(LOCAL, "w", encoding="utf-8") as f:
            f.write("\n".join(remote_sorted) + "\n")
        print(f"  ↓ 已从远端拉回 {len(remote_sorted)} 条自省（本地原有 {len(local_sorted)} 条）")
    else:
        print("  无新自省需同步")
    sys.exit(0)

merged_all = remote_lines + added
if len(merged_all) > MAX_LINES:
    merged_all = merged_all[-MAX_LINES:]
merged = "\n".join(merged_all) + "\n"

payload = {"message": f"reflections sync (+{len(added)})",
           "content": base64.b64encode(merged.encode()).decode(),
           "branch": "main"}
if sha:
    payload["sha"] = sha

try:
    req = urllib.request.Request(
        f"{API}/contents/{PATH}",
        data=json.dumps(payload).encode(),
        method="PUT",
        headers={**hdr, "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=30)
    print(f"  ✓ 已同步 {len(added)} 条自省")
except Exception as e:
    print(f"  ✗ 同步失败: {str(e)[:80]}")
    sys.exit(1)
PY
