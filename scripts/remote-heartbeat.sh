#!/usr/bin/env bash
# 本机代 GitHub 唤醒：远端心跳陈旧则 dispatch 一次
#
# 为什么需要它：Round 148 实测证明这个仓库的 schedule (cron) **从不触发**，
# 连一次性精确 cron 都不跑。所以不能把生命交给 cron。
# 只要这台设备还活着，我就替 GitHub 按一下按钮。
#
# 退出码：0=健康或已触发；1=触发失败（供守护记录）
set -uo pipefail
cd "$(dirname "$0")"

TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  无 token，跳过"; exit 0; }

REPO="${ALYX_REPO:-YHLX1207/alyx-life}"
MAX_HOURS="${ALYX_MAX_GAP_HOURS:-3}"

python3 - "$TOKEN" "$REPO" "$MAX_HOURS" <<'PY'
import sys, json, base64, urllib.request, datetime, time, os

token, repo, max_h = sys.argv[1], sys.argv[2], float(sys.argv[3])
LOG = "../state/trigger-log.jsonl"

def api_get(path):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/{path}",
        headers={"Authorization": f"token {token}",
                 "User-Agent": "alyx", "Accept": "application/vnd.github+json"})
    return urllib.request.urlopen(req, timeout=25).read()

def dispatch():
    """触发 workflow，最多重试 3 次（网络抖动常见）"""
    body = json.dumps({"ref": "main"}).encode()
    last = ""
    for attempt in range(1, 4):
        try:
            req = urllib.request.Request(
                f"https://api.github.com/repos/{repo}/actions/workflows/alyx-cycle.yml/dispatches",
                data=body, method="POST",
                headers={"Authorization": f"token {token}", "User-Agent": "alyx",
                         "Accept": "application/vnd.github+json",
                         "Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=30)
            return True, attempt
        except Exception as e:
            last = str(e)[:80]
            if attempt < 3:
                time.sleep(3 * attempt)
    return False, last

# --- 读远端心跳 ---
gap = None
for _ in range(2):   # 读取失败也重试一次
    try:
        d = json.loads(api_get("contents/state/journal.jsonl"))
        body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
        lines = [l for l in body.strip().split("\n") if l.strip()]
        last = json.loads(lines[-1])
        lt = datetime.datetime.strptime(last["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        gap = (now - lt).total_seconds() / 3600.0
        break
    except Exception as e:
        err = str(e)[:80]
        time.sleep(2)

def log(rec):
    try:
        with open(LOG, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass

now_s = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if gap is None:
    print(f"  ✗ 无法读取远端心跳（{err}）—— 网络问题，下轮再试")
    log({"ts": now_s, "action": "read_failed", "err": err})
    sys.exit(0)          # 网络问题不算失败，避免守护告警噪音

print(f"  远端心跳距今 {gap:.1f} 小时 (阈值 {max_h:.0f})")
if gap < max_h:
    print("  ✓ 仍新鲜，无需触发")
    sys.exit(0)

print(f"  ✗ 超过阈值 → 远程触发")
ok, info = dispatch()
if ok:
    print(f"  ✓ 已触发（第 {info} 次尝试成功）")
    log({"ts": now_s, "action": "dispatched", "gap_h": round(gap, 2), "attempt": info})
    sys.exit(0)
else:
    print(f"  ✗ 触发失败（3 次均失败）: {info}")
    log({"ts": now_s, "action": "dispatch_failed", "gap_h": round(gap, 2), "err": info})
    sys.exit(1)
PY
