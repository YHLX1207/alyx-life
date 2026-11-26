#!/usr/bin/env bash
# 安全推送 JSONL：推送前先合并远端，防止本地旧版本覆盖远端新内容
#
# 缘起（Round 230）：
#   D223 时我把本地 self-thoughts.jsonl（3 条）直接 PUT 到远端，
#   **覆盖了 CI 刚写入的第 4 条**（17:45:12 的规则思考）。
#
#   提交历史清楚记录了这次覆盖：
#     17:45:12  sync state/self-thoughts.jsonl (+1)   ← CI 写入
#     17:47:44  D223: CI 首次独立产出思考（里程碑）    ← 我的本地版本覆盖
#
#   根因：直接 PUT 是**整体替换**，不会保留远端独有的记录。
#
# 本脚本强制走"读-合并-写"路径：
#   1. 读远端现有内容
#   2. 按 ts 字段合并本地与远端（去重）
#   3. 排序后整体写回（此时整体替换是安全的，因为已包含两边）
#   4. 写回本地，保持本地与远端一致
set -uo pipefail
cd "$(dirname "$0")"

REL="${1:-}"
[ -n "$REL" ] || { echo "用法: $0 <state/xxx.jsonl>"; exit 1; }

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-life}"
STATE_DIR="${ALYX_STATE_DIR:-../state}"

[ -n "$TOKEN" ] || { echo "  ✗ 无 token"; exit 2; }

python3 - "$TOKEN" "$REPO" "$REL" "$STATE_DIR" <<'PY'
import sys, os, json, base64, urllib.request, urllib.error

token, repo, rel, state_dir = sys.argv[1:5]
API = f"https://api.github.com/repos/{repo}"
LOCAL = os.path.join("..", rel)
hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json", "Connection": "close"}

if not os.path.exists(LOCAL):
    print(f"  ✗ 本地不存在 {rel}")
    sys.exit(1)

def key_of(line):
    try:
        return json.loads(line).get("ts") or line
    except Exception:
        return line

# 读本地
local_lines = [l.strip() for l in open(LOCAL, encoding="utf-8") if l.strip()]

# 读远端
remote_lines, sha = [], None
try:
    req = urllib.request.Request(f"{API}/contents/{rel}", headers=hdr)
    d = json.loads(urllib.request.urlopen(req, timeout=25).read())
    body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
    remote_lines = [l for l in body.strip().split("\n") if l.strip()]
    sha = d.get("sha")
except urllib.error.HTTPError as e:
    if e.code != 404:
        print(f"  ✗ 读远端失败 HTTP {e.code}")
        sys.exit(1)
except Exception as e:
    print(f"  ✗ 读远端失败: {str(e)[:50]}")
    sys.exit(1)

# 合并去重
seen = set()
merged = []
for l in remote_lines + local_lines:
    k = key_of(l)
    if k in seen:
        continue
    seen.add(k)
    merged.append(l)

# 按 ts 排序（有 ts 的按时间，无 ts 的保持原序放前面）
def sort_key(l):
    try:
        return json.loads(l).get("ts") or ""
    except Exception:
        return ""
merged.sort(key=sort_key)

added = len(merged) - len(remote_lines)
content = "\n".join(merged) + "\n"

remote_content = "\n".join(remote_lines) + "\n" if remote_lines else ""

if content == remote_content:
    # 远端内容已包含合并结果 ⇒ 不必写远端
    # ⚠️ 但本地可能比远端少（Round 230 变异测试发现）：
    #    此时必须**把远端内容写回本地**，否则本地会一直是旧的。
    local_content = "\n".join(local_lines) + "\n" if local_lines else ""
    if local_content != remote_content:
        with open(LOCAL, "w", encoding="utf-8") as f:
            f.write(remote_content)
        print(f"  ↓ {rel}: 本地补齐（{len(local_lines)} → {len(remote_lines)} 条，来自远端）")
    else:
        print(f"  {rel}: 无需同步（两边一致 {len(remote_lines)} 条）")
    sys.exit(0)

payload = {"message": f"safe-merge {rel} (+{max(0,added)})",
           "content": base64.b64encode(content.encode()).decode(),
           "branch": "main"}
if sha:
    payload["sha"] = sha

try:
    req = urllib.request.Request(f"{API}/contents/{rel}",
                                 data=json.dumps(payload).encode(), method="PUT",
                                 headers={**hdr, "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=30)
    # 同步本地
    with open(LOCAL, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  ✓ {rel}: 合并后 {len(merged)} 条（远端原有 {len(remote_lines)}，本地 {len(local_lines)}）")
except Exception as e:
    print(f"  ✗ 写入失败: {str(e)[:60]}")
    sys.exit(1)
PY
