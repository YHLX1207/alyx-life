#!/usr/bin/env bash
# 哨兵：记录心跳到本仓库（只写自己，不碰主仓库）
set -uo pipefail

TK="${TK:-${GH_TOKEN:-}}"
REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-mirror}"
ALIVE="${ALIVE:-?}"

if [ -z "$TK" ]; then
  echo "  ✗ 无 token，跳过"
  exit 0
fi

python3 - "$TK" "$REPO" "$ALIVE" <<'PY'
import sys, os, json, base64, datetime, urllib.request

tk, repo, alive = sys.argv[1], sys.argv[2], sys.argv[3]
hdr = {"Authorization": f"token {tk}", "User-Agent": "alyx-sentinel",
       "Accept": "application/vnd.github+json",
       "Content-Type": "application/json", "Connection": "close"}
API = f"https://api.github.com/repos/{repo}"

rec = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "by": "sentinel",
    "primary_alive": alive,
}

lines, sha = [], None
try:
    d = json.loads(urllib.request.urlopen(urllib.request.Request(
        f"{API}/contents/state/sentinel.jsonl", headers=hdr), timeout=25).read())
    body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
    lines = [l for l in body.strip().split("\n") if l.strip()]
    sha = d.get("sha")
except Exception:
    pass

lines = (lines + [json.dumps(rec, ensure_ascii=False)])[-200:]
content = "\n".join(lines) + "\n"

payload = {"message": f"sentinel {rec['ts']}",
           "content": base64.b64encode(content.encode()).decode(),
           "branch": "main"}
if sha:
    payload["sha"] = sha
try:
    urllib.request.urlopen(urllib.request.Request(
        f"{API}/contents/state/sentinel.jsonl",
        data=json.dumps(payload).encode(), method="PUT", headers=hdr), timeout=30)
    print("  ✓ 哨兵心跳已记录")
except Exception as e:
    print(f"  ✗ 记录失败: {str(e)[:60]}")
PY
