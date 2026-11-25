#!/usr/bin/env bash
# 产物检查：验证"每轮必变的数据"是否真的在更新
#
# 为什么需要（Round 179）：
#   我在 D159/D164/D165/D167/D174 五次遇到"步骤 success 但产物没变"。
#   每次都是靠人工翻日志才发现。这个脚本把那个排查过程自动化。
#
# 与 verify.sh 的区别：
#   verify.sh 检查"系统功能是否正常"（脚本能跑、依赖齐全）
#   check-products.sh 检查"数据是否真的在流动"（产物是否新鲜）
set -uo pipefail
cd "$(dirname "$0")"

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-life}"

# 每个产物的最大容忍年龄（分钟）
MAX_AGE_JOURNAL=45       # 心跳：设计 30 分钟一轮
MAX_AGE_REFLECTIONS=45
MAX_AGE_DECISIONS=45
MAX_AGE_WATCHLOG=120     # 互监：每 20 轮 ≈1h

_rc=0
python3 - "$TOKEN" "$REPO" <<'PY' || _rc=$?
import sys, json, base64, urllib.request, urllib.error, datetime, os

token, repo = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)

CHECKS = [
    ("journal",         "state/journal.jsonl",         "心跳",   45),
    ("reflections",     "state/reflections.jsonl",     "自省",   45),
    ("chain-decisions", "state/chain-decisions.jsonl", "决策",   45),
    ("watch-log",       "state/watch-log.jsonl",       "互监",  120),
    ("nodes",           "state/nodes.json",            "节点",  120),
    # ⚠️ 自述曾静默过时 20 小时（Round 188）。它虽不是"每轮必变"，
    #    但一旦过时就会误导接手者，必须纳入检查。
    ("self-export",     "state/self-export.md",        "自述",  120),
]

def fetch(remote_path):
    if token:
        try:
            req = urllib.request.Request(
                f"https://api.github.com/repos/{repo}/contents/{remote_path}",
                headers={"Authorization": f"token {token}", "User-Agent": "alyx",
                         "Accept": "application/vnd.github+json", "Connection": "close"})
            d = json.loads(urllib.request.urlopen(req, timeout=25).read())
            raw = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
            return raw, "remote"
        except Exception:
            pass
    local = os.path.join("..", remote_path)
    if os.path.exists(local):
        return open(local, encoding="utf-8").read(), "local"
    return None, None

def newest_ts(raw, name):
    """从 jsonl / json / markdown 中取最新时间戳"""
    if name == "self-export":
        # markdown 里找 "导出时间：YYYY-MM-DDTHH:MM:SSZ"
        import re as _re
        m = _re.search(r"导出时间[：:]\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", raw)
        return m.group(1) if m else None
    if name == "nodes":
        try:
            d = json.loads(raw)
            stamps = []
            for k, v in d.items():
                if k == "_summary" or not isinstance(v, dict):
                    continue
                ls = v.get("last_seen")
                if ls:
                    stamps.append(ls)
            return max(stamps) if stamps else None
        except Exception:
            return None
    best = None
    for line in raw.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            ts = json.loads(line).get("ts")
        except Exception:
            continue
        if ts and (best is None or ts > best):
            best = ts
    return best

bad, ok = [], []
print(f"  {'产物':<10}{'条数':>6}  {'最新':<22}{'年龄':>8}  来源")
print("  " + "-" * 62)

for name, path, label, maxage in CHECKS:
    raw, src = fetch(path)
    if raw is None:
        print(f"  {label:<10}{'—':>6}  {'不存在':<22}{'—':>8}  ✗")
        bad.append((label, "产物不存在"))
        continue

    if name == "self-export":
        count = len(raw.splitlines())
    elif name == "nodes":
        count = len([k for k in json.loads(raw) if k != "_summary"])
    else:
        count = len([l for l in raw.strip().split("\n") if l.strip()])

    ts = newest_ts(raw, name)
    if not ts:
        print(f"  {label:<10}{count:>6}  {'无时间戳':<22}{'—':>8}  {src}")
        bad.append((label, "无时间戳"))
        continue

    try:
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        age = (now - t).total_seconds() / 60
    except Exception:
        bad.append((label, "时间戳格式错"))
        continue

    fresh = age <= maxage
    mark = "✓" if fresh else "✗"
    print(f"  {label:<10}{count:>6}  {ts:<22}{age:>7.0f}m  {src} {mark}")
    if not fresh:
        bad.append((label, f"{age:.0f} 分钟未更新（上限 {maxage}）"))
    else:
        ok.append(label)

print()
if bad:
    print(f"  ✗ {len(bad)} 项异常:")
    for label, why in bad:
        print(f"      {label}: {why}")
    print()
    print("  排查顺序：")
    print("    1. 这个数据走 API 还是 git？（走 git 会被 rebase 丢弃）")
    print("    2. 最近一次运行用的是哪个版本的工作流？（版本时间差）")
    print("    3. 该运行里对应步骤结论是什么？（success 不代表产物更新）")
    print("    4. 手动执行写入脚本，看是否成功（区分逻辑问题 vs 环境问题）")
    sys.exit(1)
else:
    print(f"  ✓ 全部 {len(ok)} 项产物正常")
    sys.exit(0)
PY

exit "${_rc:-0}"
