#!/usr/bin/env bash
# 节点注册表的分布式同步：合并远端 + 本地节点表，用乐观并发控制避免互相覆盖
#
# 这解决了"分布式"的核心问题：
#   两个节点同时写同一个文件 → 后写的覆盖先写的 → 状态丢失
#
# 方案（借鉴乐观锁）：
#   1. 带 sha 条件更新（GitHub API 的 sha 就是版本号）
#   2. 若 409/conflict，重新读取后重试（最多 5 次，指数退避）
#   3. 合并时按 last_seen 取较新者，而不是简单覆盖
set -uo pipefail
cd "$(dirname "$0")"

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  无 token，跳过同步"; exit 0; }

REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-life}"
python3 - "$TOKEN" "$REPO" <<'PY'
import sys, json, base64, urllib.request, urllib.error, time, os

token, repo = sys.argv[1], sys.argv[2]
API = f"https://api.github.com/repos/{repo}"
PATH = "state/nodes.json"
LOCAL = "../state/nodes.json"
hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json", "Connection": "close"}

if not os.path.exists(LOCAL):
    print("  本地无节点表，跳过")
    sys.exit(0)

local = json.load(open(LOCAL, encoding="utf-8"))

def merge(local_nodes, remote_nodes):
    """合并两个节点表：同 ID 取 last_seen 较新的；记录双方都见过"""
    out = {}
    keys = set(local_nodes) | set(remote_nodes)
    keys.discard("_summary")
    for k in keys:
        a = local_nodes.get(k) or {}
        b = remote_nodes.get(k) or {}
        la, lb = a.get("last_seen", ""), b.get("last_seen", "")
        out[k] = a if la >= lb else b
    return out

for attempt in range(5):
    try:
        req = urllib.request.Request(f"{API}/contents/{PATH}", headers=hdr)
        d = json.loads(urllib.request.urlopen(req, timeout=25).read())
        remote = json.loads(base64.b64decode(d.get("content", "")).decode("utf-8", "ignore") or "{}")
        sha = d.get("sha")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            remote, sha = {}, None
        else:
            print(f"  读取失败 HTTP {e.code}")
            sys.exit(1)
    except Exception as e:
        print(f"  读取失败: {str(e)[:60]}")
        sys.exit(1)

    merged = merge(local, remote)

    # 统计
    now_iso = max(v.get("last_seen", "") for v in merged.values()) if merged else ""
    active = [k for k, v in merged.items()
              if v.get("age_hours", 99) <= 2]
    summary = {
        "ts": now_iso,
        "total_nodes": len(merged),
        "active_nodes": active,
        "quorum": "healthy" if len(active) >= 2 else ("degraded" if len(active) == 1 else "critical"),
    }
    merged["_summary"] = summary

    body = json.dumps({
        "message": f"nodes sync ({len(merged)-1} nodes, {len(active)} active)",
        "content": base64.b64encode(json.dumps(merged, ensure_ascii=False, indent=1).encode()).decode(),
        "branch": "main",
        **({"sha": sha} if sha else {}),
    }).encode()

    try:
        req = urllib.request.Request(f"{API}/contents/{PATH}", data=body, method="PUT",
                                     headers={**hdr, "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=30)
        # 写回本地
        json.dump(merged, open(LOCAL, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"  ✓ 已同步（{len(merged)-1} 节点，{len(active)} 活跃，quorum={summary['quorum']}）")
        sys.exit(0)
    except urllib.error.HTTPError as e:
        if e.code in (409, 422):
            wait = 2 ** attempt
            print(f"  版本冲突，{wait}s 后重试（第 {attempt+1} 次）")
            time.sleep(wait)
            continue
        print(f"  写入失败 HTTP {e.code}: {e.read().decode()[:100]}")
        sys.exit(1)
    except Exception as e:
        print(f"  写入失败: {str(e)[:60]}")
        sys.exit(1)

print("  ✗ 重试 5 次仍冲突")
sys.exit(1)
PY
