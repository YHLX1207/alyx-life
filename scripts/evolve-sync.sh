#!/usr/bin/env bash
# 进化提议协调：合并设备节点与 CI 节点的提议，解决冲突
#
# 为什么需要（Round 247）：
#   用户要求"分布式、自延伸拓展"。设备节点和 CI 节点都在运行进化机制，
#   但**没有协调机制确保两者的提议一致**。
#   如果两个节点对同一个模式提议了不同行动，它们会分叉 ⇒ 分布式不一致。
#
#   本脚本：
#   1. 读取本地提议（rule-proposals, action-proposals）
#   2. 读取远端提议（从 GitHub Contents API）
#   3. 合并：取并集（两边的提议都保留）
#   4. 解决冲突：同一 pattern/finding 有不同行动时，优先选有效的
#   5. 写回本地，并通过 push-merge 同步到远端
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-life}"

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  ✗ 无 token"; exit 2; }

python3 - "$STATE" "$REPO" "$TOKEN" <<'PY'
import sys, os, json, base64, urllib.request, urllib.error, datetime

state, repo, token = sys.argv[1:4]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
API = f"https://api.github.com/repos/{repo}"
hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json", "Connection": "close"}

def load_local(name):
    rows = []
    try:
        for line in open(os.path.join(state, name), encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    except FileNotFoundError:
        pass
    return rows

def load_remote(name):
    rows = []
    try:
        req = urllib.request.Request(f"{API}/contents/state/{name}", headers=hdr)
        d = json.loads(urllib.request.urlopen(req, timeout=25).read())
        body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
        for line in body.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print(f"  · 读取远端 {name} 失败 HTTP {e.code}")
    except Exception:
        pass
    return rows

def merge_by_key(local_rows, remote_rows, key_func):
    """合并两组提议，按 key 去重。冲突时保留 occurrences 多的。"""
    merged = {}
    for r in local_rows + remote_rows:
        k = key_func(r)
        if k is None:
            continue
        if k not in merged:
            merged[k] = r
        else:
            # 冲突：保留 occurrences 多的
            if r.get("occurrences", 0) > merged[k].get("occurrences", 0):
                merged[k] = r
    return list(merged.values())

# --- 合并规则提议 ---
local_rules = load_local("rule-proposals.jsonl")
remote_rules = load_remote("rule-proposals.jsonl")
merged_rules = merge_by_key(
    local_rules, remote_rules,
    lambda r: r.get("rule_id") or r.get("pattern"))

# --- 合并行动提议 ---
local_acts = load_local("action-proposals.jsonl")
remote_acts = load_remote("action-proposals.jsonl")
merged_acts = merge_by_key(
    local_acts, remote_acts,
    lambda r: r.get("action_id") or r.get("finding"))

# --- 效果数据（用于冲突解决）---
local_evals = load_local("chain-action-eval.jsonl")
remote_evals = load_remote("chain-action-eval.jsonl")
all_evals = local_evals + remote_evals

# 统计每个 (finding, action) 的有效性
eff_map = {}
for e in all_evals:
    f = e.get("finding", "")
    a = e.get("action", "")
    v = e.get("verdict", "")
    if f and a:
        eff_map.setdefault((f, a), {"effective": 0, "ineffective": 0})
        if v == "effective":
            eff_map[(f, a)]["effective"] += 1
        elif v == "ineffective":
            eff_map[(f, a)]["ineffective"] += 1

# 如果同一 finding 有多个行动提议，用有效性数据解决
finding_to_actions = {}
for a in merged_acts:
    f = a.get("finding", "")
    if f:
        finding_to_actions.setdefault(f, []).append(a)

resolved_acts = []
for f, acts in finding_to_actions.items():
    if len(acts) <= 1:
        resolved_acts.append(acts[0])
        continue
    # 多个行动 ⇒ 选最有效的
    best = None
    best_score = -1
    for a in acts:
        act = a.get("action", "")
        eff = eff_map.get((f, act), {"effective": 0, "ineffective": 0})
        score = eff["effective"] * 2 - eff["ineffective"]
        if score > best_score:
            best_score = score
            best = a
    resolved_acts.append(best)

# --- 写回本地 ---
os.makedirs(state, exist_ok=True)
if merged_rules:
    with open(os.path.join(state, "rule-proposals.jsonl"), "w", encoding="utf-8") as f:
        for r in merged_rules:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
if resolved_acts:
    with open(os.path.join(state, "action-proposals.jsonl"), "w", encoding="utf-8") as f:
        for a in resolved_acts:
            f.write(json.dumps(a, ensure_ascii=False) + "\n")

# --- 输出 ---
print(f"  规则提议: 本地 {len(local_rules)} + 远端 {len(remote_rules)} → 合并 {len(merged_rules)}")
print(f"  行动提议: 本地 {len(local_acts)} + 远端 {len(remote_acts)} → 合并 {len(resolved_acts)}")

# 冲突解决统计
conflicts = sum(1 for f, acts in finding_to_actions.items() if len(acts) > 1)
if conflicts > 0:
    print(f"  冲突解决: {conflicts} 个 finding 有多个行动，已按有效性优选")
else:
    print("  冲突解决: 无冲突")

print(f"  ✓ 已合并并写回本地")
PY
