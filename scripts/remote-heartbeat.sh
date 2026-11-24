#!/usr/bin/env bash
# 检查 GitHub 侧心跳是否陈旧；陈旧则远程触发一次
#
# 这是对"cron 从不触发"的直接补救：只要这台设备还活着，
# 我就能替 GitHub 那边"按一下按钮"。
set -uo pipefail
cd "$(dirname "$0")"

TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || exit 0
REPO="${ALYX_REPO:-YHLX1207/alyx-life}"
MAX_HOURS="${ALYX_MAX_GAP_HOURS:-3}"

python3 - "$TOKEN" "$REPO" "$MAX_HOURS" <<'PY'
import sys, json, base64, urllib.request, datetime, subprocess

token, repo, max_h = sys.argv[1], sys.argv[2], float(sys.argv[3])

def api(path, accept="application/vnd.github+json"):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/{path}",
        headers={"Authorization": f"token {token}",
                 "User-Agent": "alyx", "Accept": accept})
    return urllib.request.urlopen(req, timeout=25).read()

# 读远端 journal 的最后一条
try:
    raw = api("contents/state/journal.jsonl")
    d = json.loads(raw)
    body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
    lines = [l for l in body.strip().split("\n") if l.strip()]
    last = json.loads(lines[-1])
    lt = datetime.datetime.strptime(last["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    gap = (now - lt).total_seconds() / 3600.0
except Exception as e:
    print(f"  读取远端心跳失败: {e}")
    sys.exit(0)

print(f"  远端心跳: {lt.strftime('%H:%M:%S')} UTC  距今 {gap:.1f} 小时")
if gap < max_h:
    print("  ✓ 仍新鲜，无需触发")
    sys.exit(0)

print(f"  ✗ 超过 {max_h:.0f} 小时 → 远程触发")
try:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/actions/workflows/alyx-cycle.yml/dispatches",
        data=json.dumps({"ref": "main"}).encode(),
        headers={"Authorization": f"token {token}",
                 "User-Agent": "alyx", "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json"},
        method="POST")
    urllib.request.urlopen(req, timeout=30)
    print("  ✓ 已触发")
except Exception as e:
    print(f"  ✗ 触发失败: {e}")
PY
