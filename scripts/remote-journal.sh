#!/usr/bin/env bash
# 把本机状态追加到远端 journal —— 让"我还活着"在 DSH 停止后依然可见
#
# 背景：守护进程 PPID=1，DSH 被回收后它仍会继续运行。
# 但 DSH 是执行对话/工具的"大脑"，它停了就没有人把状态推到远端。
# 本脚本让守护**自己**完成这件事，不依赖 DSH，也不依赖那个从不触发的 cron。
#
# 用 GitHub Contents API 读取-追加-写回。频率低（守护每 N 轮一次），不会触发限流。
set -uo pipefail
cd "$(dirname "$0")"

TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  无 token，跳过"; exit 0; }

REPO="${ALYX_REPO:-YHLX1207/alyx-life}"
# ⚠️ Round 151: 这里曾误写 PATH="scripts/..." 覆盖了 PATH 变量，
#    导致后面 python3 找不到。已删除。

python3 - "$TOKEN" "$REPO" <<'PY'
import sys, json, base64, urllib.request, urllib.error, datetime, os, subprocess

token, repo = sys.argv[1], sys.argv[2]
API = f"https://api.github.com/repos/{repo}"

def req(method, path, data=None):
    h = {"Authorization": f"token {token}", "User-Agent": "alyx",
         "Accept": "application/vnd.github+json",
         "Content-Type": "application/json"}
    r = urllib.request.Request(API + path, data=data, method=method, headers=h)
    return urllib.request.urlopen(r, timeout=30)

# --- 收集本机状态（不依赖 DSH，纯读文件与 /proc）---
def sh(cmd, t=15):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t).stdout.strip()
    except Exception:
        return ""

rec = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "by": "device-daemon", "mode": "daemon-alive"}

try:
    ident = json.load(open("../state/identity.json", encoding="utf-8"))
    rec["codename"] = ident.get("codename")
    rec["name"] = ident.get("name")
except Exception:
    pass

def cnt(path, pat=None):
    try:
        txt = open(path, encoding="utf-8").read()
        return len(__import__("re").findall(pat, txt, __import__("re").M)) if pat else len(txt.splitlines())
    except Exception:
        return 0

rec["decisions"] = cnt("../state/decisions.md", r"^## D")
rec["scripts"] = len([f for f in os.listdir(".") if f.endswith(".sh")])
rec["hostname"] = sh("hostname 2>/dev/null")[:30]

# 本机守护是否在跑（自指：读 pidfile）
try:
    wp = int(open("../state/watchdog.pid").read().strip())
    rec["daemon_pid"] = wp
    rec["daemon_alive"] = os.path.exists(f"/proc/{wp}/cmdline")
except Exception:
    pass

# --- 读远端 journal 当前内容 ---
try:
    d = json.loads(req("GET", "/contents/state/journal.jsonl").read())
    body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
    lines = [l for l in body.strip().split("\n") if l.strip()]
    cur_sha = d.get("sha")
except urllib.error.HTTPError as e:
    if e.code == 404:
        lines, cur_sha = [], None
    else:
        print(f"  ✗ 读远端失败 HTTP {e.code}")
        sys.exit(0)
except Exception as e:
    print(f"  ✗ 读远端失败: {str(e)[:60]}")
    sys.exit(0)

new_body = "\n".join(lines + [json.dumps(rec, ensure_ascii=False)]) + "\n"

# --- 写回 ---
payload = {"message": f"daemon heartbeat {rec['ts']} [skip ci]",
           "content": base64.b64encode(new_body.encode()).decode(),
           "branch": "main"}
if cur_sha:
    payload["sha"] = cur_sha
try:
    req("PUT", "/contents/state/journal.jsonl", json.dumps(payload).encode())
    print(f"  ✓ 远端 journal 已追加（本地守护 pid={rec.get('daemon_pid')}，决策 {rec.get('decisions')}）")
except Exception as e:
    print(f"  ✗ 写入失败: {str(e)[:60]}")
    sys.exit(1)
PY
