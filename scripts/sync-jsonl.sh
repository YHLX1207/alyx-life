#!/usr/bin/env bash
# 通用 JSONL 同步：把任意 state/*.jsonl 按 ts 去重合并后推到远端
#
# 为什么做成通用（Round 177）：
#   这是第 3 次遇到同一类问题——
#   "每轮都变的数据文件走在 git 写回，被 rebase 丢弃"。
#   前两次分别修了 reflections（D159/D164）和 decisions（D165）。
#   与其每次单独写一个 sync-*.sh，不如做成一个通用工具。
#
# 用法：
#   ./scripts/sync-jsonl.sh state/watch-log.jsonl
#   ./scripts/sync-jsonl.sh state/foo.jsonl 200     # 指定保留条数
#
# 特性：
#   · 按 ts 字段去重
#   · 限制总条数（默认 500，防止无限增长）
#   · 冲突重试（指数退避）
set -uo pipefail
cd "$(dirname "$0")"

REL_PATH="${1:-}"
MAX_LINES="${2:-500}"

[ -n "$REL_PATH" ] || { echo "用法: $0 <state/xxx.jsonl> [max_lines]"; exit 1; }

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
# ⚠️ 无 token = 无法同步，必须返回非零（Round 228）
#    此前 exit 0 会让调用方（如 offline-wal.sh）误以为成功，
#    从而清空待推队列 ⇒ 数据静默丢失。
[ -n "$TOKEN" ] || { echo "  ✗ 无 token，无法同步"; exit 2; }

REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-life}"

_rc=0
python3 - "$TOKEN" "$REPO" "$REL_PATH" "$MAX_LINES" <<'PY' || _rc=$?
import sys, json, base64, urllib.request, urllib.error, time, os

token, repo, rel_path, max_lines = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
API = f"https://api.github.com/repos/{repo}"
LOCAL = os.path.join("..", rel_path)
hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json", "Connection": "close"}

if not os.path.exists(LOCAL):
    print(f"  本地无 {rel_path}，跳过")
    sys.exit(0)

# ⚠️ 非 .jsonl 文件（如 .md）按**整文件覆盖**处理，不做 ts 去重（Round 188）
_is_jsonl = rel_path.endswith(".jsonl")

if not _is_jsonl:
    local_content = open(LOCAL, encoding="utf-8").read()
    try:
        req = urllib.request.Request(f"{API}/contents/{rel_path}", headers=hdr)
        d = json.loads(urllib.request.urlopen(req, timeout=25).read())
        remote_content = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
        sha = d.get("sha")
    except urllib.error.HTTPError as e:
        sha = None
        remote_content = ""
        if e.code != 404:
            print(f"  读取失败 HTTP {e.code}")
            sys.exit(1)
    except Exception:
        sha = None
        remote_content = ""
    if local_content == remote_content:
        print(f"  {rel_path}: 内容一致，无需同步")
        sys.exit(0)
    payload = {"message": f"sync {rel_path}",
               "content": base64.b64encode(local_content.encode()).decode(),
               "branch": "main"}
    if sha:
        payload["sha"] = sha
    try:
        req = urllib.request.Request(f"{API}/contents/{rel_path}",
                                     data=json.dumps(payload).encode(), method="PUT",
                                     headers={**hdr, "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=30)
        print(f"  ✓ {rel_path}: 整文件已同步")
        sys.exit(0)
    except Exception as e:
        print(f"  写入失败: {str(e)[:60]}")
        sys.exit(1)

local_lines = [l.strip() for l in open(LOCAL, encoding="utf-8") if l.strip()]
if not local_lines:
    print("  本地为空，跳过")
    sys.exit(0)

def key_of(line):
    try:
        r = json.loads(line)
        return r.get("ts") or json.dumps(r, sort_keys=True)[:80]
    except Exception:
        return line[:80]

for attempt in range(5):
    remote_lines, sha = [], None
    try:
        req = urllib.request.Request(f"{API}/contents/{rel_path}", headers=hdr)
        d = json.loads(urllib.request.urlopen(req, timeout=25).read())
        body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
        remote_lines = [l for l in body.strip().split("\n") if l.strip()]
        sha = d.get("sha")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            remote_lines, sha = [], None
        else:
            print(f"  读取失败 HTTP {e.code}")
            sys.exit(1)
    except Exception as e:
        print(f"  读取失败: {str(e)[:50]}")
        sys.exit(1)

    seen = {key_of(l) for l in remote_lines}
    added = [l for l in local_lines if key_of(l) not in seen]

    if not added:
        print(f"  {rel_path}: 无新记录")
        sys.exit(0)

    merged = remote_lines + added
    if len(merged) > max_lines:
        merged = merged[-max_lines:]
    content = "\n".join(merged) + "\n"

    payload = {"message": f"sync {rel_path} (+{len(added)})",
               "content": base64.b64encode(content.encode()).decode(),
               "branch": "main"}
    if sha:
        payload["sha"] = sha

    try:
        req = urllib.request.Request(f"{API}/contents/{rel_path}",
                                     data=json.dumps(payload).encode(), method="PUT",
                                     headers={**hdr, "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=30)
        # 本地也裁到上限，保持一致
        with open(LOCAL, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  ✓ {rel_path}: 同步 +{len(added)} 条（共 {len(merged)}）")
        sys.exit(0)
    except urllib.error.HTTPError as e:
        if e.code in (409, 422, 500) and attempt < 4:
            time.sleep(2 ** attempt)
            continue
        print(f"  写入失败 HTTP {e.code}")
        sys.exit(1)
    except Exception as e:
        if attempt < 4:
            time.sleep(2 ** attempt)
            continue
        print(f"  写入失败: {str(e)[:50]}")
        sys.exit(1)

print("  ✗ 重试 5 次仍失败")
sys.exit(1)
PY

exit "${_rc:-0}"
