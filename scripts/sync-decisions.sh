#!/usr/bin/env bash
# 把本地决策记录同步到远端（用 API，绕开 git 冲突）
#
# 为什么独立成文件：
#   1. 便于本地测试（不需要跑整个 workflow）
#   2. 避免 workflow 里内嵌复杂 Python 导致缩进/转义问题
#      （Round 170：内嵌的 rstrip("\n") 被 YAML 吃掉，导致 job 无法启动）
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
PATH = "state/chain-decisions.jsonl"
LOCAL = "../state/chain-decisions.jsonl"

hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json", "Connection": "close"}

if not os.path.exists(LOCAL):
    print("  本地无决策记录，跳过")
    sys.exit(0)

local_lines = []
for line in open(LOCAL, encoding="utf-8"):
    line = line.strip()
    if line:
        local_lines.append(line)

if not local_lines:
    print("  本地决策记录为空，跳过")
    sys.exit(0)

# 读远端
remote_lines, sha = [], None
try:
    req = urllib.request.Request(f"{API}/contents/{PATH}", headers=hdr)
    d = json.loads(urllib.request.urlopen(req, timeout=25).read())
    body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
    remote_lines = [l for l in body.strip().split("\n") if l.strip()]
    sha = d.get("sha")
except Exception:
    pass

# 按 ts 去重
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

if not added:
    print("  无新记录需同步")
    sys.exit(0)

merged = "\n".join(remote_lines + added) + "\n"
payload = {"message": f"decisions sync (+{len(added)})",
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
    print(f"  ✓ 已同步 {len(added)} 条决策记录")
except Exception as e:
    print(f"  ✗ 同步失败: {str(e)[:80]}")
    sys.exit(1)
PY
